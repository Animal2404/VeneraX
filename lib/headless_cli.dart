/// The pure decision layer of `--headless`: argument parsing, commit
/// attestation, error-record shape, model-path flattening and the golden-run
/// verdict.
///
/// This file imports nothing from the app on purpose — no `init.dart`, no comic
/// source, no translation worker, no `dart:io` beyond `Platform`. That is not
/// tidiness, it is a CI fact: a test that reaches `package:venera/headless.dart`
/// must compile the whole application graph and inherits every syntax error
/// another agent has in flight under `lib/foundation/**`, which is how one test
/// file stalled the entire `Test` job. Keeping the pass/fail maths here means it
/// is covered by a test that starts in seconds and cannot hang.
///
/// Covered by test/headless_golden_flags_test.dart.
library;

import 'dart:io' show Platform;


/// Commands that measure local inference and may therefore run with `--offline`.
const List<String> kOfflineCapableCommands = ['ocr-golden', 'ocr-selfcheck'];

/// What argv asked the headless entry point to do — a pure function of argv,
/// no IO, no bindings.
class HeadlessFlags {
  const HeadlessFlags({
    required this.command,
    required this.commandIndex,
    required this.trace,
    required this.offline,
    required this.mutedLog,
  });

  /// `ocr-golden`, `webdav`, … or null when nothing followed `--headless`.
  final String? command;

  /// Index of [command] in argv; every sub-command parser slices from here.
  final int commandIndex;

  /// `--trace`: append every step to the headless trace file.
  final bool trace;

  /// `--offline`: skip the network-typed startup steps.
  final bool offline;

  /// `--ignore-disheadless-log`: mute the app logger.
  final bool mutedLog;

  bool get isOcrCommand => kOfflineCapableCommands.contains(command);

  /// Whether the comic-source / download startup may be skipped. Only ever
  /// true for an OCR command: skipping it elsewhere would silently break
  /// webdav / updatescript / updatesubscribe.
  bool get skipsNetworkInit => offline && isOcrCommand;

  /// A fatal argument problem, or null when the invocation is runnable.
  String? get error {
    if (command == null) return 'No command provided for headless mode.';
    if (offline && !isOcrCommand) {
      return '--offline is only supported for '
          '${kOfflineCapableCommands.join(' and ')}; "$command" needs the '
          'network.';
    }
    return null;
  }
}

HeadlessFlags parseHeadlessFlags(List<String> args) {
  // The first arg is '--headless', so the command is the one right after it.
  final at = args.indexOf('--headless');
  final commandIndex = at + 1;
  final hasCommand = at >= 0 && commandIndex < args.length;
  return HeadlessFlags(
    command: hasCommand ? args[commandIndex] : null,
    commandIndex: hasCommand ? commandIndex : -1,
    trace: args.contains('--trace'),
    offline: args.contains('--offline'),
    mutedLog: args.contains('--ignore-disheadless-log'),
  );
}

/// Public on purpose: `headless.dart` calls these in production and the test
/// file asserts on them. (An `@visibleForTesting` marker would be wrong here —
/// it flags every legitimate production call across the library boundary.)
///
/// The recorded `gitsha` plus where it came from, so a reader can tell a
/// build-time attestation from a CI-runtime one. Never guess: an unknown sha is
/// reported as empty and `tool/ocr_run_stats.dart` refuses it.
class GitShaInfo {
  const GitShaInfo(this.sha, this.source);
  final String sha;

  /// `'dart-define'` | `'github-sha'` | `'none'`.
  final String source;
}

GitShaInfo resolveGitSha({
  String? defineValue,
  Map<String, String>? environment,
}) {
  final define = (defineValue ?? const String.fromEnvironment('GIT_SHA')).trim();
  if (define.isNotEmpty) return GitShaInfo(define, 'dart-define');
  // `GITHUB_SHA` only exists inside an Actions step, where it is by definition
  // the commit that produced the artifact, so it cannot mis-attribute a stale
  // binary. A developer-set `GIT_SHA` *could*, which is why it is deliberately
  // not read here.
  final ci = (environment ?? Platform.environment)['GITHUB_SHA']?.trim() ?? '';
  if (ci.isNotEmpty) return GitShaInfo(ci, 'github-sha');
  return const GitShaInfo('', 'none');
}

/// One failed page/variant: what was being measured, and what the evidence
/// says. `doc/ocr-baseline.md` D-15 step 0 requires the model paths and the
/// session EP in the record — without them a crash cannot be attributed to a
/// model at all, which is exactly how D-15 stayed unsolved for a whole run.
Map<String, dynamic> ocrErrorRecord({
  required String file,
  required String tier,
  required int batch,
  required int group,
  required int variant,
  required String error,
  Map<String, dynamic> context = const {},
  String? stack,
}) {
  return {
    'file': file,
    'tier': tier,
    'batch': batch,
    'group': group,
    'variant': variant,
    'error': error,
    ...context,
    if (stack != null && stack.isNotEmpty) 'stack': stack,
  };
}

/// The *configured* model set of a variant, flattened for an error record.
///
/// Plain parameters, not `WorkerModelPaths`: that type lives behind the
/// translation worker, and importing it here would drag the whole app graph
/// back into this file's test. The (three-line) unpack lives in
/// `headless.dart`, every decision that can be wrong lives here.
///
/// `dirs` is deliberate: the D-15 CPU containment
/// (`translation_worker.dart` -> `_cpuOnlyRecDirs`) is matched against the
/// *model directory name*, so a reader has to be able to compare the two
/// without re-deriving anything from a path. Reporting the resolved directory
/// names beside the full paths turns "did the pin apply?" from a guess into a
/// line-by-line check — and survives both separators, unlike a matcher that
/// assumes one.
Map<String, dynamic> describeModelPaths({
  required String detector,
  Map<String, String> recModels = const {},
  Map<String, String> recDicts = const {},
  Map<String, int> recHeights = const {},
  String? jaEncoder,
  String? jaDecoder,
  String? jaVocab,
}) {
  final recDirs = <String, String>{
    for (final e in recModels.entries) e.key: _dirName(e.value),
  };
  return {
    'detector': detector,
    'recModels': recModels,
    'recDicts': recDicts,
    'recHeights': recHeights,
    if (jaEncoder != null) 'jaEncoder': jaEncoder,
    if (jaDecoder != null) 'jaDecoder': jaDecoder,
    if (jaVocab != null) 'jaVocab': jaVocab,
    'dirs': {
      'detector': _dirName(detector),
      ...recDirs,
      if (jaEncoder != null) 'jaEncoder': _dirName(jaEncoder),
    },
  };
}

/// The parent directory name of a model file. The on-disk layout is
/// `translation_models/<componentId>/<file>`, so this yields the
/// `componentId` token — which is exactly what the CPU pin list is written in.
String _dirName(String path) {
  final parts = path
      .replaceAll(_backslash, '/')
      .split('/')
    ..removeWhere((e) => e.isEmpty);
  return parts.length < 2 ? '' : parts[parts.length - 2];
}

/// A single backslash, spelled as a constant so it can never degrade into the
/// empty pattern that silently disabled `_cpuOnlyRecDirs` once already.
const String _backslash = '\\';

/// Evidence that identifies **which model and which EP** a failure happened
/// under. Two path sets are reported, and the difference is the whole point:
///  * `models` (see [describeModelPaths]) — what the variant was *configured* to
///    load, derived from settings and installed files;
///  * `modelPaths` — the keys of `EpReport.modelInputShapes`, i.e. the models a
///    session was **actually opened for** in this process, each with its shape.
///
/// Only the second can separate "the rec session died" from "the detector died",
/// which is precisely what D-15 could not resolve after a full sweep
/// (doc/ocr-baseline.md, step 0). `sessions` / `degradedTrail` show whether an
/// EP fallback or a batch back-off had already happened at that moment.
Map<String, dynamic> ocrSessionEvidence({
  String? ep,
  int? sessions,
  Map<String, List<int>> modelInputShapes = const {},
  List<String> epAttempts = const [],
  List<String> degradedTrail = const [],
  Map<String, dynamic> perf = const {},
}) {
  if (ep == null && sessions == null) {
    // No report exists yet, so the isolate has opened nothing. Say that rather
    // than inventing an EP: a guessed `cpu` here would read as "it fell back"
    // in exactly the situation being investigated.
    return const {'ep': null, 'sessions': null};
  }
  return {
    'ep': ep,
    'sessions': sessions,
    'modelPaths': modelInputShapes.keys.toList(),
    'modelInputShapes': modelInputShapes,
    if (epAttempts.isNotEmpty) 'epAttempts': epAttempts,
    if (degradedTrail.isNotEmpty) 'degradedTrail': degradedTrail,
    // The worker's own last perf line: `degraded` / `sessions` as the isolate
    // reported them, alongside the structured report above.
    if (perf['degraded'] != null) 'degraded': perf['degraded'],
    if (perf['sessions'] != null) 'perfSessions': perf['sessions'],
    if (perf['ep'] != null) 'perfEp': perf['ep'],
  };
}

/// The consistency gate (plan §3.8 / §3.10, gate G1).
///
/// Tolerance must not become a pass: a page that threw simply produces no row,
/// so `mismatches` alone would read "perfect" for a run where every model
/// crashed. Hence the three additional conditions — recorded errors, zero
/// samples, and a sample count that differs from what the sweep should have
/// produced.
bool goldenIsConsistent({
  required List<Map<String, dynamic>> mismatches,
  required List<Map<String, dynamic>> errors,
  required int samples,
  required int expectedSamples,
}) {
  if (mismatches.isNotEmpty) return false;
  if (errors.isNotEmpty) return false;
  if (samples <= 0) return false;
  if (samples != expectedSamples) return false;
  return true;
}

/// Assemble the `ocr-golden` JSON payload. Field names are the frozen contract
/// of plan §3.8; `errors` is additive (a run with no errors emits `[]`).
Map<String, dynamic> buildGoldenReport({
  required List<Map<String, dynamic>> rows,
  required List<Map<String, dynamic>> mismatches,
  required List<Map<String, dynamic>> errors,
  required int expectedSamples,
  required GitShaInfo gitSha,
  Map<String, dynamic>? machine,
  Map<String, dynamic>? ort,
  Map<String, dynamic>? resource,
}) {
  final consistent = goldenIsConsistent(
    mismatches: mismatches,
    errors: errors,
    samples: rows.length,
    expectedSamples: expectedSamples,
  );
  return {
    'status': consistent ? 'success' : 'error',
    'data': {
      'gitsha': gitSha.sha,
      'gitshasource': gitSha.source,
      'machine': machine ?? const <String, dynamic>{},
      'ort': ort,
      'pages': rows,
      'errors': errors,
      'consistency': {
        'baseline': 'first-variant',
        'mismatches': mismatches,
      },
      'resource': resource ??
          const <String, dynamic>{
            'before': null,
            'during': [],
            'after': null,
          },
      'verdict': {
        'consistent': consistent,
        'samples': rows.length,
        'errors': errors.length,
        'expectedSamples': expectedSamples,
      },
    },
  };
}

/// Exit code for a finished golden run: 1 unless *both* the status field and
/// `verdict.consistent` say clean. Requiring agreement is deliberate — if one
/// of the two is ever edited the run fails, it never "looks like a pass".
int goldenExitCode(Map<String, dynamic> report) {
  final data = report['data'];
  final verdict = data is Map ? data['verdict'] : null;
  final consistent = verdict is Map && verdict['consistent'] == true;
  return (report['status'] == 'success' && consistent) ? 0 : 1;
}

/// One-line "was it slow or was it dead" summary, written to stderr: the D-14 /
/// D-15 runs could not tell a stalled harness from a merely slow one.
String goldenSummaryLine({
  required Duration elapsed,
  required int pages,
  required int variants,
  required int samples,
  required int expectedSamples,
  required int mismatches,
  required int errors,
}) {
  final ms = elapsed.inMilliseconds;
  final perRow = samples == 0 ? 0 : (ms / samples).round();
  return 'ocr-golden: $ms ms wall | $pages page(s) x $variants variant(s) '
      '-> $samples/$expectedSamples row(s) | ~$perRow ms/row '
      '(repeat included) | $mismatches mismatch(es) | $errors error(s)';
}
