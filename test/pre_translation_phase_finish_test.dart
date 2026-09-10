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
