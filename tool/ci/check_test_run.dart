// tool/ci/check_test_run.dart
//
// Gate for the `Test` job in .github/workflows/main.yml.
//
// WHY THIS FILE EXISTS
// --------------------
// The Test job used to name 33 test files explicitly while 138 existed on
// disk: 105 files (789 cases) had never run in any CI run, and a test file
// added later stayed invisible until somebody remembered to edit the workflow.
// The job now runs the whole suite (`flutter test`, no file list), which
// removes the positive whitelist — but "runs the whole suite" is only true if
// something proves it. This script is that something. It reads the machine
// report produced by `flutter test --machine` and fails the step when:
//
//   1. DRIFT      — a `test/**/*_test.dart` file on disk executed zero cases.
//                   A silent whitelist, a broken import, a dart_test.yaml
//                   filter and a suite that fails to load all look like this
//                   from the outside.
//   2. FLOOR      — executed (non-skipped) cases are below --min-executed. A
//                   run in which every case skips is green to `flutter test`;
//                   it must not be green here.
//   3. FAILURES   — any case failed outside the explicit exclusion list.
//   4. EXCLUSIONS — a declared exclusion that no longer exists on disk
//                   (stale), one without a written reason, or a list longer
//                   than maxExclusions.
//
// An exclusion is NOT a silent skip. The file still runs; its failures are
// printed and counted as "tolerated"; an entry that became unnecessary is
// reported so it gets deleted. See tool/ci/ci_excluded_tests.txt for the
// policy and the (currently empty) list.
//
// `--self-test` runs before the suite on every CI run and proves that guards
// 1-4 can actually fail — a guard nobody has ever seen fire is decoration.
//
// Usage:
//   dart run tool/ci/check_test_run.dart --self-test
//   dart run tool/ci/check_test_run.dart \
//     --report ci-out/test_report.jsonl \
//     --test-dir test \
//     --exclusions tool/ci/ci_excluded_tests.txt \
//     --min-executed 800 \
//     --flutter-exit 0

import 'dart:convert';
import 'dart:io';

const int exitPass = 0;
const int exitFail = 1;
const int exitUsage = 2;

/// Hard cap on tolerated exclusions. If a runner cannot provide more than this
/// many dependencies, the fix is the environment or a counted self-skip in the
/// test — not a longer list.
const int maxExclusions = 8;

// ---------------------------------------------------------------------------
// machine-report parsing
// ---------------------------------------------------------------------------

class SuiteStats {
  int ran = 0; // executed and not skipped (passed + failed)
  int passed = 0;
  int failed = 0;
  int skipped = 0;
  final List<String> failedNames = <String>[];
}

class ReportParse {
  final Map<String, SuiteStats> suites = <String, SuiteStats>{};
  final Map<int, String> suiteIdToPath = <int, String>{};
  final Map<int, int> testIdToSuite = <int, int>{};
  final Map<int, String> testNames = <int, String>{};
  final Map<int, String> lastErrorFor = <int, String>{};
  final List<String> loadErrors = <String>[];
  final List<String> firstUnparsed = <String>[];
  int lines = 0;
  int unparsedLines = 0;
  int suiteEvents = 0;
  int testDones = 0;

  /// Flutter-tool lifecycle events (no `type`), e.g. `test.startedProcess`.
  /// Counted so the log can say what it skipped instead of staying silent.
  int toolEvents = 0;
  bool sawDone = false;
  bool doneSuccess = false;
}

/// `D:\a\VeneraX\VeneraX\test\foo_test.dart` -> `test/foo_test.dart`.
String repoRelative(String rawPath) {
  var p = rawPath.replaceAll('\\', '/');
  while (p.contains('//')) {
    p = p.replaceAll('//', '/');
  }
  if (p.startsWith('./')) {
    p = p.substring(2);
  }
  if (p.startsWith('test/')) {
    return p;
  }
  final i = p.lastIndexOf('/test/');
  if (i >= 0) {
    return p.substring(i + 1);
  }
  return p;
}

void _recordUnparsed(ReportParse report, String line) {
  report.unparsedLines++;
  if (report.firstUnparsed.length < 3) {
    report.firstUnparsed.add(line.length > 120 ? '${line.substring(0, 120)}...' : line);
  }
}

ReportParse parseReport(String text) {
  final report = ReportParse();
  for (final raw in const LineSplitter().convert(text)) {
    final line = raw.trim();
    if (line.isEmpty) {
      continue;
    }
    report.lines++;
    dynamic decoded;
    try {
      decoded = jsonDecode(line);
    } catch (_) {
      _recordUnparsed(report, line);
      continue;
    }
    if (decoded is Map<String, dynamic>) {
      _handleEvent(report, decoded);
    } else if (decoded is List) {
      // The flutter tool writes its own lifecycle events
      // (`{"event":"test.startedProcess",...}`) onto the same stream as
      // package:test's one-object-per-line events, but wrapped in a JSON
      // *array*. They carry no "type", they are not test events, and calling
      // them unparseable output makes the guard cry wolf about a healthy
      // report — 139 such lines (one per suite) in the first full run.
      for (final item in decoded) {
        if (item is Map<String, dynamic>) {
          _handleEvent(report, item);
        } else {
          _recordUnparsed(report, line);
        }
      }
    } else {
      _recordUnparsed(report, line);
    }
  }
  return report;
}

void _handleEvent(ReportParse report, Map<String, dynamic> event) {
  final type = event['type'];
  if (type is! String) {
    report.toolEvents++;
    return;
  }
  switch (type) {
    case 'suite':
      final suite = event['suite'];
      if (suite is Map) {
        final id = suite['id'];
        final path = suite['path'];
        if (id is int && path is String) {
          final rel = repoRelative(path);
          report.suiteIdToPath[id] = rel;
          report.suites.putIfAbsent(rel, () => SuiteStats());
          report.suiteEvents++;
        }
      }
      break;
    case 'testStart':
      final test = event['test'];
      if (test is Map) {
        final id = test['id'];
        final suiteId = test['suiteID'];
        final name = test['name'];
        if (id is int && suiteId is int && name is String) {
          report.testIdToSuite[id] = suiteId;
          report.testNames[id] = name;
        }
      }
      break;
    case 'testDone':
      final id = event['testID'];
      if (id is! int) {
        break;
      }
      report.testDones++;
      final hidden = event['hidden'] == true;
      final skipped = event['skipped'] == true;
      final result = event['result'];
      if (hidden) {
        // The synthetic "loading <file>" test: a non-success result here is a
        // suite that failed to compile or load.
        if (result != 'success') {
          final path = report.suiteIdToPath[report.testIdToSuite[id]] ?? '<unknown>';
          final detail = report.lastErrorFor[id] ?? '$result';
          report.loadErrors.add('$path: $detail');
        }
        break;
      }
      final rel = report.suiteIdToPath[report.testIdToSuite[id]] ?? '<unknown>';
      final stats = report.suites.putIfAbsent(rel, () => SuiteStats());
      final name = report.testNames[id] ?? '<unnamed>';
      if (skipped) {
        stats.skipped++;
      } else if (result == 'success') {
        stats.ran++;
        stats.passed++;
      } else {
        stats.ran++;
        stats.failed++;
        stats.failedNames.add(name);
      }
      break;
    case 'error':
      final id = event['testID'];
      final message = event['error'];
      if (id is int && message is String) {
        report.lastErrorFor[id] = message.split('\n').first;
      }
      break;
    case 'done':
      report.sawDone = true;
      report.doneSuccess = event['success'] == true;
      break;
    default:
      break;
  }
}

// ---------------------------------------------------------------------------
// the guard
// ---------------------------------------------------------------------------

class GuardInput {
  GuardInput({
    required this.diskTests,
    required this.parse,
    required this.exclusions,
    required this.minExecuted,
    required this.flutterExit,
  });

  final List<String> diskTests;
  final ReportParse parse;
  final Map<String, String> exclusions;
  final int minExecuted;
  final int flutterExit;
}

class GuardResult {
  GuardResult({
    required this.failures,
    required this.warnings,
    required this.notes,
    required this.summary,
  });

  final List<String> failures;
  final List<String> warnings;
  final List<String> notes;
  final String summary;
  bool get ok => failures.isEmpty;
}

GuardResult evaluate(GuardInput input) {
  final failures = <String>[];
  final warnings = <String>[];
  final notes = <String>[];

  final disk = input.diskTests.toList()..sort();
  final diskSet = disk.toSet();
  final parse = input.parse;
  final exclusions = input.exclusions;

  if (exclusions.length > maxExclusions) {
    failures.add('EXCLUSION CAP: ${exclusions.length} exclusions declared, the cap is '
        '$maxExclusions. Fix the runner or let the test skip itself (a counted '
        '`skip:`); do not grow the list.');
  }

  if (parse.lines == 0) {
    failures.add('REPORT EMPTY: `flutter test --machine` produced no JSON events at all, '
        'so nothing was measured. See ci-out/test_stderr.log in the step log.');
  } else if (parse.suiteEvents == 0) {
    failures.add('REPORT HAS NO SUITES: ${parse.lines} event(s) parsed, none of them a suite. '
        'Treating a report that never mentions a test file as a broken run, not as a pass.');
  }
  if (parse.unparsedLines > 0) {
    warnings.add('${parse.unparsedLines} machine-report line(s) were not JSON: '
        '${parse.firstUnparsed.join(' | ')}');
  }
  if (parse.toolEvents > 0) {
    notes.add('${parse.toolEvents} flutter-tool lifecycle event(s) ignored '
        '(no "type"; e.g. test.startedProcess) — not test results');
  }

  // 1. exclusions that no longer exist.
  for (final path in exclusions.keys) {
    if (!diskSet.contains(path)) {
      failures.add('STALE EXCLUSION: $path is listed in the exclusion file but does not '
          'exist on disk. Delete the entry.');
    }
  }

  // 2. drift: on disk, but nothing executed.
  final drift = <String>[];
  for (final path in disk) {
    if (exclusions.containsKey(path)) {
      continue;
    }
    final stats = parse.suites[path];
    if (stats == null) {
      drift.add('$path (no suite in the report at all)');
      continue;
    }
    if (stats.ran == 0) {
      drift.add('$path (${stats.skipped} case(s), all skipped, 0 executed)');
    }
  }
  if (drift.isNotEmpty) {
    failures.add('DRIFT: ${drift.length} test file(s) exist on disk but executed zero cases. '
        'This is the failure mode a file whitelist used to hide:\n    ${drift.join('\n    ')}');
  }

  for (final path in parse.suites.keys) {
    if (!diskSet.contains(path)) {
      warnings.add('report contains a suite that is not on disk: $path (stale report?)');
    }
  }

  // 3. declared exclusions: tolerate, but say so loudly.
  final tolerated = <String>[];
  for (final entry in exclusions.entries) {
    final path = entry.key;
    final reason = entry.value;
    final stats = parse.suites[path];
    if (stats == null) {
      tolerated.add(path);
      notes.add('EXCLUDED (never ran) $path — reason: $reason');
      continue;
    }
    if (stats.failed > 0) {
      tolerated.add(path);
      notes.add('EXCLUDED (tolerated ${stats.failed} failure(s) of '
          '${stats.ran + stats.skipped} case(s)) $path — reason: $reason');
      for (final name in stats.failedNames.take(5)) {
        notes.add('    tolerated failure: $name');
      }
    } else {
      warnings.add('exclusion no longer needed (${stats.ran} case(s) executed, 0 failed): '
          '$path — delete the entry');
    }
  }

  // 4. real failures.
  final realFailures = <String>[];
  for (final entry in parse.suites.entries) {
    if (exclusions.containsKey(entry.key)) {
      continue;
    }
    for (final name in entry.value.failedNames) {
      realFailures.add('${entry.key}: $name');
    }
  }
  if (realFailures.isNotEmpty) {
    failures.add('FAILED CASES: ${realFailures.length} case(s) failed outside the exclusion '
        'list:\n    ${realFailures.take(60).join('\n    ')}');
  }

  // 5. floor.
  var ran = 0;
  var passed = 0;
  var failed = 0;
  var skipped = 0;
  for (final stats in parse.suites.values) {
    ran += stats.ran;
    passed += stats.passed;
    failed += stats.failed;
    skipped += stats.skipped;
  }
  if (ran < input.minExecuted) {
    failures.add('FLOOR: executed $ran case(s), the floor is ${input.minExecuted}. A run in '
        'which everything skips is green to `flutter test` and must not be green here.');
  }

  // 6. exit-code cross-check.
  if (input.flutterExit != 0 && realFailures.isEmpty && drift.isEmpty) {
    if (tolerated.isEmpty) {
      failures.add('EXIT CODE: `flutter test` exited ${input.flutterExit}, but the report '
          'attributes no failure and there is no drift. Treating this as a load/crash '
          'failure; read ci-out/test_stderr.log.');
    } else {
      warnings.add('`flutter test` exited ${input.flutterExit}; the only failures are '
          'tolerated exclusions (${tolerated.join(', ')}).');
    }
  }

  for (final error in parse.loadErrors.take(10)) {
    notes.add('LOAD ERROR: $error');
  }

  final buffer = StringBuffer();
  buffer.writeln('================ CI TEST GUARD ================');
  buffer.writeln('on-disk test files   : ${disk.length}');
  buffer.writeln('suites in report     : ${parse.suites.length}');
  buffer.writeln('executed cases       : $ran');
  buffer.writeln('passed / failed      : $passed / $failed');
  buffer.writeln('skipped              : $skipped');
  buffer.writeln('exclusions           : ${exclusions.length} (cap $maxExclusions)');
  buffer.writeln('executed floor       : ${input.minExecuted}');
  buffer.writeln('flutter test exit    : ${input.flutterExit}');
  for (final note in notes) {
    buffer.writeln('note: $note');
  }
  for (final warning in warnings) {
    buffer.writeln('warning: $warning');
  }
  for (final failure in failures) {
    buffer.writeln('FAIL: $failure');
  }
  buffer.writeln('-----------------------------------------------');
  buffer.writeln(failures.isEmpty
      ? 'GUARD PASS: every on-disk test file executed at least one case, no unexcluded '
          'failure, executed-case floor met.'
      : 'GUARD FAIL: ${failures.length} condition(s) above.');

  return GuardResult(
    failures: failures,
    warnings: warnings,
    notes: notes,
    summary: buffer.toString(),
  );
}

// ---------------------------------------------------------------------------
// files
// ---------------------------------------------------------------------------

List<String> listDiskTests(String dir) {
  final root = Directory(dir);
  if (!root.existsSync()) {
    throw FormatException('test directory "$dir" does not exist');
  }
  final out = <String>[];
  for (final entity in root.listSync(recursive: true, followLinks: false)) {
    if (entity is! File) {
      continue;
    }
    final rel = repoRelative(entity.path);
    if (!rel.endsWith('_test.dart')) {
      continue;
    }
    out.add(rel);
  }
  out.sort();
  return out;
}

/// `test/foo_test.dart | why this runner cannot run it`
Map<String, String> readExclusions(String path) {
  final file = File(path);
  if (!file.existsSync()) {
    throw FormatException('exclusion file $path not found — commit it even when empty');
  }
  final out = <String, String>{};
  var lineNo = 0;
  for (final raw in const LineSplitter().convert(file.readAsStringSync())) {
    lineNo++;
    final line = raw.trim();
    if (line.isEmpty || line.startsWith('#')) {
      continue;
    }
    final separator = line.indexOf('|');
    if (separator < 0) {
      throw FormatException('$path:$lineNo has no reason — format is '
          '"test/x_test.dart | why"');
    }
    final testPath = line.substring(0, separator).trim();
    final reason = line.substring(separator + 1).trim();
    if (testPath.isEmpty || reason.isEmpty) {
      throw FormatException('$path:$lineNo needs both a path and a reason');
    }
    out[testPath] = reason;
  }
  return out;
}

void writeStepSummary(String text) {
  final target = Platform.environment['GITHUB_STEP_SUMMARY'];
  if (target == null || target.isEmpty) {
    return;
  }
  try {
    File(target).writeAsStringSync('```\n$text```\n', mode: FileMode.append);
  } catch (_) {
    // A missing summary file must never change the verdict.
  }
}

// ---------------------------------------------------------------------------
// self-test
// ---------------------------------------------------------------------------

class SuiteSpec {
  SuiteSpec(this.path, this.results);

  /// Absolute, Windows-style, so repoRelative() is exercised too.
  final String path;

  /// 'pass' | 'fail' | 'skip'
  final List<String> results;
}

String buildReport(List<SuiteSpec> specs) {
  final buffer = StringBuffer();
  var suiteId = 0;
  var testId = 0;
  for (final spec in specs) {
    buffer.writeln(jsonEncode({
      'type': 'suite',
      'suite': {'id': suiteId, 'path': spec.path},
    }));
    final loadingId = testId++;
    buffer.writeln(jsonEncode({
      'type': 'testStart',
      'test': {'id': loadingId, 'name': 'loading ${spec.path}', 'suiteID': suiteId},
    }));
    buffer.writeln(jsonEncode({
      'type': 'testDone',
      'testID': loadingId,
      'result': 'success',
      'skipped': false,
      'hidden': true,
    }));
    for (final result in spec.results) {
      final id = testId++;
      buffer.writeln(jsonEncode({
        'type': 'testStart',
        'test': {'id': id, 'name': 'case $id', 'suiteID': suiteId},
      }));
      buffer.writeln(jsonEncode({
        'type': 'testDone',
        'testID': id,
        'result': result == 'fail' ? 'error' : 'success',
        'skipped': result == 'skip',
        'hidden': false,
      }));
    }
    suiteId++;
  }
  buffer.writeln(jsonEncode({'type': 'done', 'success': true}));
  return buffer.toString();
}

int runSelfTest() {
  const absA = 'D:/a/VeneraX/VeneraX/test/a_test.dart';
  const absB = 'D:/a/VeneraX/VeneraX/test/b_test.dart';
  const absC = 'D:/a/VeneraX/VeneraX/test/c_test.dart';
  final problems = <String>[];
  var checks = 0;

  void expectThat(String label, bool condition) {
    checks++;
    if (!condition) {
      problems.add(label);
    }
    stdout.writeln('[self-test] ${condition ? 'ok  ' : 'FAIL'} $label');
  }

  GuardResult run(
    List<SuiteSpec> specs, {
    Map<String, String> exclusions = const <String, String>{},
    int min = 1,
    int flutterExit = 0,
    List<String> disk = const <String>['test/a_test.dart', 'test/b_test.dart', 'test/c_test.dart'],
  }) {
    return evaluate(GuardInput(
      diskTests: disk,
      parse: parseReport(buildReport(specs)),
      exclusions: exclusions,
      minExecuted: min,
      flutterExit: flutterExit,
    ));
  }

  // 1. healthy
  var result = run(
    [SuiteSpec(absA, ['pass']), SuiteSpec(absB, ['pass']), SuiteSpec(absC, ['pass'])],
    min: 3,
  );
  expectThat('healthy full run passes', result.ok);

  // 2. drift: c_test.dart exists on disk but never executes.
  result = run(
    [SuiteSpec(absA, ['pass']), SuiteSpec(absB, ['pass'])],
    min: 2,
  );
  expectThat(
    'a file that executes nothing fails the drift guard',
    !result.ok && result.failures.any((f) => f.contains('test/c_test.dart')),
  );

  // 3. floor: everything skipped.
  result = run(
    [SuiteSpec(absA, ['skip']), SuiteSpec(absB, ['skip']), SuiteSpec(absC, ['skip'])],
    min: 1,
  );
  expectThat(
    'an all-skipped run fails the executed-case floor',
    !result.ok && result.failures.any((f) => f.contains('FLOOR')),
  );

  // 4. stale exclusion.
  result = run(
    [SuiteSpec(absA, ['pass']), SuiteSpec(absB, ['pass']), SuiteSpec(absC, ['pass'])],
    exclusions: {'test/gone_test.dart': 'file was deleted'},
    min: 3,
  );
  expectThat(
    'a stale exclusion fails',
    !result.ok && result.failures.any((f) => f.contains('STALE EXCLUSION')),
  );

  // 5. tolerated failure inside a declared exclusion.
  result = run(
    [SuiteSpec(absA, ['pass']), SuiteSpec(absB, ['pass']), SuiteSpec(absC, ['fail'])],
    exclusions: {'test/c_test.dart': 'needs a native DLL the runner does not have'},
    min: 2,
    flutterExit: 1,
  );
  expectThat('an excluded failure is tolerated', result.ok);
  expectThat('a tolerated failure is named in the summary', result.summary.contains('tolerated'));

  // 6. real failure outside the exclusion list.
  result = run(
    [SuiteSpec(absA, ['pass']), SuiteSpec(absB, ['pass']), SuiteSpec(absC, ['fail'])],
    min: 2,
    flutterExit: 1,
  );
  expectThat(
    'an unexcluded failure fails',
    !result.ok && result.failures.any((f) => f.contains('FAILED CASES')),
  );

  // 7. exclusion cap.
  final disk10 = List<String>.generate(
    10,
    (i) => 'test/${String.fromCharCode(97 + i)}_test.dart',
  );
  result = run(
    [for (final path in disk10) SuiteSpec('D:/a/VeneraX/VeneraX/$path', ['pass'])],
    exclusions: {for (final path in disk10) path: 'pretend environment gap'},
    min: 1,
    disk: disk10,
  );
  expectThat(
    'the exclusion cap fires',
    !result.ok && result.failures.any((f) => f.contains('EXCLUSION CAP')),
  );

  // 8. an exclusion line without a reason is rejected outright.
  final temp = Directory.systemTemp.createTempSync('ci_guard_selftest_');
  try {
    final file = File('${temp.path}/excluded.txt')
      ..writeAsStringSync('test/a_test.dart\n');
    var rejected = false;
    try {
      readExclusions(file.path);
    } catch (_) {
      rejected = true;
    }
    expectThat('an exclusion without a reason is rejected', rejected);
  } finally {
    try {
      temp.deleteSync(recursive: true);
    } catch (_) {}
  }

  // 9. flutter-tool lifecycle events arrive as a JSON *array* on the same
  //    stream; they must be counted as tool noise, never as a corrupt report.
  final arrayReport = '[{"event":"test.startedProcess","params":{"vmServiceUri":null}}]\n'
      '${buildReport([SuiteSpec(absA, ['pass'])])}';
  result = evaluate(GuardInput(
    diskTests: const <String>['test/a_test.dart'],
    parse: parseReport(arrayReport),
    exclusions: const <String, String>{},
    minExecuted: 1,
    flutterExit: 0,
  ));
  expectThat(
    'array-wrapped flutter-tool events are not called unparseable',
    result.ok &&
        !result.summary.contains('were not JSON') &&
        result.summary.contains('lifecycle'),
  );

  if (problems.isEmpty) {
    stdout.writeln('GUARD SELF-TEST PASS: $checks/$checks checks behaved as specified '
        '(drift, floor, stale exclusion, cap, tolerated failure, real failure, '
        'missing-reason rejection).');
    return exitPass;
  }
  stdout.writeln('GUARD SELF-TEST FAIL: ${problems.length}/$checks check(s) wrong:');
  for (final problem in problems) {
    stdout.writeln('  - $problem');
  }
  return exitFail;
}

// ---------------------------------------------------------------------------
// entry point
// ---------------------------------------------------------------------------

void main(List<String> args) {
  if (args.contains('--self-test')) {
    exitCode = runSelfTest();
    return;
  }

  String? reportPath;
  var testDir = 'test';
  String? exclusionsPath;
  var minExecuted = 0;
  var flutterExit = 0;

  var i = 0;
  while (i < args.length) {
    final arg = args[i];
    String value() {
      if (i + 1 >= args.length) {
        stderr.writeln('missing value for $arg');
        exit(exitUsage);
      }
      return args[++i];
    }

    if (arg == '--report') {
      reportPath = value();
    } else if (arg == '--test-dir') {
      testDir = value();
    } else if (arg == '--exclusions') {
      exclusionsPath = value();
    } else if (arg == '--min-executed') {
      minExecuted = int.parse(value());
    } else if (arg == '--flutter-exit') {
      flutterExit = int.parse(value());
    } else {
      stderr.writeln('unknown argument: $arg');
      exit(exitUsage);
    }
    i++;
  }

  if (reportPath == null) {
    stderr.writeln('--report is required (or pass --self-test)');
    exit(exitUsage);
  }

  final reportFile = File(reportPath);
  if (!reportFile.existsSync()) {
    stdout.writeln('GUARD FAIL: machine report $reportPath was never written — '
        '`flutter test` did not get far enough to report anything.');
    exit(exitFail);
  }

  final ReportParse parse = parseReport(reportFile.readAsStringSync());

  var disk = <String>[];
  var exclusions = <String, String>{};
  try {
    disk = listDiskTests(testDir);
    exclusions = exclusionsPath == null
        ? <String, String>{}
        : readExclusions(exclusionsPath);
  } on FormatException catch (error) {
    stdout.writeln('GUARD FAIL: ${error.message}');
    exit(exitFail);
  }

  final result = evaluate(GuardInput(
    diskTests: disk,
    parse: parse,
    exclusions: exclusions,
    minExecuted: minExecuted,
    flutterExit: flutterExit,
  ));

  stdout.writeln(result.summary);
  writeStepSummary(result.summary);
  exit(result.ok ? exitPass : exitFail);
}
