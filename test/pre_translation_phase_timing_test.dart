// NOTE: 本文件按任务约束在本地**未运行**（禁止本地 flutter test / 构建）。
// 只经过 `flutter analyze --no-pub`。列入待云端 `Test` job 验证清单。
//
// Plan 12-B + 12-C, data layer: the two stage-2 phases get their own measured
// `ms/页`, every stream shows how many samples its rate rests on, and the
// **first** measured sample is already enough to print a rate.
//
// What these tests guard against, specifically:
//  * a `ms/页` that came from anywhere other than the producer's own numbers
//    (the service reports a structured GroupPerf; nothing here is regexed out
//    of a log line — see the companion
//    `translation_group_perf_reporting_test.dart`);
//  * a warm-up rate being *quietly promoted* to a stable one: the sample count
//    rides with it, and the ETA — which multiplies a rate into a promise about
//    every remaining page — keeps using the stable window only;
//  * an unmeasured phase printing `0` instead of `—`.
//
// All folds go through PreTranslationProgress.snapshot (the pure one);
// .of reads the worker singletons, which tests must not touch.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/comic_type.dart';
import 'package:venera/foundation/image_translation/pre_translation_tasks.dart';
import 'package:venera/foundation/image_translation/translation_service.dart';
import 'package:venera/foundation/image_translation/translation_types.dart';

final _start = DateTime(2026);

DateTime _at(int seconds) => _start.add(Duration(seconds: seconds));

PreTranslationTask _task({
  int total = 100,
  int done = 0,
  int failed = 0,
  PreTranslationTaskStatus status = PreTranslationTaskStatus.running,
  DateTime? finishedAt,
  PreTranslationTaskSummary? finalSummary,
}) {
  return PreTranslationTask(
    id: 't',
    cid: 'c',
    sourceKey: 's',
    comicType: ComicType(0),
    title: 'Comic',
    chapters: [
      PreTranslationChapter(eid: '1', title: 'Ch 1', total: total, done: done, failed: failed),
    ],
    createdAt: _start,
    status: status,
    finishedAt: finishedAt,
    finalSummary: finalSummary,
  );
}

/// A group of [pages] whose request took [llmMs] and whose draw loop took
/// [renderMs] — the shape the service reports. `totalMs` is **computed**, never
/// typed, so a test that changes one phase can never quietly describe a split
/// that does not add up (the invariant the service builds the object under).
GroupPerf _group({
  int pages = 4,
  int llmPages = 4,
  int llmMs = 8000,
  int renderPages = 4,
  int renderMs = 2000,
  int resolveMs = 1000,
  int ocrMs = 0,
}) {
  return GroupPerf(
    pages: pages,
    ocrCachedPages: 0,
    ocrRunPages: 0,
    llmPages: llmPages,
    renderPages: renderPages,
    resolveMs: resolveMs,
    ocrMs: ocrMs,
    llmMs: llmMs,
    renderMs: renderMs,
    totalMs: resolveMs + ocrMs + llmMs + renderMs,
    bytesIn: 1024,
    bytesOut: 2048,
  );
}

PreTranslationActivity _sweepActiveActivity({int recognized = 8, int total = 82}) {
  var activity = PreTranslationActivity()
    ..chapterIndex = 1
    ..chapterEid = '1';
  activity.groups[PreTranslationActivity.ocrSweepIndex] =
      PreTranslationGroupActivity(index: -1, pageCount: total)
        ..stage = TranslationStage.recognizing
        ..recognizedPages = recognized;
  return activity;
}

void main() {
  group('GroupPerf is the single source of the stage-2 numbers', () {
    test('ms/page divides by the pages that phase actually carried', () {
      final perf = _group(llmPages: 4, llmMs: 8000, renderPages: 2, renderMs: 900);
      expect(perf.translationMsPerPage, 2000);
      expect(perf.renderMsPerPage, 450);
      // End-to-end cost per input page, for the committed stream's warm-up:
      // 1000 resolve + 0 ocr + 8000 request + 900 draw = 9900 over 4 pages.
      expect(perf.totalMsPerPage, closeTo(9900 / 4, 1e-9));
    });

    test('a phase that carried nothing has no cost, and never reports 0', () {
      // A group resolved entirely from the text cache: the draw loop ran, the
      // request never did. Quoting "0 ms/页" for translation would claim a
      // measurement of instantaneous translation.
      final perf = _group(llmPages: 0, llmMs: 0, renderPages: 3, renderMs: 600);
      expect(perf.translationMsPerPage, isNull);
      expect(perf.renderMsPerPage, 200);
      // An empty group cannot divide anything.
      expect(_group(pages: 0).totalMsPerPage, isNull);
    });

    test('the log line is generated from the object, and says every field', () {
      // A *test* is allowed to read the log; production is not. Checked
      // against the object it came from, this is the drift guard: reword or
      // drop a field and this fails here rather than silently moving a number
      // out of the card's reach.
      final perf = _group(
        pages: 6,
        llmPages: 5,
        llmMs: 7,
        renderPages: 6,
        renderMs: 8,
      );
      final line = perf.toLogLine();
      expect(line, startsWith('GroupPerf pages=6 '));
      for (final part in [
        'ocr_cached=0',
        'ocr_run=0',
        'resolveMs:1000',
        'ocrMs:0',
        'llmMs:7',
        'renderMs:8',
        'llm_ms=7',
        'render_ms=8',
        'render_pages=6',
        // 1000 + 0 + 7 + 8, i.e. the total the helper computed from the parts.
        'total_ms=1015',
        'llm_pages=5',
      ]) {
        expect(line, contains(part));
      }
    });
  });

  group('12-C: the first measured sample already gives a rate', () {
    test('one OCR chunk with a duration is a rate, flagged as warm-up', () {
      var activity = PreTranslationActivity();
      activity.recordOcrPages(8, workMs: 2000, at: _at(0));
      var rates = activity.sweepRates;
      expect(rates.samples, 1);
      expect(rates.sampleCount, 1);
      // 8 pages over the 2 s the chunk actually took -> 240 pages/min.
      expect(rates.measuredPagesPerMinute, closeTo(240, 1e-9));
      expect(rates.pagesPerMinute, closeTo(240, 1e-9));
      expect(rates.msPerPage, 250);
      // ...and it is *not* a wall-clock window figure: nothing spanning a
      // few seconds exists yet.
      expect(rates.stablePagesPerMinute, isNull);
      expect(rates.isWarmup, isTrue);
    });

    test('one sample with no duration still says nothing', () {
      // The fetch-failure path credits a page without ever timing anything.
      // Showing a rate there would be inventing one, so the card prints —.
      var activity = PreTranslationActivity();
      activity.recordOcrPages(1, at: _at(0));
      var rates = activity.sweepRates;
      expect(rates.samples, 1);
      expect(rates.pagesPerMinute, isNull);
      expect(rates.msPerPage, isNull);
      expect(rates.isWarmup, isFalse);
    });

    test('the shown rate becomes the wall-clock window figure once one exists', () {
      var activity = PreTranslationActivity();
      // Two commits, 20 s of measured work each, 60 s apart: the measured
      // figure says 12 pages/min (8 pages / 40 s of work), the window says
      // 8 pages/min (8 pages / 60 s of wall clock). The second is the truth
      // about the job's pace, so once it exists it takes over.
      activity.recordSettledPages(4, workMs: 20000, at: _at(0));
      expect(activity.commitRates.pagesPerMinute, closeTo(12, 1e-9));
      expect(activity.commitRates.isWarmup, isTrue);
      activity.recordSettledPages(4, workMs: 20000, at: _at(60));
      var rates = activity.commitRates;
      expect(rates.stablePagesPerMinute, closeTo(8, 1e-9));
      expect(rates.pagesPerMinute, closeTo(8, 1e-9));
      expect(rates.isWarmup, isFalse);
      // ms/page keeps describing the measured work, not the wall clock.
      expect(rates.msPerPage, closeTo(40000 / 8, 1e-9));
      expect(rates.samples, 2);
    });

    test('a warm-up rate is shown but never turned into an ETA', () {
      var task = _task(total: 100, done: 40);
      var activity = PreTranslationActivity()
        ..chapterIndex = 1
        ..chapterEid = '1';
      activity.recordSettledPages(4, workMs: 20000, at: _at(0));
      var view = PreTranslationProgress.snapshot(
        task,
        activity: activity,
        now: _at(30),
      );
      // The row shows the first sample...
      expect(view.commitRatePerMinute, closeTo(12, 1e-9));
      expect(view.commitSamples, 1);
      // ...and the estimate row stays — instead of extrapolating one group
      // across 60 remaining pages (plan 12-A: insufficient samples -> —).
      expect(view.eta, isNull);

      activity.recordSettledPages(4, workMs: 20000, at: _at(60));
      var settled = PreTranslationProgress.snapshot(
        task,
        activity: activity,
        now: _at(61),
      );
      expect(settled.eta, isNotNull, reason: 'a real window may be projected');
      expect(settled.commitSamples, 2);
    });

    test('a long pause retires the rate that produced it', () {
      var activity = PreTranslationActivity();
      // A real burst: 8 pages over 10 s -> a genuine 48 pages/min window.
      activity.recordOcrPages(4, workMs: 5000, at: _at(0));
      activity.recordOcrPages(4, workMs: 5000, at: _at(10));
      expect(activity.sweepRates.stablePagesPerMinute, closeTo(48, 1e-9));
      // Nothing happens for longer than the 120 s window, then one page lands.
      // The two samples that made "48" are gone; the number must go with them,
      // or a job that stalled for five minutes keeps advertising the speed of
      // the burst that ended — and the ETA divides the remaining pages by it.
      activity.recordOcrPages(1, workMs: 1000, at: _at(300));
      expect(activity.sweepRates.samples, 1);
      expect(
        activity.sweepRates.stablePagesPerMinute,
        isNull,
        reason: 'the window no longer contains the burst',
      );
      // What remains is the single fresh sample, shown as one sample.
      expect(activity.sweepRates.pagesPerMinute, closeTo(60, 1e-9));
      expect(activity.sweepRates.isWarmup, isTrue);
      expect(activity.sweepRates.msPerPage, 1000);
    });

    test('a retired rate cannot leak into the ETA', () {
      var task = _task(total: 100, done: 8);
      var activity = PreTranslationActivity()
        ..chapterIndex = 1
        ..chapterEid = '1';
      activity.recordSettledPages(4, workMs: 20000, at: _at(0));
      activity.recordSettledPages(4, workMs: 20000, at: _at(30));
      var live = PreTranslationProgress.snapshot(
        task,
        activity: activity,
        now: _at(31),
      );
      expect(live.commitRatePerMinute, closeTo(16, 1e-9));
      expect(live.eta, isNotNull, reason: 'a real window may be projected');

      activity.recordSettledPages(4, workMs: 20000, at: _at(200));
      var paused = PreTranslationProgress.snapshot(
        task,
        activity: activity,
        now: _at(201),
      );
      // The row still says what the last measured group cost per page...
      expect(paused.commitRatePerMinute, isNotNull);
      expect(paused.commitSamples, 1);
      // ...but no arrival time is promised on it.
      expect(
        paused.eta,
        isNull,
        reason: 'the window retired the samples the rate came from',
      );
    });

    test('window trimming drops stale durations out of ms/page', () {
      var activity = PreTranslationActivity();
      // 8 pages in 8000 ms of work: 1000 ms/page.
      activity.recordRenderWork(_group(renderPages: 8, renderMs: 8000), at: _at(0));
      expect(activity.renderWorkRates.msPerPage, 1000);
      // Two samples 150 s apart: the first leaves the 120 s window, so the
      // remaining single sample alone must answer 300 ms/page.
      activity.recordOcrPages(4, workMs: 1200, at: _at(0));
      activity.recordOcrPages(4, workMs: 1200, at: _at(150));
      expect(activity.sweepRates.samples, 1);
      expect(activity.sweepRates.msPerPage, 300);
    });
  });

  group('12-B: each phase row gets its own measured cost', () {
    test('a reported group moves translation and render, not recognition', () {
      var activity = PreTranslationActivity();
      activity.recordTranslatedGroup(_group(llmPages: 4, llmMs: 8000), at: _at(0));
      activity.recordRenderWork(_group(renderPages: 4, renderMs: 2000));

      expect(activity.translateRates.msPerPage, 2000);
      expect(activity.renderWorkRates.msPerPage, 500);
      expect(
        activity.sweepRates.msPerPage,
        isNull,
        reason: 'the three streams stay separate',
      );
      expect(activity.sweepRates.samples, 0);
      expect(activity.commitRates.samples, 0);
    });

    test('a cache-resolved group is never billed for a request', () {
      var activity = PreTranslationActivity();
      // recordTranslatedGroup is the *measured* channel: with no pages in the
      // request there is nothing to bill, so it adds nothing at all. The
      // forward loop routes such a group to recordTranslatedPages instead
      // (below), which is why a resumed chapter still shows a translation rate.
      activity.recordTranslatedGroup(_group(llmPages: 0, llmMs: 0));
      expect(activity.translateRates.samples, 0);
      expect(activity.translateRates.pagesPerMinute, isNull);
      expect(activity.translateRates.msPerPage, isNull);
    });

    test('a duration-less arrival moves the window but claims no ms/page', () {
      var activity = PreTranslationActivity();
      activity.recordTranslatedPages(4, at: _at(0));
      activity.recordTranslatedPages(4, at: _at(30));
      var rates = activity.translateRates;
      // 8 answered pages over the 30 s between arrivals: a real wall-clock
      // rate, from samples that never pretend to know how long the model took.
      expect(rates.stablePagesPerMinute, closeTo(16, 1e-9));
      expect(rates.msPerPage, isNull);
      expect(rates.measuredPagesPerMinute, isNull);
    });

    test('an answer reported late is still windowed at the time it landed', () {
      var activity = PreTranslationActivity();
      // Group B answered at t+30 and came back first; group A answered at t+10
      // but its report only lands after its draw loop finished. Sampling at the
      // arrival moment therefore *back-dates* the second add. A tracker that
      // assumes append order would compute the window span from t+30 backwards
      // — negative, then, on the next add, short — and hand the ETA an inflated
      // pages/min: the fake ETA plan 12-A forbids.
      activity.recordTranslatedGroup(
        _group(llmPages: 4, llmMs: 20000),
        at: _at(30),
      );
      activity.recordTranslatedGroup(
        _group(llmPages: 4, llmMs: 10000),
        at: _at(10),
      );
      var rates = activity.translateRates;
      expect(rates.samples, 2);
      // 8 pages across the 20 s that really separate the two arrivals.
      expect(rates.stablePagesPerMinute, closeTo(24, 1e-9));
      // 30 s of measured request work over 8 pages.
      expect(rates.msPerPage, closeTo(30000 / 8, 1e-9));
    });

    test('the sample count describes the rate printed beside it', () {
      // Warm-up: three samples arrived, only the timed one backs the shown
      // rate, so the card must say "1 样本", not "3 样本".
      var warm = PreTranslationActivity();
      warm.recordOcrPages(4, at: _at(0));
      warm.recordOcrPages(4, at: _at(1));
      warm.recordOcrPages(4, workMs: 4000, at: _at(2));
      var rates = warm.sweepRates;
      expect(rates.stablePagesPerMinute, isNull, reason: '2 s span is too short');
      expect(rates.pagesPerMinute, closeTo(60, 1e-9));
      expect(rates.samples, 1);
      // Once the window rate exists, every sample in it backs that one.
      var stable = PreTranslationActivity();
      stable.recordOcrPages(4, at: _at(0));
      stable.recordOcrPages(4, at: _at(30));
      stable.recordOcrPages(4, workMs: 6000, at: _at(60));
      expect(stable.sweepRates.stablePagesPerMinute, isNotNull);
      expect(stable.sweepRates.samples, 3);
    });

    test('the fold shows all three rows with their own numbers', () {
      var task = _task(total: 100, done: 8);
      var activity = PreTranslationActivity()
        ..chapterIndex = 1
        ..chapterEid = '1';
      activity.recordOcrPages(8, workMs: 4000, at: _at(0));
      activity.recordTranslatedGroup(
        _group(llmPages: 4, llmMs: 8000, renderPages: 4, renderMs: 2000),
        at: _at(10),
      );
      activity.recordRenderWork(_group(renderPages: 4, renderMs: 2000));
      activity.recordSettledPages(4, workMs: 11000, at: _at(12));

      var view = PreTranslationProgress.snapshot(
        task,
        activity: activity,
        now: _at(20),
      );
      // Recognition: 8 pages / 4 s of chunk time. ms/page for this row is the
      // worker's own batch figure, which the fold was not handed here -> —.
      expect(view.recognitionRatePerMinute, isNull, reason: 'no sweep owns the card now');
      expect(view.recognitionSamples, isNull);
      expect(view.msPerPage, isNull);
      // Translation: 4 pages / 8 s = 30 pages/min, 2000 ms/page, 1 sample.
      expect(view.translationRatePerMinute, closeTo(30, 1e-9));
      expect(view.translationSamples, 1);
      expect(view.translationMsPerPage, 2000);
      // Rendered: 4 pages / 11 s end-to-end = ~21.8 pages/min, and the draw
      // phase's own 500 ms/page.
      expect(view.commitRatePerMinute, closeTo(60000 * 4 / 11000, 1e-6));
      expect(view.commitSamples, 1);
      expect(view.renderMsPerPage, 500);
      // No fake zeros anywhere in the row set.
      expect(view.eta, isNull);
    });

    test('a sweep still hides the stage-2 rows: no borrowed numbers', () {
      var task = _task(total: 82, done: 8);
      var activity = _sweepActiveActivity(recognized: 16, total: 82);
      activity.recordOcrPages(8, workMs: 4000, at: _at(0));
      activity.recordTranslatedGroup(
        _group(llmPages: 4, llmMs: 8000, renderPages: 4, renderMs: 2000),
        at: _at(10),
      );
      activity.recordRenderWork(_group(renderPages: 4, renderMs: 2000));

      var view = PreTranslationProgress.snapshot(
        task,
        activity: activity,
        now: _at(20),
      );
      // Recognition is live from its first measured chunk...
      expect(view.recognitionRatePerMinute, closeTo(120, 1e-9));
      expect(view.recognitionSamples, 1);
      // ...while the two stage-2 rows print — even though their trackers hold
      // samples, because mid-sweep those numbers are not what the job is doing.
      expect(view.translationRatePerMinute, isNull);
      expect(view.translationSamples, isNull);
      expect(view.translationMsPerPage, isNull);
      // The draw cost is a per-page latency of a phase that ended; it stays
      // visible next to the commit rate, which is likewise never sweep-derived.
      expect(view.renderMsPerPage, 500);
    });
  });

  group('12-B/12-C: the frozen summary keeps what the card was showing', () {
    test('a warm-up rate and its sample count survive into the summary', () {
      var task = _task(total: 82, done: 8);
      var activity = _sweepActiveActivity(recognized: 8, total: 82);
      activity.recordOcrPages(8, workMs: 4000, at: _at(0));
      activity.recordTranslatedGroup(
        _group(llmPages: 4, llmMs: 8000, renderPages: 4, renderMs: 2000),
        at: _at(10),
      );
      activity.recordRenderWork(_group(renderPages: 4, renderMs: 2000));
      var live = PreTranslationProgress.snapshot(task, activity: activity, now: _at(20));
      var summary = PreTranslationTaskSummary.capture(live, activity: activity);

      // The summary is a museum plaque: it keeps each phase's own last figure
      // ungated, including the one the live fold hid at this instant.
      expect(summary.recognitionRatePerMinute, closeTo(120, 1e-9));
      expect(summary.recognitionSamples, 1);
      expect(summary.translationRatePerMinute, closeTo(30, 1e-9));
      expect(summary.translationSamples, 1);
      expect(summary.translationMsPerPage, 2000);
      expect(summary.renderMsPerPage, 500);
      expect(summary.renderRatePerMinute, isNull);

      var stored = PreTranslationTask.fromJson(
        jsonDecode(
          jsonEncode(
            _task(
              total: 82,
              done: 8,
              status: PreTranslationTaskStatus.completed,
              finishedAt: _at(20),
              finalSummary: summary,
            ).toJson(),
          ),
        ) as Map<String, dynamic>,
      );
      var restored = stored.finalSummary!.toProgress(stored);
      expect(restored.translationSamples, 1);
      expect(restored.recognitionSamples, 1);
      expect(restored.translationMsPerPage, 2000);
      expect(restored.renderMsPerPage, 500);
      expect(restored.commitRatePerMinute, isNull);
      // A restored card shows what the live card showed: the same rate, the
      // same sample count, and no invented zero.
      expect(restored.elapsed, const Duration(seconds: 20));
    });

    test('a job that measured nothing persists no zeros', () {
      var summary = PreTranslationTaskSummary.capture(
        PreTranslationProgress.snapshot(_task()),
      );
      expect(summary.recognitionRatePerMinute, isNull);
      expect(summary.recognitionSamples, isNull);
      expect(summary.translationSamples, isNull);
      expect(summary.renderSamples, isNull);
      expect(summary.translationMsPerPage, isNull);
      expect(summary.renderMsPerPage, isNull);
      // Nothing to store: the JSON stays free of null-valued keys.
      expect(jsonEncode(summary.toJson()), isNot(contains('Samples')));
    });
  });
}
