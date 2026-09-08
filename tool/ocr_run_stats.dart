// Aggregates `--headless ocr-golden --json` output into a row for
// doc/ocr-baseline.md, and enforces the rules that make the table meaningful.
//
//   dart run tool/ocr_run_stats.dart <golden.json>            # print a table row
//   dart run tool/ocr_run_stats.dart <golden.json> --check    # CI: corpus + verdict only
//
// Exit code 1 means "do not merge": the plan forbids shipping a claim that the
// data does not support (V6-1, §3.10).
import 'dart:convert';
import 'dart:io';

void main(List<String> args) {
  final positional = args.where((a) => !a.startsWith('--')).toList();
  if (positional.isEmpty) {
    stderr.writeln('usage: dart run tool/ocr_run_stats.dart <golden.json> [--check]');
    exit(2);
  }
  final checkOnly = args.contains('--check');
  final raw = File(positional.first).readAsStringSync();

  // headless prints `[CLI PRINT] {json}`; tolerate a log-heavy file.
  final line = raw
      .split('\n')
      .lastWhere((l) => l.contains('[CLI PRINT] '), orElse: () => '');
  if (line.isEmpty) {
    stderr.writeln('no "[CLI PRINT]" line found — did ocr-golden run?');
    exit(2);
  }
  final payload = jsonDecode(line.substring(line.indexOf('[CLI PRINT] ') + 12))
      as Map<String, dynamic>;

  final verdict = payload['verdict'] as Map<String, dynamic>? ?? const {};
  final consistency = payload['consistency'] as Map<String, dynamic>? ?? const {};
  final mismatches = (consistency['mismatches'] as List? ?? const []);
  final pages = (payload['pages'] as List? ?? const [])
      .cast<Map<String, dynamic>>();
  final ort = payload['ort'] as Map<String, dynamic>?;
  final resource = payload['resource'] as Map<String, dynamic>?;

  if (pages.isEmpty) {
    stderr.writeln('no pages sampled — the corpus or the model set is unusable');
    exit(1);
  }
  if (mismatches.isNotEmpty) {
    stderr.writeln('CONSISTENCY FAILURE (G1): ${mismatches.length} mismatch(es)');
    for (final m in mismatches) {
      stderr.writeln('  ${jsonEncode(m)}');
    }
    exit(1);
  }
  if (verdict['consistent'] != true) {
    stderr.writeln('verdict.consistent is not true — refusing to report a win');
    exit(1);
  }

  if (checkOnly) {
    stdout.writeln('OK: ${pages.length} samples, text consistent across variants');
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
    payload['gitsha'] ?? '?',
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
    '${pages.length} samples / 0 mismatch',
  ].join(' | ');

  stdout.writeln('| $row |');
  stdout.writeln('');
  stdout.writeln('probe sources: ${jsonEncode(after?['sources'] ?? before?['sources'] ?? {})}');
  if (after?['gpuCurrentMB'] == null) {
    stdout.writeln(
      'NOTE: no GPU reading — record N/A in the table, never 0 (plan §3.6).',
    );
  }
}
