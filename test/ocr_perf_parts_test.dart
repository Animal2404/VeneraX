import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/image_translation/ort_capabilities.dart';
import 'package:venera/foundation/image_translation/pre_translation_tasks.dart';
import 'package:venera/foundation/image_translation/translation_worker.dart';

/// The worker perf log reports det/rec/dec as three `ms:` fields, but the
/// stopwatches are NOT siblings: the decoder loop starts and stops wholly
/// inside the recognition interval (translation_worker.dart — `recSw.start`
/// … `_mangaOcrBatchMulti(decStopwatch: decSw)` … `recSw.stop`), so a reader
/// that sums the three fields gets a total larger than `total_ms`. A real
/// line measured exactly that way: det 5760 + rec 29817 + dec 21255 = 56832
/// against total_ms 35647. [ocrPerfParts] turns the nested timers into a
/// disjoint sum that closes on `total_ms`; these tests pin the identity with
/// that real captured line.
void main() {
  group('ocrPerfParts (additive partition of total_ms)', () {
    test('closes on the captured failing log line', () {
      final parts = ocrPerfParts(
        detMs: 5760,
        recMs: 29817,
        decMs: 21255,
        totalMs: 35647,
      );
      // det + rec + rest is the true sequential wall; dec nests in rec.
      expect(parts.detMs + parts.recGpuMs + parts.decMs + parts.restMs, 35647);
      expect(parts.recGpuMs, 29817 - 21255);
      expect(parts.decMs, 21255);
      expect(parts.restMs, 35647 - 5760 - 29817);
      // The old misleading sum — asserted to differ, so a refactor that
      // re-exposes it cannot pass unnoticed.
      expect(
        parts.detMs + parts.recGpuMs + parts.decMs,
        isNot(5760 + 29817 + 21255),
      );
    });

    test('decMs is clamped inside recMs (it cannot exceed its parent)', () {
      final parts = ocrPerfParts(
        detMs: 100,
        recMs: 150,
        decMs: 999, // nested stopwatch mis-set / clock skew
        totalMs: 300,
      );
      expect(parts.decMs, 150);
      expect(parts.recGpuMs, 0);
      expect(parts.detMs + parts.recGpuMs + parts.decMs + parts.restMs, 300);
    });

    test('restMs never goes negative when segment timers overshoot', () {
      final parts = ocrPerfParts(
        detMs: 1000,
        recMs: 1000,
        decMs: 0,
        totalMs: 500,
      );
      expect(parts.restMs, 0);
      expect(parts.recGpuMs, 1000);
    });

    test('zero-decode batch (non-ja engines only) splits det/rec/rest', () {
      final parts = ocrPerfParts(
        detMs: 400,
        recMs: 600,
        decMs: 0,
        totalMs: 1100,
      );
      expect(parts.recGpuMs, 600);
      expect(parts.decMs, 0);
      expect(parts.restMs, 100);
      expect(parts.detMs + parts.recGpuMs + parts.decMs + parts.restMs, 1100);
    });
  });

  group('pool capacity — what imageTranslationOcrWorkers can actually buy',
      () {
    // The slider says "OCR parallelism (0 = auto)", max 6. These pin the
    // effective ceilings the code imposes on top of the setting — the
    // sweep's window is sized by `TranslationWorker.poolCapacity`, which
    // resolves through this function.
    test('desktop + GPU caps the requested 6 at 2', () {
      expect(
        resolveOcrPoolSize(
          requested: 6,
          processorCount: 16,
          isMobile: false,
          isDesktop: true,
          sourceLang: 'ja',
          hasJapaneseModel: true,
          ep: OrtEpKind.directml,
        ),
        2,
      );
    });

    test('desktop + CPU honours the requested 6', () {
      expect(
        resolveOcrPoolSize(
          requested: 6,
          processorCount: 16,
          isMobile: false,
          isDesktop: true,
          sourceLang: 'ja',
          hasJapaneseModel: true,
          ep: OrtEpKind.cpu,
        ),
        6,
      );
    });

    test('mobile caps at 2 even when 6 is requested (non-ja)', () {
      expect(
        resolveOcrPoolSize(
          requested: 6,
          processorCount: 8,
          isMobile: true,
          isDesktop: false,
          sourceLang: 'en',
          hasJapaneseModel: false,
          ep: OrtEpKind.cpu,
        ),
        2,
      );
    });

    test('mobile + japanese model forces a single worker (memory policy)',
        () {
      expect(
        resolveOcrPoolSize(
          requested: 0,
          processorCount: 8,
          isMobile: true,
          isDesktop: false,
          sourceLang: 'auto',
          hasJapaneseModel: true,
          ep: OrtEpKind.cpu,
        ),
        1,
      );
    });
  });

  group('ocrSweepWindowFor (stage-1 in-flight chunk window)', () {
    test('single-isolate pools keep the sweep alive (floor 1)', () {
      expect(PreTranslationTaskManager.ocrSweepWindowFor(1), 1);
      expect(PreTranslationTaskManager.ocrSweepWindowFor(0), 1);
    });

    test('desktop GPU pool capacity (2) is fed exactly', () {
      expect(PreTranslationTaskManager.ocrSweepWindowFor(2), 2);
    });

    test('a CPU pool of 6 is NOT fed past 2 by the sweep', () {
      // Deliberate ceiling: 2 is the VRAM/memory peak the reader already
      // reaches; scaling the sweep past it is a separate, measured decision.
      expect(PreTranslationTaskManager.ocrSweepWindowFor(6), 2);
    });
  });
}
