import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/image_translation/ort_capabilities.dart';
import 'package:venera/foundation/image_translation/pre_translation_tasks.dart';
import 'package:venera/foundation/image_translation/translation_performance_config.dart';
import 'package:venera/foundation/image_translation/translation_pipeline.dart';
import 'package:venera/foundation/image_translation/translation_types.dart';
import 'package:venera/foundation/image_translation/translation_worker.dart';

void main() {
  group('PageOcr', () {
    test('constructs correctly and reflects error and empty status', () {
      final okEmpty = PageOcr(const [], const [], const {});
      expect(okEmpty.hasError, isFalse);
      expect(okEmpty.isEmpty, isTrue);
      expect(okEmpty.error, isNull);

      final withError = PageOcr(
        const [],
        const [],
        const {},
        error: 'Decoding failed: invalid format',
      );
      expect(withError.hasError, isTrue);
      expect(withError.error, 'Decoding failed: invalid format');
      expect(withError.isEmpty, isTrue);

      final withReady = PageOcr(
        [
          TranslatedRegion(
            rect: IntRect(0, 0, 10, 10),
            eraseRect: IntRect(0, 0, 10, 10),
            eraseRects: const [],
            text: '你好',
            backgroundColor: 0,
            textColor: 0,
            lineHeight: 12,
          ),
        ],
        const [],
        const {'zh': 1},
      );
      expect(withReady.hasError, isFalse);
      expect(withReady.isEmpty, isFalse);
    });
  });

  group('OcrPageResult', () {
    test('stores blocks or error per page', () {
      final successResult = OcrPageResult(
        pageIndex: 0,
        blocks: [
          OcrBlock(
            rect: IntRect(10, 20, 50, 60),
            eraseRect: IntRect(10, 20, 50, 60),
            eraseRects: const [],
            text: 'こんにちは',
            language: 'ja',
            backgroundColor: 0xFFFFFFFF,
            textColor: 0xFF000000,
            lineHeight: 16,
          ),
        ],
      );
      expect(successResult.pageIndex, 0);
      expect(successResult.error, isNull);
      expect(successResult.blocks?.length, 1);

      final failedResult = OcrPageResult(
        pageIndex: 1,
        error: 'Format unsupported',
      );
      expect(failedResult.pageIndex, 1);
      expect(failedResult.error, 'Format unsupported');
      expect(failedResult.blocks, isNull);
    });
  });

  group('TranslationWorker Perf Logs Ring Buffer', () {
    test('keeps up to 20 recent logs in order', () {
      final worker = TranslationWorker.instance;
      for (var i = 0; i < 25; i++) {
        worker.addPerfLog('log $i');
      }
      expect(worker.recentPerfLogs.length, 20);
      expect(worker.recentPerfLogs.first, 'log 5');
      expect(worker.recentPerfLogs.last, 'log 24');
    });
  });

  group('Pipeline Concurrency Clamping (V4-3 / §4.2.3)', () {
    test('clamps GPU concurrency to at most 2 to prevent VRAM over-allocation', () {
      const perf = TranslationPerformanceValues(
        batchPages: 8,
        ocrWorkers: 3,
        imageConcurrency: 6,
        llmConcurrency: 4,
        ep: EpPreference.auto,
      );

      // On CPU: follows base llmConcurrency (4)
      final cpuConcurrency = PreTranslationTaskManager.pipelineConcurrencyFor(
        perf,
        isMobile: false,
        sourceLang: 'en',
        hasJapaneseModel: false,
        ep: OrtEpKind.cpu,
      );
      expect(cpuConcurrency, 4);

      // On DirectML: clamped to min(4, 2) = 2
      final dmlConcurrency = PreTranslationTaskManager.pipelineConcurrencyFor(
        perf,
        isMobile: false,
        sourceLang: 'en',
        hasJapaneseModel: false,
        ep: OrtEpKind.directml,
      );
      expect(dmlConcurrency, 2);

      // On CUDA: clamped to min(4, 2) = 2
      final cudaConcurrency = PreTranslationTaskManager.pipelineConcurrencyFor(
        perf,
        isMobile: false,
        sourceLang: 'en',
        hasJapaneseModel: false,
        ep: OrtEpKind.cuda,
      );
      expect(cudaConcurrency, 2);
    });

    test('mobile Japanese model pipeline stays single group in flight', () {
      const perf = TranslationPerformanceValues(
        batchPages: 4,
        ocrWorkers: 2,
        imageConcurrency: 3,
        llmConcurrency: 3,
      );

      final concurrency = PreTranslationTaskManager.pipelineConcurrencyFor(
        perf,
        isMobile: true,
        sourceLang: 'ja',
        hasJapaneseModel: true,
        ep: OrtEpKind.cpu,
      );
      expect(concurrency, 1);
    });
  });
}
