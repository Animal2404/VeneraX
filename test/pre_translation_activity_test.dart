import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/comic_type.dart';
import 'package:venera/foundation/image_translation/ordered_group_committer.dart';
import 'package:venera/foundation/image_translation/ort_capabilities.dart';
import 'package:venera/foundation/image_translation/pre_translation_tasks.dart';
import 'package:venera/foundation/image_translation/translation_types.dart';
import 'package:venera/foundation/image_translation/translation_worker.dart';

PreTranslationTask taskWith(List<PreTranslationChapter> chapters) {
  return PreTranslationTask(
    id: 't',
    cid: 'c',
    sourceKey: 's',
    comicType: ComicType(0),
    title: 'Comic',
    chapters: chapters,
    createdAt: DateTime(2026),
  );
}

void main() {
  // The live activity channel exists because chapter counters commit one whole
  // group at a time — the resume cursor needs done+failed to stay a contiguous
  // committed prefix. These guard that the display layer reads the in-flight
  // groups without ever being able to move those counters.
  group('PreTranslationActivity', () {
    test('head stage is the lowest-numbered live group, not the newest', () {
      var activity = PreTranslationActivity();
      activity.groups[2] = PreTranslationGroupActivity(index: 2, pageCount: 4)
        ..stage = TranslationStage.rendering;
      activity.groups[0] = PreTranslationGroupActivity(index: 0, pageCount: 4)
        ..stage = TranslationStage.translating;
      activity.groups[1] = PreTranslationGroupActivity(index: 1, pageCount: 4)
        ..stage = TranslationStage.recognizing;

      // Group 0 holds the commit cursor, so it is the honest answer to
      // "why hasn't the page count moved".
      expect(activity.headStage, TranslationStage.translating);
    });

    test('head stage is null with no live group', () {
      expect(PreTranslationActivity().headStage, isNull);
    });

    test('stage counts group concurrent work by phase', () {
      var activity = PreTranslationActivity();
      activity.groups[0] = PreTranslationGroupActivity(index: 0, pageCount: 4)
        ..stage = TranslationStage.recognizing;
      activity.groups[1] = PreTranslationGroupActivity(index: 1, pageCount: 4)
        ..stage = TranslationStage.recognizing;
      activity.groups[2] = PreTranslationGroupActivity(index: 2, pageCount: 4)
        ..stage = TranslationStage.fetching;

      expect(activity.stageCounts, {
        TranslationStage.recognizing: 2,
        TranslationStage.fetching: 1,
      });
    });

    test('live progress adds uncommitted pages to the committed value', () {
      // One chapter of 10 pages, 2 committed, a group with 3 pages resolved.
      var chapter = PreTranslationChapter(
        eid: '1',
        title: 'Ch 1',
        total: 10,
        done: 2,
      );
      var task = taskWith([chapter]);
      var activity = PreTranslationActivity()..chapterIndex = 1;
      activity.groups[0] = PreTranslationGroupActivity(index: 0, pageCount: 4)
        ..completedPages = 3;

      expect(task.progress, closeTo(0.2, 1e-9));
      expect(activity.liveProgress(task), closeTo(0.5, 1e-9));
    });

    test('uncommitted pages only count toward the running chapter slice', () {
      // Two chapters: the second is running, so its in-flight pages fill half
      // of that chapter and therefore a quarter of the whole job.
      var task = taskWith([
        PreTranslationChapter(eid: '1', title: 'Ch 1', total: 4, done: 4),
        PreTranslationChapter(eid: '2', title: 'Ch 2', total: 4),
      ]);
      var activity = PreTranslationActivity()..chapterIndex = 2;
      activity.groups[0] = PreTranslationGroupActivity(index: 0, pageCount: 4)
        ..completedPages = 2;

      expect(task.progress, closeTo(0.5, 1e-9));
      expect(activity.liveProgress(task), closeTo(0.75, 1e-9));
    });

    test('falls back to committed progress before a chapter starts', () {
      var task = taskWith([
        PreTranslationChapter(eid: '1', title: 'Ch 1', total: 10, done: 5),
      ]);
      // chapterIndex 0 = nothing running yet.
      var activity = PreTranslationActivity();
      activity.groups[0] = PreTranslationGroupActivity(index: 0, pageCount: 4)
        ..completedPages = 3;

      expect(activity.liveProgress(task), task.progress);
    });

    test('falls back while the chapter page count is unresolved', () {
      var task = taskWith([
        PreTranslationChapter(eid: '1', title: 'Ch 1'),
      ]);
      var activity = PreTranslationActivity()..chapterIndex = 1;
      activity.groups[0] = PreTranslationGroupActivity(index: 0, pageCount: 4)
        ..completedPages = 2;

      expect(activity.liveProgress(task), 0);
    });

    test('never exceeds 1 when a group over-reports', () {
      var task = taskWith([
        PreTranslationChapter(eid: '1', title: 'Ch 1', total: 4, done: 3),
      ]);
      var activity = PreTranslationActivity()..chapterIndex = 1;
      activity.groups[0] = PreTranslationGroupActivity(index: 0, pageCount: 4)
        ..completedPages = 9;

      expect(activity.liveProgress(task), 1.0);
    });

    test('partly-finished pages move the bar before the group commits', () {
      // The point of the fractional weights: one group of 4 walking fetch →
      // recognize → translate → render must show four distinct values, not sit
      // at 0 and then jump when its counters commit.
      var task = taskWith([
        PreTranslationChapter(eid: '1', title: 'Ch 1', total: 8),
      ]);
      var activity = PreTranslationActivity()..chapterIndex = 1;
      var group = PreTranslationGroupActivity(index: 0, pageCount: 4);
      activity.groups[0] = group;

      var seen = <double>[];
      for (var completed in [
        4 * fetchedPageWeight, // all downloaded
        4 * 0.55, // all recognized
        4 * 0.8, // translation returned
        4.0, // drawn
      ]) {
        group.completedPages = completed;
        seen.add(activity.liveProgress(task));
      }

      expect(seen.first, greaterThan(0));
      expect(seen.last, closeTo(0.5, 1e-9));
      for (var i = 1; i < seen.length; i++) {
        expect(seen[i], greaterThan(seen[i - 1]));
      }
    });

    test('dropping a group takes its pages back out of live progress', () {
      // An abandoned group (cancel/pause) is removed rather than committed, so
      // the bar has to fall back to the committed value instead of keeping
      // credit for work that will be redone.
      var task = taskWith([
        PreTranslationChapter(eid: '1', title: 'Ch 1', total: 10, done: 2),
      ]);
      var activity = PreTranslationActivity()..chapterIndex = 1;
      activity.groups[0] = PreTranslationGroupActivity(index: 0, pageCount: 4)
        ..completedPages = 3;
      expect(activity.liveProgress(task), closeTo(0.5, 1e-9));

      activity.groups.remove(0);
      expect(activity.uncommittedPages, 0);
      expect(activity.liveProgress(task), closeTo(0.2, 1e-9));
    });

    test('failed pages keep the page counter moving with the bar', () {
      // A page that fails is finished work: it moves the percentage, so the
      // counter has to move with it. Reporting successes only froze the number
      // whenever a batch failed, making a running job look stuck.
      var chapter = PreTranslationChapter(
        eid: '1',
        title: 'Ch 1',
        total: 10,
        done: 4,
        failed: 2,
      );
      var task = taskWith([chapter]);
      var activity = PreTranslationActivity()
        ..chapterIndex = 1
        ..chapterEid = '1'
        ..bufferedDone = 1
        ..bufferedFailed = 2;

      expect(activity.liveDone(task), 5);
      expect(activity.liveFailed(task), 4);
      expect(activity.liveProcessed(task), 9);
      // Same set the bar counts.
      expect(
        activity.liveProcessed(task) / chapter.total,
        closeTo(activity.liveProgress(task), 1e-9),
      );
    });
  });

  // Groups overlap and may finish out of order, but their counts commit in
  // strict group order so done+failed stays a contiguous prefix for the resume
  // cursor. These guard the buffered-credit channel that keeps the display
  // honest while a finished group waits behind a slower predecessor.
  group('applyGroupResult', () {
    test('a group finishing out of order does not make the live figures dip', () {
      // Group 1 wins the race while group 0 is still on the LLM. Its counts
      // cannot move the cursor, so without buffered credit its pages would
      // vanish from the display the moment it left the in-flight map.
      var chapter = PreTranslationChapter(eid: '1', title: 'Ch 1', total: 8);
      var task = taskWith([chapter]);
      var activity = PreTranslationActivity()
        ..chapterIndex = 1
        ..chapterEid = '1';
      activity.groups[0] = PreTranslationGroupActivity(index: 0, pageCount: 4)
        ..completedPages = 4 * 0.8; // translated, waiting to be drawn
      activity.groups[1] = PreTranslationGroupActivity(index: 1, pageCount: 4)
        ..completedPages = 4; // drawn
      var before = activity.liveProgress(task);

      PreTranslationTaskManager.applyGroupResult(
        OrderedGroupCommitter(0),
        chapter,
        activity,
        1,
        GroupResult(4, 0, {}),
      );

      expect(chapter.done, 0, reason: 'cursor cannot move past group 0');
      expect(activity.bufferedDone, 4);
      expect(activity.groups.containsKey(1), isFalse);
      expect(activity.liveProgress(task), closeTo(before, 1e-9));

      // The chapter still reads as unfinished: group 0's pages are neither
      // committed nor buffered, so a premature "translated" tick is impossible.
      var live = PreTranslationTaskManager.livePagesFor(chapter, activity);
      expect(live, (done: 4, processed: 4));
      expect(live.processed, lessThan(chapter.total));
    });

    test("every group's pages leave the buffer when the prefix commits", () {
      var chapter = PreTranslationChapter(eid: '1', title: 'Ch 1', total: 8);
      var activity = PreTranslationActivity()..chapterEid = '1';
      var committer = OrderedGroupCommitter(0);

      PreTranslationTaskManager.applyGroupResult(
        committer,
        chapter,
        activity,
        1,
        GroupResult(3, 1, {5}),
      );
      expect((chapter.done, chapter.failed), (0, 0));
      expect((activity.bufferedDone, activity.bufferedFailed), (3, 1));

      // Group 0 releases itself and the buffered group 1 in one go.
      PreTranslationTaskManager.applyGroupResult(
        committer,
        chapter,
        activity,
        0,
        GroupResult(4, 0, {}),
      );

      expect((chapter.done, chapter.failed), (7, 1));
      expect(chapter.failedPages, {5});
      expect(activity.bufferedPages, 0, reason: 'buffer must balance to zero');
      expect(
        PreTranslationTaskManager.livePagesFor(chapter, activity),
        (done: 7, processed: 8),
      );
    });

    test('buffered pages only credit the chapter they belong to', () {
      var running = PreTranslationChapter(
        eid: '1',
        title: 'Ch 1',
        total: 8,
        done: 4,
      );
      var other = PreTranslationChapter(
        eid: '2',
        title: 'Ch 2',
        total: 8,
        done: 4,
      );
      var activity = PreTranslationActivity()
        ..chapterEid = '1'
        ..bufferedDone = 3
        ..bufferedFailed = 1;

      expect(
        PreTranslationTaskManager.livePagesFor(running, activity),
        (done: 7, processed: 8),
      );
      expect(
        PreTranslationTaskManager.livePagesFor(other, activity),
        (done: 4, processed: 4),
      );
      expect(
        PreTranslationTaskManager.livePagesFor(running, null),
        (done: 4, processed: 4),
      );
    });
  });

  // The stage-1 recognition sweep used to be invisible to every page figure:
  // its credit sat only in the `index: -1` slot's phase-weighted
  // [completedPages] and reached the progress bar, never a counter. On a real
  // 82-page chapter the log showed pages=[0..7] settled while the card read
  // 「页数: 0/82」. These guard the fix: the sweep must reach the displayed
  // values — while [PreTranslationActivity.liveProcessed] keeps its exact
  // committed+buffered meaning the group above pins down.
  //
  // All progress-fold assertions go through [PreTranslationProgress.snapshot]
  // (the pure fold), never [PreTranslationProgress.of] — the latter reads the
  // worker singletons, and tests must not touch them (repo rule: no isolate
  // side effects from the test VM). Worker data here is injected fake data.
  group('stage-1 sweep reaches the displayed figures', () {
    PreTranslationActivity sweepActivity(int recognized, {int total = 82}) {
      var activity = PreTranslationActivity()
        ..chapterIndex = 1
        ..chapterEid = '1';
      activity.groups[PreTranslationActivity.ocrSweepIndex] =
          PreTranslationGroupActivity(index: -1, pageCount: total)
            ..stage = TranslationStage.recognizing
            // The exact wiring from _runChapterOcrPass: weighted for the bar,
            // raw for the page line.
            ..completedPages = recognized * 0.55
            ..recognizedPages = recognized;
      return activity;
    }

    test('recognizedThrough counts the index:-1 sweep slot', () {
      var task = taskWith([
        PreTranslationChapter(eid: '1', title: 'Ch 1', total: 82),
      ]);
      var activity = sweepActivity(8);

      // The regression: this had to be > 0 the moment the log said pages
      // [0..7] were done.
      expect(activity.recognizedThrough(task), 8);
      expect(activity.ocrRecognizedPages, 8);
      expect(activity.ocrSweepPendingPages, 74);
      // liveProcessed is untouched: still committed + buffered only, so the
      // "Pages" line's meaning does not shift out from under its own tests.
      expect(activity.liveProcessed(task), 0);
      // Nothing is translated or rendered while only the sweep has run.
      expect(activity.translatedThrough(task), 0);
      expect(activity.renderedThrough(task), 0);
    });

    test('the card snapshot exposes the sweep count, focus, and no fake rates', () {
      var task = taskWith([
        PreTranslationChapter(eid: '1', title: 'Ch 1', total: 82),
      ]);
      var activity = sweepActivity(8);
      var now = DateTime(2026);
      var view = PreTranslationProgress.snapshot(task, activity: activity, now: now);

      expect(view.recognized, 8);
      expect(view.translated, 0);
      expect(view.rendered, 0);
      expect(view.sweepActive, isTrue);
      expect(view.focusRecognizing, isTrue);
      expect(view.focusTranslating, isFalse);
      expect(view.focusRendering, isFalse);
      // Unreadable figures are null (the card prints —), never a 0 pretending
      // to be data.
      expect(view.commitRatePerMinute, isNull);
      expect(view.recognitionRatePerMinute, isNull);
      expect(view.eta, isNull);
      expect(view.batch, isNull);
      expect(view.msPerPage, isNull);
      expect(view.epName, isNull);
      expect(view.sessions, isNull);
      expect(view.arenaMb, isNull);
      expect(view.degradedLabel, isNull);
      expect(view.elapsed, isNotNull);
    });

    test('committed pages before a sweep still count as recognized after it', () {
      // Resume case: 20 pages done earlier, the sweep now runs over the rest.
      var task = taskWith([
        PreTranslationChapter(eid: '1', title: 'Ch 1', total: 82, done: 20),
      ]);
      var activity = sweepActivity(30);
      expect(activity.recognizedThrough(task), 50);

      // Sweep finished, stage 2 launched: every remaining page of the chapter
      // has passed recognition, and the buffered credit is not double-counted.
      activity.groups.remove(PreTranslationActivity.ocrSweepIndex);
      activity.bufferedDone = 3;
      activity.groups[0] = PreTranslationGroupActivity(index: 0, pageCount: 4)
        ..stage = TranslationStage.translating;
      // processed = 23; chapter remaining = 82 - 20 - 3 = 59 → 82 clamped.
      expect(activity.recognizedThrough(task), 82);
      expect(activity.translatedThrough(task), 23);
      expect(activity.renderedThrough(task), 23);
    });

    test('a rendering group credits translated but not rendered pages', () {
      var task = taskWith([
        PreTranslationChapter(eid: '1', title: 'Ch 1', total: 8),
      ]);
      var activity = PreTranslationActivity()
        ..chapterIndex = 1
        ..chapterEid = '1';
      activity.groups[0] = PreTranslationGroupActivity(index: 0, pageCount: 4)
        ..stage = TranslationStage.rendering;
      activity.groups[1] = PreTranslationGroupActivity(index: 1, pageCount: 4)
        ..stage = TranslationStage.translating;

      expect(activity.translatedThrough(task), 4);
      expect(activity.renderedThrough(task), 0);
      expect(activity.recognizedThrough(task), 8);
    });

    test('phase lines never exceed the task total', () {
      var task = taskWith([
        PreTranslationChapter(eid: '1', title: 'Ch 1', total: 4, done: 4),
      ]);
      var activity = PreTranslationActivity()
        ..chapterIndex = 1
        ..chapterEid = '1';
      // Over-reporting groups (mirrors the liveProgress over-report guard).
      activity.groups[0] = PreTranslationGroupActivity(index: 0, pageCount: 9)
        ..stage = TranslationStage.rendering;
      expect(activity.recognizedThrough(task), 4);
      expect(activity.translatedThrough(task), 4);
      expect(activity.renderedThrough(task), 4);
    });

    test('pages/min comes from settled groups, null before enough data', () {
      var task = taskWith([
        PreTranslationChapter(eid: '1', title: 'Ch 1', total: 100, done: 40),
      ]);
      var activity = PreTranslationActivity()
        ..chapterIndex = 1
        ..chapterEid = '1';
      var t0 = DateTime(2026);
      // One sample is not a rate.
      activity.recordSettledPages(4, at: t0);
      expect(activity.pagesPerMinute, isNull);
      activity.recordSettledPages(4, at: t0.add(const Duration(seconds: 60)));
      // 8 pages over 60 s → 8 pages/min.
      expect(activity.pagesPerMinute, closeTo(8, 1e-9));

      var view = PreTranslationProgress.snapshot(task, activity: activity, now: t0.add(const Duration(seconds: 60)));
      expect(view.commitRatePerMinute, closeTo(8, 1e-9));
      // 60 pages left at 8/min → 7.5 min.
      expect(view.eta, const Duration(seconds: 450));
    });

    test('recognition rate only shows while its sweep is live', () {
      var task = taskWith([
        PreTranslationChapter(eid: '1', title: 'Ch 1', total: 82),
      ]);
      var activity = sweepActivity(0);
      var t0 = DateTime(2026);
      activity.recordOcrPages(4, at: t0);
      activity.recordOcrPages(4, at: t0.add(const Duration(seconds: 30)));
      expect(activity.sweepPagesPerMinute, closeTo(16, 1e-9));
      expect(activity.pagesPerMinute, isNull, reason: 'streams stay separate');

      var view = PreTranslationProgress.snapshot(task, activity: activity, now: t0.add(const Duration(seconds: 30)));
      expect(view.recognitionRatePerMinute, closeTo(16, 1e-9));

      // Sweep over → the recognition figure stops claiming to be live.
      activity.groups.remove(PreTranslationActivity.ocrSweepIndex);
      var after = PreTranslationProgress.snapshot(
        task,
        activity: activity,
        now: t0.add(const Duration(seconds: 31)),
      );
      expect(after.recognitionRatePerMinute, isNull);
    });

    test('worker batch stats reach the card while fresh and vanish when stale', () {
      var task = taskWith([
        PreTranslationChapter(eid: '1', title: 'Ch 1', total: 82),
      ]);
      var now = DateTime(2026);
      var perf = OcrBatchPerf(
        pages: 2,
        epName: 'directml',
        detBatchCap: 1,
        recBatchCap: 8,
        detTiles: 4,
        detBuckets: 4,
        detMs: 2927,
        recGroups: 3,
        recBatches: 12,
        recCrops: 87,
        recMs: 11282,
        decRows: 58,
        decSteps: 146,
        decMs: 6311,
        totalMs: 14233,
        sessionCount: 4,
        arenaBytes: 40 * 1024 * 1024,
        degradedTrail: const [],
      );
      var view = PreTranslationProgress.snapshot(
        task,
        batchPerf: perf,
        batchPerfAt: now,
        now: now,
      );
      expect(view.batch, isNotNull);
      expect(view.batch!.recCrops, 87);
      expect(view.msPerPage, closeTo(14233 / 2, 1e-9));
      // epName may come from a batch even without an EpReport.
      expect(view.epName, 'directml');

      var stale = PreTranslationProgress.snapshot(
        task,
        batchPerf: perf,
        batchPerfAt: now.subtract(const Duration(minutes: 2)),
        now: now,
      );
      expect(stale.batch, isNull, reason: 'a dead-old batch is not live speed');
      expect(stale.msPerPage, isNull);
    });

    test('engine row reports the EpReport honestly', () {
      var task = taskWith([
        PreTranslationChapter(eid: '1', title: 'Ch 1', total: 82),
      ]);
      var report = EpReport(
        active: OrtEpKind.directml,
        runtimeVersion: '1.0',
        attempts: const ['directml'],
        modelInputShapes: const {},
        batchCapable: true,
        sessionCount: 4,
        arenaCapacityBytes: 30 * 1024 * 1024,
        hiddenArenaCapacityBytes: 10 * 1024 * 1024,
        degradedTrail: const ['rec16<-32'],
      );
      var view = PreTranslationProgress.snapshot(task, workerReport: report);
      expect(view.epName, 'directml');
      expect(view.sessions, 4);
      expect(view.arenaMb, closeTo(40.0, 1e-9));
      expect(view.degradedLabel, 'rec16<-32');

      var clean = PreTranslationProgress.snapshot(
        task,
        workerReport: EpReport(
          active: OrtEpKind.cpu,
          runtimeVersion: '1.0',
          attempts: const [],
          modelInputShapes: const {},
          batchCapable: false,
        ),
      );
      // An observed "no degradation" is data, and reads differently from the
      // absence of any report (null → the card prints —).
      expect(clean.degradedLabel, 'none');
    });
  });
}
