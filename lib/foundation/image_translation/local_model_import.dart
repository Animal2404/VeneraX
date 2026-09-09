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
///
/// ## Reading a declared shape (the rule that broke every install once)
/// `TensorShapeProto.Dimension` is a protobuf **oneof**: `dim_value` (a
/// literal) or `dim_param` (a symbolic name). Paddle2ONNX names its dynamic
/// axes (`p2o.DynamicDimension.3`), torch exports name them too (`height`),
/// and some exporters write `dim_value = -1`. All of those say *"any size"*,
/// so every one of them satisfies a required shape; only an axis pinned to a
/// *different literal* contradicts one. A symbolic name is therefore never
/// evidence of a mismatch — treat it as such and healthy models are declared
/// broken (that is defect 1). Counts a graph leaves open (the class axis)
/// cannot be compared at all: they are reported as runtime-resolved notes by
/// [runtimeResolvedClassNote], never guessed.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/image_translation/translation_models.dart';
import 'package:venera/foundation/log.dart';
import 'package:venera/utils/translations.dart';

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
// User-facing wording
// ===========================================================================

/// Every sentence this validator can show a human.
///
/// The user reading it is Chinese-speaking and cannot read English, so the
/// skeleton is Chinese: `<结论>：<原因>。<下一步>`. Technical identifiers stay
/// verbatim inside the sentence — `rec.onnx`, `float32`, `softmax_11.tmp_0`,
/// `[?,3,?,?]`, a `dim_param` name — because they are the handle a user (or a
/// bug report) has to grab, and translating them would remove the only
/// diagnostic value the message has.
///
/// `assets/translation.json` is what the running app actually renders: it
/// carries the same ids under `zh_CN` (byte-identical to the fallback below)
/// and `zh_TW` (Traditional wording). This table is the floor for the two
/// places where the asset bundle is not reachable — the worker isolate and a
/// unit test — and `test/model_dict_consistency_test.dart` fails the build if
/// the two sources ever drift apart, so "the JSON is the source" is a checked
/// statement rather than an intention.
abstract final class ModelMessages {
  /// Keys in `assets/translation.json` are namespaced with this prefix
  /// (`modelCheck.missingFile`), so a validator string can never collide with
  /// a natural-language UI label in the same flat table.
  static const namespace = 'modelCheck.';

  /// `id → Chinese skeleton with @placeholders`.
  static const skeletons = <String, String>{
    // ---- the file itself -------------------------------------------------
    'missingFile': '缺少文件：@file。请把该文件放入 @dir，或下载这个组件后再试。',
    'emptyFile':
        '文件为空（0 字节）：@file。这通常是网盘同步或复制中断留下的半成品，'
        '请重新复制一份完整的文件。',
    'lockedFile':
        '文件正被其他程序占用：@file（同步盘还在下载、编辑器还开着，'
        '或杀毒软件正在扫描）。请等它忙完之后再校验。',
    'fileUnreadable': '无法读取 @file（@os）。',
    // ---- "this is not a model" ------------------------------------------
    'notOnnxModel':
        '不像是一个 ONNX 模型：@file 的开头是 @byte。被改名的文档、下载到的'
        '错误网页、以及损坏的文件都是这个样子。请确认放入的确实是 .onnx 模型。',
    'truncatedModel':
        '@file 在模型数据中途就结束了（下载被截断？）。请重新复制一份完整的文件。',
    'badProtobuf': '@file 不是可以解析的 protobuf 数据。',
    'badVarint': '@file 里的长度编码（varint）已经损坏。',
    'unreadableModel': '@file 不是可以读取的 ONNX 模型。',
    'inconsistentLengths':
        '@file 不是可以读取的 ONNX 模型（内部各段的长度互相对不上）。',
    'noGraph': '@file 是一个 ONNX 容器，但里面没有模型图。',
    'noOutput': '@file 没有声明任何输出（graph output）。',
    // ---- shapes ----------------------------------------------------------
    'badImageInputShape':
        '输入形状不符：@role需要 @need 形式的 float32 图像输入，'
        '但 @file 没有这样的输入。它的输入是 @inputs。'
        '请确认放入的是同一种模型。',
    'badImageInputAxis':
        '输入形状不符：@role需要 @need 形式的 float32 图像输入，'
        '但 @file 的@axis，无法按这个形状喂数据。它的输入是 @inputs。'
        '请确认放入的是正确的@role。',
    'axisPinned': '第 @i 维（@name）固定为 @got，这里需要 @want',
    'axisBatch': '批量',
    'axisChannel': '通道数',
    'axisHeight': '高',
    'axisWidth': '宽',
    'roleDetector': '文字检测模型',
    'roleRec': '文字识别模型',
    'roleEncoder': 'manga-ocr 编码器',
    'detMapChannels':
        '输出不是概率图：检测模型应输出单通道的概率图（[batch,height,width] 或 '
        '[batch,1,height,width]），但 @file 的第一个输出是 @shape，'
        '不是 DBNet 能用的结果。请更换检测模型。',
    'detNotTensor': '@file 没有输出概率图（它的第一个输出不是张量）。',
    'recNotTensor': '@file 没有输出 CTC 概率（它的第一个输出不是张量）。',
    'recOutputRank':
        '输出形状不符：识别模型应输出 CTC 概率 [batch,sequence,classes]，'
        '但 @file 的第一个输出是 @shape（@rank 维张量）。'
        '把检测模型放进识别位，报的就是这个错。请更换识别模型。',
    'decoderInputs':
        '输入形状不符：manga-ocr 解码器需要一个 int64 的 token 输入和一个 '
        'float32 的编码器隐层输入，但 @file 的输入是 @inputs。',
    'decoderOutput':
        '输出形状不符：解码器应输出 [batch,position,vocabulary] 的词表概率，'
        '但 @file 的第一个输出是 @shape。',
    'decoderNotTensor':
        '@file 没有输出词表概率（它的第一个输出不是张量）。',
    'float16OnCpu':
        '精度不匹配：“@file”声明了 float16 张量（@tensors），'
        '但“@comp”走的是 CPU 路径，只能读 float32——硬跑只会安静地出乱码。'
        '这看起来是该模型的 FP16 版本，请换用 FP32 版本。',
    'float16NeedsGpu':
        '“@file”声明的是 float16 输入输出，只能在 GPU 执行提供者上运行。',
    'fixedBatch':
        '“@file”的批量维被固定为 1：可以用，但批量识别不会让它更快'
        '（每次只能送进一张裁切图）。',
    'runtimeResolvedClasses':
        '“@file”的类别数要到运行时才知道（输出 @shape 中下标 2 的那一维是动态的'
        '@note），所以@check没有执行——这一项只有真实会话能判断'
        '（runtime-resolved）。',
    // ---- dictionary / vocabulary pairing --------------------------------
    'dictClassMismatch':
        '类别数对不上：模型输出 @classes 类，而 "@dict" 只有 @lines 行。'
        '程序使用词典时会在最前面补一个空白类、最后补一个空格类，'
        '所以模型必须正好输出 @lines + @extra = @need 类。'
        '换了别的语言的词典、或换了另一代模型，就会这样对不上。'
        '请更换与该词典配套的模型。',
    'vocabClassMismatch':
        '词表对不上：解码器输出 @classes 个 token 类，而 vocab.txt 有 @lines 行。'
        '超出词表的 token 在解码时会被悄悄丢掉，'
        '请让解码器和词表来自同一个 manga-ocr 版本。',
    'dictNotUtf8':
        '@file 不是合法的 UTF-8 文本——多半是被改名的二进制文件，'
        '或者是下载到一半断掉的词典。',
    'dictEmpty':
        '@file 里没有任何词典内容。请把真正的词典放进去（每行一个字或一个词）。',
    'dictMissingOwn':
        '这个组件识别文字所需的词典（dict.txt）不存在。请把词典文件放入 @dir。',
    'dictMissingShared':
        '这个组件识别文字所需的词典不存在（它借用 "@from" 的 dict.txt）。'
        '请先安装那个提供词典的基础 OCR 组件。',
    'sharedDictNotUtf8':
        '借用的 dict.txt 不是合法的 UTF-8 文本，请重新安装提供它的那个基础 OCR '
        '组件。',
    // ---- checksums, runtime probe, bookkeeping ---------------------------
    'checksumMatch': '校验和与发布版本一致',
    'checksumDiffers':
        '校验和与发布版本不一致（实际为 @actual）。已按本地导入处理：'
        '只按文件结构判断能否使用。',
    'structureNotDoubleChecked': '结构无法二次核对（@err）',
    'runtimeLoadRefused':
        '“@file”完全无法被 ONNX 运行时加载——它只是名字叫模型文件而已。',
    'atRuntime': '运行时检查结果：@problem',
    'classCountDrift':
        '“@file”在元数据里声明 @declared 类，运行时却看到 @runtime 类：'
        '这个模型自相矛盾，不可信。请重新获取该文件。',
    'allFilesOk': '@count 个文件全部通过检查。',
    'componentNotPublished':
        '该组件尚未发布，应用不会加载它的文件，校验它的本地副本没有意义。',
    'validatorCrashed':
        '校验无法完成（@err）。文件已按“未校验”保留为可用状态：请重试，'
        '或重新下载该组件。',
    'dynamicAxesNote': '（显示为 ? 的维度是动态的，符号名为 @names）',
    'checkDictPair': '“类别数 = 词典行数 + @extra”这项核对',
    'checkVocabPair': '“类别数 = 词表行数”这项核对',
    'symbolicAxes': '，符号名为 @names',
    'fileDoesNotExist': '文件不存在（@path）',
  };

  /// [skeletons['componentNotPublished']], as a `const` the early return in
  /// [validateComponent] can hand to an [ImportVerdict] without a lookup.
  static const componentNotPublished =
      '该组件尚未发布，应用不会加载它的文件，校验它的本地副本没有意义。';

  /// Assemble message [id]: `assets/translation.json` wins for the current
  /// locale, the Chinese [skeletons] entry is the floor, and `@name` tokens
  /// are filled from [params].
  static String render(String id, [Map<String, Object> params = const {}]) {
    final skeleton = localized(id) ?? skeletons[id];
    if (skeleton == null) return id;
    var text = skeleton;
    for (final entry in params.entries) {
      text = text.replaceAll('@${entry.key}', '${entry.value}');
    }
    return text;
  }

  /// A label that lives in the table under its own name (a component's
  /// `displayNameKey`): the localised text when it is loaded, the key
  /// otherwise — never a crash, because a name is not worth one.
  /// Labels live under their own name, without the `modelCheck.` prefix: a
  /// component's `displayNameKey` is shared with the settings page.
  static String label(String key) => localized(key, namespaced: false) ?? key;

  /// The table entry for the current locale, or null when the bundle is not
  /// loaded (worker isolate, unit test) or has no such key.
  static String? localized(String id, {bool namespaced = true}) {
    try {
      final locale = App.locale;
      final table = locale.languageCode == 'en'
          ? 'en_US'
          : '${locale.languageCode}_${locale.countryCode}';
      final tableKey = namespaced ? '$namespace$id' : id;
      return AppTranslation.translations[table]?[tableKey];
    } catch (_) {
      // Two real cases, both expected: `AppTranslation.translations` is a
      // `late final` that only the UI startup fills (so reading it throws in
      // the worker isolate and in a unit test), and `App.locale` reads
      // `appdata`, which may not be ready yet. The caller then renders the
      // Chinese skeleton — the same text `zh_CN` carries.
      return null;
    }
  }
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
  ///
  /// [readOnnxSignature] normalises every spelling of "dynamic" to `null`,
  /// including the `-1` that Paddle writes as a literal `dim_value`.
  /// Hand-built signatures (a [SessionIntrospector]) may still carry `-1`:
  /// go through [staticDim] rather than reading this list directly.
  final List<int?> dims;

  /// Symbolic names (`dim_param`) per dimension, `''` when absent.
  final List<String> dimParams;

  /// False for non-tensor ports (sequences, maps) — not usable by the worker.
  final bool isTensor;

  /// The literal size of axis [i], or null when that axis is **dynamic**.
  ///
  /// `TensorShapeProto.Dimension` is a protobuf `oneof`: either `dim_value`
  /// (a literal) or `dim_param` (a symbolic name). Paddle2ONNX writes every
  /// dynamic axis as `dim_param = "p2o.DynamicDimension.3"`, HuggingFace
  /// torch exports as `dim_param = "height"`, and older Paddle exports as
  /// `dim_value = -1` — three spellings of the same statement: *"this axis is
  /// not pinned, it accepts any size"*. A dynamic axis therefore can never
  /// contradict a required shape, and only a **pinned** axis that differs is
  /// a mismatch. (A symbolic name is never itself evidence of anything: that
  /// misreading is what marked every healthy install invalid.)
  int? staticDim(int i) {
    if (i < 0 || i >= dims.length) return null;
    final d = dims[i];
    if (d == null || d < 0) return null;
    if (i < dimParams.length && dimParams[i].isNotEmpty) return null;
    return d;
  }

  /// The symbolic name (`dim_param`) of axis [i], `''` when it has none.
  String dimParam(int i) => (i >= 0 && i < dimParams.length) ? dimParams[i] : '';

  /// Whether axis [i] declares no fixed size (see [staticDim]).
  bool isDynamicDim(int i) => i >= 0 && i < dims.length && staticDim(i) == null;

  /// Whether axis [i] can carry [expected]: either it is dynamic ("any"), or
  /// it is pinned to exactly [expected]. This is the only question a static
  /// shape gate may ask of a declared axis.
  bool axisAllows(int i, int expected) {
    final d = staticDim(i);
    return d == null || d == expected;
  }

  bool get isFloat => elemType == OnnxElementType.float;
  bool get isFloat16 =>
      elemType == OnnxElementType.float16 ||
      elemType == OnnxElementType.bfloat16;
  bool get isInt64 => elemType == OnnxElementType.int64;
  int get rank => dims.length;

  /// Shape for human messages: dynamic axes render as `?`, never as their
  /// symbolic name (see [symbolicAxesNote] for the diagnostic form).
  String get shapeText {
    final parts = <String>[];
    for (var i = 0; i < dims.length; i++) {
      final d = staticDim(i);
      parts.add(d == null ? '?' : '$d');
    }
    return '[${parts.join(',')}]';
  }

  /// `axis=symbol` pairs of the dynamic axes, for diagnostics only.
  String? get symbolicAxesNote {
    final named = <String>[];
    for (var i = 0; i < dims.length; i++) {
      final p = i < dimParams.length ? dimParams[i] : '';
      if (isDynamicDim(i) && p.isNotEmpty) named.add('$i=$p');
    }
    return named.isEmpty ? null : named.join(', ');
  }

  @override
  String toString() => '$name: ${OnnxElementType.nameOf(elemType)}$shapeText';
}

/// Renders a tensor list for an error message.
///
/// Dynamic axes appear as `?` in the shapes, and the symbolic names behind
/// them are kept only as a trailing annotation: they say *why* an axis is
/// open, they are never output as the proof of a mismatch (that wording is
/// what told the user a healthy model was broken).
String describeTensors(Iterable<OnnxTensor> tensors) {
  final listed = tensors.toList();
  final body = listed.map((t) => t.toString()).join('; ');
  final notes = <String>[
    for (var t in listed)
      if (t.symbolicAxesNote != null) '${t.name}: ${t.symbolicAxesNote}',
  ];
  if (notes.isEmpty) return body;
  return '$body${ModelMessages.render('dynamicAxesNote', {'names': notes.join('; ')})}';
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
// Layout used (ONNX's onnx.proto field numbers, verified against the eight
// real model files of a live install — see the note on [parseGraph]):
//   ModelProto        : ir_version=1(varint) graph=7(bytes) opset_import=8 …
//   GraphProto        : node=1 name=2 initializer=5 doc_string=6
//                       input=11 output=12 value_info=13 …
//                       (11 IS the input list — this file had 11/12 swapped
//                       once, and the test fixtures agreed with the swap; see
//                       the note inside [parseGraph])
//   ValueInfoProto    : name=1 type=2
//   TypeProto         : tensor_type=1 sequence_type=4 map_type=5 …
//   TypeProto.Tensor  : elem_type=1(varint) shape=2
//   TensorShapeProto  : dim=1
//   TensorShapeProto.Dimension : oneof { dim_value=1(varint) dim_param=2(string) }
//
// Only ValueInfo subtrees are materialised; everything else (above all the
// multi-hundred-megabyte `initializer` weight blobs of GraphProto field 5)
// is skipped with an O(1) seek, so a full read of a 460 MB model costs a
// few hundred small reads — milliseconds, safe for any isolate, zero FFI.

/// Reads the declared graph input/output metadata of an ONNX file.
///
/// Throws [OnnxMetaReaderException] with a human message (Chinese, per
/// [ModelMessages]) when the file is not readable as an ONNX model: wrong
/// bytes, truncated download, HTML error page saved under a `.onnx` name…
OnnxSignature readOnnxSignature(String path, {String? fileName}) {
  final label = fileName ?? _baseName(path);
  final file = File(path);
  if (!file.existsSync()) {
    throw OnnxMetaReaderException(
      ModelMessages.render('fileDoesNotExist', {'path': path}),
    );
  }
  final raf = file.openSync();
  try {
    if (raf.lengthSync() == 0) {
      throw OnnxMetaReaderException(
        ModelMessages.render('emptyFile', {'file': label}),
      );
    }
    final r = _ProtoReader(raf, label);
    final first = r.readByte();
    // Rewind BOTH the bookkeeping and the actual file handle — they are
    // assumed to stay in lockstep everywhere else in the reader.
    r.pos = 0;
    raf.setPositionSync(0);
    if (first != 0x08) {
      // ModelProto always starts with the ir_version varint, field 1.
      throw OnnxMetaReaderException(
        ModelMessages.render('notOnnxModel', {
          'file': label,
          'byte': '0x${first.toRadixString(16).padLeft(2, '0')}',
        }),
      );
    }
    return r.parseModel(raf.lengthSync());
  } finally {
    raf.closeSync();
  }
}

/// Trailing path segment, for messages about a file the reader only knows by
/// path.
String _baseName(String path) {
  final normalised = path.replaceAll(r'\', '/');
  final cut = normalised.lastIndexOf('/');
  return cut < 0 || cut == normalised.length - 1
      ? normalised
      : normalised.substring(cut + 1);
}

class _ProtoReader {
  _ProtoReader(this.file, this.fileName);

  final RandomAccessFile file;

  /// What to call the file in a message: the name the component expects,
  /// not the (possibly absolute) path.
  final String fileName;
  int pos = 0;

  OnnxMetaReaderException _fail(String id) => OnnxMetaReaderException(
    ModelMessages.render(id, {'file': fileName}),
  );

  int readByte() {
    pos += 1;
    return file.readByteSync();
  }

  Uint8List readBytes(int n) {
    if (n < 0) {
      throw _fail('badProtobuf');
    }
    final buf = Uint8List(n);
    final got = file.readIntoSync(buf);
    if (got != n) {
      throw _fail('truncatedModel');
    }
    pos += n;
    return buf;
  }

  String readString(int n) => utf8.decode(readBytes(n), allowMalformed: true);

  void skip(int n) {
    if (n < 0) {
      throw _fail('badProtobuf');
    }
    pos += n;
    file.setPositionSync(pos);
  }

  int readVarint() {
    var result = 0;
    var shift = 0;
    while (true) {
      if (shift > 63) {
        throw _fail('badVarint');
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
        throw _fail('unreadableModel');
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
      throw _fail('inconsistentLengths');
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
      throw _fail('noGraph');
    }
    return graph!;
  }

  OnnxSignature parseGraph(int length) {
    final inputs = <OnnxTensor>[];
    final outputs = <OnnxTensor>[];
    // PRIMARY CAUSE of "every installed model is invalid" — read this before
    // "fixing" the shape rules.
    //
    // onnx.proto says `GraphProto.input = 11` and `GraphProto.output = 12`.
    // This reader had them the other way round, so `sig.inputs` held the
    // graph's OUTPUTS and vice versa: every healthy model was parsed
    // inside-out, and the user-facing sentence literally read
    //     its inputs are softmax_11.tmp_0: float32[…,6625]
    // which is an output tensor wearing an input's name. Ground truth was
    // taken from the eight real files of a live install (a separate protobuf
    // walk, not this reader): field 11 is always `x` / `pixel_values`, field
    // 12 is always `sigmoid_0.tmp_0` / `softmax_11.tmp_0` / `logits`.
    //
    // Why the tests stayed green across the whole period: the fixture writer
    // in `test/local_model_import_test.dart` was built to the SAME inverted
    // numbers. Reader and test agreed with each other and both disagreed with
    // the format — the shape of a test suite that can never catch its own
    // premise. A "symbolic dimensions are rejected" bug (the secondary
    // cause, see [OnnxTensor.staticDim]) was hiding underneath it and only
    // became visible once the two sides were re-derived from onnx.proto.
    scanScope(length, (fn, wt) {
      if (wt != 2) {
        skipBody(wt);
        return;
      }
      switch (fn) {
        case 11: // input
          inputs.add(parseValueInfo(readVarint()));
        case 12: // output
          outputs.add(parseValueInfo(readVarint()));
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

  /// One `TensorShapeProto.Dimension` — a `oneof` of `dim_value` (1) and
  /// `dim_param` (2). Returns the literal size, or `null` when the axis is
  /// dynamic, plus the symbolic name (empty when there is none).
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
    // A negative `dim_value` is not a size: Paddle's exporter writes -1 for
    // "unknown", which protobuf encodes as an unsigned varint that lands here
    // as 2^64-1 → -1 in Dart's 64-bit int. Normalise it (and any other
    // nonsense negative) to "dynamic" so the shape rules never mistake it
    // for a pinned axis.
    final pinned = value;
    if (pinned != null && pinned < 0) value = null;
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
  return ModelMessages.render('dictClassMismatch', {
    'classes': classes,
    'dict': dictName,
    'lines': dictLines,
    'extra': dictCharsetExtraClasses,
    'need': dictLines + dictCharsetExtraClasses,
  });
}

/// The manga-ocr rule: decoder output classes == vocab lines.
String? vocabClassMismatchProblem({
  required int classes,
  required int vocabLines,
}) {
  if (classes == vocabLines) return null;
  return ModelMessages.render(
    'vocabClassMismatch',
    {'classes': classes, 'lines': vocabLines},
  );
}

/// What a *dynamic* class axis means for the dictionary cross-check.
///
/// The `C == N + 2` gate (and the manga `C == vocab` gate) compares two
/// numbers. If the graph leaves its last axis open — `dim_param`, or the -1
/// Paddle writes — then `C` is **runtime-resolved**: the worker learns it
/// from the tensor it actually gets back (`_probeRecClasses` in
/// `translation_worker.dart`), and no static reading of the file can name it.
/// That is not a defect, and guessing a number here would be worse than
/// saying nothing: a wrong guess either strands a working model or waves
/// through a broken one. So the cross-check is skipped and this note records
/// exactly which check did not run, per file.
String? runtimeResolvedClassNote(
  ModelComponent c,
  ModelFile file,
  OnnxSignature sig,
) {
  final role = roleOf(c, file.name);
  if (role != ModelFileRole.rec && role != ModelFileRole.mangaDecoder) {
    return null;
  }
  final out = out3OrNull(sig);
  if (out == null) return null;
  if (out.staticDim(2) != null) return null;
  final symbol = out.dimParam(2);
  return ModelMessages.render('runtimeResolvedClasses', {
    'file': file.name,
    'shape': out.shapeText,
    'note': symbol.isEmpty
        ? ''
        : ModelMessages.render('symbolicAxes', {'names': symbol}),
    'check': ModelMessages.render(
      role == ModelFileRole.rec ? 'checkDictPair' : 'checkVocabPair',
      {'extra': dictCharsetExtraClasses},
    ),
  });
}

/// Is there an input this app can feed?
///
/// The rule is the one a declared shape actually permits: an axis counts as
/// satisfied when it is **pinned to the expected value or dynamic** ("any"),
/// and only a pinned axis with a different value is a mismatch — see
/// [OnnxTensor.axisAllows] for why the `dim_value` / `dim_param` oneof makes
/// that the only reading that is not nonsense.
///
/// [staticHeight] / [staticWidth] pin the spatial axes (the manga-ocr encoder
/// is compiled for 224×224); an open axis stays open, because nothing in the
/// graph forbids the size the worker will feed.
bool _hasImageInput(OnnxSignature sig, {int? staticHeight, int? staticWidth}) {
  for (var t in sig.inputs) {
    if (!t.isTensor || !t.isFloat || t.rank != 4) continue;
    if (!t.axisAllows(1, 3)) continue;
    if (staticHeight != null && !t.axisAllows(2, staticHeight)) continue;
    if (staticWidth != null && !t.axisAllows(3, staticWidth)) continue;
    return true;
  }
  return false;
}

/// "This is not the kind of model this slot expects", in words.
///
/// Two different answers, because they are two different problems for the
/// user: no image-shaped input at all (wrong file), versus an input whose
/// declared axes cannot accept what the worker feeds — which is named axis by
/// axis (`第 1 维（通道数）固定为 4，这里需要 3`), since "the shape is wrong"
/// without a number to look at is not actionable.
String _badImageInput(
  ModelFile file,
  OnnxSignature sig,
  String role,
  String need, {
  int? staticHeight,
  int? staticWidth,
}) {
  final params = {
    'file': file.name,
    'role': role,
    'need': need,
    'inputs': describeTensors(sig.inputs),
  };
  final axis = _pinnedImageAxis(sig, staticHeight: staticHeight, staticWidth: staticWidth);
  if (axis == null) {
    return ModelMessages.render('badImageInputShape', params);
  }
  return ModelMessages.render('badImageInputAxis', {...params, 'axis': axis});
}

/// The first axis of an otherwise image-shaped input that is *pinned* to a
/// value the worker cannot use, described in words; null when no input even
/// has the rank/element type of an image.
String? _pinnedImageAxis(
  OnnxSignature sig, {
  int? staticHeight,
  int? staticWidth,
}) {
  for (final t in sig.inputs) {
    if (!t.isTensor || !t.isFloat || t.rank != 4) continue;
    for (final (axis, want) in [
      (1, 3),
      if (staticHeight != null) (2, staticHeight),
      if (staticWidth != null) (3, staticWidth),
    ]) {
      final got = t.staticDim(axis);
      if (got != null && got != want) {
        return ModelMessages.render('axisPinned', {
          'i': axis,
          'name': ModelMessages.render('axis${_axisKey(axis)}'),
          'got': got,
          'want': want,
        });
      }
    }
  }
  return null;
}

String _axisKey(int axis) => const ['Batch', 'Channel', 'Height', 'Width'][axis];

/// Hard structural problems of one ONNX file, human-readable, or null.
///
/// Deliberately conservative: rules only reject shapes that provably cannot
/// work with the worker's fixed pre/post processing, never "unusual but
/// probably fine". A count that the graph does not fix (a dynamic class axis)
/// is *not* a defect — it is simply outside what a static check may judge, so
/// it is reported as a note by [runtimeResolvedClassNote] instead.
String? onnxStructuralProblem(
  ModelComponent c,
  ModelFile file,
  OnnxSignature sig,
) {
  final role = roleOf(c, file.name);
  if (sig.outputs.isEmpty) {
    return ModelMessages.render('noOutput', {'file': file.name});
  }
  final fp16 = _fp16Problem(c, file, sig);
  if (fp16 != null) return fp16;

  final out = sig.outputs.first;
  switch (role) {
    case ModelFileRole.detector:
      if (!_hasImageInput(sig)) {
        return _badImageInput(
          file,
          sig,
          ModelMessages.render('roleDetector'),
          '[batch,3,height,width]',
        );
      }
      if (!out.isTensor) {
        return ModelMessages.render('detNotTensor', {'file': file.name});
      }
      if (out.rank == 3) return null;
      if (out.rank == 4 && out.axisAllows(1, 1)) return null;
      return ModelMessages.render(
        'detMapChannels',
        {'file': file.name, 'shape': out.shapeText},
      );
    case ModelFileRole.rec:
      if (!_hasImageInput(sig)) {
        return _badImageInput(
          file,
          sig,
          ModelMessages.render('roleRec'),
          '[batch,3,height,width]',
        );
      }
      if (!out.isTensor) {
        return ModelMessages.render('recNotTensor', {'file': file.name});
      }
      if (out.rank != 3) {
        return ModelMessages.render('recOutputRank', {
          'file': file.name,
          'shape': out.shapeText,
          'rank': out.rank,
        });
      }
      return null;
    case ModelFileRole.mangaEncoder:
      if (!_hasImageInput(sig, staticHeight: 224, staticWidth: 224)) {
        return _badImageInput(
          file,
          sig,
          ModelMessages.render('roleEncoder'),
          '[batch,3,224,224]',
          staticHeight: 224,
          staticWidth: 224,
        );
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
        return ModelMessages.render('decoderInputs', {
          'file': file.name,
          'inputs': describeTensors(sig.inputs),
        });
      }
      if (!out.isTensor) {
        return ModelMessages.render('decoderNotTensor', {'file': file.name});
      }
      if (out.rank != 3) {
        return ModelMessages.render(
          'decoderOutput',
          {'file': file.name, 'shape': out.shapeText},
        );
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
      if (t.isTensor && t.isFloat16) '${t.name}（输入）',
    for (var t in sig.outputs)
      if (t.isTensor && t.isFloat16) '${t.name}（输出）',
  ];
  if (bad.isEmpty) return null;
  return ModelMessages.render('float16OnCpu', {
    'file': file.name,
    'tensors': bad.join('、'),
    'comp': ModelMessages.label(c.displayNameKey ?? c.id),
  });
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
      mainInput.staticDim(0) == 1) {
    warnings.add(
      ModelMessages.render('fixedBatch', {'file': file.name}),
    );
  }
  if (c.requiresGpuEp) {
    final fp16 = [...sig.inputs, ...sig.outputs].any(
      (t) => t.isTensor && t.isFloat16,
    );
    if (fp16) {
      warnings.add(
        ModelMessages.render('float16NeedsGpu', {'file': file.name}),
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

/// Add a per-file note without clobbering the one already there (the checksum
/// verdict and a structural note can both concern the same file).
void _appendNote(_ComponentAnalysis a, String fileName, String note) {
  final old = a.notes[fileName];
  a.notes[fileName] = (old == null || old.isEmpty) ? note : '$old / $note';
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
      reason: ModelMessages.componentNotPublished,
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
          _appendNote(a, file.name, ModelMessages.render('checksumMatch'));
        } else {
          shaMatched[file.name] = false;
          _appendNote(
            a,
            file.name,
            ModelMessages.render('checksumDiffers', {'actual': actual}),
          );
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
            ModelMessages.render('runtimeLoadRefused', {'file': file.name}),
          );
          break;
        }
        final problem = onnxStructuralProblem(component, file, runtime);
        if (problem != null && shaMatched[file.name] != true) {
          a.failedFile = file.name;
          a.problems.add(
            ModelMessages.render('atRuntime', {'problem': problem}),
          );
          break;
        }
        final runtimeOut = out3OrNull(runtime);
        // `dims[2]` on its own would read Paddle's -1 as a class count.
        final runtimeClasses = runtimeOut?.staticDim(2);
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
            a.problems.add(
              ModelMessages.render('atRuntime', {'problem': pairProblem}),
            );
            break;
          }
          final staticOut = out3OrNull(a.signatures[file.name]!);
          if (staticOut?.dims[2] != null &&
              staticOut!.dims[2] != runtimeClasses) {
            a.failedFile = file.name;
            a.problems.add(
              ModelMessages.render('classCountDrift', {
                'file': file.name,
                'declared': staticOut.staticDim(2) ?? '?',
                'runtime': runtimeClasses,
              }),
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
        ? ModelMessages.render(
            'allFilesOk',
            {'count': component.files.length},
          )
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
          ModelMessages.render('validatorCrashed', {'err': e}),
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
        ModelMessages.render('missingFile', {
          'file': file.name,
          'dir': component.directory,
        }),
      );
      return;
    }
    if (f.lengthSync() == 0) {
      a.failedFile = file.name;
      a.problems.add(
        ModelMessages.render('emptyFile', {'file': file.name}),
      );
      return;
    }
    if (checkLocks && _isLocked(path)) {
      a.failedFile = file.name;
      a.problems.add(
        ModelMessages.render('lockedFile', {'file': file.name}),
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
            _appendNote(
              a,
              file.name,
              ModelMessages.render(
                'structureNotDoubleChecked',
                {'err': e.message},
              ),
            );
            continue;
          }
          a.failedFile = file.name;
          // The reader's own message already names the file and explains the
          // defect in Chinese; wrapping it again would put English around it.
          a.problems.add(e.message);
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
        // A class axis the graph leaves open is recorded as a note and the
        // matching cross-check below simply does not run: never guessed.
        final resolved = runtimeResolvedClassNote(component, file, sig);
        if (resolved != null) {
          _appendNote(a, file.name, resolved);
          a.warnings.add(resolved);
        }
        if (role == ModelFileRole.rec || role == ModelFileRole.mangaDecoder) {
          final out = out3OrNull(sig);
          if (out != null) {
            if (role == ModelFileRole.rec) recClasses = out.staticDim(2);
            if (role == ModelFileRole.mangaDecoder) {
              decoderClasses = out.staticDim(2);
            }
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
      ModelMessages.render('dictNotUtf8', {'file': fileName}),
    );
    return null;
  } on FileSystemException catch (e) {
    a.failedFile = fileName;
    a.problems.add(
      ModelMessages.render('fileUnreadable', {'file': fileName, 'os': e}),
    );
    return null;
  }
  if (lines.isEmpty) {
    a.failedFile = fileName;
    a.problems.add(
      ModelMessages.render('dictEmpty', {'file': fileName}),
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
    final from = component.dictFrom;
    a.problems.add(
      from == null
          ? ModelMessages.render(
              'dictMissingOwn',
              {'dir': component.directory},
            )
          : ModelMessages.render('dictMissingShared', {'from': from}),
    );
    return null;
  }
  try {
    return dictLineCountSync(dictPath);
  } on FormatException {
    a.failedFile = null;
    a.problems.add(ModelMessages.render('sharedDictNotUtf8'));
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
