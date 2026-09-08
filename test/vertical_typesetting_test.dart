import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/image_translation/vertical_typesetting.dart';

/// Phase 11-S2 (plan §8.4 V11-3). Table-driven checks on the vertical
/// typesetting layer: every punctuation mark the renderer claims to re-shape
/// must carry real numbers, tate-chu-yoko runs must be cut as whole clusters,
/// and the 禁则 tables must actually answer the queries the line breakers ask.
void main() {
  group('tatePunct table', () {
    test('covers the marks the plan lists as required', () {
      const required = [
        '，', '。', '、', '！', '？', '：', '；', '…', 'ー', //
        '「', '」', '『', '』', '（', '）',
      ];
      for (final mark in required) {
        expect(tatePunct.containsKey(mark), isTrue, reason: '$mark missing');
      }
    });

    test('full-width stop and comma hug the top-right of the cell', () {
      for (final mark in ['，', '。', '、']) {
        final entry = tatePunct[mark]!;
        expect(entry.dxRatio, greaterThan(0), reason: '$mark must move right');
        expect(entry.dyRatio, lessThan(0), reason: '$mark must move up');
        expect(entry.rotation, 0.0, reason: '$mark stays upright');
      }
    });

    test('horizontal-only marks are turned 90 degrees clockwise', () {
      for (final mark in ['…', 'ー', '〜', '—']) {
        expect(tatePunct[mark]!.rotation, 90.0, reason: '$mark must turn');
      }
    });

    test('brackets turn and open across the column', () {
      // A corner turned clockwise reads as a corner closing across a column;
      // the opener sits at the cell's head, the closer at its tail.
      expect(tatePunct['「']!.rotation, 90.0);
      expect(tatePunct['」']!.rotation, 90.0);
      expect(tatePunct['「']!.dyRatio, lessThan(0));
      expect(tatePunct['」']!.dyRatio, greaterThan(0));
      expect(tatePunct['「']!.dxRatio, greaterThan(0));
      expect(tatePunct['」']!.dxRatio, lessThan(0));
    });

    test('symmetric marks are declared no-ops, not table misses', () {
      for (final mark in ['・', '々']) {
        final entry = tatePunct[mark]!;
        expect(entry.dxRatio, 0.0);
        expect(entry.dyRatio, 0.0);
        expect(entry.rotation, 0.0);
      }
    });
  });

  group('layoutVerticalSpans', () {
    test('plain CJK becomes one upright cell per character', () {
      final spans = layoutVerticalSpans('你好世界');
      expect(spans.map((s) => s.text).join(), '你好世界');
      expect(
        spans.every((s) => s.kind == VerticalSpanKind.ideograph),
        isTrue,
      );
      expect(spans.every((s) => s.rotation == 0.0 && s.cells == 1), isTrue);
    });

    test('punctuation carries its table offsets into the span', () {
      final spans = layoutVerticalSpans('いいよ。');
      final last = spans.last;
      expect(last.kind, VerticalSpanKind.punctuation);
      expect(last.text, '。');
      expect(last.dxRatio, tatePunct['。']!.dxRatio);
      expect(last.dyRatio, tatePunct['。']!.dyRatio);
      expect(last.rotation, 0.0, reason: 'a stop stays upright');
      expect(last.cells, 1);

      final ellipsis = layoutVerticalSpans('等等…').last;
      expect(ellipsis.rotationRad, closeTo(3.141592653589793 / 2, 1e-9));
      expect(ellipsis.isRotated, isTrue);
    });

    test('tate-chu-yoko: digits, counters and Latin stay one cluster', () {
      expect(layoutVerticalSpans('OK').single.kind, VerticalSpanKind.cluster);
      expect(layoutVerticalSpans('OK').single.cells, 1);
      expect(layoutVerticalSpans('OK').single.rotation, 0.0);

      final pair = layoutVerticalSpans('2人').single;
      expect(pair.kind, VerticalSpanKind.cluster);
      expect(pair.text, '2人', reason: 'a counter joins its short number');
      expect(pair.cells, 1, reason: 'two characters, one em');

      final date = layoutVerticalSpans('3/5').single;
      expect(date.text, '3/5', reason: 'a slash number is never split');
      expect(date.cells, 2, reason: 'three characters pack two per em');
    });

    test('a cluster keeps the column flow: text is reassembled exactly', () {
      const text = '彼はOKと3/5を言った';
      final spans = layoutVerticalSpans(text);
      expect(spans.map((s) => s.text).join(), text);
      expect(spans.any((s) => s.kind == VerticalSpanKind.cluster), isTrue);
    });

    test('long digit runs are still one cluster and size their cells', () {
      final span = layoutVerticalSpans('2024').single;
      expect(span.kind, VerticalSpanKind.cluster);
      expect(span.cells, 2);
      expect(layoutVerticalSpans('12345').single.cells, 3);
    });

    test('whitespace and empty input produce nothing', () {
      expect(layoutVerticalSpans(''), isEmpty);
      expect(layoutVerticalSpans('  　 '), isEmpty);
    });

    test('unknown characters fall through instead of disappearing', () {
      const exotic = '￥★©';
      final spans = layoutVerticalSpans(exotic);
      expect(spans.map((s) => s.text).join(), exotic);
      expect(spans.every((s) => s.cells == 1), isTrue);
    });
  });

  group('kinsoku tables', () {
    test('closing marks and separators may not open a column', () {
      for (final mark in ['。', '，', '、', '！', '？', '」', '…', 'ー']) {
        expect(kinsokuStart.contains(mark), isTrue, reason: mark);
        expect(canStartLine(mark), isFalse, reason: mark);
      }
    });

    test('opening brackets may not close a column', () {
      for (final mark in ['「', '（', '『', '【']) {
        expect(kinsokuEnd.contains(mark), isTrue, reason: mark);
        expect(canEndLine(mark), isFalse, reason: mark);
      }
    });

    test('ordinary ideographs are legal at both ends', () {
      expect(canStartLine('人'), isTrue);
      expect(canEndLine('人'), isTrue);
      expect(canStartLine(''), isFalse);
    });

    test('tables never contradict each other', () {
      for (final mark in kinsokuStart) {
        expect(kinsokuEnd.contains(mark), isFalse, reason: '$mark both?');
      }
    });
  });
}
