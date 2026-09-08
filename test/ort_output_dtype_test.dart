import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/image_translation/ort_capabilities.dart';
import 'package:venera/foundation/image_translation/ort_ffi.dart';

// ---------------------------------------------------------------------------
// Minimal protobuf writer + ONNX graph builder (offline, no fixtures, no
// network). Enough wire format to emit a single-Identity-node graph; the
// field numbers come from onnx.proto (ModelProto.ir_version=1,
// producer_name=2, graph=7, opset_import=8; GraphProto.node=1, name=2,
// input=11, output=12; NodeProto.input=1, output=2, op_type=4;
// ValueInfoProto.name=1, type=2; TypeProto.tensor_type=1;
// Tensor.elem_type=1, shape=2; TensorShapeProto.dim=1; Dimension.dim_value=1;
// OperatorSetIdProto.version=2). If a number were wrong, ORT would reject
// the model at session open — the test is its own parser check.
// ---------------------------------------------------------------------------

List<int> _varint(int v) {
  final out = <int>[];
  var x = v;
  while (true) {
    final b = x & 0x7f;
    x = x >>> 7;
    if (x == 0) {
      out.add(b);
      return out;
    }
    out.add(b | 0x80);
  }
}

List<int> _tag(int field, int wireType) => _varint((field << 3) | wireType);

List<int> _v(int field, int value) => [..._tag(field, 0), ..._varint(value)];

List<int> _s(int field, String value) {
  final b = utf8.encode(value);
  return [..._tag(field, 2), ..._varint(b.length), ...b];
}

List<int> _m(int field, List<int> msg) =>
    [..._tag(field, 2), ..._varint(msg.length), ...msg];

List<int> _typeProto(int elemType, List<int> dims) {
  final shape = <int>[];
  for (final d in dims) {
    shape.addAll(_m(1, _v(1, d))); // TensorShapeProto.dim[i].dim_value
  }
  final tensor = [..._v(1, elemType), ..._m(2, shape)];
  return _m(1, tensor);
}

List<int> _valueInfo(String name, int elemType, List<int> dims) =>
    [..._s(1, name), ..._m(2, _typeProto(elemType, dims))];

/// `out = Identity(in)` with the given element type and static shape.
/// elemType: ONNX TensorProto.DataType (FLOAT=1, INT64=7, FLOAT16=10).
List<int> buildIdentityModel({required int elemType, required List<int> dims}) {
  final node = [..._s(1, 'in'), ..._s(2, 'out'), ..._s(4, 'Identity')];
  final graph = <int>[
    ..._m(1, node),
    ..._s(2, 'ort_dtype_gate'),
    ..._m(11, _valueInfo('in', elemType, dims)),
    ..._m(12, _valueInfo('out', elemType, dims)),
  ];
  return <int>[
    ..._v(1, 9), // ir_version 9 (supported by the 1.17..1.22 runtimes here)
    ..._s(2, 'venera-test'),
    ..._m(8, _v(2, 17)), // opset_import: ai.onnx v17 (Identity: any tensor)
    ..._m(7, graph),
  ];
}

// ---------------------------------------------------------------------------
// Runtime discovery. OrtRuntime.open looks for onnxruntime.dll next to the
// test binary and on PATH; under flutter_tester neither holds it, so the
// test points kernel32.SetDllDirectoryW at a repo-cached copy first. If no
// runtime is reachable the ORT-backed groups report as skipped — that is
// the honest boundary of "测不到".
// ---------------------------------------------------------------------------

Directory? _packageRoot() {
  String j(List<String> parts) => parts.join(Platform.pathSeparator);
  var d = Directory.current;
  while (true) {
    final marker = File(
      j([d.path, 'lib', 'foundation', 'image_translation', 'ort_ffi.dart']),
    );
    if (marker.existsSync() &&
        File(j([d.path, 'pubspec.yaml'])).existsSync()) {
      return d;
    }
    final parent = d.parent;
    if (parent.path == d.path) return null;
    d = parent;
  }
}

/// Windows: add [dir] to LoadLibrary's search path before ORT is opened.
bool _setDllDirectory(String dir) {
  try {
    final kernel32 = DynamicLibrary.open('kernel32.dll');
    final setDllDirectory = kernel32.lookupFunction<
      Int32 Function(Pointer<Utf8>),
      int Function(Pointer<Utf8>)
    >('SetDllDirectoryW');
    final p = dir.toNativeUtf8();
    final ok = setDllDirectory(p) != 0;
    calloc.free(p);
    return ok;
  } catch (_) {
    return false;
  }
}

/// Returns a runtime version string when ORT opened, null otherwise.
String? _tryOpenOrt() {
  try {
    if (Platform.isWindows) {
      final root = _packageRoot();
      if (root == null) return null;
      String j(List<String> parts) =>
          parts.join(Platform.pathSeparator);
      final candidates = [
        j([root.path, '.cache', 'ort', 'test_install']),
        j([root.path, 'build', 'windows', 'x64', 'runner', 'Release']),
      ];
      for (final dir in candidates) {
        if (File(j([dir, 'onnxruntime.dll'])).existsSync() &&
            _setDllDirectory(dir)) {
          break;
        }
      }
    }
    OrtRuntime.open();
    return OrtRuntime.runtimeVersion();
  } catch (_) {
    return null;
  }
}

Matcher throwsDtypeGate(int numericType, String outputName) => throwsA(
  isA<OrtFfiException>().having(
    (e) => e.message,
    'message',
    'unexpected output dtype $numericType for $outputName',
  ).having((e) => e.kind, 'kind', OrtFfiErrorKind.invalidGraph),
);

void main() {
  final ortVersion = _tryOpenOrt();
  final ortReady = ortVersion != null;

  final modelDir = Directory.systemTemp.createTempSync('venera_ort_dtype');
  String j(List<String> parts) => parts.join(Platform.pathSeparator);

  // Float32 model, shape [1, 2, 3]: rows of the argmax grid.
  final fp32Path = j([modelDir.path, 'identity_f32_1_2_3.onnx']);
  File(fp32Path).writeAsBytesSync(
    buildIdentityModel(elemType: 1, dims: [1, 2, 3]),
  );
  // fp16 model, shape [3] — the exact D-11 scenario (no keep_io_types).
  final fp16Path = j([modelDir.path, 'identity_f16_3.onnx']);
  File(fp16Path).writeAsBytesSync(buildIdentityModel(elemType: 10, dims: [3]));
  // int64 model, shape [2] — a second non-fp32 dtype (numeric 7).
  final i64Path = j([modelDir.path, 'identity_i64_2.onnx']);
  File(i64Path).writeAsBytesSync(buildIdentityModel(elemType: 7, dims: [2]));

  final fp32Data = Float32List.fromList(
    [0.1, 2.5, -1.0, 7.0, 3.2, 7.1],
  ); // rows → argmax [1, 2]

  Float32List in32() => fp32Data;
  Map<String, OrtInput> in32Inputs() => {
    'in': OrtInput.float32(in32(), [1, 2, 3]),
  };

  OrtFfiSession openSession(String path) {
    final s = OrtFfiSession.open(path, ep: OrtEpKind.cpu);
    addTearDown(s.close);
    return s;
  }

  tearDownAll(() {
    try {
      modelDir.deleteSync(recursive: true);
    } catch (_) {}
  });

  group('dtype gate before float32 reads (D-11)', () {
    test('fp32 output passes run(), round-trips identity data, '
        'OrtOutput.elementType is the queried type', () {
      final session = openSession(fp32Path);
      final outs = session.run(in32Inputs());
      final out = outs['out']!;
      expect(out.shape, [1, 2, 3]);
      expect(out.elementType, OrtRuntime.typeFloat32);
      expect(out.data, fp32Data);
    }, skip: !ortReady);

    test('fp16 output is refused on every read path with the numeric dtype '
        '(10) in the message', () {
      final session = openSession(fp16Path);
      final inputs = {
        'in': OrtInput.float16(
          Uint16List.fromList([0x3C00, 0x4000, 0x4200]),
          [3],
        ),
      };
      expect(() => session.run(inputs), throwsDtypeGate(10, 'out'));
      expect(
        () => session.runArgmaxGrid(
          inputs,
          'out',
          batch: 1,
          steps: 1,
          classes: 3,
        ),
        throwsDtypeGate(10, 'out'),
      );
      expect(
        () => session.runArgmaxLastPosition(inputs, 'out', batch: 1, seqLen: 1),
        throwsDtypeGate(10, 'out'),
      );
      expect(
        () => session.runInPlace<double>(
          inputs,
          'out',
          (ptr, shape, n) => ptr[0],
        ),
        throwsDtypeGate(10, 'out'),
      );
      final arena = OrtTensorArena();
      addTearDown(arena.free);
      expect(
        () => session.runInto(
          inputs,
          outputName: 'out',
          dst: arena,
          offset: 0,
        ),
        throwsDtypeGate(10, 'out'),
      );
    }, skip: !ortReady);

    test('int64 output is refused too (numeric dtype 7), proving the check '
        'reads the real element type instead of assuming float32', () {
      final session = openSession(i64Path);
      final inputs = {
        'in': OrtInput.int64(Int64List.fromList([5, -2]), [2]),
      };
      expect(() => session.run(inputs), throwsDtypeGate(7, 'out'));
      expect(
        () => session.runArgmaxLastRow(inputs, 'out'),
        throwsDtypeGate(7, 'out'),
      );
    }, skip: !ortReady);
  });

  group('runArgmaxGrid classes cross-check (task 2, option b)', () {
    final warnings = <String>[];
    setUp(() {
      warnings.clear();
      OrtFfiSession.classMismatchWarning = (title, content) =>
          warnings.add('$title|$content');
    });
    tearDown(() => OrtFfiSession.classMismatchWarning = null);

    test('mismatch fires the sink with model vs dict counts, decoding '
        'still uses the real shape.last', () {
      final session = openSession(fp32Path);
      final result = session.runArgmaxGrid(
        in32Inputs(),
        'out',
        batch: 1,
        steps: 2,
        classes: 9, // dict pretends to have 9 rows; model has 3
      );
      expect(warnings, hasLength(1));
      expect(warnings.single, contains('model emits 3 classes'));
      expect(warnings.single, contains('dict has 9 rows'));
      expect(warnings.single, contains('"out"'));
      expect(result.toList(), [1, 2]);
    }, skip: !ortReady);

    test('matching classes stay silent', () {
      final session = openSession(fp32Path);
      final result = session.runArgmaxGrid(
        in32Inputs(),
        'out',
        batch: 1,
        steps: 2,
        classes: 3,
      );
      expect(warnings, isEmpty);
      expect(result.toList(), [1, 2]);
    }, skip: !ortReady);

    test('last-position decoding unaffected by the gate on fp32', () {
      final session = openSession(fp32Path);
      final result = session.runArgmaxLastPosition(
        in32Inputs(),
        'out',
        batch: 1,
        seqLen: 2,
      );
      // Last row is [7.0, 3.2, 7.1] → index 2.
      expect(result.toList(), [2]);
    }, skip: !ortReady);

    test('without a wired sink the mismatch still surfaces via stdout '
        '(fallback path; Log.warning wiring lives in the worker layer)', () {
      OrtFfiSession.classMismatchWarning = null;
      final session = openSession(fp32Path);
      expect(
        () => session.runArgmaxGrid(
          in32Inputs(),
          'out',
          batch: 1,
          steps: 2,
          classes: 12,
        ),
        prints(contains('WARNING [OCR Rec] runArgmaxGrid("out")')),
      );
    }, skip: !ortReady);
  });

  // No runtime needed: the index constant must equal what the cached
  // onnxruntime_c_api.h header actually says. Re-derives the OrtApi member
  // order exactly like tool/gen_ort_api.dart, so a hand-edited
  // ort_api_indices.g.dart (or a stale .g file after a runtime upgrade) is
  // caught here. Skips itself when the header is not cached.
  group('generator index integrity (no native runtime needed)', () {
    final root = _packageRoot();
    final headerPath = root == null
        ? null
        : j([root.path, '.cache', 'ort', 'headers', 'onnxruntime_c_api.h']);
    final header = headerPath == null ? null : File(headerPath);

    test('OrtApiIdx.getTensorElementType matches the header-derived order', () {
      final body = RegExp(
        r'struct OrtApi \{(.*?)\};',
        dotAll: true,
      ).firstMatch(header!.readAsStringSync())!;
      final entries = <String>[];
      final p1 = RegExp(r'\(\s*ORT_API_CALL\s*\*\s*([A-Za-z0-9_]+)\s*\)');
      final p2 = RegExp(r'ORT_API2_STATUS\s*\(\s*([A-Za-z0-9_]+)\s*,');
      final p3 = RegExp(r'ORT_CLASS_RELEASE\s*\(\s*([A-Za-z0-9_]+)\s*\)');
      for (final line in body.group(1)!.split('\n')) {
        final m1 = p1.firstMatch(line);
        if (m1 != null) {
          entries.add(m1.group(1)!);
          continue;
        }
        final m2 = p2.firstMatch(line);
        if (m2 != null) {
          entries.add(m2.group(1)!);
          continue;
        }
        final m3 = p3.firstMatch(line);
        if (m3 != null) {
          entries.add('Release${m3.group(1)!}');
        }
      }
      final derived = entries.indexOf('GetTensorElementType');
      expect(derived, greaterThanOrEqualTo(0), reason: 'header parsing failed');
      expect(OrtApiIdx.getTensorElementType, derived);
      // Anchors shared with the generator's self-check, so the parse is not
      // silently misaligned by one entry.
      expect(entries.indexOf('CreateStatus'), 0);
      expect(entries.indexOf('Run'), 9);
      expect(entries.indexOf('CreateTensorWithDataAsOrtValue'), 49);
    }, skip: header == null || !header.existsSync());

    test('the fp32 constant pinned by the gate is ONNX '
        'ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT == 1', () {
      expect(OrtRuntime.typeFloat32, 1);
    });
  });
}
