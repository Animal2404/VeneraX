// NOTE: 本文件按仓库约束在本地**未运行**（禁止本地 flutter test / 构建），
// 只经过 `flutter analyze --no-pub`；结论以云端 `Test` job 为准。
//
// 这里钉的是"黑色色块"取证所需的两个数：**分类器在窗口里量到的背景亮度、
// 以及它判为文字的那一类的亮度**（外加掩膜覆盖率）。
//
// 起因是用户那次运行里真实出现的现象，我是拿他自己的原图与渲染图对比复现的：
// 第 31 页「クソッ」那种白字黑底上，擦完留下一条深色拖影；第 35 页的黑色爱心
// 与网点也被抹成一块黑斑。台账却写着 `erased=N rolled_back=0` —— "成功"。
//
// 黑块有两个完全不同的成因，修法也完全不同：
//   ① 掩膜把美术区当成文字吃掉了（深底窗口里两个类选反）
//   ② 填充把周围未被掩膜的暗像素拖了过来
// 台账原本两个都不记录，所以只能靠猜。现在每次擦除都会带上
// `masks={x,y(bg=… text=… cover=…)}`，一行日志就能分辨。

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/image_translation/inpaint.dart';
import 'package:venera/foundation/image_translation/translation_types.dart';

void main() {
  RgbaImage page(int w, int h, int value) {
    final pixels = Uint8List(w * h * 4);
    for (var i = 0; i < pixels.length; i += 4) {
      pixels[i] = value;
      pixels[i + 1] = value;
      pixels[i + 2] = value;
      pixels[i + 3] = 255;
    }
    return RgbaImage(w, h, pixels);
  }

  void fill(RgbaImage image, int l, int t, int r, int b, int value) {
    for (var y = t; y < b; y++) {
      for (var x = l; x < r; x++) {
        final base = (y * image.width + x) * 4;
        image.pixels[base] = value;
        image.pixels[base + 1] = value;
        image.pixels[base + 2] = value;
      }
    }
  }

  group('the erase ledger records what the classifier decided', () {
    test('dark lettering on light paper reports a bright background', () {
      final image = page(120, 120, 235);
      // A few dark strokes, the shape the classifier is meant to find.
      for (var i = 0; i < 5; i++) {
        fill(image, 20 + i * 16, 30, 24 + i * 16, 90, 25);
      }

      final mask = TextInpainter.computeMask(image, IntRect(12, 24, 100, 96));

      expect(mask, isNotNull);
      expect(mask!.bgLuma, greaterThan(180));
      expect(mask.textLuma, lessThan(90));
      expect(mask.ledger, contains('bg='));
      expect(mask.ledger, contains('cover='));
    });

    test('the ledger line carries them, so a report can be checked', () {
      final image = page(120, 120, 235);
      for (var i = 0; i < 5; i++) {
        fill(image, 20 + i * 16, 30, 24 + i * 16, 90, 25);
      }

      final report = TextInpainter.eraseReport(image, [
        IntRect(12, 24, 100, 96),
      ]);
      final line = report.describe();

      expect(report.erased, 1);
      expect(line, contains('masks={'));
      expect(line, contains('bg='));
      expect(line, contains('text='));
      // The reason this exists: "erased, no rollback" and "the page shows a
      // black smear" must not be able to hold at the same time unnoticed. The
      // masks group is what breaks the tie — a rollback line only appears when
      // there was one.
      expect(line, contains('erased=1'));
    });

    test('a window the classifier declined reports nothing to erase', () {
      final image = page(80, 80, 200);

      final report = TextInpainter.eraseReport(image, [
        IntRect(10, 10, 70, 70),
      ]);

      expect(report.skipped, 1);
      expect(report.describe(), isNot(contains('masks={')));
    });
  });
}
