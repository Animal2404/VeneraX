// Regression test for the CI guard (tool/ci/check_test_run.dart), pinned by
// run 34364131841: `flutter test` exited 1 with every recorded case green —
// testStart 1488 / testDone 1488, zero `result != success`, zero `error`
// events, stderr empty — and the machine report ended with
// {"success":false,"type":"done"}.
//
// The guard must classify exactly that shape as a PROCESS-TEARDOWN failure
// and stay RED. Turning it into "exit 1 but all passed => green" is the
// silent-whitelist failure mode the guard exists to prevent, so the wording
// and the verdict are both asserted here.
//
// Imports the guard relatively (it lives in tool/, not lib/): parseReport /
// evaluate / buildReport are pure — they touch no files and no process.
import 'package:flutter_test/flutter_test.dart';
import '../tool/ci/check_test_run.dart';

const String _absA = 'D:/a/VeneraX/VeneraX/test/a_test.dart';

GuardInput _input({required int flutterExit, required bool doneSuccess}) {
  return GuardInput(
    diskTests: const <String>['test/a_test.dart'],
    parse: parseReport(
      buildReport([SuiteSpec(_absA, ['pass', 'pass'])], doneSuccess: doneSuccess),
    ),
    exclusions: const <String, String>{},
    minExecuted: 1,
    flutterExit: flutterExit,
  );
}

void main() {
  test('the 34364131841 shape (green cases, done.success=false, exit 1) is RED', () {
    final result = evaluate(_input(flutterExit: 1, doneSuccess: false));
    expect(result.ok, isFalse,
        reason: 'exit 1 with green cases is never a pass');
    expect(
      result.failures.any((f) => f.contains('EXIT CODE') && f.contains('PROCESS-TEARDOWN')),
      isTrue,
      reason: 'the failure must be named as a process-teardown failure: ${result.failures}',
    );
    expect(result.summary, contains('done.success=false'));
  });

  test('the same report with exit 0 stays GREEN (no failure is manufactured)', () {
    final result = evaluate(_input(flutterExit: 0, doneSuccess: true));
    expect(result.ok, isTrue, reason: result.summary);
    expect(result.summary, contains('machine done event   : success=true'));
  });

  test('parsing keeps the hidden load/setUp/tearDown accounting intact for this report', () {
    // buildReport emits one hidden 'loading' test per suite; a teardown failure
    // is NOT a load error, and the guard must not re-label it as one.
    final parsed =
        parseReport(buildReport([SuiteSpec(_absA, ['pass', 'pass'])], doneSuccess: false));
    expect(parsed.sawDone, isTrue);
    expect(parsed.doneSuccess, isFalse);
    expect(parsed.loadErrors, isEmpty);
    expect(parsed.suites['test/a_test.dart']!.passed, 2);
    expect(parsed.suites['test/a_test.dart']!.failed, 0);
  });
}
