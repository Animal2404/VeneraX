import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/image_translation/page_renderer.dart';
import 'package:venera/foundation/image_translation/translation_pipeline.dart';
import 'package:venera/foundation/image_translation/translation_types.dart';

/// Defect-A regression (叠字): the detector can deliver one caption as two
/// regions whose boxes cover the same art (connected-component bounding
/// boxes overlap by nature, and each cluster is recognized whole, so both
/// carry the same paragraph). The renderer has exactly one text pass per
/// region — no double-draw path exists inside it — so colliding regions are
/// merged into one reading-order block before planning, and no pixel area
/// can end up covered by two blocks of text.
///
/// Defect-B regression (残字): the erase footprint handed to the inpainter is
/// grown past the flood-fill box by a bounded margin, so the anti-aliased
/// fringe the binary threshold left outside the detected rect is inside the
/// eraser's classification window.
///
/// Everything below is asserted at the plan level (pure functions) plus one
/// end-to-end pixel test for the kept-original restore.
RgbaImage _whiteImage(int width, int height) {
  var pixels = Uint8List(width * height * 4);
  for (var i = 0; i < width * height; i++) {
    pixels[i * 4] = 255;
    pixels[i * 4 + 1] = 255;
    pixels[i * 4 + 2] = 255;
    pixels[i * 4 + 3] = 255;
  }
  return RgbaImage(width, height, pixels);
}

/// Left half red, right half green: a restore that (wrongly) sampled the
/// *whole* page into a left-half box would put green pixels in it, and the
/// red/green split makes that visible to a pixel assertion.
Future<Uint8List> _splitPng(int width, int height) async {
  var pixels = Uint8List(width * height * 4);
  for (var y = 0; y < height; y++) {
    for (var x = 0; x < width; x++) {
      var i = (y * width + x) * 4;
      pixels[i] = x < width ~/ 2 ? 255 : 0; // R
      pixels[i + 1] = x < width ~/ 2 ? 0 : 255; // G
      pixels[i + 2] = 0;
      pixels[i + 3] = 255;
    }
  }
  var completer = Completer<ui.Image>();
  ui.decodeImageFromPixels(
    pixels,
    width,
    height,
    ui.PixelFormat.rgba8888,
    completer.complete,
  );
  var image = await completer.future;
  try {
    var data = await image.toByteData(format: ui.ImageByteFormat.png);
    return data!.buffer.asUint8List();
  } finally {
    image.dispose();
  }
}

Future<Uint8List> _decodeRgba(Uint8List png) async {
  var codec = await ui.instantiateImageCodec(png);
  var frame = await codec.getNextFrame();
  try {
    var data = await frame.image.toByteData(format: ui.ImageByteFormat.rawRgba);
    return data!.buffer.asUint8List();
  } finally {
    frame.image.dispose();
    codec.dispose();
  }
}

TranslatedRegion _region(
  IntRect rect,
  String text, {
  List<IntRect>? eraseRects,
  int lineHeight = 24,
}) {
  return TranslatedRegion(
    rect: rect,
    eraseRect: eraseRects?.first ?? rect,
    eraseRects: eraseRects,
    text: text,
    backgroundColor: 0xFFFFFFFF,
    textColor: 0xFF000000,
    lineHeight: lineHeight,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('resolveRegionCollisions — one rectangle, one block of text', () {
    test('duplicate detections of one caption merge into a single block', () {
      // The screenshot-2 case: the same paragraph arrives twice over the
      // same art (two component boxes, whole-crop recognition on each).
      final a = _region(
        IntRect(100, 100, 300, 180),
        '我的名字是堀川吾郎，但这体格在高中…',
        eraseRects: [IntRect(104, 104, 296, 138), IntRect(104, 142, 296, 176)],
      );
      final b = _region(
        IntRect(102, 101, 302, 181),
        '我的名字是堀川吾郎，但这体格在高中…',
        eraseRects: [IntRect(106, 105, 298, 139)],
      );
      final out = resolveRegionCollisions([a, b]);
      expect(out, hasLength(1), reason: 'the two copies became one block');
      expect(
        out.single.text,
        '我的名字是堀川吾郎，但这体格在高中…',
        reason: 'identical texts collapse — the paragraph is painted once',
      );
      expect(out.single.rect.left, 100);
      expect(out.single.rect.top, 100);
      expect(out.single.rect.right, 302);
      expect(out.single.rect.bottom, 181);
      expect(
        out.single.eraseRects,
        hasLength(3),
        reason: 'every member line stays inside the erase footprint',
      );
    });

    test(
      'distinct texts in colliding boxes merge once, in reading order',
      () {
        // The screenshot-3 case: two staggered vertical columns whose boxes
        // overlap — painted separately they interleave into garbage.
        final rightColumn = _region(
          IntRect(140, 100, 190, 400),
          '但是只是…男生',
        );
        final leftColumn = _region(
          IntRect(120, 160, 170, 460),
          '这课时大都有分明',
        );
        final out = resolveRegionCollisions([leftColumn, rightColumn]);
        expect(out, hasLength(1));
        expect(
          out.single.text,
          '但是只是…男生\n这课时大都有分明',
          reason: 'manga order: same-row columns read right first',
        );
      },
    );

    test('the final placement plan never double-covers one pixel area', () {
      final dupA = _region(IntRect(100, 100, 300, 180), '胸部超级大声音超级魔性');
      final dupB = _region(IntRect(102, 101, 302, 181), '胸部超级大声音超级魔性');
      final elsewhere = _region(IntRect(600, 600, 800, 660), '远处旁白块');
      final merged = resolveRegionCollisions([dupA, dupB, elsewhere]);
      expect(merged, hasLength(2));

      final placements = planRegions(merged, const ui.Size(1000, 1000));
      final painted = placements.where((p) => p.paints).toList();
      expect(painted, hasLength(2), reason: 'both blocks still get placed');
      for (var i = 0; i < painted.length; i++) {
        for (var j = i + 1; j < painted.length; j++) {
          expect(
            painted[i].box.intersect(painted[j].box).isEmpty,
            isTrue,
            reason:
                'no pixel area is covered by two blocks of text: '
                '${painted[i].box} vs ${painted[j].box}',
          );
        }
      }
    });

    test('a collision-free list passes through untouched (S5 unaffected)', () {
      // The autosize fixture: one bubble, three same-text stacked lines with
      // real gaps. Grouping is S5's business; the merge must not eat it.
      final regions = [
        _region(IntRect(100, 100, 620, 165), '十二个汉字刚好占满一行测试预算'),
        _region(IntRect(105, 180, 615, 220), '十二个汉字刚好占满一行测试预算'),
        _region(IntRect(102, 232, 618, 260), '十二个汉字刚好占满一行测试预算'),
      ];
      final out = resolveRegionCollisions(regions);
      expect(identical(out, regions), isTrue, reason: 'same list, untouched');
      expect(out, hasLength(3));
    });

    test('a kept-original restore stays inside its own box (pixel proof)',
        () async {
      const width = 80;
      const height = 60;
      var original = await _splitPng(width, height);
      var decoded = _whiteImage(width, height);
      // Latin-heavy filler in a 20x20 box: nothing fits above the legibility
      // floor, so S1 keeps it original and the restore pass stamps the
      // source artwork back. The box sits wholly in the image's LEFT (red)
      // half — the old full-page src rect would have shrunk the whole
      // red/green artwork into it, putting green pixels where red belongs.
      var region = _region(
        IntRect(10, 10, 30, 30),
        'This source caption is deliberately far too long for the box.',
      );
      var result = await renderTranslatedPageWithReport(original, decoded, [
        region,
      ]);
      expect(
        result.report.keepOriginal,
        contains(0),
        reason: 'precondition: the block really kept its original',
      );
      var pixels = await _decodeRgba(result.png);
      for (var y = 10; y < 30; y++) {
        for (var x = 10; x < 30; x++) {
          var i = (y * width + x) * 4;
          expect(
            pixels.sublist(i, i + 2),
            [255, 0],
            reason: 'restored pixel $x,$y must come from the same spot, red',
          );
        }
      }
    });
  });

  group('eraseFootprintRects — the eraser sees the whole glyph', () {
    test('the grown footprint contains the detected text rect on every side', () {
      var region = _region(
        IntRect(0, 0, 120, 60),
        '教師の模範',
        eraseRects: [IntRect(12, 12, 98, 38)],
        lineHeight: 30,
      );
      var grown = PageTranslationPipeline.eraseFootprintRects([region], 1000, 1000);
      expect(grown, hasLength(1));
      var rect = grown.single;
      expect(rect.left, lessThan(12));
      expect(rect.top, lessThan(12));
      expect(rect.right, greaterThan(98));
      expect(rect.bottom, greaterThan(38));
      expect(rect.width, greaterThan(98 - 12));
      expect(rect.height, greaterThan(38 - 12));
    });

    test('the margin is bounded: never under 2px, never over 4px', () {
      var small = _region(
        IntRect(0, 0, 40, 20),
        'あ',
        eraseRects: [IntRect(10, 10, 30, 20)],
        lineHeight: 8,
      );
      var tiny = PageTranslationPipeline.eraseFootprintRects([small], 1000, 1000).single;
      expect(10 - tiny.left, 2); // 2 + 8 ~/ 16

      var huge = _region(
        IntRect(0, 0, 400, 300),
        'ド',
        eraseRects: [IntRect(100, 100, 300, 300)],
        lineHeight: 200,
      );
      var big = PageTranslationPipeline.eraseFootprintRects([huge], 1000, 1000).single;
      expect(100 - big.left, 4); // 2 + 200 ~/ 16 = 14 — capped at 4
      expect(big.right, 304);
      expect(big.bottom, 304);
    });

    test('footprints are clamped to the image', () {
      var region = _region(
        IntRect(0, 0, 20, 20),
        'x',
        eraseRects: [IntRect(0, 0, 20, 20)],
        lineHeight: 30,
      );
      var rect = PageTranslationPipeline.eraseFootprintRects([region], 100, 80).single;
      expect(rect.left, greaterThanOrEqualTo(0));
      expect(rect.top, greaterThanOrEqualTo(0));
      expect(rect.right, lessThanOrEqualTo(100));
      expect(rect.bottom, lessThanOrEqualTo(80));
    });

    test('degenerate line boxes are never handed to the eraser', () {
      var region = _region(
        IntRect(0, 0, 40, 40),
        'x',
        eraseRects: [IntRect(5, 5, 5, 9)],
      );
      expect(PageTranslationPipeline.eraseFootprintRects([region], 1000, 1000), isEmpty);
    });
  });
}
