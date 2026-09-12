// NOTE: 本文件按仓库约束在本地**未运行**（禁止本地 flutter test / 构建），
// 只经过 `flutter analyze --no-pub`；结论以云端 `Test` job 为准。
//
// 两处用户可见的缺陷，各自对应下面一组断言：
//
//  1. 「每项要有完成用时，并且到点就停」。识别 37/37 之后，那一行必须显示这一
//     阶段自己的耗时，而且**不再增长**；翻译、渲染同理。旧行为是：三行都等到
//     整个任务结束才停（`用时` 取自 `now`），阶段结束后数字还在长。
//     实现把三个"完成时刻"钉在数据层（[PreTranslationActivity.notePhaseCompletions]），
//     显示值由 [phaseDoneAfter] 换算，构建期不读时钟。
//
//  2. 「预计还需不是按秒刷新的」。旧 ETA = 剩余页 × 每页耗时，只在有样本落地时
//     才重算，于是「已用时」每秒跳、「预计还需」卡住不动。现在按 [decayEta] 用
//     墙钟衰减：两次样本之间它自己往下走，下一个 commit 再锚定一次。
//
// 全部走纯函数 / 纯 fold（[PreTranslationProgress.snapshot] 是那个不碰单例的
// 版本；`.of` 会读 worker 单例，测试不能碰）。

import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/comic_type.dart';
import 'package:venera/foundation/image_translation/pre_translation_tasks.dart';
import 'package:venera/foundation/image_translation/translation_types.dart';

final _start = DateTime(2026, 1, 1, 12);

DateTime _at(int seconds) => _start.add(Duration(seconds: seconds));

PreTranslationTask _task({
  int total = 8,
  int done = 0,
  int failed = 0,
  PreTranslationTaskStatus status = PreTranslationTaskStatus.running,
}) {
  return PreTranslationTask(
    id: 't',
    cid: 'c',
    sourceKey: 's',
    comicType: ComicType(0),
    title: 'Comic',
    chapters: [
      PreTranslationChapter(
        eid: '1',
        title: 'Ch 1',
        total: total,
        done: done,
        failed: failed,
      ),
    ],
    createdAt: _start,
    status: status,
  );
}

/// An activity whose stage-1 sweep slot is present, which is how the manager
/// creates it while `_runChapterOcrPass` recognizes the chapter.
PreTranslationActivity _sweeping(int pages) {
  final activity = PreTranslationActivity();
  activity.groups[PreTranslationActivity.ocrSweepIndex] =
      PreTranslationGroupActivity(
        index: PreTranslationActivity.ocrSweepIndex,
        pageCount: pages,
      );
  return activity;
}

PreTranslationGroupActivity _sweepSlot(PreTranslationActivity activity) =>
    activity.groups[PreTranslationActivity.ocrSweepIndex]!;

void main() {
  group('decayEta: the projection moves between commits', () {
    test('no projection, or no anchor, stays as it was', () {
      expect(decayEta(null, now: _at(30)), isNull);
      expect(
        decayEta(const Duration(seconds: 60), now: _at(30)),
        const Duration(seconds: 60),
      );
    });

    test('time already spent on the in-flight work is subtracted', () {
      expect(
        decayEta(
          const Duration(seconds: 60),
          now: _at(30),
          lastSampleAt: _at(0),
        ),
        const Duration(seconds: 30),
      );
      // Every extra second of watching moves it one second down — which is the
      // whole point: the row has to tick without a batch landing.
      expect(
        decayEta(
          const Duration(seconds: 60),
          now: _at(31),
          lastSampleAt: _at(0),
        ),
        const Duration(seconds: 29),
      );
    });

    test('never runs past zero, and a backwards clock cannot add time', () {
      expect(
        decayEta(
          const Duration(seconds: 60),
          now: _at(90),
          lastSampleAt: _at(0),
        ),
        Duration.zero,
      );
      expect(
        decayEta(
          const Duration(seconds: 60),
          now: _at(0),
          lastSampleAt: _at(10),
        ),
        const Duration(seconds: 60),
      );
    });
  });

  group('phaseDoneAfter: a finished phase reports a frozen duration', () {
    test('nothing stamped yet prints nothing', () {
      expect(phaseDoneAfter(_task(), null), isNull);
    });

    test('it is measured from the job start, and clamped at zero', () {
      final task = _task();
      expect(phaseDoneAfter(task, _at(90)), const Duration(minutes: 1, seconds: 30));
      expect(
        phaseDoneAfter(task, _start.subtract(const Duration(seconds: 5))),
        Duration.zero,
      );
    });
  });

  group('notePhaseCompletions stamps each phase once, at its own finish', () {
    test('an unfinished phase is not stamped', () {
      final task = _task();
      final activity = PreTranslationActivity();
      activity.notePhaseCompletions(task, _at(5));
      expect(activity.recognizedDoneAt, isNull);
      expect(activity.translatedDoneAt, isNull);
      expect(activity.renderedDoneAt, isNull);
    });

    test('recognition is stamped when the sweep has covered the chapter', () {
      final task = _task();
      final activity = _sweeping(8);
      _sweepSlot(activity).recognizedPages = 4;
      activity.notePhaseCompletions(task, _at(20));
      expect(
        activity.recognizedDoneAt,
        isNull,
        reason: 'half the chapter recognized is not recognition finished',
      );

      _sweepSlot(activity).recognizedPages = 8;
      activity.notePhaseCompletions(task, _at(40));
      expect(activity.recognizedDoneAt, _at(40));
      expect(
        activity.translatedDoneAt,
        isNull,
        reason: 'recognizing the pages does not translate them',
      );
    });

    test('translation and rendering are stamped when the pages commit', () {
      final task = _task();
      final activity = _sweeping(8);
      _sweepSlot(activity).recognizedPages = 8;
      activity.notePhaseCompletions(task, _at(40));

      task.chapters.first.done = 8;
      activity.notePhaseCompletions(task, _at(70));
      expect(activity.translatedDoneAt, _at(70));
      expect(activity.renderedDoneAt, _at(70));
      expect(
        activity.recognizedDoneAt,
        _at(40),
        reason: 'the earlier phase keeps the time it actually finished',
      );
    });

    test('a stamp never moves once written', () {
      final task = _task();
      final activity = _sweeping(8);
      _sweepSlot(activity).recognizedPages = 8;
      task.chapters.first.done = 8;
      activity.notePhaseCompletions(task, _at(70));
      activity.notePhaseCompletions(task, _at(999));
      expect(activity.recognizedDoneAt, _at(70));
      expect(activity.translatedDoneAt, _at(70));
      expect(activity.renderedDoneAt, _at(70));
    });

    test('a job with no pages stamps nothing', () {
      final task = _task(total: 0);
      final activity = PreTranslationActivity();
      activity.notePhaseCompletions(task, _at(10));
      expect(activity.recognizedDoneAt, isNull);

      task.chapters.first.done = 0;
      activity.notePhaseCompletions(task, _at(20));
      expect(activity.translatedDoneAt, isNull);
      expect(activity.renderedDoneAt, isNull);
    });
  });

  group('the card fold reports the stamps, and the ETA keeps moving', () {
    PreTranslationActivity finishedActivity(PreTranslationTask task) {
      final activity = _sweeping(task.total);
      _sweepSlot(activity).recognizedPages = task.total;
      activity.notePhaseCompletions(task, _at(40));
      task.chapters.first.done = task.total;
      activity.notePhaseCompletions(task, _at(70));
      return activity;
    }

    test('each phase row gets its own finished duration', () {
      final task = _task();
      final activity = finishedActivity(task);
      final view = PreTranslationProgress.snapshot(
        task,
        activity: activity,
        now: _at(120),
      );
      expect(view.recognitionDoneAfter, const Duration(seconds: 40));
      expect(view.translationDoneAfter, const Duration(seconds: 70));
      expect(view.renderDoneAfter, const Duration(seconds: 70));
    });

    test('an unstamped phase reports nothing so the row can show its rate', () {
      final task = _task();
      final activity = _sweeping(8);
      _sweepSlot(activity).recognizedPages = 8;
      activity.notePhaseCompletions(task, _at(40));
      final view = PreTranslationProgress.snapshot(
        task,
        activity: activity,
        now: _at(60),
      );
      expect(view.recognitionDoneAfter, const Duration(seconds: 40));
      expect(view.translationDoneAfter, isNull);
      expect(view.renderDoneAfter, isNull);
    });

    test('the ETA shrinks with wall clock while the rate stands still', () {
      final task = _task(total: 100);
      final activity = PreTranslationActivity();
      // Two commits 60 s apart, 4 pages each: a stable 4 pages/min — the
      // narrowest fixture the tracker accepts as a rate rather than a warm-up.
      activity.recordSettledPages(4, workMs: 20000, at: _at(0));
      activity.recordSettledPages(4, workMs: 20000, at: _at(60));
      task.chapters.first.done = 8;

      final early = PreTranslationProgress.snapshot(
        task,
        activity: activity,
        now: _at(70),
      );
      final later = PreTranslationProgress.snapshot(
        task,
        activity: activity,
        now: _at(80),
      );
      expect(early.eta, isNotNull);
      expect(later.eta, isNotNull);
      expect(
        later.eta!,
        lessThan(early.eta!),
        reason: 'the estimate must count down between commits, not freeze',
      );
      expect(
        later.eta!,
        greaterThanOrEqualTo(Duration.zero),
      );
    });
  });

  group('phase costs: the three rows must add up to the total', () {
    // The reported run, to the second — the one in the user's screenshot:
    // job start 15:08:12, recognition done 15:09:02 (the card's 「已识别 0:50」),
    // translation done 15:12:53 (the card's 「已翻译 4:41」), render done
    // 15:12:56 (「已渲染 4:44」). The rows printed the *cumulative* marks, so
    // "Translated 4:41" contained the 0:50 of OCR and the three rows could not
    // be added up to the 4:44 printed under them. These fixtures are that run.
    PreTranslationTask reportedTask() => PreTranslationTask(
      id: 't',
      cid: 'c',
      sourceKey: 's',
      comicType: ComicType(0),
      title: 'Comic',
      chapters: [PreTranslationChapter(eid: '1', title: 'Ch 1', total: 37)],
      createdAt: DateTime(2026, 9, 12, 15, 8, 12),
      status: PreTranslationTaskStatus.running,
    );

    PreTranslationActivity reportedActivity() {
      final activity = PreTranslationActivity();
      activity.ocrStartedAt = DateTime(2026, 9, 12, 15, 8, 20);
      activity.requestSentAt = DateTime(2026, 9, 12, 15, 9, 3);
      activity.firstResponseAt = DateTime(2026, 9, 12, 15, 10, 51);
      activity.recognizedDoneAt = DateTime(2026, 9, 12, 15, 9, 2);
      activity.translatedDoneAt = DateTime(2026, 9, 12, 15, 12, 53);
      activity.renderedDoneAt = DateTime(2026, 9, 12, 15, 12, 56);
      return activity;
    }

    test('the reported run: 0:50 OCR + 3:51 translate + 0:03 render = 4:44', () {
      final d = phaseDurationsOf(reportedTask(), reportedActivity());

      expect(d.recognition, const Duration(seconds: 50));
      expect(
        d.translation,
        const Duration(seconds: 231),
        reason: '4:41 minus the 0:50 the row used to swallow',
      );
      expect(d.render, const Duration(seconds: 3));
      expect(d.total, const Duration(seconds: 284));
      expect(d.sum, d.total, reason: 'the rows must add up to the total row');
      expect(d.complete, isTrue);
      expect(d.ocrStartDelay, const Duration(seconds: 8));
    });

    test('an open phase has no sum at all, rather than half a number', () {
      final task = reportedTask();
      final activity = PreTranslationActivity()
        ..recognizedDoneAt = DateTime(2026, 9, 12, 15, 9, 2);

      final d = phaseDurationsOf(task, activity);

      expect(d.recognition, const Duration(seconds: 50));
      expect(d.translation, isNull);
      expect(d.render, isNull);
      expect(d.total, isNull);
      expect(d.sum, isNull);
      expect(d.complete, isFalse);
    });

    test('a backwards clock cannot print a negative phase', () {
      final task = reportedTask();
      final activity = PreTranslationActivity()
        ..recognizedDoneAt = DateTime(2026, 9, 12, 15, 9, 2)
        ..translatedDoneAt = DateTime(2026, 9, 12, 15, 9, 0)
        ..renderedDoneAt = DateTime(2026, 9, 12, 15, 8, 0);

      final d = phaseDurationsOf(task, activity);

      expect(d.translation, Duration.zero);
      expect(d.render, Duration.zero);
      for (final v in [d.recognition, d.translation, d.render, d.total]) {
        expect(v!.isNegative, isFalse);
      }
    });

    test('the persisted summary agrees with the live job, to the second', () {
      // A card opened after the fact reads the summary; a card watched live
      // reads the activity. The two must not disagree about what a phase cost,
      // which is why both go through the same subtraction.
      final live = phaseDurationsOf(reportedTask(), reportedActivity());
      final stored = phaseDurationsFromStamps(
        recognitionDoneAfterMs: 50000,
        translationDoneAfterMs: 281000,
        renderDoneAfterMs: 284000,
      );

      expect(stored.recognition, live.recognition);
      expect(stored.translation, live.translation);
      expect(stored.render, live.render);
      expect(stored.total, live.total);
      expect(stored.sum, stored.total);
    });

    test('a summary from before this change simply has no durations', () {
      final stored = phaseDurationsFromStamps(
        recognitionDoneAfterMs: null,
        translationDoneAfterMs: null,
        renderDoneAfterMs: null,
      );

      expect(stored.complete, isFalse);
      expect(stored.sum, isNull);
    });

    test('the pipeline stamps are written once and never move', () {
      final activity = PreTranslationActivity();

      activity.notePipelineStage(TranslationStage.recognizing, _at(5));
      activity.notePipelineStage(TranslationStage.translating, _at(30));
      activity.noteFirstResponse(_at(90));
      // Every later chunk re-reports its stage, and every later group answers.
      activity.notePipelineStage(TranslationStage.recognizing, _at(40));
      activity.notePipelineStage(TranslationStage.translating, _at(60));
      activity.noteFirstResponse(_at(120));

      expect(activity.ocrStartedAt, _at(5));
      expect(activity.requestSentAt, _at(30));
      expect(activity.firstResponseAt, _at(90));
    });
  });

  group('the board has something true to say while a request is out', () {
    // The reported run's silent window: the first request went out at 15:09:03
    // and the first answer landed at 15:10:51, and for those 108 seconds the
    // card had no line that could change. These assertions pin the two facts
    // the board is built from, so "the screen looked frozen" cannot come back
    // as a display bug that no test sees.
    PreTranslationActivity activityWith({
      DateTime? requestSentAt,
      DateTime? firstResponseAt,
    }) {
      final activity = PreTranslationActivity();
      activity.requestSentAt = requestSentAt;
      activity.firstResponseAt = firstResponseAt;
      return activity;
    }

    test('waiting is live: it grows with the clock the card is drawn at', () {
      final activity = activityWith(
        requestSentAt: DateTime(2026, 9, 12, 15, 9, 3),
      );

      expect(
        activity.waitingFor(DateTime(2026, 9, 12, 15, 9, 33)),
        const Duration(seconds: 30),
      );
      expect(
        activity.waitingFor(DateTime(2026, 9, 12, 15, 10, 51)),
        const Duration(seconds: 108),
        reason: 'the reported silence, to the second',
      );
    });

    test('there is no wait before a request, and none after an answer', () {
      expect(
        activityWith().waitingFor(DateTime(2026, 9, 12, 15, 9, 30)),
        isNull,
        reason: 'nothing has been asked yet',
      );
      expect(
        activityWith(
          requestSentAt: DateTime(2026, 9, 12, 15, 9, 3),
          firstResponseAt: DateTime(2026, 9, 12, 15, 10, 51),
        ).waitingFor(DateTime(2026, 9, 12, 15, 11, 0)),
        isNull,
        reason: 'the answer is in; the wait is over for good',
      );
    });

    test('a backwards clock cannot print a negative wait', () {
      final activity = activityWith(
        requestSentAt: DateTime(2026, 9, 12, 15, 9, 3),
      );

      expect(
        activity.waitingFor(DateTime(2026, 9, 12, 15, 9, 0)),
        Duration.zero,
      );
    });

    test('the first-response flag follows the two stamps', () {
      expect(activityWith().isWaitingForFirstResponse, isFalse);
      expect(
        activityWith(
          requestSentAt: DateTime(2026, 9, 12, 15, 9, 3),
        ).isWaitingForFirstResponse,
        isTrue,
      );
      expect(
        activityWith(
          requestSentAt: DateTime(2026, 9, 12, 15, 9, 3),
          firstResponseAt: DateTime(2026, 9, 12, 15, 10, 51),
        ).isWaitingForFirstResponse,
        isFalse,
      );
    });

    test('the board carries the current item and the last response', () {
      final task = _task();
      final activity = PreTranslationActivity()
        ..currentChapter = 'Ch 2'
        ..currentFromPage = 12
        ..currentToPage = 17
        ..requestSentAt = _at(10)
        ..lastResponseAt = _at(40);
      task.chapters.first.done = task.total;
      activity.notePhaseCompletions(task, _at(50));

      final view = PreTranslationProgress.snapshot(
        task,
        activity: activity,
        now: _at(20),
      );

      expect(view.currentChapter, 'Ch 2');
      expect(view.currentFromPage, 12);
      expect(view.currentToPage, 17);
      expect(view.lastResponseAt, _at(40));
      expect(view.boardWaiting, const Duration(seconds: 10));
      expect(view.boardError, isNull);
    });

    test('a finished card carries no board facts at all', () {
      // The summary path leaves every one of them null: a finished job has no
      // current item, no wait, and must not name whichever model is configured
      // now as if it had produced this output.
      final task = _task(status: PreTranslationTaskStatus.completed);
      final progress = PreTranslationProgress.snapshot(task, now: _at(60));
      final summary = PreTranslationTaskSummary.capture(progress);
      final view = summary.toProgress(task);

      expect(view.currentChapter, isNull);
      expect(view.boardWaiting, isNull);
      expect(view.boardModel, isNull);
      expect(view.lastResponseAt, isNull);
      expect(view.boardError, isNull);
    });
  });

  group('the frozen summary carries the phase finish times', () {
    test('through JSON, and back into the card fold', () {
      final task = _task();
      final activity = _sweeping(8);
      _sweepSlot(activity).recognizedPages = 8;
      activity.notePhaseCompletions(task, _at(40));
      task.chapters.first.done = 8;
      activity.notePhaseCompletions(task, _at(70));

      final progress = PreTranslationProgress.snapshot(
        task,
        activity: activity,
        now: _at(75),
      );
      final summary = PreTranslationTaskSummary.capture(
        progress,
        activity: activity,
      );
      final restored = PreTranslationTaskSummary.fromJson(summary.toJson());
      final view = restored.toProgress(task);

      expect(view.recognitionDoneAfter, const Duration(seconds: 40));
      expect(view.translationDoneAfter, const Duration(seconds: 70));
      expect(view.renderDoneAfter, const Duration(seconds: 70));
    });

    test('a summary recorded before this change simply has no durations', () {
      final task = _task(done: 8);
      final summary = PreTranslationTaskSummary.fromJson(const {
        'recognized': 8,
        'translated': 8,
        'rendered': 8,
      });
      final view = summary.toProgress(task);
      expect(view.recognitionDoneAfter, isNull);
      expect(view.translationDoneAfter, isNull);
      expect(view.renderDoneAfter, isNull);
    });
  });
}
