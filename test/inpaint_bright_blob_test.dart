// NOTE: 本文件按仓库约束在本地**未运行**（禁止本地 flutter test / 构建），
// 只经过 `flutter analyze --no-pub`；结论以云端 `Test` job 为准。
//
// 这里钉的是"智能清除不再残留黑色色块"，用**尺寸判据**而不是覆盖率。
//
// 上一轮先用覆盖率做过一次（上限 0.35），CI 报了 7 处失败：合法用例里既有
// "贴页边的密集标题"（覆盖 0.76）、也有"黑气泡上的白色细笔画"（覆盖 0.47），
// 它们与出斑窗口在覆盖上完全重叠。因此这次换判据，并且**只在"文字类=亮"时**
// 生效 —— 深字浅底（普通情形、密集标题都属于它）一个字节都不会被这条规则碰到。
//
// 判据与阈值都来自实测（重算分类器 + 用户缓存原图）：
//   出斑窗口的最大亮连通域 = 3,216 px（白字黑底压在美术上）/ 63,604 px（黑爱心+纸面）
//   合法细白笔画           = 360 px
// 阈值 2,000 px 落在这条空隙里。

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/image_translation/inpaint.dart';
import 'package:venera/foundation/image_translation/translation_types.dart';

void main() {
  RgbaImage solid(int w, int h, int v) {
    final pixels = Uint8List(w * h * 4);
    for (var i = 0; i < pixels.length; i += 4) {
      pixels[i] = v;
      pixels[i + 1] = v;
      pixels[i + 2] = v;
      pixels[i + 3] = 255;
    }
    return RgbaImage(w, h, pixels);
  }

  void rect(RgbaImage image, int l, int t, int r, int b, int v) {
    for (var y = t; y < b; y++) {
      for (var x = l; x < r; x++) {
        final base = (y * image.width + x) * 4;
        image.pixels[base] = v;
        image.pixels[base + 1] = v;
        image.pixels[base + 2] = v;
      }
    }
  }

  int lum(RgbaImage image, int x, int y) {
    final base = (y * image.width + x) * 4;
    return (0.299 * image.pixels[base] +
            0.587 * image.pixels[base + 1] +
            0.114 * image.pixels[base + 2])
        .round();
  }

  group('white on dark: thin strokes erase, one big bright blob does not', () {
    test('thin light strokes inside a black bubble are still erased', () {
      // The suite's own fixture shape, kept here on purpose: the coverage
      // ceiling broke exactly this case, and it must keep working.
      final img = solid(120, 120, 8);
      rect(img, 30, 34, 90, 40, 250);
      rect(img, 30, 46, 82, 52, 250);
      rect(img, 30, 58, 88, 64, 250);

      final report = TextInpainter.eraseReport(img, [IntRect(28, 32, 92, 66)]);

      expect(report.erased, 1, reason: 'light lettering on a dark bubble');
      for (var y = 32; y < 66; y++) {
        for (var x = 28; x < 92; x++) {
          expect(lum(img, x, y), lessThan(90), reason: '($x,$y) stroke left');
        }
      }
    });

    test('dense dark lettering is untouched by this rule', () {
      // Dark-on-light never enters the bright guard, whatever the mask covers —
      // this is the other case the coverage ceiling broke.
      final img = solid(40, 20, 245);
      for (var y = 1; y < 17; y++) {
        for (var x = 1; x < 39; x++) {
          rect(img, x, y, x + 1, y + 1, 20);
        }
      }

      final report = TextInpainter.eraseReport(img, [IntRect(0, 0, 40, 20)]);

      expect(report.erased, 1, reason: 'dense dark lettering stays erasable');
      expect(lum(img, 20, 10), greaterThan(200));
    });

    test('a big bright blob over dark artwork is refused, pixels untouched', () {
      // The page-35 shape: a bright field much larger than any glyph.
      final img = solid(200, 200, 60);
      rect(img, 20, 20, 180, 80, 250);

      final before = Uint8List.fromList(img.pixels);
      final report = TextInpainter.eraseReport(img, [IntRect(16, 16, 184, 84)]);

      expect(report.erased, 0, reason: 'this is the window that smeared');
      expect(report.skipped, 1);
      expect(img.pixels, before, reason: 'a refused window changes nothing');
    });

    test('even a modest bright blob is refused — the page-31 shape', () {
      // 40x80 = 3,200 px, the smallest of the measured smearing windows.
      final img = solid(200, 200, 60);
      rect(img, 60, 60, 100, 140, 250);

      final report = TextInpainter.eraseReport(img, [IntRect(56, 56, 104, 144)]);

      expect(report.erased, 0);
      expect(report.skipped, 1);
    });

    test('the threshold sits in the gap the measurements left', () {
      expect(
        maxBrightComponentPixels,
        greaterThan(360),
        reason: 'the legitimate white-on-dark fixture',
      );
      expect(
        maxBrightComponentPixels,
        lessThan(3216),
        reason: 'the smallest smearing window',
      );
    });
  });
}
