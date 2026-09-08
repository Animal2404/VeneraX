// Aggregates `--headless ocr-golden --json` output into a row for
// doc/ocr-baseline.md, and enforces the rules that make the table meaningful.
//
//   dart run tool/ocr_run_stats.dart <golden.json>            # print a table row
//   dart run tool/ocr_run_stats.dart <golden.json> --check    # CI: corpus + verdict only
//
// Exit code 1 means "do not merge": the plan forbids shipping a claim that the
// data does not support (V6-1, §3.10).
//
// Every check here collects a problem instead of exiting on the first one, so a
// single run tells the operator everything that is wrong with the artifact —
// partial diagnostics are how a broken measurement gets rationalised.
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
  final payload =
      decoded['data'] is Map<String, dynamic> ? decoded['data'] as Map<String, dynamic> : decoded;

  final verdict = payload['verdict'] as Map<String, dynamic>? ?? const {};
  final consistency = payload['consistency'] as Map<String, dynamic>? ?? const {};
  final mismatches = (consistency['mismatches'] as List? ?? const []);
  final errors = (payload['errors'] as List? ?? const []);
  final pages = (payload['pages'] as List? ?? const [])
      .cast<Map<String, dynamic>>();
  final ort = payload['ort'] as Map<String, dynamic>?;
  final resource = payload['resource'] as Map<String, dynamic>?;

  final problems = <String>[];

  // --- attestation -----------------------------------------------------------
  // A baseline row that cannot name its commit is not reproducible, so it is
  // not evidence (plan V6-9: "gitsha=2f6464f, 不是空着，也不是估算"). An empty
  // field must never be swallowed by printing "?" either.
  final gitsha = checkGitSha(
    (payload['gitsha'] ?? '').toString().trim(),
    source: (payload['gitshasource'] ?? '').toString().trim(),
    allowUnattested: allowUnattested,
    problems: problems,
  );

  // --- sample integrity ------------------------------------------------------
  if (pages.isEmpty) {
    problems.add('no pages sampled — the corpus or the model set is unusable');
  }
  if (errors.isNotEmpty) {
    // §3.10: "不许用『跳过失败页』来提高一致率". The harness now survives a
    // per-page crash and lists what it lost; losing rows is still not a pass.
    problems.add('MEASUREMENT GAPS: ${errors.length} page/variant(s) failed and '
        'produced no row — failures must be attributed, not skipped');
    for (final e in errors.take(10)) {
      stderr.writeln('  error: ${jsonEncode(e)}');
    }
    if (errors.length > 10) {
      stderr.writeln('  … ${errors.length - 10} more error record(s) in the JSON');
    }
  }
  final expected = (verdict['expectedSamples'] as num?)?.toInt();
  if (expected != null && pages.length != expected) {
    problems.add('row loss: verdict.expectedSamples=$expected but '
        'pages=${pages.length} — the sweep did not finish');
  }
  if (mismatches.isNotEmpty) {
    problems.add('CONSISTENCY FAILURE (G1): ${mismatches.length} mismatch(es)');
    for (final m in mismatches) {
      stderr.writeln('  ${jsonEncode(m)}');
    }
  }
  if (verdict['consistent'] != true) {
    problems.add('verdict.consistent is not true — refusing to report a win');
  }
  // The harness gates on status *and* verdict (lib/headless.dart goldenExitCode).
  // A payload where only one of them says "clean" contradicts itself, and a
  // self-contradicting report is not evidence.
  if (status == 'error' && verdict['consistent'] == true) {
    problems.add('status="error" while verdict.consistent=true — the report '
        'contradicts itself; neither field can be trusted');
  }

  if (problems.isNotEmpty) {
    for (final p in problems) {
      stderr.writeln(p.startsWith('WARNING') ? p : 'ERROR: $p');
    }
    exit(1);
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
    gitsha,
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
  if (gitsha == 'UNATTESTED') {
    stdout.writeln('NOTE: this row is UNATTESTED (--allow-unattested): it cannot '
        'be used as a before/after anchor without a commit sha.');
  }
}

/// Validate the recorded commit sha, appending to [problems] instead of
/// throwing so the caller reports every defect of this artifact at once.
///
/// Returns the value to print in the table. Only ever returns `UNATTESTED`
/// when the caller passed `--allow-unattested`; the default is to refuse.
String checkGitSha(
  String raw, {
  required bool allowUnattested,
  String source = '',
  required List<String> problems,
}) {
  if (raw.isEmpty) {
    final origin = source.isEmpty ? '' : ' (gitshasource="$source")';
    final message = 'WARNING: "gitsha" is empty$origin — this baseline JSON '
        'cannot prove which commit produced it. The build that made this binary '
        'was not given --dart-define=GIT_SHA=<sha> (see '
        '.github/workflows/main.yml and windows/build.py). An unattributable '
        'number cannot be compared with a later one (plan V6-9, §3.9 rule 1).';
    if (!allowUnattested) {
      // Default: refuse. Exit code 1 is the whole point — an empty sha must
      // never be swallowed by printing "?" as the table used to do.
      problems.add(message);
      return '';
    }
    // Explicitly allowed, and still loud: the emitted row says UNATTESTED.
    stderr.writeln('$message -- emitting an UNATTESTED row because '
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
    stderr.writeln('$message -- recorded as UNATTESTED because '
        '--allow-unattested was passed.');
    return 'UNATTESTED';
  }
  if (source == 'github-sha') {
    // True inside Actions, where the variable is the checkout of the build
    // that ran; recorded so a reader knows it is a runtime attestation.
    stderr.writeln('NOTE: gitsha came from GITHUB_SHA at runtime, not from the '
        'build-time define.');
  }
  return raw.toLowerCase();
}
