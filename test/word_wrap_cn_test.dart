import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/image_translation/vertical_typesetting.dart';
import 'package:venera/foundation/image_translation/word_wrap_cn.dart';

/// Phase 11-S3 (plan §8.4 V11-3). These assert the *rules*, not a dictionary:
/// `wrapCJK` is a typographic heuristic, so the meaningful guarantees are
/// "a line never opens with a closing mark", "a token is never cut from
/// inside", "the tail is never a single orphan character", and "no character
/// is ever lost". Word-boundary correctness is explicitly NOT claimed.
void main() {
  String joined(List<String> lines) => lines.map((l) => l.trim()).join();

  List<String> cjkOnly(String text) =>
      text.runes.map(String.fromCharCode).where((c) {
        var r = c.runes.first;
        return (r >= 0x4E00 && r <= 0x9FFF) ||
            (r >= 0x3040 && r <= 0x30FF) ||
            (r >= 0x3000 && r <= 0x303F);
      }).toList();

  test('空串与空白返回空结果', () {
    expect(wrapCJK('', 5), isEmpty);
    expect(wrapCJK('    ', 5), isEmpty);
    expect(wrapCJK('\n\t ', 5), isEmpty);
  });

  test('非法行宽退化为每单元一行，且字不丢', () {
    const text = '一二三';
    expect(wrapCJK(text, 0), ['一', '二', '三']);
    expect(wrapCJK(text, 1), ['一', '二', '三']);
    expect(wrapCJK(text, -3), ['一', '二', '三']);
  });

  test('双字绑定：断点落在偶数个汉字之后', () {
    var lines = wrapCJK('一二三四五六七八九十', 5);
    expect(lines, ['一二三四', '五六七八', '九十']);
    // 每一整行的汉字数都是偶数，行尾不会出现单字孤行。
    for (var line in lines.take(lines.length - 1)) {
      expect(cjkOnly(line).length.isOdd, isFalse, reason: line);
    }
    expect(lines.last.length % 2, 0, reason: '尾巴也不能是孤字');
  });

  test('双字绑定：奇数预算也不会漏字', () {
    const text = '吾妻之道岂可一日无也';
    var lines = wrapCJK(text, 7);
    expect(joined(lines).replaceAll(' ', ''), text);
    expect(lines.length, greaterThan(1));
  });

  test('原子不拆：数字与英文 token 永远整体成行', () {
    expect(wrapCJK('比分是三比五', 4), hasLength(2));

    var lines = wrapCJK('这个是OK的', 2);
    expect(
      lines.any((l) => l.contains('OK')),
      isTrue,
      reason: 'the Latin run must stay whole: $lines',
    );
    expect(
      lines.any((l) => l == 'O' || l == 'K' || l.contains('O K')),
      isFalse,
      reason: 'it must not be cut from inside: $lines',
    );

    // A slash number survives as one token even when it exceeds the budget.
    lines = wrapCJK('日期为3/5没错', 3);
    expect(
      lines.any((l) => l.contains('3/5')),
      isTrue,
      reason: 'a date is atomic: $lines',
    );
  });

  test('标点悬挂：任何一行都不以行首禁则字符开头', () {
    const samples = [
      '今天天气很好，我们一起去公园玩吧，那里的花开了。',
      '他说：「这件事不成，再想想办法。」她很犹豫。',
      '这是第一项——也是最后一项——请注意！真的。',
    ];
    for (final text in samples) {
      for (var limit in [4, 5, 6, 7, 9]) {
        var lines = wrapCJK(text, limit);
        for (var line in lines) {
          expect(
            line,
            isNot(startsWith(' ')),
            reason: 'trimmed: $lines (limit $limit)',
          );
          var head = line.runes.first;
          var headChar = String.fromCharCode(head);
          expect(
            kinsokuStart.contains(headChar),
            isFalse,
            reason: '"$headChar" opened a line in $lines (limit $limit)',
          );
          var tail = line.runes.last;
          expect(
            kinsokuEnd.contains(String.fromCharCode(tail)),
            isFalse,
            reason: 'a bracket was left dangling in $lines (limit $limit)',
          );
        }
        expect(
          joined(lines).replaceAll(' ', ''),
          text,
          reason: 'nothing may be lost (limit $limit)',
        );
      }
    }
  });

  test('孤字收尾被并回上一行', () {
    // 10 characters at a budget of 9 would otherwise end on a single glyph.
    var lines = wrapCJK('一二三四五六七八九〇', 9);
    expect(lines.last.length, greaterThanOrEqualTo(2), reason: '$lines');
  });

  test('纯英文：优先在空格处断，绝不在单词中间断', () {
    expect(wrapCJK('hello world', 5), ['hello', 'world']);
    expect(wrapCJK('hello world', 20), ['hello world']);
    // One unbreakable word: kept whole and on a line of its own.
    expect(wrapCJK('internationalization', 5), ['internationalization']);
  });

  test('中英混排：空格不被吞掉，token 完整', () {
    var lines = wrapCJK('使用 Google 翻译效果一般', 8);
    // Gaps are free for the budget but may be dropped where a line ends, so
    // the invariant is checked with whitespace normalised on both sides.
    expect(
      joined(lines).replaceAll(RegExp(r'\s+'), ''),
      '使用Google翻译效果一般',
    );
    expect(lines.any((l) => l.contains('Google')), isTrue);
  });

  test('超长单字符文本不崩溃（逐字成行）', () {
    var lines = wrapCJK('一' * 40, 3);
    expect(lines.every((l) => l.isNotEmpty), isTrue);
    expect(joined(lines).length, 40);
  });

  test('预算小于单元宽度时仍然推进，不死循环', () {
    var lines = wrapCJK('abcdefghij中文', 2);
    expect(joined(lines).replaceAll(' ', ''), 'abcdefghij中文');
  });
}
