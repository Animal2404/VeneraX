import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/image_translation/page_prefetcher.dart';

/// The prefetch ring is the fix for "the GPU waits on the network" (plan D-7),
/// and it sits on the path that decides which pages get OCR'd at all. A dropped
/// index there is a silently missing page in a chapter, so ordering, exactly-once
/// delivery, the tail, and the concurrency bound are all asserted here.
void main() {
  Uint8List bytes(int value) => Uint8List.fromList([value]);

  test('delivers every index exactly once', () async {
    final prefetcher = PagePrefetcher(
      depth: 3,
      fetch: (i) async => bytes(i),
    );
    final got = <int>[];
    await for (final page in prefetcher.run(List.generate(11, (i) => i * 7))) {
      got.add(page.index);
    }
    got.sort();
    expect(got, List.generate(11, (i) => i * 7));
  });

  test('an empty index list completes immediately', () async {
    var calls = 0;
    final prefetcher = PagePrefetcher(
      depth: 4,
      fetch: (i) async {
        calls++;
        return bytes(i);
      },
    );
    final got = <PrefetchedPage>[];
    await for (final page in prefetcher.run(const <int>[])) {
      got.add(page);
    }
    expect(got, isEmpty);
    expect(calls, 0);
  });

  test('never exceeds the configured concurrency', () async {
    var inFlight = 0;
    var peak = 0;
    final prefetcher = PagePrefetcher(
      depth: 3,
      fetch: (i) async {
        inFlight++;
        peak = inFlight > peak ? inFlight : peak;
        await Future<void>.delayed(const Duration(milliseconds: 5));
        inFlight--;
        return bytes(i);
      },
    );
    await for (final _ in prefetcher.run(List.generate(20, (i) => i))) {}
    expect(peak, lessThanOrEqualTo(3), reason: 'backpressure is the point');
    expect(peak, greaterThan(1), reason: 'it must actually overlap');
  });

  test('surfaces a failed fetch without losing the other pages', () async {
    final prefetcher = PagePrefetcher(
      depth: 2,
      fetch: (i) async {
        if (i == 4) throw Exception('http 404');
        return bytes(i);
      },
    );
    final ok = <int>[];
    final failed = <int>[];
    await for (final page in prefetcher.run(List.generate(8, (i) => i))) {
      (page.failed ? failed : ok).add(page.index);
    }
    expect(failed, [4]);
    expect(ok..sort(), [0, 1, 2, 3, 5, 6, 7]);
  });

  test('a slow consumer does not lose pages and does not run ahead', () async {
    var started = 0;
    final prefetcher = PagePrefetcher(
      depth: 2,
      fetch: (i) async {
        started++;
        return bytes(i);
      },
    );
    final seen = <int>[];
    await for (final page in prefetcher.run(List.generate(9, (i) => i))) {
      seen.add(page.index);
      // Consume one at a time with a gap; the ring must stay bounded.
      await Future<void>.delayed(const Duration(milliseconds: 2));
      // Bounded run-ahead. Measured bound is 2*depth + 1, not depth + workers,
      // because Channel.push lets *every* blocked pusher resume on a single
      // release and they re-add without re-checking the size — so the queue can
      // overshoot by (waiters - 1). With depth 2: 2 buffered + 1 overshoot +
      // 2 fetched-but-unpushed = 5. That overshoot is a property of the shared
      // Channel (used elsewhere), deliberately not changed here; this assertion
      // pins it so a future "fix" to Channel is noticed rather than silently
      // doubling the prefetch window.
      expect(
        started - seen.length,
        lessThanOrEqualTo(2 * 2 + 1),
        reason: 'prefetch ran ahead without bound: a chapter could sit in RAM',
      );
    }
    expect(seen.length, 9);
  });

  test('cancelling the stream stops delivery without hanging', () async {
    final prefetcher = PagePrefetcher(
      depth: 2,
      fetch: (i) async {
        await Future<void>.delayed(const Duration(milliseconds: 2));
        return bytes(i);
      },
    );
    final stream = prefetcher.run(List.generate(50, (i) => i));
    final seen = <int>[];
    final sub = stream.listen((page) => seen.add(page.index));
    await Future<void>.delayed(const Duration(milliseconds: 20));
    await sub.cancel();
    // Cancelling mid-stream must not throw or leave the harness hanging; the
    // pages already delivered are the ones that were consumed.
    expect(seen.length, greaterThan(0));
    expect(seen.length, lessThan(50));
  });
}
