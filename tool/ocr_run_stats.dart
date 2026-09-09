// Aggregates `--headless ocr-golden --json` output into a row for
// doc/ocr-baseline.md, and enforces the rules that make the table meaningful.
//
//   dart run tool/ocr_run_stats.dart <golden.json>            # print a table row
//   dart run tool/ocr_run_stats.dart <golden.json> --check    # CI: corpus + verdict only
//
// Exit code 1 means "do not merge": the plan forbids shipping a claim that the
// data does not support (V6-1, §3.10).
//
// The *decision* itself is [assessRun] below: a pure function over the report's
// fields. It used to be proved by `dart run`-ing this script from a test, which
// costs one full compile per case and stalled CI's `Test` job for hours; rules
// this important are asserted directly instead. Every check collects a problem
// rather than exiting on the first one, so a single run tells the operator
// everything that is wrong with the artifact — partial diagnostics are how a
// broken measurement gets rationalised.
import 'dart:convert';
import 'dart:io';

void main(List<String> args) {
  final positional = args.where((a) => !a.startsWith('--')).toList();
  if (positional.isEmpty) {
    stderr.writeln('usage: dart run tool/ocr_run_stats.dart <golden.json> '
        '[--check] [--allow-unattested]');
    exit(2);
  }
  final checkOnly = args.contains('--check');
  // Escape hatch for replaying a JSON produced before the GIT_SHA define
  // existed. It is *not* silent: the row it emits says UNATTESTED.
  final allowUnattested = args.contains('--allow-unattested');
  final raw = File(positional.first).readAsStringSync();

  // headless prints `[CLI PRINT] {json}`; tolerate a log-heavy file.
  final line = raw
      .split('\n')
      .lastWhere((l) => l.contains('[CLI PRINT] '), orElse: () => '');
  if (line.isEmpty) {
    stderr.writeln('no "[CLI PRINT]" line found — did ocr-golden run?');
    exit(2);
  }
  final decoded = jsonDecode(line.substring(line.indexOf('[CLI PRINT] ') + 12))
      as Map<String, dynamic>;

  // headless wraps the report as `{"status": …, "data": { … }}` (plan §3.8).
  // This tool used to read `verdict` / `pages` off the top level, so *every*
  // real run looked like "no pages sampled" — unwrap it, and accept a flat
  // payload too so a hand-trimmed JSON still works.
  final status = decoded['status'];
  final payload = decoded['data'] is Map
      ? Map<String, dynamic>.from(decoded['data'] as Map)
      : decoded;

  final verdict = payload['verdict'] as Map<String, dynamic>? ?? const {};
  final consistency = payload['consistency'] as Map<String, dynamic>? ?? const {};
  final mismatches = (consistency['mismatches'] as List? ?? const []);
  final errors = (payload['errors'] as List? ?? const []);
  final pages = (payload['pages'] as List? ?? const [])
      .cast<Map<String, dynamic>>();
  final ort = payload['ort'] as Map<String, dynamic>?;
  final resource = payload['resource'] as Map<String, dynamic>?;

  final assessment = assessRun(
    gitsha: (payload['gitsha'] ?? '').toString().trim(),
    gitshaSource: (payload['gitshasource'] ?? '').toString().trim(),
    allowUnattested: allowUnattested,
    sampleCount: pages.length,
    errors: errors,
    mismatches: mismatches,
    consistent: verdict['consistent'],
    expectedSamples: (verdict['expectedSamples'] as num?)?.toInt(),
    status: status,
  );

  for (final notice in assessment.notices) {
    stderr.writeln(notice);
  }
  // Itemised evidence for the two lists that can silently empty themselves.
  for (final e in errors.take(10)) {
    stderr.writeln('  error: ${jsonEncode(e)}');
  }
  if (errors.length > 10) {
    stderr.writeln('  … ${errors.length - 10} more error record(s) in the JSON');
  }
  for (final m in mismatches) {
    stderr.writeln('  ${jsonEncode(m)}');
  }
  if (!assessment.publishable) {
    for (final p in assessment.problems) {
      stderr.writeln(p.startsWith('WARNING') ? p : 'ERROR: $p');
    }
    exit(assessment.exitCode);
  }

  if (checkOnly) {
    stdout.writeln(
      'OK: ${pages.length} samples, 0 errors, text consistent across variants',
    );
    return;
  }

  int med(String key) {
    final v = pages.map((p) => (p[key] as num?)?.toInt() ?? 0).toList()..sort();
    return v.isEmpty ? 0 : v[v.length ~/ 2];
  }

  final before = (resource?['before'] as Map?)?.cast<String, dynamic>();
  final after = (resource?['after'] as Map?)?.cast<String, dynamic>();
  String mb(Map? m, String k) {
    final v = m?[k];
    return v == null ? 'N/A' : '${v.toStringAsFixed(0)}';
  }

  final row = [
    '', // row number, filled by hand
    DateTime.now().toIso8601String().substring(0, 10),
    assessment.gitsha,
    '${(payload['machine'] as Map?)?['os']}/${ort?['active'] ?? '?'}',
    ort?['runtimeVersion'] ?? '?',
    ort?['active'] ?? '?',
    pages.first['tier'] ?? '?',
    pages.first['batch'] ?? '?',
    med('totalMsMedian'),
    med('detMs'),
    med('recMs'),
    med('decMs'),
    '${mb(before, 'gpuCurrentMB')}→${mb(after, 'gpuCurrentMB')}',
    '${mb(before, 'workingSetMB')}→${mb(after, 'workingSetMB')}',
    '${pages.length} samples / 0 mismatch / 0 error',
  ].join(' | ');

  stdout.writeln('| $row |');
  stdout.writeln('');
  stdout.writeln('probe sources: ${jsonEncode(after?['sources'] ?? before?['sources'] ?? {})}');
  if (after?['gpuCurrentMB'] == null) {
    stdout.writeln(
      'NOTE: no GPU reading — record N/A in the table, never 0 (plan §3.6).',
    );
  }
  if (assessment.gitsha == 'UNATTESTED') {
    stdout.writeln('NOTE: this row is UNATTESTED (--allow-unattested): it cannot '
        'be used as a before/after anchor without a commit sha.');
  }
}

/// What a golden run licenses. Pure: no IO, no `exit`, no clock.
class RunAssessment {
  RunAssessment({
    required this.gitsha,
    required this.problems,
    required this.notices,
  });

  /// The value to put in the table's `gitsha` column (possibly `UNATTESTED`).
  final String gitsha;

  /// Reasons this artifact must not become a baseline row.
  final List<String> problems;

  /// Things worth saying that do not block publishing.
  final List<String> notices;

  bool get publishable => problems.isEmpty;

  int get exitCode => problems.isEmpty ? 0 : 1;
}

/// The gate, as data. See `test/headless_golden_flags_test.dart` for the cases.
RunAssessment assessRun({
  required String gitsha,
  String gitshaSource = '',
  bool allowUnattested = false,
  required int sampleCount,
  required List<Object?> errors,
  required List<Object?> mismatches,
  required Object? consistent,
  int? expectedSamples,
  Object? status,
}) {
  final problems = <String>[];
  final notices = <String>[];
  final sha = evaluateGitSha(
    gitsha,
    source: gitshaSource,
    allowUnattested: allowUnattested,
    problems: problems,
    notices: notices,
  );

  // --- sample integrity ------------------------------------------------------
  if (sampleCount == 0) {
    problems.add(
        'no pages sampled — the corpus or the model set is unusable');
  }
  if (errors.isNotEmpty) {
    // §3.10: "不许用『跳过失败页』来提高一致率". The harness now survives a
    // per-page crash and lists what it lost; losing rows is still not a pass.
    problems.add('MEASUREMENT GAPS: ${errors.length} page/variant(s) failed and '
        'produced no row — failures must be attributed, not skipped');
  }
  if (expectedSamples != null && sampleCount != expectedSamples) {
    problems.add('row loss: verdict.expectedSamples=$expectedSamples but '
        'pages=$sampleCount — the sweep did not finish');
  }
  if (mismatches.isNotEmpty) {
    problems.add(
        'CONSISTENCY FAILURE (G1): ${mismatches.length} mismatch(es)');
  }
  if (consistent != true) {
    problems.add('verdict.consistent is not true — refusing to report a win');
  }
  // The harness gates on status *and* verdict (lib/headless_cli.dart
  // goldenExitCode). A payload where only one of them says "clean" contradicts
  // itself, and a self-contradicting report is not evidence.
  if (status == 'error' && consistent == true) {
    problems.add('status="error" while verdict.consistent=true — the report '
        'contradicts itself; neither field can be trusted');
  }
  return RunAssessment(
    gitsha: sha,
    problems: problems,
    notices: notices,
  );
}

/// Convenience wrapper named after what CI cares about.
int exitCodeFor({
  required String gitsha,
  String gitshaSource = '',
  bool allowUnattested = false,
  required int sampleCount,
  required List<Object?> errors,
  required List<Object?> mismatches,
  required Object? consistent,
  int? expectedSamples,
  Object? status,
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
    ).exitCode;

/// Validate the recorded commit sha, appending to [problems] (blocking) or
/// [notices] (informational) instead of writing to stderr, so the caller reports
/// every defect of an artifact at once and the rule stays assertable.
///
/// Returns the value to print in the table. Only ever returns `UNATTESTED` when
/// the caller passed `--allow-unattested`; the default is to refuse — an empty
/// sha must never be swallowed by printing "?", which is what this column used
/// to do (plan V6-9: "不是空着，也不是估算").
String evaluateGitSha(
  String raw, {
  required bool allowUnattested,
  String source = '',
  required List<String> problems,
  required List<String> notices,
}) {
  if (raw.isEmpty) {
    final origin = source.isEmpty ? '' : ' (gitshasource="$source")';
    final message = 'WARNING: "gitsha" is empty$origin — this baseline JSON '
        'cannot prove which commit produced it. The build that made this binary '
        'was not given --dart-define=GIT_SHA=<sha> (see '
        '.github/workflows/main.yml and windows/build.py). An unattributable '
        'number cannot be compared with a later one (plan V6-9, §3.9 rule 1).';
    if (!allowUnattested) {
      problems.add(message);
      return '';
    }
    // Explicitly allowed, and still loud: the emitted row says UNATTESTED.
    notices.add('$message -- emitting an UNATTESTED row because '
        '--allow-unattested was passed.');
    return 'UNATTESTED';
  }
  // "unknown", "dirty", a truncated word — anything that is not hex is a hole
  // in the provenance chain, not a detail.
  if (!RegExp(r'^[0-9a-fA-F]{7,40}$').hasMatch(raw)) {
    final message = 'WARNING: "gitsha"="$raw" is not a commit sha '
        '(7-40 hex characters expected) — it cannot serve as provenance.';
    if (!allowUnattested) {
      problems.add(message);
      return raw;
    }
    notices.add('$message -- recorded as UNATTESTED because '
        '--allow-unattested was passed.');
    return 'UNATTESTED';
  }
  if (source == 'github-sha') {
    // True inside Actions, where the variable is the checkout of the build that
    // ran; a reader must know this is a runtime attestation, not a baked one.
    notices.add('NOTE: gitsha came from GITHUB_SHA at runtime, not from the '
        'build-time define.');
  }
  return raw.toLowerCase();
}
