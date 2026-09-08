import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/image_translation/translation_models.dart';
import 'package:venera/foundation/image_translation/translation_types.dart';
import 'package:venera/foundation/image_translation/translation_worker.dart';

void main() {
  group('Dict and Charset Consistency (V3-6)', () {
    late Directory tempDir;
    late File dictFile;

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('ocr_dict_test_');
      dictFile = File('${tempDir.path}/test_dict.txt');
      // Create a mock dictionary with 5 lines
      dictFile.writeAsStringSync('a\nb\nc\nd\ne\n');
    });

    tearDown(() {
      if (tempDir.existsSync()) {
        tempDir.deleteSync(recursive: true);
      }
    });

    test('loadCharset produces correct blank and space tokens', () {
      final charset = loadCharset(dictFile.path);
      // 5 lines in dict + blank at index 0 + space at last index = 7 tokens
      expect(charset.length, 7);
      expect(charset.first, '');
      expect(charset.last, ' ');
      expect(charset.sublist(1, 6), ['a', 'b', 'c', 'd', 'e']);
    });

    test('loadCharset succeeds when expectedClasses matches charset.length', () {
      final charset = loadCharset(dictFile.path, expectedClasses: 7);
      expect(charset.length, 7);
    });

    test('loadCharset throws DictMismatchException when expectedClasses does not match', () {
      expect(
        () => loadCharset(dictFile.path, expectedClasses: 10),
        throwsA(isA<DictMismatchException>()),
      );

      try {
        loadCharset(dictFile.path, expectedClasses: 10);
        fail('Should have thrown DictMismatchException');
      } on DictMismatchException catch (e) {
        expect(e.message, contains('Expected 8 dict lines but got 5'));
      }
    });

    test('loadCharset throws DictMismatchException when file is missing', () {
      expect(
        () => loadCharset('${tempDir.path}/non_existent.txt'),
        throwsA(isA<DictMismatchException>()),
      );
    });
  });

  group('Direction-Aware Line Inflation (RecParams)', () {
    test('horizontal text expands symmetrically by padPx', () {
      // 100 wide x 30 high: left=50, top=50, right=150, bottom=80 (h / w = 0.3 <= 1.3)
      final line = IntRect(50, 50, 150, 80);
      final inflated = RecParams.inflateLine(line, 500, 500);

      expect(inflated.left, 50 - RecParams.padPx);
      expect(inflated.right, 150 + RecParams.padPx);
      expect(inflated.top, 50 - RecParams.padPx);
      expect(inflated.bottom, 80 + RecParams.padPx);
    });

    test('vertical text expands vertically by padPx * 3', () {
      // 20 wide x 60 high: left=50, top=50, right=70, bottom=110 (h / w = 3.0 > 1.3)
      final line = IntRect(50, 50, 70, 110);
      final inflated = RecParams.inflateLine(line, 500, 500);

      expect(inflated.left, 50 - RecParams.padPx);
      expect(inflated.right, 70 + RecParams.padPx);
      expect(inflated.top, 50 - RecParams.padPx * 3);
      expect(inflated.bottom, 110 + RecParams.padPx * 3);
    });
  });

  group('Model Tier and CPU Guard (F3)', () {
    test('workerPaths with gpuEpActive: false never includes requiresGpuEp models', () {
      final paths = TranslationModels.workerPaths(
        tier: ModelTier.high,
        gpuEpActive: false,
      );

      // Even when tier is high, FP16 variants requiring GPU must not be selected on CPU
      if (paths.jaEncoder != null) {
        expect(paths.jaEncoder, isNot(contains('fp16')));
      }
      for (var model in paths.recModels.values) {
        expect(model, isNot(contains('fp16')));
      }
    });

    test('ModelComponent properties are correctly initialized', () {
      expect(TranslationModels.detector.tier, ModelTier.fast);
      expect(TranslationModels.detectorHigh.tier, ModelTier.high);
      expect(TranslationModels.detectorManga.enabled, isFalse);

      expect(TranslationModels.ocrZhFp16.requiresGpuEp, isTrue);
      expect(TranslationModels.ocrZhHighFp16.requiresGpuEp, isTrue);
      expect(TranslationModels.ocrJaFp16.requiresGpuEp, isTrue);

      expect(TranslationModels.ocrZhHigh.dictFrom, 'ocr_zh');
      expect(TranslationModels.ocrZhHighFp16.dictFrom, 'ocr_zh');
    });

    test('ModelKind groups components appropriately', () {
      final detectors = TranslationModels.all
          .where((c) => c.kind == ModelKind.detector)
          .map((c) => c.id)
          .toList();
      expect(detectors, containsAll(['text_detector', 'text_detector_high', 'text_detector_manga']));

      final manga = TranslationModels.all
          .where((c) => c.kind == ModelKind.mangaEncoder)
          .map((c) => c.id)
          .toList();
      expect(manga, containsAll(['ocr_ja', 'ocr_ja_fp16']));
    });
  });
}
