import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/image_translation/page_renderer.dart';
import 'package:venera/foundation/image_translation/translation_types.dart';

/// Defect A (black blocks), painting side.
///
/// The eraser cannot invent a colour — it only ever copies a pixel that was
/// already on the page ([inpaint_no_black_block_test.dart] pins that). The one
/// place this renderer paints anything near-black in the erase modes is the
/// *halo* around the replacement lettering: `0xE6000000`, drawn at up to 35% of
/// the glyph size ([kStrokeRatioCeil]), which covers several times the area of
/// the ink it rings. So a black block on a translated page is a halo drawn on
/// the wrong assumption, and the assumption is made here, in
/// [backgroundReadsDark].
///
/// The fixture below is the shape that used to go wrong: a caption's *grown*
/// box (safeGrowRect borrows gutter on all four sides) catching a strip of dark
/// artwork along with a bright bubble. A mean over that box says "dark page";
/// the majority of it says "the lettering sits on bright art". The two answers
/// differ, and only one of them paints a black mass across a white bubble.
///
/// NOT VERIFIED LOCALLY (no `flutter test` in this workspace) — see the
/// "待云端 Test job 验证" list.
RgbaImage _bands(List<int> luminances) {
  // One row per luminance, 40px wide.
  final h = luminances.length, w = 40;
  final px = Uint8List(w * h * 4);
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      final i = (y * w + x) * 4;
      px[i] = luminances[y];
      px[i + 1] = luminances[y];
      px[i + 2] = luminances[y];
      px[i + 3] = 255;
    }
  }
  return RgbaImage(w, h, px);
}

/// 18 rows of bright bubble, 6 of mid-tone art, 16 of black sky.
///
/// mean = (18·250 + 6·60 + 16·0) / 40 = 121.5 → the old mean test read this box
/// as dark; brightShare (45%) > darkShare (40%) → it is not.
final _mixed = _bands(<int>[
  ...List.filled(18, 250),
  ...List.filled(6, 60),
  ...List.filled(16, 0),
]);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final box = const ui.Rect.fromLTRB(0, 0, 40, 40);

  group('backgroundReadsDark — who is allowed to pick up the black pen', () {
    test('the mixed fixture is below the mean threshold (precondition)', () {
      // Proof that this test is aiming at the real disagreement: the old rule
      // (`mean < 128`) would have answered `true` here, and `true` is the
      // branch that draws a 90%-opaque black halo across the page.
      var sum = 0.0, count = 0;
      for (var y = 0; y < _mixed.height; y++) {
        for (var x = 0; x < _mixed.width; x++) {
          final i = (y * _mixed.width + x) * 4;
          sum += _mixed.pixels[i];
          count++;
        }
      }
      expect(sum / count, lessThan(128));
    });

    test('a mostly-bright box takes the light branch even when its mean is low',
        () {
      expect(
        backgroundReadsDark(_mixed, box),
        isFalse,
        reason:
            'bright majority: dark lettering with a white halo, never a '
            'black halo — that halo is the reported black block',
      );
    });

    test('a box that really is dark still gets light lettering', () {
      final dark = _bands([
        ...List.filled(30, 0),
        ...List.filled(6, 60),
        ...List.filled(4, 250),
      ]);
      expect(backgroundReadsDark(dark, box), isTrue);
    });

    test('a clean white bubble is unchanged by the new test', () {
      expect(backgroundReadsDark(_bands(List.filled(40, 245)), box), isFalse);
    });

    test('a mid-tone box with no majority reads as light (safe branch)', () {
      // Half black, half bright, no mean signal: ties go to the light branch,
      // because a white halo over dark art is still readable while a black one
      // over bright art is a block.
      final tie = _bands([
        ...List.filled(20, 0),
        ...List.filled(20, 255),
      ]);
      expect(backgroundReadsDark(tie, box), isFalse);
    });

    test('a box that does not fit the page is not evidence of darkness', () {
      // The stride/length disagreement class: reading past the buffer is how
      // zero-filled slack becomes a black pixel, so "cannot read" must never
      // answer `true`.
      final tiny = RgbaImage(40, 40, Uint8List(40 * 20 * 4));
      expect(
        backgroundReadsDark(tiny, const ui.Rect.fromLTRB(0, 0, 40, 40)),
        isFalse,
      );
    });
  });

  group('the halo itself is unchanged (S4 red line)', () {
    test('stroke width still tracks the source ratio 1:1, capped as before',
        () {
      // This file must not quietly soften the outline the fit budget pays for:
      // the black block was a wrong *branch*, not a wrong thickness, and S4's
      // measured-equals-painted contract stays exactly where the tests left it.
      expect(strokeWidthForSize(20, sourceStrokeRatio: 0.3), 6.0);
      expect(strokeRatioFor(0.9), kStrokeRatioCeil);
      expect(strokeRatioFor(null), kDefaultStrokeRatio);
    });
  });
}
