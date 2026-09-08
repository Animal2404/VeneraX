import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/image_translation/ocr_batching.dart';
import 'package:venera/foundation/image_translation/ort_capabilities.dart';
import 'package:venera/foundation/image_translation/ort_ffi.dart';
import 'package:venera/foundation/image_translation/translation_worker.dart';

/// Stands in for `OrtFfiSession`: the real class cannot be constructed in a
/// unit test (`open` requires the native ONNX Runtime library), so
/// [EpSessionCache] is generic over the session type and these tests drive
/// the real class with fakes that record how often they were released.
class FakeOcrSession {
  FakeOcrSession(this.path, this.ep);

  final String path;
  final OrtEpKind ep;
  int closeCount = 0;

  bool get closed => closeCount > 0;

  @override
  String toString() => '$path@${ep.name}';
}

const _desktopDml = OrtProbe(
  runtimeVersion: 'test',
  hasCudaSymbol: false,
  hasDmlSymbol: true,
  isWindows: true,
  isDesktop: true,
);

const _noGpu = OrtProbe(
  runtimeVersion: 'test',
  hasCudaSymbol: false,
  hasDmlSymbol: false,
  isWindows: false,
  isDesktop: false,
);

/// `decideAfterFailure` maps deviceRemoved to `goCpuPermanently` — the exact
/// decision that used to strand the old DirectML session in the map.
const _deviceRemoved = OrtFfiException(
  'D3D_ERROR_DEVICE_REMOVED: the GPU went away',
  OrtFfiErrorKind.deviceRemoved,
);

/// Cache over fakes; [opens] and [released] (optional) observe the two sides
/// of the native boundary — which EP was asked for, and which session
/// handles were handed back.
EpSessionCache<FakeOcrSession> buildCache({
  int dmlDiesAfter = 1 << 30,
  bool cpuDies = false,
  List<String>? opens,
  List<FakeOcrSession>? released,
}) {
  var dmlWins = 0;
  return EpSessionCache<FakeOcrSession>(
    open: (path, ep, threads) {
      opens?.add(EpSessionCache.keyFor(path, ep));
      if (ep == OrtEpKind.directml) {
        if (dmlWins >= dmlDiesAfter) throw _deviceRemoved;
        dmlWins++;
      } else if (cpuDies) {
        throw _deviceRemoved;
      }
      return FakeOcrSession(path, ep);
    },
    // The production wiring is `(s) => s.close()` — idempotent, which is why
    // eviction cannot double-free; the fake mirrors that by counting.
    release: (session) {
      session.closeCount++;
      released?.add(session);
    },
  );
}

const _det = 'models/text_detector.onnx';
const _zhRec = 'models/ocr_zh/rec.onnx';
const _enRec = 'models/ocr_en/rec.onnx';

FakeOcrSession resolve(
  EpSessionCache<FakeOcrSession> cache,
  String path, {
  OrtProbe probe = _desktopDml,
  bool forceCpu = false,
}) =>
    cache.resolve(
      path,
      pref: EpPreference.auto,
      probe: probe,
      intraOpThreads: 2,
      forceCpu: forceCpu,
    );

void main() {
  group('EpSessionCache — one live session per path, keyed by its real EP', () {
    // The bug this guards (found after D-15): every successful open rewrote
    // the worker-wide `_ep`, so once any model fell back to CPU every later
    // lookup used the key `path@cpu`, missed, re-opened the model — and the
    // previous `path@directml` session stayed in the map forever: the same
    // model on two providers at once, VRAM from both held, sessionCount
    // inflated. The fix: keys name the EP the session actually runs on, and
    // publishing a path supersedes (closes + removes) its other-EP session.
    test('after a CPU fallback no DirectML session lingers for the path', () {
      final cache = buildCache(dmlDiesAfter: 1);

      // Request 1 while the GPU is healthy: the recognizer runs DirectML.
      final recDml = resolve(cache, _zhRec);
      expect(recDml.ep, OrtEpKind.directml);
      expect(cache.observedEp, OrtEpKind.directml);

      // The detector now hits the dead GPU mid-request → permanent CPU
      // fallback. (Different paths may keep different EPs; only ONE session
      // per path is forbidden.)
      final detCpu = resolve(cache, _det);
      expect(detCpu.ep, OrtEpKind.cpu);
      expect(cache.observedEp, OrtEpKind.cpu);
      expect(cache.sessionCount, 2);

      // Next page: the zh recognizer is looked up again. The old code asked
      // for `@cpu`, missed, re-opened on CPU and left the DirectML handle
      // stranded. The fixed code re-opens, and publishing `@cpu` must close
      // and evict `@directml` — exactly once (idempotent close).
      final recCpu = resolve(cache, _zhRec);
      expect(recCpu.ep, OrtEpKind.cpu);
      expect(
        recDml.closed,
        isTrue,
        reason: 'the superseded DirectML session must be released',
      );
      expect(
        recDml.closeCount,
        1,
        reason: 'close() is idempotent in production; eviction must reach '
            'it exactly once anyway',
      );
      expect(
        cache.contains(_zhRec, OrtEpKind.directml),
        isFalse,
        reason: 'no dual-EP residue may stay in the map',
      );
      expect(cache.contains(_zhRec, OrtEpKind.cpu), isTrue);
      expect(
        cache.sessionCount,
        2,
        reason: 'det + zh rec — an inflated count is exactly what hid D-13',
      );
      expect(
        cache.keys.toList(),
        unorderedEquals([
          EpSessionCache.keyFor(_det, OrtEpKind.cpu),
          EpSessionCache.keyFor(_zhRec, OrtEpKind.cpu),
        ]),
      );
    });

    test('the first DirectML success is keyed by the provider it ran on', () {
      // Regression for the mis-keying half of the bug: the old code computed
      // the key from `_ep` at entry (initially `cpu`) and filed a session
      // that actually ran DirectML under `path@cpu`.
      final cache = buildCache();
      final session = resolve(cache, _det);
      expect(session.ep, OrtEpKind.directml);
      expect(cache.contains(_det, OrtEpKind.directml), isTrue);
      expect(cache.contains(_det, OrtEpKind.cpu), isFalse);
      expect(cache.observedEp, OrtEpKind.directml);
      expect(cache.sessionCount, 1);
    });

    test('a steady re-resolve is a cache hit and opens nothing again', () {
      final opens = <String>[];
      final cache = buildCache(opens: opens);
      final first = resolve(cache, _det);
      final again = resolve(cache, _det);
      expect(identical(again, first), isTrue);
      expect(opens, [EpSessionCache.keyFor(_det, OrtEpKind.directml)]);
    });

    test('CPU-pinned (D-15) recognizers never rewrite the observation', () {
      final opens = <String>[];
      final cache = buildCache(opens: opens);
      resolve(cache, _det);
      expect(cache.observedEp, OrtEpKind.directml);

      final pinned = resolve(cache, _enRec, forceCpu: true);
      expect(pinned.ep, OrtEpKind.cpu);
      expect(opens.last, EpSessionCache.keyFor(_enRec, OrtEpKind.cpu));
      expect(
        cache.observedEp,
        OrtEpKind.directml,
        reason: 'a pinned open is not evidence about the GPU; letting it '
            'advance the observation drags every unrelated model to CPU',
      );

      // The pinned path keeps hitting its own cpu key, and the detector its
      // own directml key — the two EPs describe different paths, not two
      // sessions of one path.
      expect(identical(resolve(cache, _enRec, forceCpu: true), pinned), isTrue);
      expect(cache.sessionCount, 2);
    });

    test('GPU recovery supersedes the CPU session of the same path', () {
      // The eviction works in both directions: a path that had fallen back
      // to CPU must not keep its CPU handle once the same path re-opens on
      // a recovered GPU.
      final cache = buildCache();
      final cpu = resolve(cache, _det, probe: _noGpu);
      expect(cpu.ep, OrtEpKind.cpu);
      // Another model proves the GPU is back, advancing the observation…
      resolve(cache, _zhRec);
      expect(cache.observedEp, OrtEpKind.directml);
      // …so the detector is re-probed and now lands on DirectML.
      final dml = resolve(cache, _det);
      expect(dml.ep, OrtEpKind.directml);
      expect(cpu.closed, isTrue);
      expect(cpu.closeCount, 1);
      expect(cache.contains(_det, OrtEpKind.cpu), isFalse);
      expect(cache.sessionCount, 2);
    });

    test('when even the last-resort CPU open fails the error surfaces', () {
      final cache = buildCache(dmlDiesAfter: 0, cpuDies: true);
      expect(
        () => resolve(cache, _det),
        throwsA(isA<OrtFfiException>()),
      );
      expect(
        cache.sessionCount,
        0,
        reason: 'nothing was ever published; a failed open must not leave '
            'ghost entries behind',
      );
    });

    test('the attempts log names each provider outcome', () {
      final cache = buildCache(dmlDiesAfter: 1);
      resolve(cache, _zhRec); // directml:ok
      resolve(cache, _det); // directml:fail → cpu fallback
      expect(cache.attempts.first, 'directml:ok');
      expect(
        cache.attempts
            .any((a) => a.startsWith('directml:fail(deviceRemoved)')),
        isTrue,
      );
    });

    test('closeAll releases every live session exactly once', () {
      final released = <FakeOcrSession>[];
      final cache = buildCache(dmlDiesAfter: 0, released: released);
      final a = resolve(cache, _det);
      final b = resolve(cache, _zhRec);
      expect(a.ep, OrtEpKind.cpu); // directml dead → fallback
      expect(b.ep, OrtEpKind.cpu);
      cache.closeAll();
      expect(a.closed, isTrue);
      expect(b.closed, isTrue);
      expect(cache.sessionCount, 0);
      expect(released, hasLength(2));
      cache.closeAll(); // idempotent — nothing left to release
      expect(released, hasLength(2));
    });

    test('non-desktop probes open on CPU only and say so in the key', () {
      final opens = <String>[];
      final cache = buildCache(opens: opens);
      final s = resolve(cache, _det, probe: _noGpu);
      expect(s.ep, OrtEpKind.cpu);
      expect(opens, [EpSessionCache.keyFor(_det, OrtEpKind.cpu)]);
      expect(cache.observedEp, OrtEpKind.cpu);
    });
  });

  group('runWithShrinkLadder — shared det/rec/dec in-place retry (task 2)',
      () {
    const buckets = [160, 256, 384, 512, 640, 768, 896, 960];
    BatchProfile p(int det, int rec, int dec) => BatchProfile(
          detBatch: det,
          recBatch: rec,
          decBatch: dec,
          widthQuantum: 64,
          widthBuckets: buckets,
        );

    test('an OOMing pass re-runs at every halved profile until it fits', () {
      final seen = <int>[];
      var failures = 2;
      final trail = <String>[];
      runWithShrinkLadder(
        start: p(2, 32, 32),
        attempt: (profile) {
          seen.add(profile.recBatch);
          if (failures-- > 0) {
            throw const OrtFfiException(
              'out of memory',
              OrtFfiErrorKind.outOfMemory,
            );
          }
        },
        onShrink: (next, previous) =>
            trail.add('dec${next.decBatch}<-${previous.decBatch}'),
      );
      expect(seen, [32, 16, 8]);
      expect(
        trail,
        ['dec16<-32', 'dec8<-16'],
        reason: 'event names must say which pass retreated and from what',
      );
    });

    test('a non-OOM failure rethrows untouched — shrinking cannot fix it',
        () {
      expect(
        () => runWithShrinkLadder(
          start: p(4, 32, 32),
          attempt: (_) => throw const OrtFfiException(
            'invalid graph',
            OrtFfiErrorKind.invalidGraph,
          ),
          onShrink: (_, __) => fail('must not shrink for a non-OOM error'),
        ),
        throwsA(isA<OrtFfiException>()),
      );
    });

    test('OOM at recBatch 1 runs the pass exactly once and rethrows', () {
      var runs = 0;
      expect(
        () => runWithShrinkLadder(
          start: p(1, 1, 1),
          attempt: (_) {
            runs++;
            throw const OrtFfiException(
              'out of memory',
              OrtFfiErrorKind.outOfMemory,
            );
          },
          onShrink: (_, __) => fail('there is no rung below 1'),
        ),
        throwsA(isA<OrtFfiException>()),
      );
      expect(
        runs,
        1,
        reason: 'a page that genuinely cannot fit must fail loudly, not '
            'loop on a clamped halve()',
      );
    });

    test('the shrinking profile composes into a sticky ceiling', () {
      // This is how the worker persists a retreat across requests:
      // `onShrink` composes `next` into its ceiling; the loop hands out
      // strictly decreasing profiles, so the composition is monotone.
      var ceiling = cappedBy(p(2, 16, 16), null);
      final seen = <BatchProfile>[];
      var failures = 3;
      runWithShrinkLadder(
        start: ceiling,
        attempt: (profile) {
          seen.add(profile);
          if (failures-- > 0) {
            throw const OrtFfiException(
              'out of memory',
              OrtFfiErrorKind.outOfMemory,
            );
          }
        },
        onShrink: (next, previous) => ceiling = cappedBy(next, ceiling),
      );
      expect(ceiling.recBatch, 2);
      expect(ceiling.detBatch, 1); // 2→1→1→1: clamped, never zero
      expect(seen.map((x) => x.recBatch).toList(), [16, 8, 4, 2]);
      expect(seen.first.detBatch, 2);
      expect(seen.last.detBatch, 1);
    });
  });

  group('charsetClassMismatch — batch-path validation is a warning (task 3)',
      () {
    test('a missing probe result skips the check explicitly', () {
      // `null` expectedClasses means the probe could not read the model's
      // output shape. A missing observation must never be treated as a
      // mismatch — that would turn an unreadable graph into a wall of
      // false warnings on every page.
      expect(
        charsetClassMismatch(
          lang: 'zh',
          charsetLength: 6624,
          expectedClasses: null,
        ),
        isNull,
      );
    });

    test('agreement produces no warning', () {
      expect(
        charsetClassMismatch(
          lang: 'zh',
          charsetLength: 6624,
          expectedClasses: 6624,
        ),
        isNull,
      );
    });

    test('a mismatch warns and names both counts, the lang and the dict', () {
      final note = charsetClassMismatch(
        lang: 'zh',
        charsetLength: 6624,
        expectedClasses: 6625,
        dictPath: '/data/models/ocr_zh/dict.txt',
      );
      expect(note, isNotNull);
      expect(note, contains('6624'));
      expect(note, contains('6625'));
      expect(note, contains('zh'));
      expect(note, contains('/data/models/ocr_zh/dict.txt'));
    });
  });
}
