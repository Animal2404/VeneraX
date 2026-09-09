// NOTE: 本文件按任务约束在本地**未运行**（禁止本地 flutter test / 构建）。
// 只经过 `flutter analyze --no-pub`。列入待云端验证清单。
//
// Covers the three-phase rate split of the pre-translation progress card
// (recognition / translation / rendering each get their own window, never a
// shared number), the user-tunable refresh interval normalisation, and the
// end-of-job summary that keeps the finished card's figures alive.
//
// All fold assertions go through PreTranslationProgress.snapshot (the pure
// fold) — PreTranslationProgress.of reads the worker singletons, which tests
// must not touch (repo rule: no isolate side effects from the test VM).

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/comic_type.dart';
import 'package:venera/foundation/image_translation/pre_translation_tasks.dart';
import 'package:venera/foundation/image_translation/translation_types.dart';

PreTranslationTask taskWith(
  List<PreTranslationChapter> chapters, {
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
    chapters: chapters,
    createdAt: DateTime(2026),
    status: status,
    finishedAt: finishedAt,
    finalSummary: finalSummary,
  );
}

PreTranslationActivity sweepActivity(int recognized, {int total = 82}) {
  var activity = PreTranslationActivity()
    ..chapterIndex = 1
    ..chapterEid = '1';
  activity.groups[PreTranslationActivity.ocrSweepIndex] =
      PreTranslationGroupActivity(index: -1, pageCount: total)
        ..stage = TranslationStage.recognizing
        ..completedPages = recognized * 0.55
        ..recognizedPages = recognized;
  return activity;
}

void main() {
  group('translating→rendering crossing is detected once per group', () {
    test('noteStage fires only on the crossing into rendering', () {
      var g = PreTranslationGroupActivity(index: 0, pageCount: 4);
      expect(g.stage, TranslationStage.fetching);
      // Moving *toward* rendering must not fire: the answer has not landed.
      expect(g.noteStage(TranslationStage.loadingModel), isFalse);
      expect(g.noteStage(TranslationStage.recognizing), isFalse);
      expect(g.noteStage(TranslationStage.translating), isFalse);
      // The crossing itself: exactly once.
      expect(g.noteStage(TranslationStage.rendering), isTrue);
      // Later per-page rendering reports must not re-fire it.
      expect(g.noteStage(TranslationStage.rendering), isFalse);
      expect(g.stage, TranslationStage.rendering);
    });

    test('a cache-resolved group fires on its first rendering report too', () {
      // A group whose text came from the on-disk cache never sits in
      // `translating`; the fetch→render jump is still "the answer landed"
      // (from cache), matching translatedThrough's counting semantics.
      var g = PreTranslationGroupActivity(index: 0, pageCount: 2);
      expect(g.noteStage(TranslationStage.rendering), isTrue);
    });
  });

  group('three independent rate windows', () {
    test('translation stream: null before enough data, then pages/min', () {
      var activity = PreTranslationActivity();
      var t0 = DateTime(2026);
      // One sample is not a rate — and must never read as 0.
      activity.recordTranslatedPages(4, at: t0);
      expect(activity.translatePagesPerMinute, isNull);
      // Two samples spanning less than the tracker's minimum span: still not
      // a rate (a burst of two commits says nothing about steady speed).
      activity.recordTranslatedPages(
        4,
        at: t0.add(const Duration(seconds: 1)),
      );
      expect(activity.translatePagesPerMinute, isNull);
      // Third sample: 12 pages over 60 s → 12 pages/min.
      activity.recordTranslatedPages(
        4,
        at: t0.add(const Duration(seconds: 60)),
      );
      expect(activity.translatePagesPerMinute, closeTo(12, 1e-9));
    });

    test('zero/negative pages never enter a stream (no fake samples)', () {
      var activity = PreTranslationActivity();
      var t0 = DateTime(2026);
      activity.recordTranslatedPages(0, at: t0);
      activity.recordTranslatedPages(-3, at: t0.add(const Duration(seconds: 30)));
      activity.recordTranslatedPages(4, at: t0.add(const Duration(seconds: 60)));
      // Only the real sample exists → one sample → no rate.
      expect(activity.translatePagesPerMinute, isNull);
    });

    test('streams stay separate: a sweep sample moves only recognition', () {
      var activity = sweepActivity(0);
      var t0 = DateTime(2026);
      activity.recordOcrPages(4, at: t0);
      activity.recordOcrPages(4, at: t0.add(const Duration(seconds: 30)));
      // 8 pages over 30 s → 16/min on the recognition window only.
      expect(activity.sweepPagesPerMinute, closeTo(16, 1e-9));
      expect(activity.translatePagesPerMinute, isNull);
      expect(activity.pagesPerMinute, isNull);
    });

    test('the fold hands each phase line its own stream and hides the others', () {
      var task = taskWith([
        PreTranslationChapter(eid: '1', title: 'Ch 1', total: 100),
      ]);
      var activity = PreTranslationActivity()
        ..chapterIndex = 1
        ..chapterEid = '1';
      var t0 = DateTime(2026);
      activity.recordOcrPages(8, at: t0);
      activity.recordOcrPages(8, at: t0.add(const Duration(seconds: 30)));
      activity.recordTranslatedPages(4, at: t0.add(const Duration(seconds: 40)));
      activity.recordTranslatedPages(4, at: t0.add(const Duration(seconds: 70)));
      activity.recordSettledPages(4, at: t0.add(const Duration(seconds: 50)));
      activity.recordSettledPages(4, at: t0.add(const Duration(seconds: 80)));

      // While a sweep owns the card: recognition quotes its stream, the two
      // stage-2 streams print — (they are not measured mid-sweep) even though
      // their trackers hold samples.
      activity.groups[PreTranslationActivity.ocrSweepIndex] =
          PreTranslationGroupActivity(index: -1, pageCount: 100)
            ..stage = TranslationStage.recognizing
            ..recognizedPages = 16;
      var during = PreTranslationProgress.snapshot(
        task,
        activity: activity,
        now: t0.add(const Duration(seconds: 80)),
      );
      // 16 pages / 30 s → 32/min; 8 pages / 30 s → 16/min each.
      expect(during.recognitionRatePerMinute, closeTo(32, 1e-9));
      expect(during.translationRatePerMinute, isNull);
      expect(during.commitRatePerMinute, closeTo(16, 1e-9),
          reason: 'commit rate is never sweep-derived and stays shown');

      // Sweep over: the recognition figure stops claiming to be live, and
      // the translation stream takes its place on the Translated line.
      activity.groups.remove(PreTranslationActivity.ocrSweepIndex);
      var after = PreTranslationProgress.snapshot(
        task,
        activity: activity,
        now: t0.add(const Duration(seconds: 81)),
      );
      expect(after.recognitionRatePerMinute, isNull);
      expect(after.translationRatePerMinute, closeTo(16, 1e-9));
      expect(after.commitRatePerMinute, closeTo(16, 1e-9));
    });
  });

  group('elapsed survives the end', () {
    test('a finished job folds createdAt→finishedAt with no activity', () {
      var task = taskWith(
        [PreTranslationChapter(eid: '1', title: 'Ch 1', total: 4, done: 4)],
        status: PreTranslationTaskStatus.completed,
        finishedAt: DateTime(2026).add(const Duration(minutes: 5)),
      );
      var view = PreTranslationProgress.snapshot(task);
      expect(view.elapsed, const Duration(minutes: 5));
      // No rates were measured, no worker data is quoted: every derived
      // figure reads `—` (null), none of them 0.
      expect(view.recognitionRatePerMinute, isNull);
      expect(view.translationRatePerMinute, isNull);
      expect(view.commitRatePerMinute, isNull);
      expect(view.eta, isNull);
      expect(view.batch, isNull);
      expect(view.epName, isNull);
      // A committed page has passed all three phases: the phase lines agree.
      expect(view.recognized, 4);
      expect(view.translated, 4);
      expect(view.rendered, 4);
    });

    test('a paused job keeps ticking elapsed against wall clock', () {
      // Paused: not running, no finishedAt, but the activity is alive —
      // elapsed must not vanish into — while the card still shows live
      // counts (the fold decides from `activity != null`).
      var task = taskWith(
        [PreTranslationChapter(eid: '1', title: 'Ch 1', total: 10, done: 2)],
        status: PreTranslationTaskStatus.paused,
      );
      var now = DateTime(2026).add(const Duration(minutes: 2));
      var view = PreTranslationProgress.snapshot(
        task,
        activity: PreTranslationActivity()..chapterIndex = 1,
        now: now,
      );
      expect(view.elapsed, const Duration(minutes: 2));
    });
  });

  group('end-of-job summary keeps the card populated', () {
    test('capture freezes rates and engine figures the live fold measured', () {
      var task = taskWith([
        PreTranslationChapter(eid: '1', title: 'Ch 1', total: 82, done: 60),
      ]);
      var activity = sweepActivity(8);
      var t0 = DateTime(2026);
      activity.recordOcrPages(8, at: t0);
      activity.recordOcrPages(8, at: t0.add(const Duration(seconds: 30)));
      activity.recordTranslatedPages(6, at: t0.add(const Duration(seconds: 40)));
      activity.recordTranslatedPages(6, at: t0.add(const Duration(seconds: 90)));
      activity.recordSettledPages(4, at: t0.add(const Duration(seconds: 50)));
      activity.recordSettledPages(4, at: t0.add(const Duration(seconds: 80)));
      var live = PreTranslationProgress.snapshot(
        task,
        activity: activity,
        now: t0.add(const Duration(seconds: 90)),
      );

      // Capture reads the streams *ungated*: at the end, each phase row is a
      // museum plaque ("what this phase last measurably did"), not a claim
      // about the current phase — so the sweep-window recognition rate and
      // the pre-sweep translation rate are both kept even though the live
      // fold (correctly) hides one of them at this instant.
      var summary = PreTranslationTaskSummary.capture(live, activity: activity);
      // The sweep's raw credit survives into the final view even though it
      // was never a committed page.
      expect(summary.recognized, 68);
      // 16 pages / 30 s → 32/min; 12 pages / 50 s → 14.4/min;
      // 8 pages / 30 s → 16/min.
      expect(summary.recognitionRatePerMinute, closeTo(32, 1e-9));
      expect(summary.translationRatePerMinute, closeTo(14.4, 1e-6));
      expect(summary.renderRatePerMinute, closeTo(16, 1e-6));
      // Nothing measured → nothing claimed.
      expect(summary.msPerPage, isNull);
      expect(summary.epName, isNull);
      expect(summary.degradedLabel, isNull);

      // JSON round trip through the task object (this is the only storage:
      // no new database table, just the persisted task map).
      var taskWithSummary = taskWith(
        [PreTranslationChapter(eid: '1', title: 'Ch 1', total: 82, done: 60)],
        status: PreTranslationTaskStatus.completed,
        finishedAt: t0.add(const Duration(seconds: 90)),
        finalSummary: summary,
      );
      var decoded = PreTranslationTask.fromJson(
        jsonDecode(jsonEncode(taskWithSummary.toJson())) as Map<String, dynamic>,
      );
      expect(decoded.finalSummary, isNotNull);
      expect(
        decoded.finalSummary!.recognitionRatePerMinute,
        closeTo(32, 1e-6),
      );
      expect(
        decoded.finalSummary!.translationRatePerMinute,
        closeTo(14.4, 1e-6),
      );
      expect(decoded.finalSummary!.renderRatePerMinute, closeTo(16, 1e-6));
      expect(decoded.finalSummary!.recognized, 68);
      // A measured 0 (translated 60 pages → translatedThrough folds 60;
      // rendered 60) must survive as a number, not be dropped like a null.
      expect(decoded.finalSummary!.translated, 60);
      expect(decoded.finalSummary!.rendered, 60);

      var view = decoded.finalSummary!.toProgress(decoded);
      expect(view.running, isFalse);
      expect(view.sweepActive, isFalse);
      expect(view.recognized, 68);
      expect(view.recognitionRatePerMinute, closeTo(32, 1e-6));
      expect(view.translationRatePerMinute, closeTo(14.4, 1e-6));
      expect(view.commitRatePerMinute, closeTo(16, 1e-6));
      // Elapsed comes from the persisted timestamps, not from the summary.
      expect(view.elapsed, const Duration(seconds: 90));
      // The worker's last batch belongs to whoever used the pool last — the
      // final view must never quote one.
      expect(view.batch, isNull);
    });

    test('an empty summary decodes to all-null (no fabricated zeros)', () {
      var s = PreTranslationTaskSummary.fromJson({});
      expect(s.recognized, isNull);
      expect(s.recognitionRatePerMinute, isNull);
      expect(s.translationRatePerMinute, isNull);
      expect(s.renderRatePerMinute, isNull);
      expect(s.msPerPage, isNull);
      expect(s.epName, isNull);
      expect(s.sessions, isNull);
      expect(s.arenaMb, isNull);
      expect(s.degradedLabel, isNull);

      // toProgress on null counts falls back to the committed counters, not
      // to zero, and keeps rates null (— on the card).
      var task = taskWith(
        [PreTranslationChapter(eid: '1', title: 'Ch 1', total: 30, done: 12, failed: 3)],
        status: PreTranslationTaskStatus.failed,
        finishedAt: DateTime(2026).add(const Duration(minutes: 1)),
        finalSummary: s,
      );
      var view = s.toProgress(task);
      expect(view.processed, 15);
      expect(view.recognized, 15);
      expect(view.translated, 15);
      expect(view.rendered, 15);
      expect(view.recognitionRatePerMinute, isNull);
      expect(view.elapsed, const Duration(minutes: 1));
    });

    test('a legacy task JSON (no finalSummary key) loads with null summary', () {
      var legacy = PreTranslationTask.fromJson({
        'id': 't',
        'cid': 'c',
        'sourceKey': 's',
        'comicType': 0,
        'title': 'Comic',
        'createdAt': DateTime(2026).toIso8601String(),
        'status': 'completed',
        'chapters': [
          {
            'eid': '1',
            'title': 'Ch 1',
            'total': 5,
            'done': 5,
            'failed': 0,
          },
        ],
      });
      expect(legacy.finalSummary, isNull);
      // The card's fallback path must still fold honest committed numbers.
      var view = PreTranslationProgress.snapshot(legacy);
      expect(view.rendered, 5);
      expect(view.recognitionRatePerMinute, isNull);
      expect(view.elapsed, isNull, reason: 'no finishedAt and not running');
    });

    test('an observed degraded "none" survives the round trip (≠ absence)', () {
      var s = PreTranslationTaskSummary(degradedLabel: 'none', sessions: 0);
      var back = PreTranslationTaskSummary.fromJson(
        jsonDecode(jsonEncode(s.toJson())) as Map<String, dynamic>,
      );
      // "none" is a real observation; null is the absence of a report; 0
      // sessions is a measurement, not "missing" — none may collapse.
      expect(back.degradedLabel, 'none');
      expect(back.sessions, 0);
    });
  });

  group('refresh interval setting', () {
    test('normalizeMs: missing/garbage/out-of-range fall back to 1 s', () {
      expect(PreTranslationRefresh.normalizeMs(null), 1000);
      expect(PreTranslationRefresh.normalizeMs('fast'), 1000);
      expect(PreTranslationRefresh.normalizeMs(499), 1000);
      expect(PreTranslationRefresh.normalizeMs(5001), 1000);
      expect(PreTranslationRefresh.normalizeMs(0), 1000);
      expect(PreTranslationRefresh.normalizeMs(-1), 1000);
    });

    test('normalizeMs: the configured range 0.5–5 s passes through intact', () {
      expect(PreTranslationRefresh.normalizeMs(500), 500);
      expect(PreTranslationRefresh.normalizeMs(1000), 1000);
      expect(PreTranslationRefresh.normalizeMs(2500), 2500);
      expect(PreTranslationRefresh.normalizeMs(5000), 5000);
      // Fractional stored values (JSON doubles) round instead of throwing —
      // a settings read must never be able to crash a notify path.
      expect(PreTranslationRefresh.normalizeMs(1500.4), 1500);
      expect(PreTranslationRefresh.intervalFrom(800), const Duration(milliseconds: 800));
      expect(PreTranslationRefresh.intervalFrom(null), const Duration(seconds: 1));
    });

    test('the default is strictly inside the allowed range', () {
      expect(PreTranslationRefresh.defaultMs, greaterThan(PreTranslationRefresh.minMs));
      expect(PreTranslationRefresh.defaultMs, lessThan(PreTranslationRefresh.maxMs));
      expect(PreTranslationRefresh.minMs, 500);
      expect(PreTranslationRefresh.maxMs, 5000);
    });
  });
}
