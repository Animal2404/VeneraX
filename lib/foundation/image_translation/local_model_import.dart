/// Local model import & validation (Phase 10 §7.2.2, decision R-3).
///
/// Lets a user drop `.onnx` / `dict.txt` / `vocab.txt` files obtained from a
/// network drive or community share straight into a component directory and
/// find out — before inference, never during — whether the files are usable.
/// Every failure path produces a human-readable [ImportVerdict.reason]; a bad
/// file must never reach a worker-isolate crash (V10-4).
///
/// ## Red line R3 (FFI only inside the translation worker isolate)
/// This file performs **no FFI at all**: it imports neither `dart:ffi`, nor
/// `ort_ffi.dart`, nor `flutter_onnxruntime`, and it never opens an ORT
/// session. Model introspection here is pure-Dart parsing of the ONNX
/// Protobuf *metadata* (the declared graph inputs/outputs, their ranks,
/// element types and static dimensions) straight from the file's bytes, so
/// running it on the UI isolate is safe. `local_model_import_test.dart`
/// guards this import list mechanically.
/// Anything only a live session can answer (the graph actually loading,
/// runtime-resolved shapes) is exposed as the [SessionIntrospector] hook
/// below — a **待接 (not yet wired)** interface. Without it, validation
/// falls back to the declared metadata, which already covers every crash
/// class of plan D-10 / D-11 (wrong file kind, dict↔model class mismatch,
/// fp16 IO on a CPU component, truncated / HTML-instead-of-model downloads).
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:venera/foundation/image_translation/translation_models.dart';
import 'package:venera/foundation/log.dart';

// ===========================================================================
// Public verdict type
// ===========================================================================

/// Outcome of [validateComponent] / the synchronous structure gate.
class ImportVerdict {
  const ImportVerdict({
    required this.ok,
    required this.state,
    required this.reason,
    this.warnings = const [],
    this.notes = const {},
  });

  /// Whether the component's local files are usable for inference.
  final bool ok;

  /// State recorded for the component (verified / invalid / present).
  final ModelState state;

  /// Human-readable single-paragraph explanation. On success a short
  /// confirmation; on failure the concrete defect(s), with numbers.
  final String reason;

  /// Non-fatal findings (e.g. batch dimension fixed to 1: usable but slow).
  final List<String> warnings;

  /// Per-file notes (checksum status etc.), keyed by file name.
  final Map<String, String> notes;

  @override
  String toString() =>
      'ImportVerdict($state, ok: $ok'
      '${warnings.isEmpty ? '' : ', ${warnings.length} warning(s)'})';
}

// ===========================================================================
// Pending interface (R3): runtime session introspection
// ===========================================================================

/// **待接 (to be wired) — never implement directly on the UI isolate.**
///
/// Contract: implementations answer with the *runtime* tensor metadata of
/// one ONNX file, or `null` when the ONNX runtime refuses to load the graph
/// (which [validateComponent] then reports as a hard failure).
///
/// Red line R3: opening an `OrtFfiSession` (and anything else in
/// `ort_ffi.dart`) is only allowed inside the translation worker isolate.
/// The wiring therefore needs a new message case in
/// `translation_worker.dart` (owned by another task) that, **on the worker
/// side**, calls `OrtFfiSession.open` → reports `inputNames` /
/// `inputShapes()` / output ranks, element types via `OrtOutput.shape` →
/// and always `close()`es the probe session afterwards (Phase 7's
/// idempotent `OrtFfiSession.close()`). The caller-side closure in the UI
/// isolate must be nothing but that SendPort round-trip; it must never
/// touch FFI itself.
///
/// Until it is wired, callers simply omit `sessionProbe` and validation
/// uses the declared metadata only.
typedef SessionIntrospector = Future<OnnxSignature?> Function(String onnxPath);

// ===========================================================================
// ONNX metadata model (pure Dart, FFI-free)
// ===========================================================================

/// ONNX `TensorProto.DataType` element type ids.
///
/// These MUST stay equal to the `OrtRuntime.typeXxx` constants in
/// `ort_ffi.dart` (same underlying ONNX Runtime enum); the equality is
/// pinned by a test in `local_model_import_test.dart`. The duplication is
/// deliberate: importing `ort_ffi.dart` here would drag FFI into a file
/// that is required to run on the UI isolate (red line R3).
abstract final class OnnxElementType {
  static const float = 1;
  static const uint8 = 2;
  static const int32 = 6;
  static const int64 = 7;
  static const string = 8;
  static const bool = 9;
  static const float16 = 10;
  static const bfloat16 = 16;

  static String nameOf(int t) => switch (t) {
    float => 'float32',
    uint8 => 'uint8',
    int32 => 'int32',
    int64 => 'int64',
    string => 'string',
    bool => 'bool',
    float16 => 'float16',
    bfloat16 => 'bfloat16',
    _ => 'type#$t',
  };
}

/// One declared graph input/output.
class OnnxTensor {
  const OnnxTensor({
    required this.name,
    required this.elemType,
    required this.dims,
    this.dimParams = const [],
    this.isTensor = true,
  });

  final String name;

  /// [OnnxElementType] id, or 0 when the graph declares no tensor type.
  final int elemType;

  /// Shape; `null` entries are dynamic (symbolic or unknown) dimensions.
  final List<int?> dims;

  /// Symbolic names (`dim_param`) per dimension, `''` when absent.
  final List<String> dimParams;

  /// False for non-tensor ports (sequences, maps) — not usable by the worker.
  final bool isTensor;

  bool get isFloat => elemType == OnnxElementType.float;
  bool get isFloat16 =>
      elemType == OnnxElementType.float16 ||
      elemType == OnnxElementType.bfloat16;
  bool get isInt64 => elemType == OnnxElementType.int64;
  int get rank => dims.length;

  String get shapeText {
    final parts = <String>[];
    for (var i = 0; i < dims.length; i++) {
      final d = dims[i];
      final p = i < dimParams.length ? dimParams[i] : '';
      parts.add(d == null ? (p.isEmpty ? '?' : p) : '$d');
    }
    return '[${parts.join(',')}]';
  }

  @override
  String toString() => '$name: ${OnnxElementType.nameOf(elemType)}$shapeText';
}

/// Declared graph inputs/outputs of one ONNX model.
class OnnxSignature {
  const OnnxSignature({required this.inputs, required this.outputs});

  final List<OnnxTensor> inputs;
  final List<OnnxTensor> outputs;

  @override
  String toString() =>
      'OnnxSignature(in: $inputs, out: $outputs)';
}

/// Raised for anything that cannot be a loadable ONNX model, or cannot be
/// parsed as one. Its message is already user-facing prose.
class OnnxMetaReaderException implements Exception {
  const OnnxMetaReaderException(this.message);

  final String message;

  @override
  String toString() => message;
}

// ===========================================================================
// ONNX protobuf metadata reader
// ===========================================================================
//
// Layout used (ONNX's onnx.proto field numbers):
//   ModelProto        : ir_version=1(varint) graph=7(bytes) opset_import=8 …
//   GraphProto        : node=1 name=2 initializer=5 doc_string=6
//                       output=11 input=12 value_info=13 …
//   ValueInfoProto    : name=1 type=2
//   TypeProto         : tensor_type=1 sequence_type=4 map_type=5 …
//   TypeProto.Tensor  : elem_type=1(varint) shape=2
//   TensorShapeProto  : dim=1
//   TensorShapeProto.Dimension : dim_value=1(varint) dim_param=2(string)
//
// Only ValueInfo subtrees are materialised; everything else (above all the
// multi-hundred-megabyte `initializer` weight blobs of GraphProto field 5)
// is skipped with an O(1) seek, so a full read of a 460 MB model costs a
// few hundred small reads — milliseconds, safe for any isolate, zero FFI.

/// Reads the declared graph input/output metadata of an ONNX file.
///
/// Throws [OnnxMetaReaderException] with a human message when the file is
/// not readable as an ONNX model (wrong bytes, truncated download, HTML
/// error page saved under a `.onnx` name, …).
OnnxSignature readOnnxSignature(String path) {
  final file = File(path);
  if (!file.existsSync()) {
    throw OnnxMetaReaderException('the file does not exist ($path)');
  }
  final raf = file.openSync();
  try {
    if (raf.lengthSync() == 0) {
      throw const OnnxMetaReaderException('the file is empty (0 bytes)');
    }
    final r = _ProtoReader(raf);
    final first = r.readByte();
    // Rewind BOTH the bookkeeping and the actual file handle — they are
    // assumed to stay in lockstep everywhere else in the reader.
    r.pos = 0;
    raf.setPositionSync(0);
    if (first != 0x08) {
      // ModelProto always starts with the ir_version varint, field 1.
      throw OnnxMetaReaderException(
        'it does not look like an ONNX model (starts with 0x'
        '${first.toRadixString(16).padLeft(2, '0')}; a renamed document, an '
        'HTML error page or a corrupt download all look like this)',
      );
    }
    return r.parseModel(raf.lengthSync());
  } finally {
    raf.closeSync();
  }
}

class _ProtoReader {
  _ProtoReader(this.file);

  final RandomAccessFile file;
  int pos = 0;

  int readByte() {
    pos += 1;
    return file.readByteSync();
  }

  Uint8List readBytes(int n) {
    if (n < 0) {
      throw const OnnxMetaReaderException('the file is not valid protobuf');
    }
    final buf = Uint8List(n);
    final got = file.readIntoSync(buf);
    if (got != n) {
      throw const OnnxMetaReaderException(
        'the file ends in the middle of the model data (truncated download?)',
      );
    }
    pos += n;
    return buf;
  }

  String readString(int n) => utf8.decode(readBytes(n), allowMalformed: true);

  void skip(int n) {
    if (n < 0) {
      throw const OnnxMetaReaderException('the file is not valid protobuf');
    }
    pos += n;
    file.setPositionSync(pos);
  }

  int readVarint() {
    var result = 0;
    var shift = 0;
    while (true) {
      if (shift > 63) {
        throw const OnnxMetaReaderException('a varint in the file is corrupt');
      }
      final b = readByte();
      result |= (b & 0x7f) << shift;
      if ((b & 0x80) == 0) return result;
      shift += 7;
    }
  }

  /// Skips a field body of the given wire type. Length-delimited bodies
  /// (weights!) are skipped by seek, never buffered.
  void skipBody(int wireType) {
    switch (wireType) {
      case 0:
        readVarint();
      case 1:
        skip(8);
      case 5:
        skip(4);
      case 2:
        skip(readVarint());
      default:
        throw const OnnxMetaReaderException(
          'the file is not a readable ONNX model',
        );
    }
  }

  /// Iterates a message scope of [length] bytes, calling [onField] with the
  /// field number and wire type; [onField] consumes the body.
  void scanScope(
    int length,
    void Function(int fieldNumber, int wireType) onField,
  ) {
    final end = pos + length;
    while (pos < end) {
      final key = readVarint();
      final fieldNumber = key >>> 3;
      final wireType = key & 0x7;
      onField(fieldNumber, wireType);
    }
    if (pos != end) {
      // A sub-field overran its parent: the file is inconsistent.
      throw const OnnxMetaReaderException(
        'the file is not a readable ONNX model (internal lengths disagree)',
      );
    }
  }

  OnnxSignature parseModel(int length) {
    OnnxSignature? graph;
    scanScope(length, (fn, wt) {
      if (fn == 7 && wt == 2) {
        graph = parseGraph(readVarint());
      } else {
        skipBody(wt);
      }
    });
    if (graph == null) {
      throw const OnnxMetaReaderException(
        'it is an ONNX container but contains no model graph',
      );
    }
    return graph!;
  }

  OnnxSignature parseGraph(int length) {
    final inputs = <OnnxTensor>[];
    final outputs = <OnnxTensor>[];
    scanScope(length, (fn, wt) {
      if (wt != 2) {
        skipBody(wt);
        return;
      }
      switch (fn) {
        case 11: // output
          outputs.add(parseValueInfo(readVarint()));
        case 12: // input
          inputs.add(parseValueInfo(readVarint()));
        default:
          // 1 node, 2 name, 5 initializer (huge!), 6 doc_string, 13 value_info…
          skip(readVarint());
      }
    });
    return OnnxSignature(inputs: inputs, outputs: outputs);
  }

  OnnxTensor parseValueInfo(int length) {
    var name = '';
    OnnxTensor? typed;
    scanScope(length, (fn, wt) {
      if (fn == 1 && wt == 2) {
        name = readString(readVarint());
      } else if (fn == 2 && wt == 2) {
        typed = parseTypeProto(readVarint(), name);
      } else {
        skipBody(wt);
      }
    });
    // Field order is not guaranteed in protobuf: if the type arrived before
    // the name, patch the name in after the fact.
    if (typed == null) {
      return OnnxTensor(name: name, elemType: 0, dims: const []);
    }
    final t = typed!;
    if (t.name.isNotEmpty) return t;
    return OnnxTensor(
      name: name,
      elemType: t.elemType,
      dims: t.dims,
      dimParams: t.dimParams,
      isTensor: t.isTensor,
    );
  }

  OnnxTensor parseTypeProto(int length, String name) {
    OnnxTensor? tensor;
    var nonTensor = false;
    scanScope(length, (fn, wt) {
      if (fn == 1 && wt == 2) {
        tensor = parseTensorType(readVarint(), name);
      } else {
        if (wt == 2 && (fn == 4 || fn == 5)) nonTensor = true; // sequence/map
        skipBody(wt);
      }
    });
    if (tensor == null) {
      return OnnxTensor(
        name: name,
        elemType: 0,
        dims: const [],
        isTensor: !nonTensor,
      );
    }
    return tensor!;
  }

  OnnxTensor parseTensorType(int length, String name) {
    var elemType = 0;
    var dims = <int?>[];
    var params = <String>[];
    scanScope(length, (fn, wt) {
      if (fn == 1 && wt == 0) {
        elemType = readVarint();
      } else if (fn == 2 && wt == 2) {
        final shape = parseShape(readVarint());
        dims = shape.$1;
        params = shape.$2;
      } else {
        skipBody(wt);
      }
    });
    return OnnxTensor(
      name: name,
      elemType: elemType,
      dims: dims,
      dimParams: params,
    );
  }

  (List<int?>, List<String>) parseShape(int length) {
    final dims = <int?>[];
    final params = <String>[];
    scanScope(length, (fn, wt) {
      if (fn == 1 && wt == 2) {
        final dim = parseDimension(readVarint());
        dims.add(dim.$1);
        params.add(dim.$2);
      } else {
        skipBody(wt);
      }
    });
    return (dims, params);
  }

  (int?, String) parseDimension(int length) {
    int? value;
    var param = '';
    scanScope(length, (fn, wt) {
      if (fn == 1 && wt == 0) {
        value = readVarint();
      } else if (fn == 2 && wt == 2) {
        param = readString(readVarint());
      } else {
        skipBody(wt);
      }
    });
    return (value, param);
  }
}

// ===========================================================================
// Structural rules (plan §7.2.2 ③, as pure functions over OnnxSignature)
// ===========================================================================

/// What role a file inside a component plays.
enum ModelFileRole {
  detector,
  rec,
  mangaEncoder,
  mangaDecoder,
  dict,
  vocab,
  other,
}

ModelFileRole roleOf(ModelComponent c, String fileName) {
  switch (fileName) {
    case 'det.onnx':
      return ModelFileRole.detector;
    case 'rec.onnx':
      return ModelFileRole.rec;
    case 'encoder.onnx':
      return ModelFileRole.mangaEncoder;
    case 'decoder.onnx':
      return ModelFileRole.mangaDecoder;
    case 'dict.txt':
      return ModelFileRole.dict;
    case 'vocab.txt':
      return ModelFileRole.vocab;
  }
  if (fileName.endsWith('.onnx')) {
    return switch (c.kind) {
      ModelKind.detector => ModelFileRole.detector,
      ModelKind.rec => ModelFileRole.rec,
      ModelKind.mangaEncoder => ModelFileRole.mangaEncoder,
    };
  }
  return ModelFileRole.other;
}

/// `C == N + 2`, exactly as the worker builds its charset.
///
/// `translation_worker.dart`'s `loadCharset()` maps a dictionary of N lines
/// to `charset = ['', ...lines, ' ']`: a CTC blank is prepended at index 0
/// and a trailing space class is appended — **that** is the "+2" of plan
/// §7.2.2 (verified against the source, `translation_worker.dart:740-753`,
/// not copied from the plan). Hence a compatible recognition model must
/// output exactly `N + 2` classes, and `runArgmaxGrid` is fed
/// `classes: charset.length`.
const int dictCharsetExtraClasses = 2;

/// The +2 rule itself; returns null when consistent, else the human message.
String? dictClassMismatchProblem({
  required int classes,
  required int dictLines,
  required String dictName,
}) {
  if (classes == dictLines + dictCharsetExtraClasses) return null;
  return 'the model outputs $classes classes, but "$dictName" has $dictLines '
      'lines: the OCR worker reads the dictionary as-is and adds one blank '
      'class in front plus one space class at the end, so the model must '
      'output exactly $dictLines + $dictCharsetExtraClasses = '
      '${dictLines + dictCharsetExtraClasses} classes. A dictionary for a '
      'different language, or a model of another generation, mismatches '
      'exactly like this.';
}

/// The manga-ocr rule: decoder output classes == vocab lines.
String? vocabClassMismatchProblem({
  required int classes,
  required int vocabLines,
}) {
  if (classes == vocabLines) return null;
  return 'the decoder outputs $classes token classes, but "vocab.txt" has '
      '$vocabLines lines. Token ids beyond the vocabulary are silently '
      'dropped when decoding, so decoder and vocabulary must come from the '
      'same manga-ocr release.';
}

bool _hasImageInput(OnnxSignature sig, {int? staticHeight, int? staticWidth}) {
  for (var t in sig.inputs) {
    if (!t.isTensor || !t.isFloat || t.rank != 4) continue;
    if (t.dims[1] != 3) continue;
    if (staticHeight != null && t.dims[2] != null && t.dims[2] != staticHeight) {
      continue;
    }
    if (staticWidth != null && t.dims[3] != null && t.dims[3] != staticWidth) {
      continue;
    }
    return true;
  }
  return false;
}

/// Hard structural problems of one ONNX file, human-readable, or null.
///
/// Deliberately conservative: rules only reject shapes that provably cannot
/// work with the worker's fixed pre/post processing, never "unusual but
/// probably fine".
String? onnxStructuralProblem(
  ModelComponent c,
  ModelFile file,
  OnnxSignature sig,
) {
  final role = roleOf(c, file.name);
  if (sig.outputs.isEmpty) {
    return '"${file.name}" declares no graph output at all.';
  }
  final fp16 = _fp16Problem(c, file, sig);
  if (fp16 != null) return fp16;

  final out = sig.outputs.first;
  switch (role) {
    case ModelFileRole.detector:
      if (!_hasImageInput(sig)) {
        return '"${file.name}" is not shaped like a text detector: it needs '
            'a float32 image input [batch,3,height,width], but its inputs '
            'are ${sig.inputs.map((t) => t.toString()).join('; ')}.';
      }
      if (!out.isTensor) {
        return '"${file.name}" does not output a probability map (its first '
            'output is not a tensor).';
      }
      if (out.rank == 3) return null;
      if (out.rank == 4 && out.dims[1] == 1) return null;
      return '"${file.name}" should output a single-channel probability map '
          '([batch,height,width] or [batch,1,height,width]), but its first '
          'output is ${out.shapeText} — that is not a DBNet map.';
    case ModelFileRole.rec:
      if (!_hasImageInput(sig)) {
        return '"${file.name}" is not shaped like a recognition model: it '
            'needs a float32 image input [batch,3,height,width], but its '
            'inputs are ${sig.inputs.map((t) => t.toString()).join('; ')}.';
      }
      if (!out.isTensor) {
        return '"${file.name}" does not output a CTC tensor (its first '
            'output is not a tensor).';
      }
      if (out.rank != 3) {
        return '"${file.name}" should output CTC probabilities '
            '[batch,sequence,classes], but its first output is '
            '${out.shapeText} — a rank-${out.rank} tensor. A text detector '
            'placed in a recognition slot fails exactly like this.';
      }
      if (out.dims[2] == null) {
        return 'the output class count of "${file.name}" is dynamic '
            '(${out.shapeText}), so it can never be matched against a fixed '
            'dictionary — inference would read the wrong stride and produce '
            'garbage.';
      }
      return null;
    case ModelFileRole.mangaEncoder:
      if (!_hasImageInput(sig, staticHeight: 224, staticWidth: 224)) {
        return '"${file.name}" is not shaped like the manga-ocr encoder: it '
            'needs a float32 image input [batch,3,224,224], but its inputs '
            'are ${sig.inputs.map((t) => t.toString()).join('; ')}.';
      }
      return null;
    case ModelFileRole.mangaDecoder:
      final hasTokens = sig.inputs.any(
        (t) => t.isTensor && t.isInt64 && t.rank >= 1,
      );
      final hasHidden = sig.inputs.any(
        (t) => t.isTensor && t.isFloat && t.rank >= 2,
      );
      if (!hasTokens || !hasHidden) {
        return '"${file.name}" is not shaped like the manga-ocr decoder: it '
            'needs an int64 token input and a float32 encoder-hidden input, '
            'but its inputs are '
            '${sig.inputs.map((t) => t.toString()).join('; ')}.';
      }
      if (!out.isTensor || out.rank != 3 || out.dims[2] == null) {
        return '"${file.name}" should output logits '
            '[batch,position,vocabulary] with a static vocabulary size, but '
            'its first output is '
            '${out.isTensor ? out.shapeText : 'not a tensor'}.';
      }
      return null;
    case ModelFileRole.dict:
    case ModelFileRole.vocab:
    case ModelFileRole.other:
      return null;
  }
}

/// D-11's offline half: fp16-declared IO on a CPU component produces
/// garbage, and the runtime is explicitly NOT going to decode fp16.
String? _fp16Problem(ModelComponent c, ModelFile file, OnnxSignature sig) {
  if (c.requiresGpuEp) return null;
  final bad = <String>[
    for (var t in sig.inputs)
      if (t.isTensor && t.isFloat16) '${t.name} (input)',
    for (var t in sig.outputs)
      if (t.isTensor && t.isFloat16) '${t.name} (output)',
  ];
  if (bad.isEmpty) return null;
  return '"${file.name}" declares float16 tensors (${bad.join(', ')}) but '
      '"${c.displayNameKey ?? c.id}" runs on the CPU path, which only reads '
      'float32 — inference would silently produce garbage. This looks like '
      'an FP16 build of the model.';
}

/// Non-fatal findings, e.g. the fixed-batch note of plan §7.2.2 ④.
List<String> onnxStructuralWarnings(
  ModelComponent c,
  ModelFile file,
  OnnxSignature sig,
) {
  final warnings = <String>[];
  final role = roleOf(c, file.name);
  final mainInput = sig.inputs.isEmpty ? null : sig.inputs.first;
  if ((role == ModelFileRole.detector || role == ModelFileRole.rec) &&
      mainInput != null &&
      mainInput.rank >= 1 &&
      mainInput.dims[0] == 1) {
    warnings.add(
      '"${file.name}" has its batch dimension fixed to 1: usable, but '
      'batched OCR cannot speed it up (one crop per call).',
    );
  }
  if (c.requiresGpuEp) {
    final fp16 = [...sig.inputs, ...sig.outputs].any(
      (t) => t.isTensor && t.isFloat16,
    );
    if (fp16) {
      warnings.add(
        '"${file.name}" declares float16 IO and can only run on the GPU '
        'execution provider.',
      );
    }
  }
  return warnings;
}

// ===========================================================================
// The validator itself
// ===========================================================================

/// Dictionary line count exactly as the worker counts it.
///
/// Same primitive (`readAsLines`) as `loadCharset()`, so the "+2" rule
/// above is guaranteed to compare like for like: Dart drops the trailing
/// empty line a final newline produces, and a blank line inside the file
/// still counts as one dictionary line.
int dictLineCountSync(String path) => File(path).readAsLinesSync().length;

class _ComponentAnalysis {
  final problems = <String>[];

  /// The component-local file that caused [problems]' last entry, or null
  /// when the problem is about a shared/foreign file (a dictFrom dictionary
  /// that is missing cannot make the local model file itself invalid).
  String? failedFile;
  final warnings = <String>[];
  final notes = <String, String>{};

  /// File name → parsed static signature, for the session-probe stage.
  final signatures = <String, OnnxSignature>{};

  /// Static CTC class count of this component's rec model, when known.
  int? recClasses;

  /// Static vocabulary class count of the manga decoder, when known.
  int? decoderClasses;

  /// Line count of the vocabulary file, when read.
  int? vocabLinesSeen;

  /// Line count of the dictionary the cross-check ran against, when read.
  int? dictLines;

  bool get ok => problems.isEmpty;
}

/// Full validation of one component's local files (plan §7.2.2).
///
/// * existence, non-emptiness, "not still held by a sync client" (Windows);
/// * `.onnx`: pure-Dart protobuf metadata read + the structural assertions
///   of §7.2.2 ③ (no FFI — see the file header);
/// * `dict.txt`: line count N vs the accompanying model's class count C
///   with `C == N + 2` (see [dictCharsetExtraClasses]);
/// * `vocab.txt`: line count == the manga decoder's class count;
/// * optionally ([checkHashes]) the published SHA-256: a *match* vouches
///   for the file outright; a *mismatch* does NOT invalidate (that is the
///   whole point of local imports from a network drive — it only shifts
///   the basis from "trust the checksum" to "trust the structure");
/// * optionally ([sessionProbe], 待接) the live runtime shapes via the
///   worker isolate.
///
/// Records the outcome into [TranslationModels.recordVerdict] and
/// invalidates the readiness cache. Never throws: an internal validator
/// fault degrades to "not blocked, but unverified".
Future<ImportVerdict> validateComponent(
  ModelComponent component, {
  bool checkHashes = false,
  SessionIntrospector? sessionProbe,
}) async {
  if (!component.enabled) {
    return const ImportVerdict(
      ok: false,
      state: ModelState.invalid,
      reason:
          'This component is not published yet, so its files are never '
          'loaded by the app; validating local copies of it is pointless.',
    );
  }
  final a = _ComponentAnalysis();
  try {
    final shaMatched = <String, bool>{};
    if (checkHashes) {
      for (var file in component.files) {
        final expected = file.expectedSha256?.toLowerCase();
        if (expected == null) continue;
        final path = component.filePath(file.name);
        if (!File(path).existsSync()) continue;
        final actual = await _sha256Of(path);
        if (actual == expected) {
          shaMatched[file.name] = true;
          a.notes[file.name] = 'checksum matches the published asset';
        } else {
          shaMatched[file.name] = false;
          a.notes[file.name] =
              'checksum differs from the published asset (got $actual) — '
              'treated as a local import and judged by structure';
        }
      }
    }
    _analyzeFiles(component, a, shaMatched: shaMatched, checkLocks: true);

    // Session stage (only when the worker-isolate probe is wired): the
    // runtime has the final say about "does this graph load at all", and
    // its resolved class counts must agree with the static view *and* the
    // dictionary — that is the pair the worker indexes at inference time.
    if (sessionProbe != null && a.ok) {
      for (var file in component.files) {
        if (a.signatures[file.name] == null) continue; // not parsed .onnx
        final runtime = await sessionProbe(component.filePath(file.name));
        if (runtime == null) {
          a.failedFile = file.name;
          a.problems.add(
            '"${file.name}" cannot be loaded by the ONNX runtime at all — '
            'it is a model file in name only.',
          );
          break;
        }
        final problem = onnxStructuralProblem(component, file, runtime);
        if (problem != null && shaMatched[file.name] != true) {
          a.failedFile = file.name;
          a.problems.add('at runtime, $problem');
          break;
        }
        final runtimeOut = out3OrNull(runtime);
        final runtimeClasses = runtimeOut?.dims[2];
        if (runtimeClasses != null && shaMatched[file.name] != true) {
          String? pairProblem;
          if (roleOf(component, file.name) == ModelFileRole.rec &&
              a.dictLines != null) {
            pairProblem = dictClassMismatchProblem(
              classes: runtimeClasses,
              dictLines: a.dictLines!,
              dictName: 'dict.txt',
            );
          } else if (roleOf(component, file.name) ==
                  ModelFileRole.mangaDecoder &&
              a.vocabLinesSeen != null) {
            pairProblem = vocabClassMismatchProblem(
              classes: runtimeClasses,
              vocabLines: a.vocabLinesSeen!,
            );
          }
          if (pairProblem != null) {
            a.failedFile = file.name;
            a.problems.add('at runtime, $pairProblem');
            break;
          }
          final staticOut = out3OrNull(a.signatures[file.name]!);
          if (staticOut?.dims[2] != null &&
              staticOut!.dims[2] != runtimeClasses) {
            a.failedFile = file.name;
            a.problems.add(
              '"${file.name}" declares ${staticOut.dims[2]} classes in its '
              'metadata but the runtime sees $runtimeClasses — the graph is '
              'inconsistent with itself and cannot be trusted.',
            );
            break;
          }
        }
        a.warnings.addAll(onnxStructuralWarnings(component, file, runtime));
      }
    }

    final ok = a.ok;
    final state = ok ? ModelState.verified : ModelState.invalid;
    final reason = ok
        ? 'All ${component.files.length} file(s) passed the checks.'
        : a.problems.join('\n');
    TranslationModels.recordVerdict(
      component,
      state,
      detail: ok ? null : reason,
    );
    TranslationModels.invalidateReadyCache();
    return ImportVerdict(
      ok: ok,
      state: state,
      reason: reason,
      warnings: List.unmodifiable(a.warnings),
      notes: Map.unmodifiable(a.notes),
    );
  } catch (e, s) {
    // A validator bug must never lock the user out of a working install.
    Log.error(
      'Local Model Import',
      'validateComponent(${component.id}) crashed: $e',
      s,
    );
    TranslationModels.recordVerdict(component, ModelState.present);
    TranslationModels.invalidateReadyCache();
    return ImportVerdict(
      ok: false,
      state: ModelState.present,
      reason:
          'Validation could not be completed ($e). The files were left '
          'usable (unverified) — retry, or re-download.',
      warnings: List.unmodifiable(a.warnings),
      notes: Map.unmodifiable(a.notes),
    );
  }
}

/// Synchronous, cheap, FFI-free structure pass used by the installation
/// gate (`TranslationModels.stateOf` → `isInstalled`): run the first time
/// a component's files are looked at, and whenever their size/mtime changed.
///
/// Returns null when the component is structurally sound, otherwise the
/// first problem text plus the local file it indicts (null when the problem
/// concerns a foreign file such as a shared dictionary).
StructureCheck checkComponentStructure(ModelComponent component) {
  final a = _ComponentAnalysis();
  try {
    _analyzeFiles(component, a, shaMatched: const {}, checkLocks: false);
  } catch (e, s) {
    // Same rule as validateComponent: a validator fault must not block a
    // working install.
    Log.error('Local Model Import', 'structure check crashed: $e', s);
    return const StructureCheck(problem: null, failedFile: null);
  }
  if (a.ok) {
    return const StructureCheck(problem: null, failedFile: null);
  }
  return StructureCheck(problem: a.problems.first, failedFile: a.failedFile);
}

/// Result of the synchronous gate of [checkComponentStructure].
class StructureCheck {
  const StructureCheck({required this.problem, required this.failedFile});

  /// Human-readable first problem, or null when everything checks out.
  final String? problem;

  /// Which file of the component the problem indicts, or null when the
  /// problem is about a foreign file (shared dictionary etc.).
  final String? failedFile;
}

void _analyzeFiles(
  ModelComponent component,
  _ComponentAnalysis a, {
  required Map<String, bool> shaMatched,
  bool checkLocks = false,
}) {
  int? recClasses;
  int? decoderClasses;
  int? ownDictLines;
  int? vocabLines;
  for (var file in component.files) {
    final path = component.filePath(file.name);
    final f = File(path);
    final role = roleOf(component, file.name);
    if (!f.existsSync()) {
      a.failedFile = file.name;
      a.problems.add(
        '"${file.name}" is missing — place it into ${component.directory} '
        '(or download the component) to use this model.',
      );
      return;
    }
    if (f.lengthSync() == 0) {
      a.failedFile = file.name;
      a.problems.add(
        '"${file.name}" is empty (0 bytes) — an interrupted copy from a '
        'network drive usually leaves files like this behind.',
      );
      return;
    }
    if (checkLocks && _isLocked(path)) {
      a.failedFile = file.name;
      a.problems.add(
        '"${file.name}" is still being held by another program (a sync '
        'client mid-copy, an open editor, antivirus…). Let that finish and '
        'validate again.',
      );
      return;
    }
    final canonical = shaMatched[file.name] == true;

    switch (role) {
      case ModelFileRole.dict:
      case ModelFileRole.vocab:
        final lines = _readTextLines(path, file.name, a);
        if (lines == null) return;
        if (role == ModelFileRole.dict) {
          ownDictLines = lines;
        } else {
          vocabLines = lines;
        }
      case ModelFileRole.detector:
      case ModelFileRole.rec:
      case ModelFileRole.mangaEncoder:
      case ModelFileRole.mangaDecoder:
        OnnxSignature sig;
        try {
          sig = readOnnxSignature(path);
        } on OnnxMetaReaderException catch (e) {
          if (canonical) {
            // The bytes are bit-identical to the published asset, so the
            // model is exactly what upstream shipped; do not block on a
            // reader quirk, only note it.
            a.notes[file.name] =
                '${a.notes[file.name] ?? ''}structure could not be '
                'double-checked (${e.message})';
            continue;
          }
          a.failedFile = file.name;
          a.problems.add('"${file.name}": ${e.message}.');
          return;
        }
        a.signatures[file.name] = sig;
        final problem = onnxStructuralProblem(component, file, sig);
        if (problem != null) {
          if (canonical) {
            a.warnings.add(
              '$problem (ignored: the checksum matches the published asset)',
            );
          } else {
            a.failedFile = file.name;
            a.problems.add(problem);
            return;
          }
        }
        a.warnings.addAll(onnxStructuralWarnings(component, file, sig));
        if (role == ModelFileRole.rec || role == ModelFileRole.mangaDecoder) {
          final out = out3OrNull(sig);
          if (out != null) {
            if (role == ModelFileRole.rec) recClasses = out.dims[2];
            if (role == ModelFileRole.mangaDecoder) decoderClasses = out.dims[2];
          }
        }
      case ModelFileRole.other:
        // Unknown extra file: not part of the contract, ignored.
        break;
    }
  }

  // Cross checks: dict ↔ model classes, vocab ↔ decoder classes.
  a.recClasses = recClasses;
  a.decoderClasses = decoderClasses;
  a.vocabLinesSeen = vocabLines;
  if (roleNeedsDict(component)) {
    final dictPath = component.filePath('dict.txt');
    final dictLines = ownDictLines ?? _readSharedDictLines(component, dictPath, a);
    if (dictLines == null) return; // missing / undecodable; already recorded
    a.dictLines = dictLines;
    if (recClasses != null) {
      final problem = dictClassMismatchProblem(
        classes: recClasses,
        dictLines: dictLines,
        dictName: 'dict.txt',
      );
      if (problem != null) {
        // Indict this component's model file; a foreign dictionary is
        // judged by its owning component's own gate.
        a.failedFile = component.ownsFileNamed('rec.onnx') ? 'rec.onnx' : null;
        a.problems.add(problem);
        return;
      }
    }
  }
  if (component.kind == ModelKind.mangaEncoder &&
      decoderClasses != null &&
      vocabLines != null) {
    final problem = vocabClassMismatchProblem(
      classes: decoderClasses,
      vocabLines: vocabLines,
    );
    if (problem != null) {
      a.failedFile = component.ownsFileNamed('decoder.onnx')
          ? 'decoder.onnx'
          : null;
      a.problems.add(problem);
      return;
    }
  }
}

OnnxTensor? out3OrNull(OnnxSignature sig) {
  if (sig.outputs.isEmpty) return null;
  final out = sig.outputs.first;
  return out.isTensor && out.rank == 3 ? out : null;
}

/// Components whose recognition head emits dictionary classes.
bool roleNeedsDict(ModelComponent c) =>
    c.kind == ModelKind.rec && (c.ownsFileNamed('dict.txt') || c.dictFrom != null);

/// Reads a dictionary/vocab file; returns the line count, or null after
/// recording the problem.
int? _readTextLines(String path, String fileName, _ComponentAnalysis a) {
  List<String> lines;
  try {
    lines = File(path).readAsLinesSync();
  } on FormatException {
    a.failedFile = fileName;
    a.problems.add(
      '"$fileName" is not valid UTF-8 text — it is probably a binary file '
      'renamed, or a download that died halfway.',
    );
    return null;
  } on FileSystemException catch (e) {
    a.failedFile = fileName;
    a.problems.add('"$fileName" cannot be read ($e).');
    return null;
  }
  if (lines.isEmpty) {
    a.failedFile = fileName;
    a.problems.add(
      '"$fileName" contains no dictionary lines — place the real dictionary '
      'file there (one character/word per line).',
    );
    return null;
  }
  return lines.length;
}

/// Same, for a dictionary owned by another component (`dictFrom`).
int? _readSharedDictLines(
  ModelComponent component,
  String dictPath,
  _ComponentAnalysis a,
) {
  if (!File(dictPath).existsSync()) {
    a.failedFile = null; // foreign file — do not indict a local one
    final origin =
        component.dictFrom != null ? ", shared from '${component.dictFrom}'" : '';
    a.problems.add(
      'the dictionary this component recognises text with ("dict.txt"'
      '$origin) is missing — install the base OCR component it borrows the '
      'dictionary from first.',
    );
    return null;
  }
  try {
    return dictLineCountSync(dictPath);
  } on FormatException {
    a.failedFile = null;
    a.problems.add(
      'the shared "dict.txt" is not valid UTF-8 text — reinstall the base '
      'OCR component it comes from.',
    );
    return null;
  }
}

/// Windows best-effort "is another process still writing this file" probe.
///
/// Opening in append mode neither truncates (R10) nor reads; a sharing
/// violation means a sync client / editor still owns the file — the one way
/// a "non-empty but half-copied" file reaches inference. Skipped on POSIX:
/// advisory locks make this meaningless there.
bool _isLocked(String path) {
  if (!Platform.isWindows) return false;
  RandomAccessFile? handle;
  try {
    handle = File(path).openSync(mode: FileMode.append);
    return false;
  } on FileSystemException {
    return true;
  } finally {
    try {
      handle?.closeSync();
    } catch (_) {}
  }
}

Future<String> _sha256Of(String path) async {
  final digest = await sha256.bind(File(path).openRead()).first;
  return digest.toString();
}
