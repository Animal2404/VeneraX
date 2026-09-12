// NOTE: 本文件按仓库约束在本地**未运行**（禁止本地 flutter test / 构建），
// 只经过 `flutter analyze --no-pub`；结论以云端 `Test` job 为准。
//
// 这里钉的是"两个气泡的译文融合"的正解：**气泡掩码**。
//
// 为什么不是几何阈值：两个气泡能并上，说明它们的文字块已经近到让几何门槛
// 连起来了；而在那个距离上，两块文字的几何和"一个气泡里排得很紧的两块"完全
// 无法区分（plan §2.5 的叙述间距算术）。唯一能分辨的是气泡本身——气泡是被
// 描边围住的连通亮区，所以"从一块文字的中心漫水能不能走到另一块"就是答案。
// 这也是 manga-image-translator 的 ballon_extractor 与 BallonsTranslator 的
// canny_flood 共同采用的做法。
//
// 全部是合成像素上的纯函数：无 isolate、无模型、无 IO、无 dart:ui。

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/image_translation/balloon.dart';
import 'package:venera/foundation/image_translation/translation_types.dart';

void main() {
  /// A white page of [w]×[h].
  RgbaImage page(int w, int h, [int background = 255]) {
    final pixels = Uint8List(w * h * 4);
    for (var i = 0; i < pixels.length; i += 4) {
      pixels[i] = background;
      pixels[i + 1] = background;
      pixels[i + 2] = background;
      pixels[i + 3] = 255;
    }
    return RgbaImage(w, h, pixels);
  }

  void paint(RgbaImage image, int l, int t, int r, int b, int v) {
    for (var y = t; y < b; y++) {
      for (var x = l; x < r; x++) {
        final base = (y * image.width + x) * 4;
        image.pixels[base] = v;
        image.pixels[base + 1] = v;
        image.pixels[base + 2] = v;
      }
    }
  }

  /// A bubble outline: a 2 px stroke rectangle (left,top)-(right,bottom).
  void outline(RgbaImage image, int l, int t, int r, int b) {
    paint(image, l, t, r, t + 2, 0);
    paint(image, l, b - 2, r, b, 0);
    paint(image, l, t, l + 2, b, 0);
    paint(image, r - 2, t, r, b, 0);
  }

  group('balloonRegionOf: a closed outline is what makes a balloon', () {
    test('a block inside an outline fills up to the outline, and stays enclosed', () {
      final image = page(200, 200);
      outline(image, 20, 20, 120, 120);
      // Two glyph strokes inside, so the fill is not a trivially empty region.
      paint(image, 50, 50, 90, 56, 0);
      paint(image, 50, 70, 90, 76, 0);

      final balloon = balloonRegionOf(image, IntRect(45, 45, 95, 80))!;

      expect(balloon.enclosed, isTrue);
      expect(balloon.contains(70, 90), isTrue, reason: 'inside the outline');
      expect(
        balloon.contains(10, 10),
        isFalse,
        reason: 'outside it — the outline stopped the fill',
      );
      expect(balloon.area, greaterThan(0));
    });

    test('a block on open artwork cannot be enclosed: the fill reaches the window', () {
      final image = page(200, 200);
      paint(image, 50, 50, 90, 56, 0);

      final balloon = balloonRegionOf(image, IntRect(45, 45, 95, 80))!;

      expect(
        balloon.enclosed,
        isFalse,
        reason: 'no outline anywhere: the answer must be unknown, not "a balloon"',
      );
    });

    test('a block whose centre sits on a stroke still finds a seed', () {
      final image = page(200, 200);
      outline(image, 20, 20, 160, 160);
      // A fat stroke right through the middle of the requested box.
      paint(image, 20, 80, 160, 96, 0);

      final balloon = balloonRegionOf(image, IntRect(70, 70, 110, 110));

      expect(balloon, isNotNull);
      expect(balloon!.area, greaterThan(0));
    });

    test('a box outside the image, or a degenerate one, returns null', () {
      final image = page(50, 50);
      // A window that cannot be placed at all: the box is entirely past the
      // page, so there is nothing to flood.
      expect(balloonRegionOf(image, IntRect(500, 500, 600, 600)), isNull);
      expect(balloonRegionOf(image, IntRect(10, 10, 10, 40)), isNull);
    });
  });

  group('sameBalloon: the veto the clustering gate needs', () {
    test('two blocks in one bubble share it', () {
      final image = page(200, 200);
      outline(image, 20, 20, 180, 180);
      paint(image, 50, 50, 56, 150, 0); // two vertical columns of lettering
      paint(image, 90, 50, 96, 150, 0);

      final left = balloonRegionOf(image, IntRect(45, 50, 60, 150))!;
      final right = balloonRegionOf(image, IntRect(85, 50, 100, 150))!;

      expect(left.enclosed, isTrue);
      expect(right.enclosed, isTrue);
      expect(
        sameBalloon(left, right),
        isTrue,
        reason: 'one outline contains both blocks: they are one region',
      );
    });

    test('two blocks in two bubbles do NOT share one — the reported defect', () {
      final image = page(240, 200);
      // Two bubbles almost touching: 10 px of paper between the outlines.
      outline(image, 20, 20, 110, 180);
      outline(image, 120, 20, 220, 180);
      paint(image, 40, 50, 46, 150, 0); // lettering in each
      paint(image, 160, 50, 166, 150, 0);

      final left = balloonRegionOf(image, IntRect(35, 50, 50, 150))!;
      final right = balloonRegionOf(image, IntRect(155, 50, 170, 150))!;

      expect(left.enclosed, isTrue);
      expect(right.enclosed, isTrue);
      expect(
        sameBalloon(left, right),
        isFalse,
        reason: 'each outline closes its own region — the merge must be refused',
      );
    });

    test('unknown evidence never vetoes', () {
      final image = page(200, 200);
      final open = balloonRegionOf(image, IntRect(45, 45, 95, 80))!;
      expect(open.enclosed, isFalse);
      expect(
        sameBalloon(open, open),
        isTrue,
        reason: 'not enclosed ⇒ unknown ⇒ keep the geometric decision',
      );
      expect(sameBalloon(null, open), isTrue);
      expect(sameBalloon(null, null), isTrue);
    });
  });
}
