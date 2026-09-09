// NOTE: 本文件按任务约束在本地**未运行**（禁止本地 flutter test / 构建）。
// 只经过 `flutter analyze --no-pub`。列入待云端 `Test` job 验证清单。
//
// The card used to print two per-page numbers that read as a contradiction:
// a four-group real-device run showed `16.8 页/分钟` (= 3.57 s/page) beside
// `平均每页 15727 毫秒`. Both were true about different things —
// `_ThroughputTracker.msPerPage` is Σ workMs / Σ pages, and with four groups in
// flight those intervals overlap, so it is ≈ 4 × the per-page wall clock — but
// only one of them was *labelled* "average per page". These tests lock the
// resolution: the measured figure keeps its exact value (its own tests pin it),
// the row gains the reciprocal of the rate it already prints, and the two are
// consistent by construction. They also lock the warm-up case, where the
// reciprocal *is* the measured figure and must not be printed twice.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/comic_type.dart';
import 'package:venera/foundation/image_translation/pre_translation_tasks.dart';
import 'package:venera/foundation/image_translation/translation_service.dart';
import 'package:venera/foundation/image_translation/translation_types.dart';
import 'package:venera/foundation/image_translation/translation_worker.dart';
import 'package:venera/pages/tasks_page.dart';

final _start = DateTime(2026);

DateTime _at(int seconds) => _start.add(Duration(seconds: seconds));

PreTranslationTask _task({
  int total = 100,
  int done = 0,
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
      PreTranslationChapter(eid: '1', title: 'Ch 1', total: total, done: done),
    ],
    createdAt: _start,
    status: status,
    finishedAt: finishedAt,
    finalSummary: finalSummary,
  );
}

GroupPerf _group({
  int pages = 4,
  int llmPages = 4,
  int llmMs = 8000,
  int renderPages = 4,
  int renderMs = 2000,
}) {
  return GroupPerf(
    pages: pages,
    ocrCachedPages: 0,
    ocrRunPages: 0,
    llmPages: llmPages,
    renderPages: renderPages,
    resolveMs: 1000,
    ocrMs: 0,
    llmMs: llmMs,
    renderMs: renderMs,
    totalMs: 1000 + llmMs + renderMs,
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

OcrBatchPerf _batch({int pages = 8, int totalMs = 2000}) => OcrBatchPerf(
      pages: pages,
      epName: 'directml',
      detBatchCap: 1,
      recBatchCap: 8,
      detTiles: 4,
      detBuckets: 4,
      detMs: 600,
      recGroups: 3,
      recBatches: 12,
      recCrops: 87,
      recMs: totalMs - 600,
      decRows: 58,
      decSteps: 146,
      decMs: 500,
      totalMs: totalMs,
      sessionCount: 4,
      arenaBytes: 40 * 1024 * 1024,
      degradedTrail: const [],
    );

void main() {
  group('one row, two per-page figures, no contradiction', () {
    test('the throughput figure is the reciprocal of the rate beside it', () {
      var activity = PreTranslationActivity();
      // Four groups of 4 pages; each request measured 15 s of its own wall
      // time and the answers landed 10 s apart. Wall clock: 16 pages / 30 s
      // = 32 pages/min = 1.875 s/page. Measured: 60 s of request time over
      // 16 pages = 3750 ms/page — the same number the old card called
      // "average per page" beside the rate.
      for (var i = 0; i < 4; i++) {
        activity.recordTranslatedGroup(
          _group(llmPages: 4, llmMs: 15000, renderPages: 4, renderMs: 4000),
          at: _at(i * 10),
        );
      }
      var rates = activity.translateRates;
      expect(rates.stablePagesPerMinute, closeTo(32, 1e-9));
      expect(rates.pagesPerMinute, closeTo(32, 1e-9));
      // The measured figure is unchanged — service time, and its own tests
      // pin its value.
      expect(rates.msPerPage, 3750);
      // The new figure is derived from the rate on the same line, so the two
      // printed numbers cannot disagree.
      expect(rates.throughputSecondsPerPage, closeTo(1.875, 1e-9));
      expect(
        rates.throughputSecondsPerPage! * rates.pagesPerMinute!,
        closeTo(60, 1e-9),
        reason: 'seconds/page x pages/min must be 60 by construction',
      );
      // ...and their ratio is the average concurrency (60 s of request time
      // over a 30 s window = 2), which is the fact the old label hid.
      expect(
        rates.msPerPage! / (rates.throughputSecondsPerPage! * 1000),
        closeTo(2, 1e-9),
      );
    });

    test('a warm-up rate does not print the same number twice', () {
      var activity = PreTranslationActivity();
      activity.recordOcrPages(8, workMs: 2000, at: _at(0));
      var rates = activity.sweepRates;
      // One measured sample: the shown rate IS the measured one, so its
      // reciprocal is exactly msPerPage — the throughput slot stays empty.
      expect(rates.pagesPerMinute, closeTo(240, 1e-9));
      expect(rates.stablePagesPerMinute, isNull);
      expect(rates.msPerPage, 250);
      expect(rates.throughputSecondsPerPage, isNull);
    });

    test('the fold carries both figures on every row', () {
      var task = _task(total: 82, done: 8);
      var activity = _sweepActiveActivity(recognized: 16, total: 82);
      // Recognition: two 4 s chunks 10 s apart -> 16 pages / 10 s = 96/min,
      // i.e. 0.625 s/page of wall clock; the row's ms/page stays the engine's
      // own batch figure (2000 ms / 8 pages = 250 ms), which is a different
      // measurement and is labelled as one.
      activity.recordOcrPages(8, workMs: 4000, at: _at(0));
      activity.recordOcrPages(8, workMs: 4000, at: _at(10));
      // Translation: one measured request -> warm-up rate, no throughput slot.
      activity.recordTranslatedGroup(
        _group(llmPages: 4, llmMs: 8000, renderPages: 4, renderMs: 2000),
        at: _at(12),
      );
      // Rendering: two commits 60 s apart -> 8 pages/min = 7.5 s/page.
      activity.recordSettledPages(4, workMs: 20000, at: _at(0));
      activity.recordSettledPages(4, workMs: 20000, at: _at(60));
      activity.recordRenderWork(_group(renderPages: 4, renderMs: 2000));

      var view = PreTranslationProgress.snapshot(
        task,
        activity: activity,
        batchPerf: _batch(),
        batchPerfAt: _at(50),
        now: _at(61),
      );
      expect(view.recognitionRatePerMinute, closeTo(96, 1e-9));
      expect(view.recognitionSecondsPerPage, closeTo(0.625, 1e-9));
      expect(view.msPerPage, 250);
      expect(
        view.recognitionSecondsPerPage! * view.recognitionRatePerMinute!,
        closeTo(60, 1e-9),
      );
      // Translation row is a warm-up: rate only, and the service time beside
      // it is the request's own 2000 ms/page.
      expect(view.translationSecondsPerPage, isNull);
      expect(view.translationMsPerPage, 2000);
      // Rendered row: pace and service time both present, reciprocal exact.
      expect(view.commitRatePerMinute, closeTo(8, 1e-9));
      expect(view.commitSecondsPerPage, closeTo(7.5, 1e-9));
      expect(view.renderMsPerPage, 500);
      expect(
        view.commitSecondsPerPage! * view.commitRatePerMinute!,
        closeTo(60, 1e-9),
      );
    });

    test('a finished card keeps the same consistent pair', () {
      var activity = PreTranslationActivity();
      activity.recordSettledPages(4, workMs: 20000, at: _at(0));
      activity.recordSettledPages(4, workMs: 20000, at: _at(60));
      activity.recordRenderWork(
        _group(renderPages: 4, renderMs: 2000),
        at: _at(61),
      );
      var live = PreTranslationProgress.snapshot(
        _task(total: 8, done: 8),
        activity: activity,
        now: _at(61),
      );
      var summary = PreTranslationTaskSummary.capture(live, activity: activity);
      expect(summary.commitSecondsPerPage, closeTo(7.5, 1e-9));
      expect(summary.renderMsPerPage, 500);

      var stored = PreTranslationTask.fromJson(
        jsonDecode(
          jsonEncode(
            _task(
              total: 8,
              done: 8,
              status: PreTranslationTaskStatus.completed,
              finishedAt: _at(61),
              finalSummary: summary,
            ).toJson(),
          ),
        ) as Map<String, dynamic>,
      );
      var restored = stored.finalSummary!.toProgress(stored);
      expect(restored.commitSecondsPerPage, closeTo(7.5, 1e-9));
      expect(restored.renderMsPerPage, 500);
      // No invented zero: an absent figure stays absent on the restored card.
      expect(restored.translationSecondsPerPage, isNull);
    });
  });

  group('the rendered strings cannot disagree', () {
    test('seconds per page keeps enough digits to match the rate', () {
      // 60000/240 pages/min = 0.25 s/page: one decimal would print "0.3" and
      // visibly contradict the rate beside it.
      expect(formatSecondsPerPage(0.25), '0.25');
      expect(formatSecondsPerPage(0.625), '0.63');
      expect(formatSecondsPerPage(1.875), '1.9');
      expect(formatSecondsPerPage(60000 / 16.8 / 1000), '3.6');
    });
  });
}
