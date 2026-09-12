// NOTE: 本文件按仓库约束在本地**未运行**（禁止本地 flutter test / 构建），
// 只经过 `flutter analyze --no-pub`；结论以云端 `Test` job 为准。
//
// 这里钉的是"智能清除不再残留黑色色块"。
//
// 现象是在用户自己的数据里复现的（原图 vs 渲染图逐页对比）：第 31 页白字黑底
// 擦完留下深色拖影，第 35 页黑色爱心连同网点被抹成黑斑。
//
// 把 `computeMask` 的判定在他那两页上离线复算，两个群体**完全不重叠**：
//
//   浅底气泡（擦除器本来要处理的场景）：掩膜覆盖 0.09 – 0.27
//   出黑斑的三个窗口（bg=74 白字黑底 / bg=151 网点 / bg=147 黑爱心）：0.45 / 0.48 / 0.51
//
// 机制是**类别选择**：在深底/中间调窗口上，"离环形均值更远的那一类算文字"选中的
// 是**亮的那一类** —— 在外面那片区域里，亮的是纸面和描边，不是字形 —— 于是近半个
// 矩形被擦掉，填充再把深色背景拖过来。所以上限从 0.85 收到 0.35：两个群体之间
// 留出余量，被拒的窗口**保持原像素**，而这正是本文件一贯的原则 ——
// "宁可留下原文，也不能留一块黑"。
//
// 下面两个夹具就是这两个群体，第二个还额外断言**像素一个字节都没变**。

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

  int lumaAt(RgbaImage image, int x, int y) {
    final base = (y * image.width + x) * 4;
    return (0.299 * image.pixels[base] +
            0.587 * image.pixels[base + 1] +
            0.114 * image.pixels[base + 2])
        .round();
  }

  group('the eraser keeps its promise: no black where the source was not', () {
    test('a bubble on light paper is still erased, as before', () {
      final image = page(160, 200, 235);
      // Dark strokes over light paper: ~15% of the rectangle.
      for (var i = 0; i < 6; i++) {
        fill(image, 30 + i * 14, 60, 34 + i * 14, 140, 30);
      }

      final report = TextInpainter.eraseReport(image, [
        IntRect(20, 50, 140, 150),
      ]);

      expect(report.erased, 1, reason: 'the ordinary case must keep working');
      // The strokes are gone: the fill borrowed the surrounding paper.
      expect(lumaAt(image, 31, 100), greaterThan(150));
    });

    test('a dark window the classifier misreads is refused, pixels untouched', () {
      // The page-31/35 shape: a dark field with bright shapes over it. The
      // classifier calls the bright class the lettering — the class choice that
      // turned those windows into smears. This fixture masks a larger share
      // than the measured 0.45, but the mechanism under test is the choice, not
      // the exact ratio: it sits above the new ceiling and below the old 0.85,
      // which is exactly the window the old rule let through.
      final image = page(160, 200, 74);
      fill(image, 24, 40, 136, 96, 245);   // a bright band (paper / outline)
      fill(image, 30, 104, 130, 160, 245); // and a bright block below it

      final before = Uint8List.fromList(image.pixels);
      final report = TextInpainter.eraseReport(image, [
        IntRect(20, 30, 140, 170),
      ]);

      expect(
        report.erased,
        0,
        reason: 'this is the window that produced the black smear',
      );
      expect(report.skipped, 1, reason: 'declined before any pixel was written');
      expect(
        image.pixels,
        before,
        reason: 'a refused window leaves the page exactly as it was',
      );
    });

    test('the ceiling sits between the two measured populations', () {
      // 0.27 is the widest legitimate bubble window on the reported run, 0.45
      // the narrowest smearing one; the constant has to stay inside that gap.
      expect(maxMaskCoverage, greaterThan(0.27));
      expect(maxMaskCoverage, lessThan(0.45));
    });
  });
}
