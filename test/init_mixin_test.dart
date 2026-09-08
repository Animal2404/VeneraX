import 'package:flutter_test/flutter_test.dart';
import 'package:venera/utils/init.dart';

/// A probe implementation of [Init].
///
/// `_isInit` is private to the mixin, so the observable contract is: does a
/// waiter complete, how many times did `doInit` actually run, and does a
/// failure surface as an error rather than as a hang.
class _Service with Init {
  _Service({this.delay = Duration.zero, this.failOnRun = 0});

  final Duration delay;

  /// Throw on this 1-based run of [doInit]; 0 never throws.
  final int failOnRun;

  int runs = 0;
  int errorsSeen = 0;

  @override
  Future<void> doInit() async {
    runs++;
    if (delay > Duration.zero) await Future.delayed(delay);
    if (failOnRun != 0 && runs >= failOnRun) {
      throw StateError('boom #$runs');
    }
  }
}

void main() {
  // The exact shape of plan D-14: `LocalManager.init()` called
  // `ComicSourceManager().ensureInit()` in a process where nothing ever calls
  // `init()`, so the future had no driver and `--headless` never returned.
  test('ensureInit starts initialization when nobody else does', () async {
    final service = _Service();
    await service.ensureInit().timeout(
      const Duration(seconds: 2),
      onTimeout: () => fail('ensureInit hung: the deadlock behind D-14'),
    );
    expect(service.runs, 1);
  });

  test('ensureInit is idempotent and cheap once initialized', () async {
    final service = _Service();
    await service.ensureInit();
    await service.ensureInit();
    await service.init();
    expect(service.runs, 1, reason: 'doInit must not run twice');
  });

  test('concurrent ensureInit and init run doInit exactly once', () async {
    final service = _Service(delay: const Duration(milliseconds: 20));
    final waiters = [
      service.ensureInit(),
      service.init(),
      service.ensureInit(),
      service.init(),
    ];
    await Future.wait(waiters).timeout(const Duration(seconds: 2));
    expect(service.runs, 1);
  });

  test('waiters all complete when initialization finishes', () async {
    final service = _Service(delay: const Duration(milliseconds: 10));
    var completed = 0;
    for (var i = 0; i < 5; i++) {
      unawaitedWait(service.ensureInit(), () => completed++);
    }
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(completed, 5);
    expect(service.runs, 1);
  });

  test('a failing doInit reports an error instead of hanging', () async {
    final service = _Service(failOnRun: 1);
    await expectLater(
      service.ensureInit().timeout(const Duration(seconds: 2)),
      throwsA(isA<StateError>()),
    );
    // A failed pass must not poison the object: a later attempt retries.
    expect(service.runs, 1);
  });

  test('init() still propagates failures to its own caller', () async {
    final service = _Service(failOnRun: 1);
    await expectLater(
      service.init().timeout(const Duration(seconds: 2)),
      throwsA(isA<StateError>()),
    );
  });
}

void unawaitedWait(Future<void> future, void Function() onDone) {
  future.then((_) => onDone()).catchError((Object _) {});
}
