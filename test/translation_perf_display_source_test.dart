// NOTE: 本文件按任务约束在本地**未运行**（禁止本地 flutter test / 构建）。
// 只经过 `flutter analyze --no-pub`。列入待云端 `Test` job 验证清单。
//
// Source-level guard for the plan 12-B red line (§5: "不用解析日志字符串的方式
// 给 UI 供数"). A behaviour test cannot express "nobody regexed a log line",
// and the repo already owns the one mechanism that can: `native_api_guard_test
// .dart` walks `lib/` and fails on patterns that must not come back. Same idea,
// narrower scope — the three files that make up the progress card's data path.
//
// Why the rule is worth locking: the temptation is documented history. Phase 2
// scraped `detMs` out of the worker's perf string and printed a number whose
// name did not match its meaning (it was the batch size). The next agent under
// time pressure reads the log because the log is right there, and the display
// silently inherits whatever the format happens to say that week. Here that
// route is a test failure, not a code-review catch.
//
// The positive half matters as much as the prohibition: the structured channel
// (`onGroupPerf` -> `recordTranslatedGroup`/`recordRenderWork`, `GroupPerf
// .toLogLine()` as the one formatter) has to stay wired, or "don't parse" just
// means "show nothing".

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

class _Rule {
  final RegExp pattern;
  final String reason;

  const _Rule(this.pattern, this.reason);
}

/// Files that make up the pre-translation progress card's data path: the fold,
/// the widget that renders it, and the service that measures a group. None of
/// them may turn display numbers out of text.
const _guarded = [
  'lib/foundation/image_translation/pre_translation_tasks.dart',
  'lib/pages/tasks_page.dart',
  'lib/foundation/image_translation/translation_service.dart',
];

/// Text-extraction primitives that, in these files, would mean "the UI is
/// being fed by a log scrape". [RegExp.new] itself is not the sin — proxy
/// parsing and tokenizer code use it legitimately elsewhere in `lib/` — which
/// is why this guard is scoped to the three files above and not to `lib/`.
/// (`RegExp` is not a const constructor, hence `final`.)
final _forbidden = [
  _Rule(
    RegExp(r'\bRegExp\s*\('),
    'the progress card must not scrape text: plan 12-B feeds it structured '
        'GroupPerf / OcrBatchPerf values instead (doc '
        'AI_TRANSLATION_PHASE3_PLAN.md §5)',
  ),
  _Rule(
    RegExp(r'\.firstMatch\(|\.allMatches\(|\.split\('),
    'string surgery in the card\'s data path means a display number is being '
        'derived from a format string, not from a measurement',
  ),
  _Rule(
    RegExp(r'\bLog\.logs\b|\brecentPerfLogs\b'),
    'log buffers are a diagnostics surface (headless dump, translation '
        'diagnostics page); reading one to fill a widget is the 12-B red line',
  ),
];

void main() {
  group('plan 12-B red line: the card is fed values, never log text', () {
    test('no parsing primitives in the progress-card data path', () {
      final violations = <String>[];
      for (final path in _guarded) {
        final file = File(path);
        expect(file.existsSync(), isTrue, reason: '$path moved?');
        final lines = file.readAsLinesSync();
        for (var i = 0; i < lines.length; i++) {
          final line = lines[i];
          // A comment may name the forbidden thing to explain why it is
          // forbidden; only code counts.
          if (line.trimLeft().startsWith('//')) continue;
          for (final rule in _forbidden) {
            if (rule.pattern.hasMatch(line)) {
              violations.add('$path:${i + 1}: ${line.trim()}\n  -> ${rule.reason}');
            }
          }
        }
      }
      expect(violations, isEmpty, reason: violations.join('\n'));
    });

    test('the structured channels stay wired', () {
      final service =
          File('lib/foundation/image_translation/translation_service.dart')
              .readAsStringSync();
      final tasks =
          File('lib/foundation/image_translation/pre_translation_tasks.dart')
              .readAsStringSync();

      // 12-B's producer: the object is built at the timing site, the log is
      // rendered FROM it, and the caller is handed the object with the
      // response.
      expect(service, contains('class GroupPerf'));
      expect(service, contains('final groupPerf = GroupPerf('));
      expect(service, contains('Log.info(\'Image Translation\', groupPerf.toLogLine())'));
      expect(service, contains('onGroupPerf?.call(groupPerf)'));
      // The one formatter, so there is no second hand-written copy of the line
      // for the two to disagree with.
      expect('parts={resolveMs:'.allMatches(service).length, 1);

      // 12-B's consumer: the two stage-2 rows are fed by the group report, and
      // the recognition row by the worker's own batch stats.
      expect(tasks, contains('void recordTranslatedGroup(GroupPerf perf'));
      expect(tasks, contains('void recordRenderWork(GroupPerf perf'));
      expect(tasks, contains('freshBatch.totalMs / freshBatch.pages'));

      // 12-A's driver: a wall-clock period that exists independently of the
      // event coalescer, with the three guards the plan asks for.
      expect(tasks, contains('class PreTranslationProgressTicker'));
      expect(tasks, contains('Timer.periodic'));
      expect(tasks, contains('void dispose()'));
    });
  });
}
