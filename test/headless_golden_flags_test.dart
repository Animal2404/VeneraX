import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/image_translation/ort_capabilities.dart';
import 'package:venera/foundation/image_translation/translation_worker.dart';
import 'package:venera/headless.dart';

/// Guards the measurement harness itself (plan §3.8 / §3.10, D-15 "先修工具").
///
/// `ocr-golden` is the only evidence behind every performance claim in this
/// project, so the parts of it that *decide* whether a run passed are tested
/// here as pure functions: tolerance for a crashed model must never turn into
/// "looks like a pass", and a baseline row must be able to name its commit.
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
        parseHeadlessFlags(['--headless', 'ocr-golden', '--ignore-disheadless-log'])
            .mutedLog,
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
          'ortReport': {'active': 'directml', 'sessionCount': 3},
        },
        stack: '#0 pipeline.ocrPages',
      );
      // The keys D-15 needs for attribution.
      expect(e['file'], '03_korean_panels.png');
      expect(e['tier'], 'fast');
      expect(e['batch'], 16);
      expect(e['group'], 2);
      expect(e['error'], contains('80070057'));
      // Which EP, which language's recognizer, and the whole session report:
      // "the exception named no model and no EP" is the reason D-15 cost a run.
      expect(e['ep'], 'directml');
      expect(e['pageLang'], 'ko');
      expect((e['ortReport'] as Map)['sessionCount'], 3);
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

    test('session evidence names the models that actually got a session', () {
      // The keys of EpReport.modelInputShapes ARE model paths: this is the only
      // field that can tell "the rec session died" apart from "the detector
      // died" without re-running anything (D-15 step 0).
      final report = EpReport(
        active: OrtEpKind.directml,
        runtimeVersion: '1.25.0',
        attempts: const ['directml', 'cpu'],
        modelInputShapes: const {
          r'C:\data\translation_models\det_ppocr_v4\det.onnx': [-1, 3, 480, 480],
          r'C:\data\translation_models\ocr_ko\rec.onnx': [32, 3, 48, 320],
        },
        batchCapable: true,
        sessionCount: 2,
        degradedTrail: const ['rec-oom-shrink'],
      );
      final ev = ocrSessionEvidence(
        report: report,
        perf: const {'degraded': 'rec-shrink', 'sessions': 2, 'ep': 'directml'},
      );
      expect(ev['modelPaths'], contains(contains('ocr_ko')));
      expect(ev['modelPaths'], contains(contains('det_ppocr_v4')));
      expect(ev['ep'], 'directml');
      expect(ev['sessions'], 2);
      expect(ev['degradedTrail'], contains('rec-oom-shrink'));
      expect(ev['degraded'], 'rec-shrink');
      expect(ev['epAttempts'], equals(['directml', 'cpu']));
      // The shapes themselves: a pinned-to-CPU model would show a cpu session
      // here, which is what makes the pin question checkable at all.
      expect((ev['modelInputShapes'] as Map).length, 2);
    });

    test('no report yet degrades to nulls, never to a throw', () {
      final ev = ocrSessionEvidence(report: null);
      expect(ev['ep'], isNull);
      expect(ev['sessions'], isNull);
      expect(ev.containsKey('modelPaths'), isFalse);
    });

    test('model paths AND their component directories are flattened (D-15 step 0)',
        () {
      // Layout on disk is <dataPath>/translation_models/<componentId>/<file>.
      // The CPU pin list is written in <componentId> tokens, so the record has
      // to expose that token — from a Windows path, not only a posix one.
      final m = describeModelPaths(WorkerModelPaths(
        detector: r'C:\data\translation_models\det_ppocr_v4\det.onnx',
        recModels: const {
          'en': r'C:\data\translation_models\ocr_en\rec.onnx',
          'ko': r'C:\data\translation_models\ocr_ko\rec.onnx',
        },
        recDicts: const {'en': r'C:\data\translation_models\ocr_en\en.txt'},
        recHeights: const {'en': 32, 'ko': 32},
      ));
      expect((m['recModels'] as Map)['en'], endsWith(r'ocr_en\rec.onnx'));
      final dirs = m['dirs'] as Map;
      expect(dirs['en'], 'ocr_en', reason: 'backslash paths must normalise');
      expect(dirs['ko'], 'ocr_ko');
      expect(dirs['detector'], 'det_ppocr_v4');

      final posix = describeModelPaths(WorkerModelPaths(
        detector: '/data/translation_models/det_ppocr_v4/det.onnx',
        recModels: const {'ko': '/data/translation_models/ocr_ko/rec.onnx'},
      ));
      expect((posix['dirs'] as Map)['ko'], 'ocr_ko');
      expect(posix.containsKey('jaEncoder'), isFalse);
      expect((posix['dirs'] as Map).containsKey('jaEncoder'), isFalse);
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

  group('tool/ocr_run_stats.dart refuses an unattested run', () {
    String payload({
      String gitsha = '2f6464f11111111111111111111111111111111',
      List<Map<String, dynamic>> errors = const [],
      bool consistent = true,
    }) {
      return '[CLI PRINT] ${jsonEncode({
            'status': consistent ? 'success' : 'error',
            'data': {
              'gitsha': gitsha,
              'gitshasource': gitsha.isEmpty ? 'none' : 'dart-define',
              'machine': {'os': 'windows'},
              'ort': {'active': 'directml', 'runtimeVersion': '1.25.0'},
              'pages': [
                {'file': 'p.png', 'tier': 'fast', 'batch': 1, 'totalMsMedian': 10},
              ],
              'errors': errors,
              'consistency': {'baseline': 'first-variant', 'mismatches': []},
              'resource': {'before': null, 'during': [], 'after': null},
              'verdict': {
                'consistent': consistent && errors.isEmpty,
                'samples': 1,
                'errors': errors.length,
                'expectedSamples': 1,
              },
            },
          })}';
    }

    int runTool(String contents, {List<String> extraArgs = const []}) {
      final dir = Directory.systemTemp.createTempSync('ocr_stats');
      final file = File('${dir.path}/golden.json')..writeAsStringSync(contents);
      final result = Process.runSync(Platform.resolvedExecutable, [
        'run',
        '${Directory.current.path}/tool/ocr_run_stats.dart',
        file.path,
        ...extraArgs,
      ]);
      dir.deleteSync(recursive: true);
      return result.exitCode;
    }

    String runToolStderr(String contents, {List<String> extraArgs = const []}) {
      final dir = Directory.systemTemp.createTempSync('ocr_stats');
      final file = File('${dir.path}/golden.json')..writeAsStringSync(contents);
      final result = Process.runSync(Platform.resolvedExecutable, [
        'run',
        '${Directory.current.path}/tool/ocr_run_stats.dart',
        file.path,
        ...extraArgs,
      ]);
      dir.deleteSync(recursive: true);
      return '${result.stdout}\n${result.stderr}';
    }

    test('empty gitsha exits non-zero and warns', () {
      final out = runToolStderr(payload(gitsha: ''));
      expect(runTool(payload(gitsha: '')), isNot(0));
      expect(out, contains('WARNING'));
      expect(out, contains('gitsha'));
    });

    test('a non-hex gitsha is refused too', () {
      expect(runTool(payload(gitsha: 'unknown')), isNot(0));
      expect(runTool(payload(gitsha: 'dirty')), isNot(0));
    });

    test('--allow-unattested still says so instead of hiding it', () {
      final out =
          runToolStderr(payload(gitsha: ''), extraArgs: ['--allow-unattested']);
      expect(out, contains('UNATTESTED'));
    });

    test('recorded per-page errors keep the run failing', () {
      // The harness now survives a crashed model; the reporter must still
      // refuse to publish that sweep as a clean baseline row.
      expect(
        runTool(payload(errors: const [
          {'file': 'p.png', 'error': 'boom'},
        ])),
        isNot(0),
      );
    });

    test('a fully attested clean run exits 0', () {
      expect(runTool(payload()), 0);
      expect(runTool(payload(), extraArgs: ['--check']), 0);
    });
  });
}
