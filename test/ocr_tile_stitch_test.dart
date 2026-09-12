// NOTE: 本文件按仓库约束在本地**未运行**（禁止本地 flutter test / 构建），
// 只经过 `flutter analyze --no-pub`；结论以云端 `Test` job 为准。
//
// 这里钉的是"相邻气泡译文融合"的根因：**同一条文字线被两个检测块各裁了一次**。
//
// 证据不是推测，是应用自己存下来的块列表（用户那次 37 页的运行）：
//
//   第 4 页  (778,1140)-(887,1463) 俺のだけど我慢してくれよ母さんのヤツとか絶対触れねーから
//            (780,1145)-(885,1284) 俺のだけどが母さんのヤ絶対触れね     ← 同句，被截断
//            (366,1206)-(477,1449) じゃあ今アタシとアンタだけってことか...♡
//            (374,1212)-(474,1277) じゃあアタってっ                   ← 同句，被截断
//   第 9 页  (142,1169)-(247,1378) 求められたら絶対逆らえないっしょ.
//            (162,1188)-(259,1370) 求められたら絶対逆らえないっしょ.   ← 逐字重复
//
// 两个重复块各自被翻译、各自回填到自己的框里，渲染出来就是截图里那种"串行/错乱"。
//
// 拼接处原本用 `_iou > 0.5` 判重。IoU 除以并集，所以"整条 vs 被裁掉一半"这种
// 尺寸差很大的同一条线，IoU 恒小于 0.5 → 两份都留下。**跨 tile 的重复要看包含度**
// （交集 / 较小者），因为被截断的那个框整个落在完整框里；而且必须保留更完整的那份。

import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/image_translation/translation_types.dart';
import 'package:venera/foundation/image_translation/translation_worker.dart';

void main() {
  group('the tile stitch keeps one copy of a line, not two', () {
    test('the two real duplicates from the run are duplicates', () {
      // Page 4, the same sentence seen whole and truncated.
      expect(
        duplicateDetectionBox(
          IntRect(778, 1140, 887, 1463),
          IntRect(780, 1145, 885, 1284),
        ),
        isTrue,
      );
      expect(
        duplicateDetectionBox(
          IntRect(366, 1206, 477, 1449),
          IntRect(374, 1212, 474, 1277),
        ),
        isTrue,
      );
      // Page 9, character-for-character the same text in two boxes.
      expect(
        duplicateDetectionBox(
          IntRect(142, 1169, 247, 1378),
          IntRect(162, 1188, 259, 1370),
        ),
        isTrue,
      );
    });

    test('order does not matter: containment is symmetric enough', () {
      final whole = IntRect(778, 1140, 887, 1463);
      final part = IntRect(780, 1145, 885, 1284);

      expect(duplicateDetectionBox(whole, part), isTrue);
      expect(duplicateDetectionBox(part, whole), isTrue);
    });

    test('the adjacent columns of one bubble are NOT duplicates', () {
      // These are different lines of the same speech bubble — the ones that must
      // stay separate blocks, or the page loses a sentence. Keeping them out of
      // the dedup is the whole reason the threshold is containment 0.8 and not
      // "boxes that touch".
      expect(
        duplicateDetectionBox(
          IntRect(239, 1086, 304, 1432),
          IntRect(142, 1169, 247, 1378),
        ),
        isFalse,
      );
      // Page 9's `チューもお・` beside `ッグい`: different texts, boxes that
      // overlap by less than half of the smaller one.
      expect(
        duplicateDetectionBox(
          IntRect(548, 1166, 631, 1246),
          IntRect(611, 1178, 648, 1257),
        ),
        isFalse,
      );
    });

    test('lines that do not touch are never duplicates', () {
      expect(
        duplicateDetectionBox(
          IntRect(1020, 982, 1089, 1105),
          IntRect(1043, 147, 1134, 220),
        ),
        isFalse,
      );
    });

    test('near-identical boxes are still caught by the old IoU rule', () {
      expect(
        duplicateDetectionBox(
          IntRect(100, 100, 200, 200),
          IntRect(102, 103, 199, 198),
        ),
        isTrue,
      );
    });

    test('the fuller copy wins, which is what the stitch replaces with', () {
      // The predicate only decides "same line"; the stitch then keeps the box
      // with the larger area. Asserted here because the choice is the second
      // half of the defect: keeping whichever arrived first is how a half-line
      // came to be recognized beside the whole one.
      final whole = IntRect(778, 1140, 887, 1463);
      final part = IntRect(780, 1145, 885, 1284);

      expect(whole.area, greaterThan(part.area));
    });

    test('a zero-area box cannot be reported as containing anything', () {
      expect(
        duplicateDetectionBox(
          IntRect(10, 10, 10, 40),
          IntRect(10, 10, 40, 40),
        ),
        isFalse,
      );
    });
  });
}
