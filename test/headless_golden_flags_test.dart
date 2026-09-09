import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera/headless_cli.dart';

import '../tool/ocr_run_stats.dart';

/// Guards the measurement harness itself (plan §3.8 / §3.10, D-15 "先修工具").
///
/// `ocr-golden` is the only evidence behind every performance claim in this
/// project, so the parts of it that *decide* whether a run passed are tested
/// here as pure functions: tolerance for a crashed model must never turn into
/// "looks like a pass", and a baseline row must be able to name its commit.
///
/// Two rules keep this file usable by CI, and the last group enforces them:
///  * it must NOT import the app graph (`headless.dart`, `init.dart`,
///    `foundation/**`, `pages/**`). Doing so compiles the whole application on
///    every run and inherits any syntax error another agent has in flight, which
///    is a minute of build for zero added proof;
///  * it must NOT spawn a child VM. Proving these rules by running the CLI tool
///    costs one compile per case — that is how the `Test` job hung for hours
///    behind this one file, blocking every other test's verdict.
void main() {
  group('headless flag parsing', () {
    test('defaults: no trace, no offline, command taken from after --headless',
        () {
      final f = parseHeadlessFlags(['--headless', 'ocr-golden', '--dir', 'x']);
      expect(f.command, 'ocr-golden');
      expect(f.commandIndex, 1);
      expect(f.trace, isFalse);
      expect(f.offline, isFalse);
      expect(f.skipsNetworkInit, isFalse);
      expect(f.error, isNull);
    });

    test('--trace is recognised wherever it sits in argv', () {
      expect(
          parseHeadlessFlags(['--headless', '--trace', 'ocr-golden']).trace,
          isTrue);
      expect(
          parseHeadlessFlags(['--headless', 'ocr-golden', '--trace']).trace,
          isTrue);
    });

    test('--offline enables the skip for the two OCR commands only', () {
      for (final cmd in kOfflineCapableCommands) {
        final f = parseHeadlessFlags(['--headless', cmd, '--offline']);
        expect(f.offline, isTrue, reason: cmd);
        expect(f.isOcrCommand, isTrue, reason: cmd);
        expect(f.skipsNetworkInit, isTrue, reason: cmd);
        expect(f.error, isNull, reason: cmd);
      }
    });

    test('--offline on a network command is rejected, not half-applied', () {
      for (final cmd in ['webdav', 'updatescript', 'updatesubscribe']) {
        final f = parseHeadlessFlags(['--headless', cmd, 'up', '--offline']);
        expect(f.skipsNetworkInit, isFalse, reason: cmd);
        expect(f.error, isNotNull, reason: cmd);
        expect(f.error, contains('--offline'));
        expect(f.error, contains(cmd));
      }
    });

    test('missing command still reports the legacy message', () {
      final f = parseHeadlessFlags(['--headless']);
      expect(f.command, isNull);
      expect(f.error, 'No command provided for headless mode.');
    });

    test('--ignore-disheadless-log maps to mutedLog', () {
      expect(
        parseHeadlessFlags([
              '--headless', 'ocr-golden', '--ignore-disheadless-log',
            ]).mutedLog,
        isTrue,
      );
    });
  });

  group('gitsha attestation', () {
    test('the build-time define wins over anything in the environment', () {
      final g = resolveGitSha(
        defineValue: '2f6464f11111111111111111111111111111111',
        environment: {'GITHUB_SHA': 'cccccccccccccccccccccccccccccccccccccccc'},
      );
      expect(g.sha, '2f6464f11111111111111111111111111111111');
      expect(g.source, 'dart-define');
    });

    test('an empty define falls back to GITHUB_SHA and says so', () {
      final g = resolveGitSha(
        defineValue: '',
        environment: {'GITHUB_SHA': 'aaaa2f6464f000000000000000000000000000'},
      );
      expect(g.sha, 'aaaa2f6464f000000000000000000000000000');
      expect(g.source, 'github-sha');
    });

    test('a developer-set GIT_SHA env var is deliberately NOT trusted', () {
      // It would let a stale binary claim any commit it likes — the exact
      // "looks attested, is not" failure the field exists to prevent.
      final g = resolveGitSha(
        defineValue: '',
        environment: {'GIT_SHA': 'deadbeefdeadbeefdeadbeefdeadbeefdeadbeef'},
      );
      expect(g.sha, '');
      expect(g.source, 'none');
    });

    test('whitespace-only define counts as missing', () {
      final g = resolveGitSha(defineValue: '   ', environment: {});
      expect(g.sha, '');
      expect(g.source, 'none');
    });
  });

  group('error records', () {
    test('every record names what was measured and what broke', () {
      final e = ocrErrorRecord(
        file: '03_korean_panels.png',
        tier: 'fast',
        batch: 16,
        group: 2,
        variant: 0,
        error: 'Bad state: Softmax_0 80070057',
        context: const {
          'ep': 'directml',
          'pageLang': 'ko',
          'sessions': 3,
          'degraded': 'rec-shrink',
        },
        stack: '#0 pipeline.ocrPages',
      );
      // The keys D-15 needs for attribution.
      expect(e['file'], '03_korean_panels.png');
      expect(e['tier'], 'fast');
      expect(e['batch'], 16);
      expect(e['group'], 2);
      expect(e['error'], contains('80070057'));
      expect(e['ep'], 'directml');
      expect(e['pageLang'], 'ko');
      expect(e['sessions'], 3);
      expect(e['degraded'], 'rec-shrink');
      expect(e['stack'], isNotNull);
    });

    test('stack is omitted when absent, context merged when present', () {
      final e = ocrErrorRecord(
        file: 'a.png',
        tier: 'fast',
        batch: 1,
        group: 1,
        variant: 0,
        error: 'boom',
      );
      expect(e.containsKey('stack'), isFalse);
      expect(e.containsKey('models'), isFalse);
    });

    test('configured model paths AND their component dirs are reported', () {
      // Layout on disk is <dataPath>/translation_models/<componentId>/<file>.
      // The CPU pin list is written in <componentId> tokens, so the record has
      // to expose that token — from a Windows path, not only a posix one.
      final m = describeModelPaths(
        detector: r'C:\data\translation_models\det_ppocr_v4\det.onnx',
        recModels: const {
          'en': r'C:\data\translation_models\ocr_en\rec.onnx',
          'ko': r'C:\data\translation_models\ocr_ko\rec.onnx',
        },
        recDicts: const {'en': r'C:\data\translation_models\ocr_en\en.txt'},
        recHeights: const {'en': 32, 'ko': 32},
      );
      expect((m['recModels'] as Map)['en'], endsWith(r'ocr_en\rec.onnx'));
      final dirs = m['dirs'] as Map;
      expect(dirs['en'], 'ocr_en', reason: 'backslash paths must normalise');
      expect(dirs['ko'], 'ocr_ko');
      expect(dirs['detector'], 'det_ppocr_v4');

      final posix = describeModelPaths(
        detector: '/data/translation_models/det_ppocr_v4/det.onnx',
        recModels: const {'ko': '/data/translation_models/ocr_ko/rec.onnx'},
      );
      expect((posix['dirs'] as Map)['ko'], 'ocr_ko');
      expect(posix.containsKey('jaEncoder'), isFalse);
      expect((posix['dirs'] as Map).containsKey('jaEncoder'), isFalse);
    });
  });

  group('session evidence', () {
    test('modelPaths come from the session report, not from settings', () {
      // The keys of EpReport.modelInputShapes ARE model paths: this is the only
      // field that separates "the rec session died" from "the detector died"
      // without re-running anything (D-15 step 0).
      final ev = ocrSessionEvidence(
        ep: 'directml',
        sessions: 2,
        modelInputShapes: const {
          r'C:\data\translation_models\det_ppocr_v4\det.onnx': [-1, 3, 480, 480],
          r'C:\data\translation_models\ocr_ko\rec.onnx': [32, 3, 48, 320],
        },
        epAttempts: const ['directml', 'cpu'],
        degradedTrail: const ['rec-oom-shrink'],
        perf: const {'degraded': 'rec-shrink', 'sessions': 2, 'ep': 'directml'},
      );
      expect(ev['modelPaths'], contains(contains('ocr_ko')));
      expect(ev['modelPaths'], contains(contains('det_ppocr_v4')));
      expect(ev['ep'], 'directml');
      expect(ev['sessions'], 2);
      expect(ev['degradedTrail'], contains('rec-oom-shrink'));
      expect(ev['degraded'], 'rec-shrink');
      expect(ev['epAttempts'], equals(['directml', 'cpu']));
      expect((ev['modelInputShapes'] as Map).length, 2);
    });

    test('no session yet says so instead of inventing an EP', () {
      final ev = ocrSessionEvidence();
      expect(ev['ep'], isNull);
      expect(ev['sessions'], isNull);
      expect(ev.containsKey('modelPaths'), isFalse);
    });
  });

  group('the verdict must not soften when pages are lost', () {
    test('a clean sweep is consistent', () {
      expect(
        goldenIsConsistent(
            mismatches: const [],
            errors: const [],
            samples: 4,
            expectedSamples: 4),
        isTrue,
      );
    });

    test('errors without mismatches are NOT a pass (defect 1 core)', () {
      expect(
        goldenIsConsistent(
          mismatches: const [],
          errors: const [
            {'file': 'a.png', 'error': 'boom'},
          ],
          samples: 3,
          expectedSamples: 4,
        ),
        isFalse,
        reason: 'tolerating a crash must not read as "consistent"',
      );
    });

    test('zero samples is never a pass', () {
      expect(
        goldenIsConsistent(
            mismatches: const [],
            errors: const [],
            samples: 0,
            expectedSamples: 4),
        isFalse,
      );
    });

    test('a sample count that merely differs from the sweep is a failure', () {
      expect(
        goldenIsConsistent(
            mismatches: const [],
            errors: const [],
            samples: 5,
            expectedSamples: 4),
        isFalse,
        reason: 'more rows than the sweep should produce means the spec moved',
      );
    });

    test('a mismatch alone fails', () {
      expect(
        goldenIsConsistent(
            mismatches: const [
              {'file': 'a.png'},
            ],
            errors: const [],
            samples: 4,
            expectedSamples: 4),
        isFalse,
      );
    });
  });

  group('report schema (plan §3.8)', () {
    Map<String, dynamic> report({
      int rows = 2,
      int expected = 2,
      List<Map<String, dynamic>> errors = const [],
      List<Map<String, dynamic>> mismatches = const [],
    }) {
      return buildGoldenReport(
        rows: [
          for (var i = 0; i < rows; i++)
            {'file': 'p$i.png', 'tier': 'fast', 'batch': 1, 'totalMsMedian': 10},
        ],
        mismatches: mismatches,
        errors: errors,
        expectedSamples: expected,
        gitSha: const GitShaInfo('2f6464f', 'dart-define'),
        machine: const {'os': 'windows', 'cpu': 12},
        ort: const {'active': 'directml'},
        resource: const {'before': null, 'during': [], 'after': null},
      );
    }

    test('the frozen field names are all present', () {
      final data = report()['data'] as Map<String, dynamic>;
      for (final key in [
        'gitsha',
        'machine',
        'ort',
        'pages',
        'consistency',
        'resource',
        'verdict',
      ]) {
        expect(data.containsKey(key), isTrue, reason: '$key is contract (§3.8)');
      }
      expect(data['gitsha'], '2f6464f');
      expect(data['gitshasource'], 'dart-define');
      expect((data['consistency'] as Map)['baseline'], 'first-variant');
      expect((data['verdict'] as Map)['consistent'], isTrue);
      expect((data['verdict'] as Map)['samples'], 2);
    });

    test('a run that lost pages reports consistent=false and status=error', () {
      final r = report(
        rows: 1,
        expected: 2,
        errors: const [
          {'file': 'p1.png', 'tier': 'fast', 'batch': 1, 'error': 'boom'},
        ],
      );
      expect(r['status'], 'error');
      final data = r['data'] as Map<String, dynamic>;
      expect((data['verdict'] as Map)['consistent'], isFalse);
      expect((data['verdict'] as Map)['errors'], 1);
      // The surviving page is still in the report — that is the whole point of
      // catching per page: its data is not thrown away with the crashed one.
      expect((data['pages'] as List).length, 1);
      expect((data['errors'] as List).length, 1);
    });

    test('exit code follows the report, and disagreement fails safe', () {
      expect(goldenExitCode(report()), 0);
      expect(goldenExitCode(report(rows: 0, expected: 2)), 1);
      // Forging only the verdict cannot resurrect a run whose status says
      // error: the two have to agree.
      final forged = report(rows: 0, expected: 2);
      (forged['data'] as Map)['verdict'] = {'consistent': true};
      expect(goldenExitCode(forged), 1, reason: 'status field still says error');
      final flipped = report()..['status'] = 'error';
      expect(goldenExitCode(flipped), 1);
    });

    test('summary line reports wall time, rows and losses', () {
      final s = goldenSummaryLine(
        elapsed: const Duration(milliseconds: 4200),
        pages: 5,
        variants: 4,
        samples: 18,
        expectedSamples: 20,
        mismatches: 0,
        errors: 2,
      );
      expect(s, startsWith('ocr-golden:'));
      expect(s, contains('4200 ms'));
      expect(s, contains('5 page(s) x 4 variant(s)'));
      expect(s, contains('18/20 row(s)'));
      expect(s, contains('2 error(s)'));
    });
  });

  group('ocr_run_stats gate (asserted directly, no child process)', () {
    final goodSha = '2f6464f${'0' * 33}';

    RunAssessment assess({
      String gitsha = '2f6464f',
      String gitshaSource = 'dart-define',
      bool allowUnattested = false,
      int sampleCount = 1,
      List<Object?> errors = const [],
      List<Object?> mismatches = const [],
      Object? consistent = true,
      int? expectedSamples = 1,
      Object? status = 'success',
    }) =>
        assessRun(
          gitsha: gitsha,
          gitshaSource: gitshaSource,
          allowUnattested: allowUnattested,
          sampleCount: sampleCount,
          errors: errors,
          mismatches: mismatches,
          consistent: consistent,
          expectedSamples: expectedSamples,
          status: status,
        );

    test('a fully attested clean run is publishable (exit 0)', () {
      final a = assess(gitsha: goodSha);
      expect(a.publishable, isTrue, reason: a.problems.join('; '));
      expect(a.exitCode, 0);
      expect(a.gitsha, goodSha);
    });

    test('empty gitsha is refused with a warning and a non-zero exit', () {
      final a = assess(gitsha: '', gitshaSource: 'none');
      expect(a.exitCode, isNot(0));
      expect(a.problems, isNotEmpty);
      expect(a.problems.first, startsWith('WARNING'));
      expect(a.problems.first, contains('gitsha'));
      expect(a.problems.first, contains('empty'));
      expect(
        exitCodeFor(
          gitsha: '',
          sampleCount: 1,
          errors: const [],
          mismatches: const [],
          consistent: true,
        ),
        1,
      );
    });

    test('a non-hex gitsha is refused too', () {
      for (final junk in ['unknown', 'dirty', 'HEAD', 'z' * 40]) {
        expect(assess(gitsha: junk).exitCode, 1, reason: junk);
      }
      // 7-40 hex is the accepted shape, short sha included: that is what the
      // plan's own `2f6464f` row uses.
      expect(assess(gitsha: '2f6464f').exitCode, 0);
    });

    test('--allow-unattested is loud, not silent', () {
      final a = assess(gitsha: '', allowUnattested: true);
      expect(a.exitCode, 0, reason: 'explicitly allowed');
      expect(a.gitsha, 'UNATTESTED');
      expect(a.notices.join(' '), contains('UNATTESTED'));
    });

    test('github-sha source is annotated, not hidden', () {
      final a = assess(gitsha: goodSha, gitshaSource: 'github-sha');
      expect(a.exitCode, 0);
      expect(a.notices.join(' '), contains('GITHUB_SHA'));
    });

    test('recorded per-page errors keep the run failing (§3.10)', () {
      // The harness now survives a crashed model; the reporter must still
      // refuse to publish that sweep as a clean baseline row.
      final a = assess(
        gitsha: goodSha,
        sampleCount: 0,
        errors: const [
          {'file': 'p.png', 'error': 'boom'},
        ],
        consistent: false,
      );
      expect(a.exitCode, 1);
      expect(a.problems.join(' '), contains('MEASUREMENT GAPS'));
    });

    test('row loss is detected even when nothing else complains', () {
      final a = assess(gitsha: goodSha, sampleCount: 3, expectedSamples: 4);
      expect(a.exitCode, 1);
      expect(a.problems.join(' '), contains('row loss'));
    });

    test('mismatches fail, and a zero-sample run can never pass', () {
      expect(
        assess(gitsha: goodSha, mismatches: const [
          {'file': 'x'},
        ]).exitCode,
        1,
      );
      expect(assess(gitsha: goodSha, sampleCount: 0).exitCode, 1);
    });

    test('status/verdict contradiction is refused', () {
      final a = assess(gitsha: goodSha, status: 'error', consistent: true);
      expect(a.exitCode, 1);
      expect(a.problems.join(' '), contains('contradicts itself'));
    });

    test('every problem is reported at once, not just the first', () {
      final a = assess(
        gitsha: '',
        sampleCount: 0,
        errors: const [
          {'file': 'p.png'},
        ],
        mismatches: const [
          {'file': 'p.png'},
        ],
        consistent: false,
        expectedSamples: 2,
      );
      expect(a.problems.length, greaterThanOrEqualTo(5));
    });
  });

  group('CI cost invariants of this file', () {
    test('this test does not import the app graph', () {
      // Tripwire for the two rules in the header note. Read directly: no shell,
      // no child process, no isolate.
      final imports = _importsOf('test/headless_golden_flags_test.dart');
      expect(imports, contains('package:venera/headless_cli.dart'));
      for (final banned in _bannedImports) {
        expect(
          imports.any((i) => i.startsWith(banned)),
          isFalse,
          reason: '$banned drags the whole app graph into this test',
        );
      }
    });

    test('no case may spawn a process', () {
      final src =
          File('test/headless_golden_flags_test.dart').readAsStringSync();
      // Patterns (not string literals) so the check cannot match its own source.
      for (final forbidden in [
        RegExp(r'Process\s*\.\s*run'),
        RegExp(r'Process\s*\.\s*start'),
        RegExp(r'Isolate\s*\.\s*spawn'),
      ]) {
        expect(forbidden.hasMatch(src), isFalse,
            reason: '$forbidden — one child VM per case is what stalled CI');
      }
    });

    test('the pure layer stays free of the app graph', () {
      expect(
        _importsOf('lib/headless_cli.dart')
            .where((i) => i.startsWith('package:venera/')),
        isEmpty,
        reason: 'headless_cli.dart is the layer CI can compile cheaply',
      );
    });
  });
}

const List<String> _bannedImports = [
  'package:venera/headless.dart',
  'package:venera/init.dart',
  'package:venera/foundation/',
  'package:venera/pages/',
];

List<String> _importsOf(String path) {
  final src = File(path).readAsStringSync();
  return RegExp("^import '(.+?)';", multiLine: true)
      .allMatches(src)
      .map((m) => m.group(1)!)
      .toList();
}
