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
/// `#negativeOne` writes `dim_value = -1` the way Paddle does (a 10-byte
/// unsigned varint) — a third spelling of "dynamic", see [_dim].
List<int> _dim(Object? d) {
  if (d is Symbol && d == #negativeOne) return _intField(1, -1);
  if (d is int) return _intField(1, d);
  if (d is String && d.isNotEmpty) return _stringField(2, d);
  return const [];
}

/// `TensorShapeProto.Dimension` in full: literal `dim_value`, symbolic
/// `dim_param`, Paddle's `-1`, or an entirely empty (unknown) dimension.
const _any = #negativeOne;

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

/// ModelProto { ir_version = 8; graph = GraphProto { input=11…, output=12… } }
///
/// The field numbers here are the whole point of the fixture writer: ONNX's
/// `GraphProto` declares `input = 11` and `output = 12`, and the reader used
/// to have them the other way round — with the writer built to the reader's
/// wrong assumption, every unit test stayed green while each of the eight
/// real model files on disk was read inside-out. Both sides now come from
/// onnx.proto, and the pinned mapping test below is what keeps them there.
List<int> onnxModelBytes({
  required List<(String, int, List<Object?>)> inputs,
  required List<(String, int, List<Object?>)> outputs,
}) {
  final graph = <int>[];
  for (final i in inputs) {
    graph.addAll(_bytesField(11, _valueInfo(i)));
  }
  for (final o in outputs) {
    graph.addAll(_bytesField(12, _valueInfo(o)));
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

// ---------------------------------------------------------------------------
// Shapes copied from the real installed models (Paddle2ONNX / torch export).
// Every dynamic axis there is a `dim_param` name, not `-1` — which is the
// exact thing the validator used to read as "wrong shape". See the
// `oneof dimension semantics` group below.
// ---------------------------------------------------------------------------

/// `ch_PP-OCRv4_rec_infer.onnx` as Paddle2ONNX writes it:
/// `x: f32[p2o.DD.0, 3, ?, p2o.DD.1]` → `softmax_11.tmp_0: f32[p2o.DD.2, p2o.DD.3, C]`.
List<int> paddleRecBytes(int classes) => onnxModelBytes(
  inputs: [
    ('x', _f32, ['p2o.DynamicDimension.0', 3, null, 'p2o.DynamicDimension.1']),
  ],
  outputs: [
    (
      'softmax_11.tmp_0',
      _f32,
      ['p2o.DynamicDimension.2', 'p2o.DynamicDimension.3', classes],
    ),
  ],
);

/// Same graph, every axis symbolic — including the channel axis. Nothing in
/// it is pinned, so nothing in it can contradict the required shape.
List<int> fullySymbolicRecBytes(int classes) => onnxModelBytes(
  inputs: [
    (
      'x',
      _f32,
      [
        'p2o.DynamicDimension.0',
        'p2o.DynamicDimension.1',
        'p2o.DynamicDimension.2',
        'p2o.DynamicDimension.3',
      ],
    ),
  ],
  outputs: [
    (
      'softmax_11.tmp_0',
      _f32,
      ['p2o.DynamicDimension.4', 'p2o.DynamicDimension.5', classes],
    ),
  ],
);

/// `ch_PP-OCRv4_det_infer.onnx` (DBNet): both axes of the map are symbolic,
/// and so is the "1" channel of the output in some exports.
List<int> paddleDetBytes({bool symbolicMapChannel = false}) => onnxModelBytes(
  inputs: [
    (
      'x',
      _f32,
      [
        'p2o.DynamicDimension.0',
        3,
        'p2o.DynamicDimension.1',
        'p2o.DynamicDimension.2',
      ],
    ),
  ],
  outputs: [
    (
      'sigmoid_0.tmp_0',
      _f32,
      [
        'p2o.DynamicDimension.3',
        symbolicMapChannel ? 'p2o.DynamicDimension.4' : 1,
        'p2o.DynamicDimension.4',
        'p2o.DynamicDimension.5',
      ],
    ),
  ],
);

/// `manga-ocr encoder_model.onnx` as the HuggingFace export names its axes:
/// `pixel_values: f32[batch_size, num_channels, height, width]`.
List<int> symbolicMangaEncoderBytes() => onnxModelBytes(
  inputs: [
    (
      'pixel_values',
      _f32,
      ['batch_size', 'num_channels', 'height', 'width'],
    ),
  ],
  outputs: [
    (
      'last_hidden_state',
      _f32,
      ['batch_size', 'Addlast_hidden_state_dim_1', 'Addlast_hidden_state_dim_2'],
    ),
  ],
);

/// The same encoder with every axis written as Paddle's `dim_value = -1`.
List<int> minusOneMangaEncoderBytes() => onnxModelBytes(
  inputs: [('pixel_values', _f32, [_any, _any, _any, _any])],
  outputs: [('last_hidden_state', _f32, [_any, _any, 768])],
);

/// The PP-OCRv3/v4 recognition graph the older exports ship: batch and
/// channels pinned, `-1` where the size is open.
List<int> minusOneRecBytes(int classes) => onnxModelBytes(
  inputs: [('x', _f32, [_any, 3, _any, _any])],
  outputs: [('softmax_2.tmp_0', _f32, [_any, _any, classes])],
);

/// The `ocr_ja` trio with symbolic encoder/decoder axes and a [vocabLines]-
/// line vocabulary the decoder's pinned class count matches.
void installSymbolicOcrJa({int vocabLines = 6, int? decoderClasses}) {
  writeBytes(TranslationModels.ocrJa, 'encoder.onnx', symbolicMangaEncoderBytes());
  writeBytes(
    TranslationModels.ocrJa,
    'decoder.onnx',
    onnxModelBytes(
      inputs: [
        ('input_ids', _i64, ['batch_size', 'decoder_sequence_length']),
        (
          'encoder_hidden_states',
          _f32,
          ['batch_size', 'encoder_sequence_length', 768],
        ),
      ],
      outputs: [
        (
          'logits',
          _f32,
          [
            'batch_size',
            'decoder_sequence_length',
            decoderClasses ?? vocabLines,
          ],
        ),
      ],
    ),
  );
  writeText(
    TranslationModels.ocrJa,
    'vocab.txt',
    '${List.generate(vocabLines, (i) => 'token$i').join('\n')}\n',
  );
}

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
      expect(v.reason, contains('缺少文件：rec.onnx'));
      expect(v.reason, contains('translation_models'));
    });

    test('empty file (interrupted copy) → says so in words', () async {
      writeText(TranslationModels.ocrZh, 'dict.txt', 'a\nb\nc\n');
      writeBytes(TranslationModels.ocrZh, 'rec.onnx', const []);
      final v = await validateComponent(TranslationModels.ocrZh);
      expect(v.ok, isFalse);
      expect(v.reason, contains('文件为空（0 字节）：rec.onnx'));
    });

    test(
      'dict line count mismatch → names C, N and the N+2 rule',
      () async {
        writeText(TranslationModels.ocrZh, 'dict.txt', 'a\nb\nc\n');
        writeBytes(TranslationModels.ocrZh, 'rec.onnx', recModelBytes(99));
        final v = await validateComponent(TranslationModels.ocrZh);
        expect(v.ok, isFalse);
        expect(v.state, ModelState.invalid);
        expect(v.reason, contains('模型输出 99 类'));
        expect(v.reason, contains('dict.txt" 只有 3 行'));
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
      expect(v.reason, contains('不像是一个 ONNX 模型'));
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
      expect(v.reason, contains('单通道的概率图'));

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
      expect(v.reason, contains('精度不匹配'));
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
        contains(contains('批量维被固定为 1')),
      );
    });
  });

  // =========================================================================
  // Defect 1, secondary cause (the primary one is the input/output field
  // number swap, pinned by the named test in this group): a declared
  // dimension is a protobuf `oneof` — `dim_value` (a literal) or `dim_param`
  // (a symbolic name). Real exporters write dynamic
  // axes as names (`p2o.DynamicDimension.3`, `height`) or as `-1`, and the
  // validator demanded a literal, so a model whose channel axis is symbolic
  // (the manga-ocr encoder: `pixel_values: f32[batch_size, num_channels,
  // height, width]`) came back "not shaped like a recognition model" →
  // invalid → not installed →
  // no worker paths → translation dead. These tests pin the *correct* reading
  // in both directions: dynamic satisfies, and a genuinely pinned wrong value
  // is still refused (the guard against "make it green by deleting the check").
  // =========================================================================
  group('oneof dimension semantics: symbolic axes mean "any", not "wrong"', () {
    test(
        'REGRESSION (primary cause): onnx.proto field 11 = input, 12 = output '
        '— the reader had them swapped, and the old fixtures agreed with the '
        'swap', () {
      // This is the test that would have failed every version of the suite
      // before the fix, because the fixture writer below used to emit
      // outputs at field 11 and inputs at field 12: reader and test were
      // self-consistent and both were wrong. Never "fix" a shape-rule failure
      // by making this pair match each other again — match onnx.proto, then
      // match the real files (see the note on `parseGraph`).
      final path = pathOf(TranslationModels.ocrZh, 'rec.onnx');
      File(path).createSync(recursive: true);
      File(path).writeAsBytesSync(
        onnxModelBytes(
          inputs: [('x', _f32, ['p2o.DynamicDimension.0', 3, 48, null])],
          outputs: [('softmax_11.tmp_0', _f32, [null, null, 6625])],
        ),
      );
      final sig = readOnnxSignature(path);
      expect(sig.inputs.map((t) => t.name), ['x']);
      expect(sig.outputs.map((t) => t.name), ['softmax_11.tmp_0']);
      expect(sig.outputs.single.staticDim(2), 6625);
    });

    test('a Paddle2ONNX recognition graph validates', () async {
      writeText(TranslationModels.ocrZh, 'dict.txt', 'a\nb\nc\n');
      writeBytes(TranslationModels.ocrZh, 'rec.onnx', paddleRecBytes(5));
      final v = await validateComponent(TranslationModels.ocrZh);
      expect(v.ok, isTrue, reason: v.reason);
      expect(TranslationModels.ocrZh.isInstalled, isTrue);
    });

    test('a recognition graph with EVERY axis symbolic validates', () async {
      writeText(TranslationModels.ocrZh, 'dict.txt', 'a\nb\nc\n');
      writeBytes(
        TranslationModels.ocrZh,
        'rec.onnx',
        fullySymbolicRecBytes(5),
      );
      final v = await validateComponent(TranslationModels.ocrZh);
      expect(v.ok, isTrue, reason: v.reason);
    });

    test('a Paddle2ONNX detector graph validates, pinned map channel or not',
        () async {
      for (final symbolic in [false, true]) {
        writeBytes(
          TranslationModels.detector,
          'det.onnx',
          paddleDetBytes(symbolicMapChannel: symbolic),
        );
        TranslationModels.forgetVerdictsFor(TranslationModels.detector);
        final v = await validateComponent(TranslationModels.detector);
        expect(v.ok, isTrue, reason: 'symbolic map channel: $symbolic\n${v.reason}');
      }
    });

    test('the manga-ocr encoder with named dynamic axes validates', () async {
      installSymbolicOcrJa();
      final v = await validateComponent(TranslationModels.ocrJa);
      expect(v.ok, isTrue, reason: v.reason);
      expect(TranslationModels.ocrJa.isInstalled, isTrue);
    });

    test('dim_value = -1 is another spelling of dynamic, not the size 2^64-1',
        () async {
      writeText(TranslationModels.ocrZh, 'dict.txt', 'a\nb\nc\n');
      writeBytes(TranslationModels.ocrZh, 'rec.onnx', minusOneRecBytes(5));
      final v = await validateComponent(TranslationModels.ocrZh);
      expect(v.ok, isTrue, reason: v.reason);
      final sig = readOnnxSignature(pathOf(TranslationModels.ocrZh, 'rec.onnx'));
      expect(sig.inputs.single.staticDim(0), isNull);
      expect(sig.inputs.single.isDynamicDim(0), isTrue);
      // …while a literal 1 stays the literal 1 the batch warning depends on.
      final pinned = recModelBytes(5, batchDim: 1);
      final p2 = pathOf(TranslationModels.ocrZh, 'rec.onnx');
      File(p2).writeAsBytesSync(pinned);
      expect(readOnnxSignature(p2).inputs.single.staticDim(0), 1);
    });

    test('an install of symbolic-dimension models still reaches the worker',
        () {
      // The user-visible consequence of the defect: no rec/det path at all.
      writeText(TranslationModels.ocrZh, 'dict.txt', 'a\nb\nc\n');
      writeBytes(TranslationModels.ocrZh, 'rec.onnx', paddleRecBytes(5));
      writeBytes(TranslationModels.detector, 'det.onnx', paddleDetBytes());
      final paths = TranslationModels.workerPaths(
        tier: ModelTier.fast,
        gpuEpActive: false,
      );
      expect(paths.recModels['zh'], contains('ocr_zh'));
      expect(paths.recDicts['zh'], isNotNull);
      expect(paths.detector, contains('text_detector'));
      expect(TranslationModels.isReadyFor('zh', tier: ModelTier.fast), isTrue);
    });

    test('a PINNED axis that contradicts the required value is still invalid',
        () async {
      // channels = 4 is not dynamic: it is a hard no. If this test goes
      // green-by-deletion, the whole gate is worthless.
      writeText(TranslationModels.ocrZh, 'dict.txt', 'a\nb\nc\n');
      writeBytes(
        TranslationModels.ocrZh,
        'rec.onnx',
        onnxModelBytes(
          inputs: [('x', _f32, [null, 4, 48, 'width'])],
          outputs: [('softmax', _f32, [null, null, 5])],
        ),
      );
      final v = await validateComponent(TranslationModels.ocrZh);
      expect(v.ok, isFalse);
      expect(v.state, ModelState.invalid);
      expect(v.reason, contains('输入形状不符'));

      // Same for a detector fed a 2-channel image input.
      writeBytes(
        TranslationModels.detector,
        'det.onnx',
        onnxModelBytes(
          inputs: [('x', _f32, [null, 2, null, null])],
          outputs: [('sigmoid', _f32, [null, 1, null, null])],
        ),
      );
      final dv = await validateComponent(TranslationModels.detector);
      expect(dv.ok, isFalse);
      expect(dv.reason, contains('输入形状不符'));
      expect(dv.reason, contains('第 1 维（通道数）固定为 2，这里需要 3'));
    });

    test('a pinned class count that contradicts the dictionary is still invalid',
        () async {
      // 6625 is a literal, so `C == N + 2` runs and refuses it: proving the
      // dynamic-axis fix did not take the cross-check with it.
      writeText(TranslationModels.ocrZh, 'dict.txt', 'a\nb\nc\n');
      writeBytes(TranslationModels.ocrZh, 'rec.onnx', paddleRecBytes(6625));
      final v = await validateComponent(TranslationModels.ocrZh);
      expect(v.ok, isFalse);
      expect(v.reason, contains('模型输出 6625 类'));
      expect(v.reason, contains('3 + 2 = 5'));
      expect(TranslationModels.ocrZh.isInstalled, isFalse);
    });

    test('a rank-4 image tensor in the recognition slot is still invalid',
        () async {
      writeText(TranslationModels.ocrZh, 'dict.txt', 'a\nb\nc\n');
      writeBytes(
        TranslationModels.ocrZh,
        'rec.onnx',
        onnxModelBytes(
          inputs: [('x', _f32, ['b', 3, 'h', 'w'])],
          outputs: [('map', _f32, ['b', 1, 'h', 'w'])],
        ),
      );
      final v = await validateComponent(TranslationModels.ocrZh);
      expect(v.ok, isFalse);
      expect(v.reason, contains('[batch,sequence,classes]'));
    });

    test('dynamic axes render as ?, and a symbolic name is only an annotation',
        () async {
      writeText(TranslationModels.ocrZh, 'dict.txt', 'a\nb\nc\n');
      writeBytes(
        TranslationModels.ocrZh,
        'rec.onnx',
        onnxModelBytes(
          inputs: [
            (
              'im_data',
              _i64,
              [
                'p2o.DynamicDimension.0',
                'p2o.DynamicDimension.1',
                'p2o.DynamicDimension.2',
                'p2o.DynamicDimension.3',
              ],
            ),
          ],
          outputs: [
            (
              'softmax_11.tmp_0',
              _f32,
              ['p2o.DynamicDimension.4', 'p2o.DynamicDimension.5', 5],
            ),
          ],
        ),
      );
      final v = await validateComponent(TranslationModels.ocrZh);
      expect(v.ok, isFalse);
      // The shape the message quotes is `?`-normalised…
      expect(v.reason, contains('im_data: int64[?,?,?,?]'));
      // …never a symbolic name standing in for a size…
      expect(v.reason, isNot(contains('[p2o.')));
      expect(v.reason, isNot(contains('int64[p2o.')));
      // …while the names survive as an explicitly labelled diagnostic.
      expect(v.reason, contains('显示为 ? 的维度是动态的'));
      expect(v.reason, contains('0=p2o.DynamicDimension.0'));
    });

    test('an open class axis skips C == N + 2 and says so, never guesses',
        () async {
      writeText(TranslationModels.ocrZh, 'dict.txt', 'a\nb\nc\n');
      writeBytes(
        TranslationModels.ocrZh,
        'rec.onnx',
        onnxModelBytes(
          inputs: [('x', _f32, ['batch', 3, 48, 'width'])],
          outputs: [
            ('softmax', _f32, ['batch', 'sequence', 'p2o.DynamicDimension.6']),
          ],
        ),
      );
      final v = await validateComponent(TranslationModels.ocrZh);
      expect(v.ok, isTrue, reason: v.reason);
      expect(v.notes['rec.onnx'], contains('runtime-resolved'));
      expect(v.notes['rec.onnx'], contains('“类别数 = 词典行数 + 2”这项核对没有执行'));
      expect(v.warnings, contains(contains('runtime-resolved')));
    });

    test('a dynamic vocabulary axis skips the manga cross-check the same way',
        () async {
      writeBytes(
        TranslationModels.ocrJa,
        'encoder.onnx',
        symbolicMangaEncoderBytes(),
      );
      writeBytes(
        TranslationModels.ocrJa,
        'decoder.onnx',
        onnxModelBytes(
          inputs: [
            ('input_ids', _i64, ['batch_size', 'decoder_sequence_length']),
            (
              'encoder_hidden_states',
              _f32,
              ['batch_size', 'encoder_sequence_length', 768],
            ),
          ],
          outputs: [
            (
              'logits',
              _f32,
              ['batch_size', 'decoder_sequence_length', 'vocab_size'],
            ),
          ],
        ),
      );
      writeText(TranslationModels.ocrJa, 'vocab.txt', 'a\nb\nc\n');
      final v = await validateComponent(TranslationModels.ocrJa);
      expect(v.ok, isTrue, reason: v.reason);
      expect(v.notes['decoder.onnx'], contains('runtime-resolved'));
      expect(v.notes['decoder.onnx'], contains('“类别数 = 词表行数”这项核对没有执行'));
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
      expect(v.reason, contains('它借用 "ocr_zh" 的 dict.txt'));
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
      expect(v.reason, contains('解码器输出 6 个 token 类'));
      expect(v.reason, contains('vocab.txt 有 5 行'));
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
        contains('模型输出 42 类'),
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

  // =========================================================================
  // Defect 3: the page runs one detection pass as it opens, so the pass has
  // to be cheap (ledger-backed) and it has to call a present-but-broken file
  // a failure without calling "not installed" one.
  // =========================================================================
  group('detection pass as the page opens (cheap, and honest)', () {
    const swept = [
      TranslationModels.detector,
      TranslationModels.ocrZh,
    ];

    test('the first pass parses, the second one comes from the ledger', () {
      writeText(TranslationModels.ocrZh, 'dict.txt', 'a\nb\nc\n');
      writeBytes(TranslationModels.ocrZh, 'rec.onnx', paddleRecBytes(5));
      writeBytes(TranslationModels.detector, 'det.onnx', paddleDetBytes());
      TranslationModels.resetStructureGateRunsForTest();
      final first = TranslationModels.runDetectionPass(swept);
      expect(first.rechecks, 2, reason: 'nothing was ever checked: both parse');
      expect(first.hasFailures, isFalse, reason: first.failed.toString());
      final second = TranslationModels.runDetectionPass(swept);
      expect(
        second.rechecks,
        0,
        reason: 'same size@mtime fingerprint must not re-read a model header',
      );
      expect(second.states.values, everyElement(ModelState.present));
    });

    test('replacing one file re-parses exactly that component', () {
      writeText(TranslationModels.ocrZh, 'dict.txt', 'a\nb\nc\n');
      writeBytes(TranslationModels.ocrZh, 'rec.onnx', paddleRecBytes(5));
      writeBytes(TranslationModels.detector, 'det.onnx', paddleDetBytes());
      TranslationModels.runDetectionPass(swept);
      TranslationModels.resetStructureGateRunsForTest();
      // A different *size* on purpose: the fingerprint is `size@mtime`, and
      // two writes inside the same millisecond would otherwise make this
      // test depend on the clock.
      writeBytes(TranslationModels.detector, 'det.onnx', detModelBytes());
      final again = TranslationModels.runDetectionPass(swept);
      expect(again.rechecks, 1);
      expect(again.states[TranslationModels.detector.id], ModelState.present);
    });

    test('a present-but-broken file is a failure; a missing one is not', () {
      // Nothing installed at all: the rows already say "Download", so the
      // page must not nag with a check-everything button.
      var result = TranslationModels.runDetectionPass(swept);
      expect(result.hasFailures, isFalse);
      expect(result.states.values, everyElement(ModelState.absent));

      writeText(TranslationModels.ocrZh, 'dict.txt', 'a\nb\nc\n');
      writeBytes(TranslationModels.ocrZh, 'rec.onnx', paddleRecBytes(42));
      result = TranslationModels.runDetectionPass(swept);
      expect(result.hasFailures, isTrue);
      expect(result.failed, [TranslationModels.ocrZh.id]);
      expect(result.detailOf(TranslationModels.ocrZh), contains('模型输出 42 类'));
    });

    test('a symbolic-dimension install sweeps clean — no button, no red rows',
        () {
      // The whole point of the defect-1 fix seen from the UI: opening the page
      // on a healthy 2026 install must produce zero complaints.
      writeText(TranslationModels.ocrZh, 'dict.txt', 'a\nb\nc\n');
      writeBytes(TranslationModels.ocrZh, 'rec.onnx', paddleRecBytes(5));
      writeBytes(TranslationModels.detector, 'det.onnx', paddleDetBytes());
      installSymbolicOcrJa();
      final result = TranslationModels.runDetectionPass([
        ...swept,
        TranslationModels.ocrJa,
      ]);
      expect(result.failed, isEmpty, reason: result.states.toString());
    });

    test('unpublished components are never swept into an invalid verdict', () {
      // runDetectionPass skips disabled rows: validateComponent would answer
      // them with "not published", which is not a file defect.
      final result = TranslationModels.runDetectionPass(TranslationModels.all);
      expect(result.states.containsKey('ocr_zh_fp16'), isFalse);
      expect(result.states.containsKey('ocr_ja_fp16'), isFalse);
      expect(result.hasFailures, isFalse);
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
      expect(v.notes['rec.onnx'], contains('校验和与发布版本一致'));
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
      expect(v.notes['rec.onnx'], contains('已按本地导入处理'));
      expect(v.reason, contains('不像是一个 ONNX 模型'));
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
        expect(v.notes['rec.onnx'], contains('校验和与发布版本不一致'));
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
      expect(v.reason, contains('完全无法被 ONNX 运行时加载'));
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
      expect(v.reason, contains('运行时检查结果：'));
      expect(v.reason, contains('模型输出 42 类'));
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
