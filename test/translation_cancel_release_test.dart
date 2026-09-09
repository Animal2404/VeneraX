import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/image_translation/pre_translation_tasks.dart';
import 'package:venera/foundation/image_translation/translation_performance_config.dart';
import 'package:venera/foundation/image_translation/translation_worker.dart';

/// Defect C: "the task is stopped, closed, cancelled — and the model is still
/// sitting in VRAM".
///
/// The teardown itself was already reachable from cancel; what was missing was
/// that cancelling could *cause* it. A running job holds one [OcrLease], and
/// [TranslationWorker.shutdownAll] defers to a bare `release()` while any lease
/// is held — including the lease of the job that just asked. The sessions came
/// down for a moment and then the job's own remaining pages asked the worker for
/// one more recognition, which re-opens them lazily. On the user's side of the
/// screen: cancelled, still loaded.
///
/// Three separate guarantees are pinned here:
///
/// * a cancel releases **whatever** [PipelineMode] says (the mode is a
///   throughput policy, and a cancelled job has no throughput left to protect);
/// * the factory default is still `freeVram` — this change must not quietly
///   flip the performance policy along the way;
/// * the evidence line reports what was **observed**, and answers `N/A` rather
///   than `0` when no isolate confirmed the release. A log that prints a number
///   nobody read is how D-13 hid the leak.
///
/// NOT VERIFIED LOCALLY (no `flutter test` in this workspace) — see the
/// "待云端 Test job 验证" list.
void main() {
  group('a cancel releases the pool regardless of PipelineMode', () {
    test('throughput keeps the pool warm only for work that is still running',
        () {
      expect(
        PreTranslationTaskManager.releasesPoolOnSweepEnd(
          mode: PipelineMode.throughput,
          canceled: false,
        ),
        isFalse,
        reason: 'ruling R-4 stands: throughput still overlaps the next sweep',
      );
      expect(
        PreTranslationTaskManager.releasesPoolOnSweepEnd(
          mode: PipelineMode.throughput,
          canceled: true,
        ),
        isTrue,
        reason: 'an explicit cancel is intent, not a throughput opportunity',
      );
    });

    test('freeVram releases either way', () {
      for (final canceled in [false, true]) {
        expect(
          PreTranslationTaskManager.releasesPoolOnSweepEnd(
            mode: PipelineMode.freeVram,
            canceled: canceled,
          ),
          isTrue,
        );
      }
    });

    test('the factory default is still freeVram (gate G2 has not passed)', () {
      // Red line: this defect fix must not change the shipped default while it
      // makes *cancelling* honest.
      expect(
        TranslationPerformanceConfig.pipelineModeFromSetting(null),
        PipelineMode.freeVram,
      );
      expect(
        TranslationPerformanceConfig.pipelineModeFromSetting('nonsense'),
        PipelineMode.freeVram,
      );
      expect(
        TranslationPerformanceConfig.pipelineModeFromSetting('throughput'),
        PipelineMode.throughput,
      );
    });
  });

  group('PoolTeardown — what may be claimed, and what must be admitted', () {
    test('an unobserved release prints N/A, never a borrowed zero', () {
      const t = PoolTeardown(
        workers: 2,
        sessions: null,
        deferred: false,
        leasesHeld: 0,
      );
      expect(t.evidence, 'sessions=N/A');
      expect(t.freed, isFalse);
    });

    test('sessions=0 with a lease still held is not "freed"', () {
      // The deferred branch: the handles went back, but somebody is still
      // holding the pool and the next request will load it again. Reporting
      // that as freed would be the same lie in a different costume.
      const t = PoolTeardown(
        workers: 1,
        sessions: 0,
        deferred: true,
        leasesHeld: 1,
      );
      expect(t.evidence, 'sessions=0');
      expect(t.freed, isFalse);
      expect(t.toString(), contains('deferred=true'));
    });

    test('a confirmed zero with nobody holding the pool is the real thing', () {
      const t = PoolTeardown(
        workers: 2,
        sessions: 0,
        deferred: false,
        leasesHeld: 0,
      );
      expect(t.freed, isTrue);
    });

    test('one worker still holding sessions dominates the answer', () {
      expect(TranslationWorker.foldSessionObservations([0, 3, 1]), 3);
    });

    test('a single missing ack voids the whole pool', () {
      // Two isolates, one acked clean and one never answered: the old code read
      // a *pool-wide* report slot and printed whichever number arrived last —
      // the clean one. One unknown is an unknown.
      expect(TranslationWorker.foldSessionObservations([0, null]), isNull);
      expect(TranslationWorker.foldSessionObservations([null, 0]), isNull);
    });

    test('no workers at all is a measured zero', () {
      expect(TranslationWorker.foldSessionObservations(const []), 0);
    });
  });

  group('shutdownAll obeys the lease that the cancelling job itself held', () {
    test('a held lease defers the teardown and says so in the evidence',
        () async {
      final worker = TranslationWorker.instance;
      final lease = worker.acquireLease();
      addTearDown(lease.release);

      final deferred = await worker.shutdownAll();
      expect(deferred.deferred, isTrue);
      expect(deferred.leasesHeld, greaterThanOrEqualTo(1));
      expect(
        deferred.freed,
        isFalse,
        reason:
            'while a lease is held the pool can reload at any time, so '
            '"freed" is not a claim this object is allowed to make',
      );
    });

    test('dropping that lease is what makes the teardown real', () async {
      // The step cancel() was missing: releasing *our own* lease before asking
      // for the pool back. Other jobs' leases are untouched, so the rule the
      // lease exists for still holds.
      final worker = TranslationWorker.instance;
      final lease = worker.acquireLease();
      lease.release();

      final teardown = await worker.shutdownAll();
      expect(teardown.deferred, isFalse);
      expect(teardown.leasesHeld, 0);
      expect(teardown.freed, isTrue, reason: 'nothing was loaded to begin with');
      expect(teardown.evidence, 'sessions=0');
    });
  });
}
