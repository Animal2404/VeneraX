import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/image_translation/pre_translation_tasks.dart';

/// S1 — telemetry honesty in the stage-1 recognition sweep.
///
/// The reported defect: a page whose fetch failed (`pre_translation_tasks.dart`
/// fetch-failure path) or whose OCR chunk threw (the `catch` in `runChunk`)
/// was counted as *recognized*. The sweep wrote `processed += chunkData.length`
/// / `processed++`, published `recognizedPages = processed`, and even called
/// `recordOcrPages(1)` for a fetch failure — so:
///
///  * the "已识别 X/Y" line claimed pages the OCR never read;
///  * `_sweepRate`'s numerator gained pages while its wall-clock span did not,
///    so the printed rate and the ETA built on it came out too optimistic.
///
/// The repository's rule for this is "unreadable is N/A, never a fake credit".
/// The fix splits the sweep's single `processed` counter into
/// `settledProcessed` (drives the bar so the denominator never freezes) and
/// `recognizedProcessed` (advanced only where `putOcr` succeeded), and stops
/// sampling a failure into the rate at all.
///
/// The arithmetic of that split is [sweepPageAccounting], a top-level pure
/// function, because the sweep itself cannot be driven from a test: it needs a
/// real pipeline, an OCR worker pool and a `TranslationStore` (R3 — no isolate,
/// no ONNX session, no GPU). These assertions are written against the *bug*:
/// every one of them is false under the pre-fix behaviour, which is what makes
/// them able to catch it.
///
/// NOT VERIFIED LOCALLY (no `flutter test` in this workspace) — see the
/// "待云端 Test job 验证" list in the hand-off report.
void main() {
  group('sweepPageAccounting: a failure settles, it does not recognize', () {
    test('a failed fetch advances the bar but not the recognized count', () {
      final step = sweepPageAccounting(
        settledPages: 0,
        recognizedPages: 0,
        chunkPages: 1,
        storedPages: 0,
      );
      expect(step.settledPages, 1, reason: 'the denominator must move');
      expect(step.completedPages, closeTo(0.55, 1e-9));
      // The red assertion: the old code published `recognizedPages = 1` here.
      expect(
        step.recognizedPages,
        0,
        reason: 'nothing was read on this page — no credit',
      );
      expect(step.tallied, isTrue, reason: 'the bar did move');
    });

    test('a chunk that threw settles whole, recognizes none', () {
      final step = sweepPageAccounting(
        settledPages: 8,
        recognizedPages: 6,
        chunkPages: 4,
        storedPages: 0,
      );
      expect(step.settledPages, 12);
      expect(step.recognizedPages, 6, reason: 'the throw path stored nothing');
      expect(step.completedPages, closeTo(6.6, 1e-9));
      expect(step.tallied, isTrue);
    });

    test('a chunk with per-page errors credits only the stored pages', () {
      // 4 pages went in, 3 came back without `hasError` and reached `putOcr`.
      final step = sweepPageAccounting(
        settledPages: 0,
        recognizedPages: 0,
        chunkPages: 4,
        storedPages: 3,
      );
      expect(step.settledPages, 4);
      expect(step.recognizedPages, 3, reason: 'the errored page is N/A');
      expect(step.completedPages, closeTo(2.2, 1e-9));
    });

    test('a healthy chunk credits every page it settled', () {
      final step = sweepPageAccounting(
        settledPages: 12,
        recognizedPages: 12,
        chunkPages: 4,
        storedPages: 4,
      );
      expect(step.settledPages, 16);
      expect(step.recognizedPages, 16);
      expect(step.completedPages, closeTo(8.8, 1e-9));
    });

    test('a chunk of zero pages is not a step', () {
      // `runChunk` returns early on an empty batch; the arithmetic must not
      // invent a settled page either (and must not touch the 0.55 weight).
      final step = sweepPageAccounting(
        settledPages: 3,
        recognizedPages: 3,
        chunkPages: 0,
        storedPages: 0,
      );
      expect(step.settledPages, 3);
      expect(step.recognizedPages, 3);
      expect(step.completedPages, closeTo(1.65, 1e-9));
      expect(step.tallied, isFalse);
    });

    test('recognition can never exceed the pages the chunk carried', () {
      final step = sweepPageAccounting(
        settledPages: 0,
        recognizedPages: 0,
        chunkPages: 2,
        storedPages: 99,
      );
      expect(step.recognizedPages, 2, reason: 'clamped to the chunk');
      expect(step.settledPages, 2);
    });
  });

  group('the sweep rate is fed by recognition, never by a failure', () {
    test('a failure samples nothing into the rate window', () {
      final activity = PreTranslationActivity();
      // What the sweep now does for one failed fetch: settle the bar, sample
      // nothing. `recordOcrPages` is what the old failure path called with
      // `pages = 1`, which added a sample the wall-clock window then divided by
      // a span it never lengthened.
      activity.recordOcrPages(0);
      expect(
        activity.sweepRates.samples,
        0,
        reason: 'a failed page is not a recognition sample',
      );
      expect(activity.sweepRates.pagesPerMinute, isNull);
      expect(activity.lastOcrSampleAt, isNull);
    });

    test('the window counts only recognized pages, not settled ones', () {
      final activity = PreTranslationActivity();
      final t0 = DateTime(2026, 1, 1, 0, 0, 0);
      final tFail = t0.add(const Duration(seconds: 30));
      final t2 = t0.add(const Duration(seconds: 60));
      // A 4-page chunk at t0, all stored; the next chunk throws at t+30s (0
      // stored, so the sweep samples nothing for it — `add` ignores pages <=
      // 0, pinned by the test above); a 2-page chunk at t+60s, all stored.
      activity.recordOcrPages(4, workMs: 4000, at: t0);
      activity.recordOcrPages(0, at: tFail);
      // The failed chunk leaves no trace in the window: no sample, and the
      // sampling clock does not move.
      expect(activity.sweepRates.samples, 1);
      expect(activity.lastOcrSampleAt, t0);
      activity.recordOcrPages(2, workMs: 2000, at: t2);

      final rates = activity.sweepRates;
      expect(
        rates.samples,
        2,
        reason: 'only the recognized chunks are samples',
      );
      // A stable rate exists only once two *recognized* samples span >= 3 s
      // (_ThroughputTracker.add: fewer than two samples leaves it null, so a
      // lone success plus a failure that is never sampled cannot produce
      // one). With two, it is 6 recognized pages over the 60 s between them:
      // the failed chunk's settled pages never enter the numerator. Had
      // settled pages been credited, the window would read 10 pages/min.
      expect(rates.stablePagesPerMinute, closeTo(6, 1e-9));
      expect(
        rates.pagesPerMinute,
        closeTo(6, 1e-9),
        reason: 'the shown rate is the wall-clock one once it exists',
      );
      expect(
        rates.msPerPage,
        1000,
        reason: '(4000+2000) ms of measured work over 6 recognized pages',
      );
      expect(activity.lastOcrSampleAt, t2);
    });
  });
}
