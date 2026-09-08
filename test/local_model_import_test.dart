/// Tests for the Phase 10 local-import gate (§7.2.2, decision R-3).
///
/// Fixtures are minimal hand-built ONNX Protobuf files (a wire-format
/// writer lives right in this file): the validator must reject bad local
/// imports with human-readable reasons, and must never require real
/// hundreds-of-megabytes models or an ORT session to make up its mind
/// (red line R3).
library;

import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/image_translation/local_model_import.dart';
import 'package:venera/foundation/image_translation/ort_ffi.dart'
    show OrtRuntime;
import 'package:venera/foundation/image_translation/translation_models.dart';
import 'package:venera/foundation/image_translation/translation_worker.dart'
    show loadCharset;

// ===========================================================================
// Minimal protobuf wire writer for ONNX metadata fixtures
// ===========================================================================

List<int> _varint(int v) {
  final out = <int>[];
  while (true) {
    final b = v & 0x7f;
    v = v >>> 7;
    if (v == 0) {
      out.add(b);
      return out;
    }
    out.add(b | 0x80);
  }
}

List<int> _key(int field, int wireType) => _varint((field << 3) | wireType);

List<int> _bytesField(int field, List<int> payload) => [
  ..._key(field, 2),
  ..._varint(payload.length),
  ...payload,
];

List<int> _stringField(int field, String s) =>
    _bytesField(field, utf8.encode(s));

List<int> _intField(int field, int v) => [..._key(field, 0), ..._varint(v)];

/// A shape dim: int = static value, String = dim_param, null = plain dynamic.
List<int> _dim(Object? d) {
  if (d is int) return _intField(1, d);
  if (d is String && d.isNotEmpty) return _stringField(2, d);
  return const [];
}

List<int> _valueInfo((String, int, List<Object?>) t) {
  final (name, elemType, dims) = t;
  final shape = <int>[];
  for (final d in dims) {
    shape.addAll(_bytesField(1, _dim(d)));
  }
  final tensorType = _bytesField(1, [
    ..._intField(1, elemType),
    ..._bytesField(2, shape),
  ]);
  final type = _bytesField(2, tensorType);
  return [..._stringField(1, name), ...type];
}

/// ModelProto { ir_version = 8; graph = GraphProto { output=11…, input=12… } }
List<int> onnxModelBytes({
  required List<(String, int, List<Object?>)> inputs,
  required List<(String, int, List<Object?>)> outputs,
}) {
  final graph = <int>[];
  for (final o in outputs) {
    graph.addAll(_bytesField(11, _valueInfo(o)));
  }
  for (final i in inputs) {
    graph.addAll(_bytesField(12, _valueInfo(i)));
  }
  return [..._intField(1, 8), ..._bytesField(7, graph)];
}

const _f32 = OnnxElementType.float;
const _i64 = OnnxElementType.int64;
const _f16 = OnnxElementType.float16;

/// A PP-OCR recognition graph outputting exactly [classes] CTC classes.
List<int> recModelBytes(int classes, {int? batchDim}) => onnxModelBytes(
  inputs: [('x', _f32, [batchDim, 3, 48, 'width'])],
  outputs: [('softmax', _f32, ['batch', 'sequence', classes])],
);

List<int> detModelBytes({int? outputRank4Channels}) => onnxModelBytes(
  inputs: [('x', _f32, [null, 3, null, null])],
  outputs: [
    (
      'sigmoid',
      _f32,
      outputRank4Channels == null
          ? [null, 1, null, null]
          : [null, outputRank4Channels, null, null],
    ),
  ],
);

// ===========================================================================
// Fixture filesystem helpers
// ===========================================================================

late Directory dataDir;

Directory compDir(ModelComponent c) =>
    Directory(c.directory)..createSync(recursive: true);

void writeBytes(ModelComponent c, String name, List<int> bytes) {
  File('${compDir(c).path}${Platform.pathSeparator}$name')
    ..createSync(recursive: true)
    ..writeAsBytesSync(bytes);
}

void writeText(ModelComponent c, String name, String text) {
  File('${compDir(c).path}${Platform.pathSeparator}$name')
    ..createSync(recursive: true)
    ..writeAsStringSync(text);
}

String pathOf(ModelComponent c, String name) =>
    '${compDir(c).path}${Platform.pathSeparator}$name';

/// A healthy ocr_zh install: 3 dictionary lines + a rec model with C = 3 + 2.
void installGoodOcrZh() {
  writeText(TranslationModels.ocrZh, 'dict.txt', 'a\nb\nc\n');
  writeBytes(TranslationModels.ocrZh, 'rec.onnx', recModelBytes(5));
}

void main() {
  setUp(() {
    dataDir = Directory.systemTemp.createTempSync('local_model_import_');
    App.dataPath = dataDir.path;
    TranslationModels.clearVerdictsForTest();
  });

  tearDown(() {
    if (dataDir.existsSync()) dataDir.deleteSync(recursive: true);
  });

  group('human-readable verdicts for bad local files (§7.2.2 ④)', () {
    test('missing file → says what is missing and where', () async {
      final v = await validateComponent(TranslationModels.ocrZh);
      expect(v.ok, isFalse);
      expect(v.state, ModelState.invalid);
      expect(v.reason, contains('"rec.onnx" is missing'));
      expect(v.reason, contains('translation_models'));
    });

    test('empty file (interrupted copy) → says so in words', () async {
      writeText(TranslationModels.ocrZh, 'dict.txt', 'a\nb\nc\n');
      writeBytes(TranslationModels.ocrZh, 'rec.onnx', const []);
      final v = await validateComponent(TranslationModels.ocrZh);
      expect(v.ok, isFalse);
      expect(v.reason, contains('"rec.onnx" is empty (0 bytes)'));
    });

    test(
      'dict line count mismatch → names C, N and the N+2 rule',
      () async {
        writeText(TranslationModels.ocrZh, 'dict.txt', 'a\nb\nc\n');
        writeBytes(TranslationModels.ocrZh, 'rec.onnx', recModelBytes(99));
        final v = await validateComponent(TranslationModels.ocrZh);
        expect(v.ok, isFalse);
        expect(v.state, ModelState.invalid);
        expect(v.reason, contains('99 classes'));
        expect(v.reason, contains('has 3 lines'));
        expect(v.reason, contains('3 + 2 = 5'));
      },
    );

    test('non-ONNX bytes in a .onnx slot (HTML error page) → plain words', () async {
      writeText(TranslationModels.ocrZh, 'dict.txt', 'a\nb\nc\n');
      writeBytes(
        TranslationModels.ocrZh,
        'rec.onnx',
        utf8.encode('<html><body>404 Not Found</body></html>'),
      );
      final v = await validateComponent(TranslationModels.ocrZh);
      expect(v.ok, isFalse);
      expect(v.reason, contains('does not look like an ONNX model'));
    });

    test('wrong-shaped detector / recognition graphs are refused', () async {
      // A detector whose output is not a single-channel map.
      writeBytes(
        TranslationModels.detector,
        'det.onnx',
        detModelBytes(outputRank4Channels: 3),
      );
      var v = await validateComponent(TranslationModels.detector);
      expect(v.ok, isFalse);
      expect(v.reason, contains('single-channel probability map'));

      // A detector graph (rank-4 map output) dropped into the rec slot.
      final bad = ModelComponent(
        id: 'ocr_ko',
        approxSizeBytes: 1,
        kind: ModelKind.rec,
        files: const [ModelFile('rec.onnx', ['x']), ModelFile('dict.txt', ['y'])],
      );
      writeText(bad, 'dict.txt', 'a\nb\nc\n');
      writeBytes(bad, 'rec.onnx', detModelBytes());
      v = await validateComponent(bad);
      expect(v.ok, isFalse);
      expect(v.reason, contains('[batch,sequence,classes]'));
    });

    test('fp16 output on a CPU component is refused (D-11 offline half)', () async {
      final comp = ModelComponent(
        id: 'ocr_en',
        approxSizeBytes: 1,
        kind: ModelKind.rec,
        files: const [ModelFile('rec.onnx', ['x']), ModelFile('dict.txt', ['y'])],
      );
      writeText(comp, 'dict.txt', 'a\nb\nc\n');
      writeBytes(
        comp,
        'rec.onnx',
        onnxModelBytes(
          inputs: [('x', _f32, [null, 3, 48, null])],
          outputs: [('softmax', _f16, [null, null, 5])],
        ),
      );
      final v = await validateComponent(comp);
      expect(v.ok, isFalse);
      expect(v.reason, contains('float16'));
    });

    test('fixed batch=1 passes but warns (usable, just slow)', () async {
      writeText(TranslationModels.ocrZh, 'dict.txt', 'a\nb\nc\n');
      writeBytes(
        TranslationModels.ocrZh,
        'rec.onnx',
        recModelBytes(5, batchDim: 1),
      );
      final v = await validateComponent(TranslationModels.ocrZh);
      expect(v.ok, isTrue);
      expect(
        v.warnings,
        contains(contains('batch dimension fixed to 1')),
      );
    });
  });

  group('the +2 of C == N + 2 is loadCharset itself (verified, not copied)', () {
    test('model matching loadCharset(dict).length always passes', () async {
      writeText(TranslationModels.ocrZh, 'dict.txt', 'a\nb\nc\nd\ne\n');
      final dictPath = pathOf(TranslationModels.ocrZh, 'dict.txt');
      final classes = loadCharset(dictPath).length; // blank + 5 + space = 7
      writeBytes(TranslationModels.ocrZh, 'rec.onnx', recModelBytes(classes));
      final v = await validateComponent(TranslationModels.ocrZh);
      expect(v.ok, isTrue, reason: v.reason);
    });

    test('a blank line inside the dict still counts as a line', () async {
      // readAsLines maps it to ' ' (loadCharset): 'a',''  ,'b','c' = 4 lines,
      // N + 2 = 6. A trailing empty line is not counted by readAsLines.
      writeText(TranslationModels.ocrZh, 'dict.txt', 'a\n\nb\nc\n');
      writeBytes(TranslationModels.ocrZh, 'rec.onnx', recModelBytes(6));
      final v = await validateComponent(TranslationModels.ocrZh);
      expect(v.ok, isTrue, reason: v.reason);
    });
  });

  group('dictFrom shared dictionaries', () {
    test('high tier is checked against the base component dict', () async {
      installGoodOcrZh();
      writeBytes(TranslationModels.ocrZhHigh, 'rec.onnx', recModelBytes(5));
      final v = await validateComponent(TranslationModels.ocrZhHigh);
      expect(v.ok, isTrue, reason: v.reason);
    });

    test('missing shared dict fails with "shared from" wording', () async {
      writeBytes(TranslationModels.ocrZhHigh, 'rec.onnx', recModelBytes(5));
      final v = await validateComponent(TranslationModels.ocrZhHigh);
      expect(v.ok, isFalse);
      expect(v.reason, contains('dict.txt'));
      expect(v.reason, contains("shared from 'ocr_zh'"));
    });

    test('base dict replacement re-checks the high-tier pair', () async {
      installGoodOcrZh();
      writeBytes(TranslationModels.ocrZhHigh, 'rec.onnx', recModelBytes(5));
      final first = await validateComponent(TranslationModels.ocrZhHigh);
      expect(first.ok, isTrue, reason: first.reason);
      // Swap the shared dictionary for a longer one: the stale verdict on
      // ocr_zh_high must not survive the fingerprint change.
      writeText(TranslationModels.ocrZh, 'dict.txt', 'a\nb\nc\nd\ne\n');
      final v = await validateComponent(TranslationModels.ocrZhHigh);
      expect(v.ok, isFalse);
      expect(v.reason, contains('5 + 2 = 7'));
    });
  });

  group('manga-ocr (encoder + decoder + vocab)', () {
    List<int> mangaEncoderBytes() => onnxModelBytes(
      inputs: [('pixel_values', _f32, [null, 3, 224, 224])],
      outputs: [('hidden', _f32, [null, 196, 768])],
    );

    List<int> mangaDecoderBytes(int vocabSize) => onnxModelBytes(
      inputs: [
        ('input_ids', _i64, [null, null]),
        ('encoder_hidden_states', _f32, [null, 196, 768]),
      ],
      outputs: [('logits', _f32, [null, null, vocabSize])],
    );

    test('consistent decoder + vocab passes', () async {
      writeBytes(TranslationModels.ocrJa, 'encoder.onnx', mangaEncoderBytes());
      writeBytes(TranslationModels.ocrJa, 'decoder.onnx', mangaDecoderBytes(6));
      writeText(TranslationModels.ocrJa, 'vocab.txt', '[PAD]\n[UNK]\n[START]\n[EOS]\nあ\nい\n');
      final v = await validateComponent(TranslationModels.ocrJa);
      expect(v.ok, isTrue, reason: v.reason);
    });

    test('decoder size ≠ vocab lines is refused by number', () async {
      writeBytes(TranslationModels.ocrJa, 'encoder.onnx', mangaEncoderBytes());
      writeBytes(TranslationModels.ocrJa, 'decoder.onnx', mangaDecoderBytes(6));
      writeText(TranslationModels.ocrJa, 'vocab.txt', '[PAD]\n[UNK]\n[START]\n[EOS]\nあ\n');
      final v = await validateComponent(TranslationModels.ocrJa);
      expect(v.ok, isFalse);
      expect(v.reason, contains('the decoder outputs 6 token classes'));
      expect(v.reason, contains('has 5 lines'));
    });

    test('a rec model dropped on encoder.onnx fails the 224 check', () async {
      writeBytes(TranslationModels.ocrJa, 'encoder.onnx', recModelBytes(5));
      final v = await validateComponent(TranslationModels.ocrJa);
      expect(v.ok, isFalse);
      expect(v.reason, contains('[batch,3,224,224]'));
    });
  });

  group('state ledger: isInstalled / workerPaths only accept sound files', () {
    test('never-checked legacy install stays usable (present branch)', () {
      // The exact shape of an existing 12-asset install: correct files are
      // already on disk, nothing has run validateComponent (fresh ledger).
      // The synchronous FFI-free gate must let them through — "must not
      // break existing installs".
      installGoodOcrZh();
      expect(TranslationModels.ocrZh.isInstalled, isTrue);
      expect(TranslationModels.stateOf(TranslationModels.ocrZh),
          ModelState.present);
    });

    test('broken drop-in is refused on sight, before inference', () {
      writeText(TranslationModels.ocrZh, 'dict.txt', 'a\nb\nc\n');
      writeBytes(TranslationModels.ocrZh, 'rec.onnx', recModelBytes(42));
      // No one called validateComponent: isInstalled itself must catch it.
      expect(TranslationModels.ocrZh.isInstalled, isFalse);
      expect(TranslationModels.stateOf(TranslationModels.ocrZh),
          ModelState.invalid);
      expect(
        TranslationModels.validationDetail(TranslationModels.ocrZh),
        contains('42 classes'),
      );
    });

    test('workerPaths drops invalid components and re-admits fixed ones', () {
      installGoodOcrZh();
      writeBytes(TranslationModels.detector, 'det.onnx', detModelBytes());
      var paths = TranslationModels.workerPaths(
        tier: ModelTier.fast,
        gpuEpActive: false,
      );
      expect(paths.recModels['zh'], isNotNull);
      expect(paths.recDicts['zh'], isNotNull);

      // Corrupt the dictionary out from under the app (network-drive
      // overwrite): the fingerprint changes, the gate re-fires.
      writeText(TranslationModels.ocrZh, 'dict.txt', 'x\ny\n');
      paths = TranslationModels.workerPaths(
        tier: ModelTier.fast,
        gpuEpActive: false,
      );
      expect(paths.recModels.containsKey('zh'), isFalse);
      expect(TranslationModels.ocrZh.isInstalled, isFalse);

      // Repair it: usable again, no restart needed.
      installGoodOcrZh();
      paths = TranslationModels.workerPaths(
        tier: ModelTier.fast,
        gpuEpActive: false,
      );
      expect(paths.recModels['zh'], isNotNull);
    });

    test('absent files → absent; verified passes → verified', () async {
      expect(TranslationModels.stateOf(TranslationModels.ocrZh),
          ModelState.absent);
      installGoodOcrZh();
      final v = await validateComponent(TranslationModels.ocrZh);
      expect(v.ok, isTrue);
      expect(TranslationModels.stateOf(TranslationModels.ocrZh),
          ModelState.verified);
      expect(TranslationModels.ocrZh.isInstalled, isTrue);
    });

    test('V10-2: unpublished FP16 components are never installed or picked', () async {
      // Even with files in place that would structurally pass.
      for (final c in [
        TranslationModels.ocrZhFp16,
        TranslationModels.ocrZhHighFp16,
        TranslationModels.ocrJaFp16,
      ]) {
        writeBytes(c, 'rec.onnx', recModelBytes(5));
        expect(c.isInstalled, isFalse, reason: c.id);
      }
      // GPU active: the pickers must still land on the fp32 components.
      installGoodOcrZh();
      writeBytes(TranslationModels.detector, 'det.onnx', detModelBytes());
      final paths = TranslationModels.workerPaths(
        tier: ModelTier.high,
        gpuEpActive: true,
      );
      expect(paths.recModels['zh'], isNot(contains('fp16')));
      expect(paths.jaEncoder, isNull); // ocr_ja not installed here
    });
  });

  group('the SHA branch: checksum-verified upstream files are installable', () {
    Future<ModelComponent> synthetic({
      required String recSha,
      required String dictSha,
      required List<int> recBytes,
      required String dictText,
    }) async {
      final c = ModelComponent(
        id: 'ocr_en', // own dict, same shape as the upstream en component
        approxSizeBytes: 1,
        kind: ModelKind.rec,
        files: [
          ModelFile('rec.onnx', const ['unused'], expectedSha256: recSha),
          ModelFile('dict.txt', const ['unused'], expectedSha256: dictSha),
        ],
      );
      writeBytes(c, 'rec.onnx', recBytes);
      writeText(c, 'dict.txt', dictText);
      return c;
    }

    String shaOf(List<int> bytes) => sha256.convert(bytes).toString();

    test('checksum match vouches for the file even if structure can\'t', () async {
      final junk = utf8.encode('not a model, but bit-identical to upstream');
      final c = await synthetic(
        recSha: shaOf(junk),
        dictSha: shaOf(utf8.encode('a\nb\nc\n')),
        recBytes: junk,
        dictText: 'a\nb\nc\n',
      );
      final v = await validateComponent(c, checkHashes: true);
      expect(v.ok, isTrue, reason: v.reason);
      expect(v.state, ModelState.verified);
      expect(v.notes['rec.onnx'], contains('checksum matches'));
      expect(c.isInstalled, isTrue);
    });

    test('checksum mismatch + broken structure → invalid', () async {
      final c = await synthetic(
        recSha: 'deadbeef' * 8,
        dictSha: shaOf(utf8.encode('a\n')),
        recBytes: utf8.encode('<html/>junk'),
        dictText: 'a\n',
      );
      final v = await validateComponent(c, checkHashes: true);
      expect(v.ok, isFalse);
      expect(v.notes['rec.onnx'], contains('treated as a local import'));
      expect(v.reason, contains('does not look like an ONNX model'));
    });

    test(
      'checksum mismatch + sound structure → local import rescued',
      () async {
        final c = await synthetic(
          recSha: 'deadbeef' * 8, // "got it from a shared drive"
          dictSha: 'cafebabe' * 8,
          recBytes: recModelBytes(5),
          dictText: 'a\nb\nc\n',
        );
        final v = await validateComponent(c, checkHashes: true);
        expect(v.ok, isTrue, reason: v.reason);
        expect(v.state, ModelState.verified);
        expect(v.notes['rec.onnx'], contains('differs'));
      },
    );
  });

  group('registry invariant: the 12 upstream fp32 assets stay installable', () {
    test('every published component file carries an expectedSha256', () {
      final published = TranslationModels.all
          .where((c) => c.enabled)
          .toList();
      expect(
        published.map((c) => c.id),
        unorderedEquals([
          'text_detector',
          'text_detector_high',
          'ocr_ja',
          'ocr_zh',
          'ocr_zh_high',
          'ocr_en',
          'ocr_ko',
        ]),
      );
      final files = published.expand((c) => c.files).toList();
      // 1 detector, 1 detector-high, 3 ja (encoder/decoder/vocab), 2 zh
      // (rec/dict), 1 zh-high (rec), 2 en, 2 ko = the 12 published assets.
      expect(files.length, 12);
      for (final f in files) {
        expect(
          f.expectedSha256,
          isNotNull,
          reason:
              '${f.name} without a checksum could only pass via the session '
              'probe (待接) — that would strand every existing install',
        );
      }
    });

    test('no session, no checksum: structurally sound upstream-shaped '
        'files are usable via the present branch', () async {
      installGoodOcrZh();
      writeBytes(TranslationModels.detector, 'det.onnx', detModelBytes());
      writeBytes(TranslationModels.detectorHigh, 'det.onnx', detModelBytes());
      expect(TranslationModels.detector.isInstalled, isTrue);
      expect(TranslationModels.detectorHigh.isInstalled, isTrue);
      expect(TranslationModels.ocrZh.isInstalled, isTrue);
      final paths = TranslationModels.workerPaths(
        tier: ModelTier.high,
        gpuEpActive: false,
      );
      expect(paths.recModels['zh'], contains('ocr_zh'));
      expect(paths.detector, contains('text_detector_high'));
      expect(TranslationModels.isReadyFor('zh', tier: ModelTier.high), isTrue);
    });
  });

  group('SessionIntrospector hook (待接 interface, contract pinned)', () {
    test('probe refusing to load the graph overrides a clean static pass', () async {
      installGoodOcrZh();
      final v = await validateComponent(
        TranslationModels.ocrZh,
        sessionProbe: (path) async => null,
      );
      expect(v.ok, isFalse);
      expect(v.state, ModelState.invalid);
      expect(v.reason, contains('cannot be loaded by the ONNX runtime'));
    });

    test('runtime class counts are the final word over the static view', () async {
      installGoodOcrZh(); // static C=5, dict 3 lines: structurally fine
      final v = await validateComponent(
        TranslationModels.ocrZh,
        sessionProbe: (path) async => const OnnxSignature(
          inputs: [
            OnnxTensor(name: 'x', elemType: _f32, dims: [null, 3, 48, null]),
          ],
          outputs: [
            OnnxTensor(
              name: 'softmax',
              elemType: _f32,
              dims: [null, null, 42], // runtime says 42, static said 5
            ),
          ],
        ),
      );
      expect(v.ok, isFalse);
      expect(v.reason, contains('at runtime,'));
      expect(v.reason, contains('42 classes'));
      expect(v.reason, contains('3 + 2 = 5'));
    });
  });

  group('red line R3 / OnnxElementType guards', () {
    test('local_model_import.dart performs no FFI whatsoever', () {
      // Why this test exists: R3 says ORT FFI lives in the worker isolate
      // only, and the settings page validates on the UI isolate. The pure
      // protobuf reader is what makes that legal; this guard stops anyone
      // (including a future me) from "just quickly" importing ort_ffi here.
      final src = File(
        'lib/foundation/image_translation/local_model_import.dart',
      ).readAsStringSync();
      for (final forbidden in const [
        "import 'dart:ffi'",
        'import \'package:venera/foundation/image_translation/ort_ffi.dart\'',
        'import \'package:flutter_onnxruntime',
        'DynamicLibrary',
        'lookupFunction',
        'OrtFfiSession.open(',
      ]) {
        expect(src, isNot(contains(forbidden)), reason: forbidden);
      }
    });

    test('element-type constants equal the worker\'s OrtRuntime values', () {
      // ort_ffi.dart cannot be imported here (FFI), but its numbers are the
      // contract: the runtime reads these ids from the same ONNX enum.
      expect(OnnxElementType.float, OrtRuntime.typeFloat32);
      expect(OnnxElementType.uint8, OrtRuntime.typeUint8);
      expect(OnnxElementType.int32, OrtRuntime.typeInt32);
      expect(OnnxElementType.int64, OrtRuntime.typeInt64);
      expect(OnnxElementType.string, OrtRuntime.typeString);
      expect(OnnxElementType.bool, OrtRuntime.typeBool);
      expect(OnnxElementType.float16, OrtRuntime.typeFloat16);
      expect(OnnxElementType.bfloat16, OrtRuntime.typeBFloat16);
    });
  });

  group('pure reader', () {
    test('round-trips names, dtypes, static and symbolic dims', () {
      final path = pathOf(TranslationModels.ocrZh, 'rec.onnx');
      File(path).createSync(recursive: true);
      File(path).writeAsBytesSync(recModelBytes(6625));
      final sig = readOnnxSignature(path);
      expect(sig.inputs.single.name, 'x');
      expect(sig.inputs.single.elemType, _f32);
      expect(sig.inputs.single.dims, [null, 3, 48, null]);
      expect(sig.inputs.single.dimParams[3], 'width');
      expect(sig.outputs.single.dims.last, 6625);
    });

    test('truncated files fail with a human message, not a crash', () {
      final bytes = recModelBytes(5);
      final path = pathOf(TranslationModels.ocrZh, 'rec.onnx');
      File(path)
        ..createSync(recursive: true)
        ..writeAsBytesSync(bytes.sublist(0, bytes.length - 3));
      expect(
        () => readOnnxSignature(path),
        throwsA(isA<OnnxMetaReaderException>()),
      );
    });
  });
}
