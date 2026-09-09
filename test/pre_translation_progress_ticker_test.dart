// NOTE: 本文件按任务约束在本地**未运行**（禁止本地 flutter test / 构建）。
// 只经过 `flutter analyze --no-pub`。列入待云端 `Test` job 验证清单。
//
// Plan 12-A: 「刷新间隔」必须是**墙钟重绘周期**，而不只是事件合并窗口。
//
// The manager's `_notifyActivity` only ever fires *while events happen*, so a
// card whose most visible figure is `createdAt -> now` sits frozen between two
// recognition chunks — the user's "设了 1 秒但已用时不动". These tests pin the
// other promise: [PreTranslationProgressTicker] fires on schedule with
// **nothing happening at all** — no notify, no OCR sample, no stage change —
// and the elapsed figure it triggers still moves.
//
// Every case drives a hand-built clock: a manual periodic scheduler replaces
// `Timer.periodic`, and the scheduler alone advances the fake `DateTime`. No
// test here sleeps on a real second, and none depends on wall-clock timing, so
// none can go flaky on a loaded CI runner (plan 12-A's acceptance rule).

import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/comic_type.dart';
import 'package:venera/foundation/image_translation/pre_translation_tasks.dart';
// Only for `formatTaskDuration`, so the headline case can assert the *rendered*
// text the user reads (plan 12-A words its acceptance that way) rather than a
// copy of the card's formatting logic. Same import precedent as
// `notification_route_safe_area_test.dart`.
import 'package:venera/pages/tasks_page.dart';

/// The fake "now" the manual scheduler advances.
class _FakeClock {
  _FakeClock(this.now);

  DateTime now;
}

class _Arm {
  _Arm({required this.interval, required this.next, required this.tick});

  final Duration interval;
  final void Function() tick;
  DateTime next;
}

/// Stand-in for `Timer.periodic` with the
/// [PreTranslationTickScheduler] signature: arming registers a callback due
/// one interval from the fake now, cancelling takes it out, and [elapse]
/// advances the fake clock firing every callback that comes due — which is
/// what makes "the timer fired, and only the timer" observable.
class _ManualScheduler {
  _ManualScheduler(this.clock);

  final _FakeClock clock;
  final _arms = <_Arm>[];

  /// How many times a scheduled callback was cancelled. The ticker must call
  /// this on stop and on dispose; a leaked periodic timer shows up here as a
  /// count that never rises.
  int cancellations = 0;

  int get armedCount => _arms.length;

  void Function() schedule(Duration interval, void Function() tick) {
    late _Arm arm;
    arm = _Arm(
      interval: interval,
      next: clock.now.add(interval),
      tick: tick,
    );
    _arms.add(arm);
    return () {
      if (_arms.remove(arm)) {
        cancellations++;
      }
    };
  }

  void elapse(Duration by) {
    final target = clock.now.add(by);
    while (true) {
      _Arm? due;
      // `toList()` because firing a callback may cancel (i.e. remove) another
      // arm, and the live list must not be mutated while being walked.
      for (final a in _arms.toList()) {
        if (a.next.isAfter(target)) continue;
        if (due == null || a.next.isBefore(due.next)) due = a;
      }
      if (due == null) {
        clock.now = target;
        return;
      }
      clock.now = due.next;
      due.next = due.next.add(due.interval);
      due.tick();
    }
  }
}

PreTranslationTask _task({
  PreTranslationTaskStatus status = PreTranslationTaskStatus.running,
  DateTime? createdAt,
  DateTime? finishedAt,
}) {
  return PreTranslationTask(
    id: 't',
    cid: 'c',
    sourceKey: 's',
    comicType: ComicType(0),
    title: 'Comic',
    chapters: [
      PreTranslationChapter(eid: '1', title: 'Ch 1', total: 100),
    ],
    createdAt: createdAt ?? DateTime(2026),
    status: status,
    finishedAt: finishedAt,
  );
}

void main() {
  group('12-A: the ticker is a wall-clock period, not an event window', () {
    test('elapsed moves on every tick while zero events happen', () {
      final clock = _FakeClock(DateTime(2026));
      final scheduler = _ManualScheduler(clock);
      final task = _task(createdAt: DateTime(2026));
      // An activity exists (the job is live) but is never fed: no sweep
      // sample, no stage report, no manager notify. This is exactly the state
      // the plan calls out — a page waiting on a slow single chunk.
      final activity = PreTranslationActivity()
        ..chapterIndex = 1
        ..chapterEid = '1';

      final elapsed = <Duration>[];
      // The acceptance is about what the user reads, so assert the rendered
      // text too, through the very function the card calls.
      final rendered = <String>[];
      final ticker = PreTranslationProgressTicker(
        interval: () => const Duration(seconds: 1),
        clock: () => clock.now,
        scheduler: scheduler.schedule,
        onTick: (now) {
          final view = PreTranslationProgress.snapshot(
            task,
            activity: activity,
            now: now,
          );
          elapsed.add(view.elapsed!);
          rendered.add(
            '已用时 ${formatTaskDuration(view.elapsed)} · '
            '预计还需 ${formatTaskDuration(view.eta)}',
          );
        },
      )..start();

      scheduler.elapse(const Duration(seconds: 3));

      expect(ticker.isRunning, isTrue);
      expect(scheduler.armedCount, 1, reason: 'one timer, not one per tick');
      expect(elapsed.length, 3);
      // The point of the whole phase: three different numbers, produced by
      // nothing but the clock.
      expect(elapsed.map((e) => e.inSeconds).toList(), [1, 2, 3]);
      expect(rendered, [
        '已用时 0:01 · 预计还需 —',
        '已用时 0:02 · 预计还需 —',
        '已用时 0:03 · 预计还需 —',
      ]);
      expect(
        activity.sweepRates.samples,
        0,
        reason: 'no OCR event was recorded, and none was needed',
      );
      expect(
        activity.translateRates.samples,
        0,
        reason: 'no translation event was recorded either',
      );
    });

    test('a single tick changes nothing else: rates stay absent, not zero', () {
      final clock = _FakeClock(DateTime(2026));
      final scheduler = _ManualScheduler(clock);
      final task = _task(createdAt: DateTime(2026));
      final activity = PreTranslationActivity()..chapterIndex = 1;
      PreTranslationProgress? view;
      PreTranslationProgressTicker(
        interval: () => const Duration(seconds: 1),
        clock: () => clock.now,
        scheduler: scheduler.schedule,
        onTick: (now) => view = PreTranslationProgress.snapshot(
          task,
          activity: activity,
          now: now,
        ),
      ).start();

      scheduler.elapse(const Duration(seconds: 2));

      expect(view, isNotNull);
      // Elapsed moved; every unmeasured figure is still null (printed `—`)
      // rather than a 0 the tick could have invented.
      expect(view!.elapsed, const Duration(seconds: 2));
      expect(view!.recognitionRatePerMinute, isNull);
      expect(view!.translationRatePerMinute, isNull);
      expect(view!.commitRatePerMinute, isNull);
      expect(view!.recognitionSamples, isNull);
      expect(view!.translationSamples, isNull);
      expect(view!.commitSamples, isNull);
      expect(view!.eta, isNull);
    });

    test('start is idempotent, so a rebuild cannot stack timers', () {
      final clock = _FakeClock(DateTime(2026));
      final scheduler = _ManualScheduler(clock);
      var ticks = 0;
      final ticker = PreTranslationProgressTicker(
        interval: () => const Duration(seconds: 1),
        clock: () => clock.now,
        scheduler: scheduler.schedule,
        onTick: (_) => ticks++,
      );
      ticker.start();
      ticker.start();
      ticker.start();

      scheduler.elapse(const Duration(seconds: 2));

      expect(scheduler.armedCount, 1);
      expect(ticks, 2);
      expect(ticker.runningInterval, const Duration(seconds: 1));
    });
  });

  group('12-A: it stops on its own', () {
    test('a finished job stops the timer from the inside', () {
      final clock = _FakeClock(DateTime(2026));
      final scheduler = _ManualScheduler(clock);
      final task = _task();
      var ticks = 0;
      final ticker = PreTranslationProgressTicker(
        interval: () => const Duration(seconds: 1),
        clock: () => clock.now,
        scheduler: scheduler.schedule,
        shouldTick: () => task.isRunning,
        onTick: (_) => ticks++,
      )..start();

      scheduler.elapse(const Duration(seconds: 2));
      expect(ticks, 2);

      task.status = PreTranslationTaskStatus.completed;
      scheduler.elapse(const Duration(seconds: 10));

      expect(ticks, 2, reason: 'no repaint after the job ended');
      expect(ticker.isRunning, isFalse);
      expect(scheduler.cancellations, 1);
    });

    test('a paused job stops it too (non-running is non-running)', () {
      final clock = _FakeClock(DateTime(2026));
      final scheduler = _ManualScheduler(clock);
      final task = _task();
      var ticks = 0;
      final ticker = PreTranslationProgressTicker(
        interval: () => const Duration(seconds: 1),
        clock: () => clock.now,
        scheduler: scheduler.schedule,
        shouldTick: () => task.isRunning,
        onTick: (_) => ticks++,
      )..start();

      scheduler.elapse(const Duration(seconds: 1));
      task.status = PreTranslationTaskStatus.paused;
      scheduler.elapse(const Duration(seconds: 5));

      expect(ticks, 1);
      expect(ticker.isRunning, isFalse);

      // Resuming re-arms through start() (the widget calls it from build), and
      // the tick cadence picks up from there.
      ticker.start();
      task.status = PreTranslationTaskStatus.running;
      scheduler.elapse(const Duration(seconds: 2));
      expect(ticks, 3);
      expect(ticker.isRunning, isTrue);
    });

    test('dispose always cancels, and cancelling twice is harmless', () {
      final clock = _FakeClock(DateTime(2026));
      final scheduler = _ManualScheduler(clock);
      var ticks = 0;
      final ticker = PreTranslationProgressTicker(
        interval: () => const Duration(seconds: 1),
        clock: () => clock.now,
        scheduler: scheduler.schedule,
        onTick: (_) => ticks++,
      )..start();

      scheduler.elapse(const Duration(seconds: 1));
      ticker.dispose();
      scheduler.elapse(const Duration(seconds: 30));
      ticker.dispose();

      expect(ticks, 1);
      expect(ticker.isRunning, isFalse);
      expect(scheduler.armedCount, 0);
      expect(scheduler.cancellations, 1, reason: 'the arm was cancelled once');
    });
  });

  group('12-A: an invisible page does not repaint', () {
    test('ticks are swallowed while hidden and resume without extra wiring', () {
      final clock = _FakeClock(DateTime(2026));
      final scheduler = _ManualScheduler(clock);
      var visible = false;
      var ticks = 0;
      final ticker = PreTranslationProgressTicker(
        interval: () => const Duration(seconds: 1),
        clock: () => clock.now,
        scheduler: scheduler.schedule,
        isVisible: () => visible,
        onTick: (_) => ticks++,
      )..start();

      scheduler.elapse(const Duration(seconds: 5));
      expect(ticks, 0, reason: 'nothing was repainted behind the user');
      expect(
        ticker.isRunning,
        isTrue,
        reason: 'the timer itself stays armed: the job is still running',
      );

      visible = true;
      scheduler.elapse(const Duration(seconds: 1));
      expect(ticks, 1, reason: 'the first tick after coming back repaints');
    });

    test('hidden time is not lost: the repaint shows the real elapsed', () {
      final clock = _FakeClock(DateTime(2026));
      final scheduler = _ManualScheduler(clock);
      var visible = false;
      final seen = <Duration>[];
      final task = _task(createdAt: DateTime(2026));
      PreTranslationProgressTicker(
        interval: () => const Duration(seconds: 1),
        clock: () => clock.now,
        scheduler: scheduler.schedule,
        isVisible: () => visible,
        onTick: (now) => seen.add(
          PreTranslationProgress.snapshot(task, now: now).elapsed!,
        ),
      ).start();

      // Twenty seconds behind another route, then back.
      scheduler.elapse(const Duration(seconds: 20));
      visible = true;
      scheduler.elapse(const Duration(seconds: 1));

      expect(seen, [const Duration(seconds: 21)]);
    });
  });

  group('12-A: the interval knob really is the cadence', () {
    test('changing it takes effect on the next tick', () {
      final clock = _FakeClock(DateTime(2026));
      final scheduler = _ManualScheduler(clock);
      var interval = const Duration(seconds: 1);
      var ticks = 0;
      final ticker = PreTranslationProgressTicker(
        interval: () => interval,
        clock: () => clock.now,
        scheduler: scheduler.schedule,
        onTick: (_) => ticks++,
      )..start();

      scheduler.elapse(const Duration(seconds: 1));
      expect(ticks, 1);
      expect(ticker.runningInterval, const Duration(seconds: 1));

      interval = const Duration(seconds: 5);
      // The tick that notices the change re-arms instead of repainting, so
      // three more seconds of the old cadence produce nothing.
      scheduler.elapse(const Duration(seconds: 2));
      expect(ticks, 1);
      expect(ticker.runningInterval, const Duration(seconds: 5));
      expect(scheduler.cancellations, 1);

      scheduler.elapse(const Duration(seconds: 5));
      expect(ticks, 2);
    });

    test('a nonsense interval cannot spin the UI', () {
      final clock = _FakeClock(DateTime(2026));
      final scheduler = _ManualScheduler(clock);
      final ticker = PreTranslationProgressTicker(
        interval: () => Duration.zero,
        clock: () => clock.now,
        scheduler: scheduler.schedule,
        onTick: (_) {},
      )..start();

      expect(
        ticker.runningInterval,
        const Duration(milliseconds: PreTranslationRefresh.defaultMs),
        reason: 'clamped to the documented default instead of 0',
      );
      scheduler.elapse(const Duration(seconds: 3));
      expect(ticker.isRunning, isTrue);
    });
  });

  group('12-A: the fold it drives stays honest', () {
    test('a finished job freezes elapsed at finishedAt, tick or no tick', () {
      final task = _task(
        createdAt: DateTime(2026),
        finishedAt: DateTime(2026).add(const Duration(minutes: 4)),
      )..status = PreTranslationTaskStatus.completed;
      // Even a far-future "now" must not make a finished job look like it is
      // still running: the ticker never runs for it (tested above), and the
      // fold would freeze the number anyway if one slipped through.
      final view = PreTranslationProgress.snapshot(
        task,
        now: DateTime(2026).add(const Duration(hours: 2)),
      );
      expect(view.elapsed, const Duration(minutes: 4));
      expect(view.eta, isNull);
    });
  });
}
