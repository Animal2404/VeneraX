import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/image_translation/page_renderer.dart';
import 'package:venera/foundation/image_translation/translation_types.dart';

/// S4 acceptance: the outline is paid for *before* the size is chosen.
///
/// The old renderer measured a stroke-free glyph run, then hung an outline of
/// `max(1.5, size × 0.14)` off the outside of that measurement — so a block
/// whose source lettering carried a heavy outline rendered at a size the
/// outline immediately ate, and the visual weight of the translation fell far
/// below the source. Every case below pins one link of the new chain:
/// ratio resolution → width → budget → probe → end-to-end size choice.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // --- pure stroke API -------------------------------------------------------

  group('strokeRatioFor', () {
    test('nothing detected falls back to the historical default ratio', () {
      expect(strokeRatioFor(null), kDefaultStrokeRatio);
    });

    test('garbage detections are refused, not multiplied through', () {
      expect(strokeRatioFor(double.nan), kDefaultStrokeRatio);
      expect(strokeRatioFor(double.infinity), kDefaultStrokeRatio);
    });

    test('detected ratios are clamped into the plausible band', () {
      expect(strokeRatioFor(0.9), kStrokeRatioCeil);
      expect(strokeRatioFor(0.001), kStrokeRatioFloor);
      expect(strokeRatioFor(0.25), 0.25);
    });
  });

  group('strokeWidthForSize', () {
    test('scales with the glyph at the default ratio', () {
      expect(strokeWidthForSize(20), 20 * kDefaultStrokeRatio);
    });

    test('a heavy source ratio thickens the outline', () {
      expect(strokeWidthForSize(20, sourceStrokeRatio: 0.3), 6.0);
      expect(
        strokeWidthForSize(20, sourceStrokeRatio: 0.3),
        greaterThan(strokeWidthForSize(20)),
      );
    });

    test('never thinner than the visibility floor', () {
      expect(strokeWidthForSize(4), kMinStrokeWidth);
    });
  });

  group('strokeInset / column geometry', () {
    test('unoutlined blocks keep the flat padding', () {
      expect(strokeInset(20, false), 4.0);
    });

    test('outlined blocks reserve exactly the stroke that will be painted',
        () {
      expect(
        strokeInset(20, true, sourceStrokeRatio: 0.3),
        4.0 + strokeWidthForSize(20, sourceStrokeRatio: 0.3),
      );
    });

    test('columns widen by the stroke, pitch and gutter alike', () {
      expect(columnPitchFor(20, 0), 20 * 1.15);
      expect(columnPitchFor(20, 3), 20 * 1.15 + 3);
      expect(columnWidthFor(20, 3), 20 * 1.2 + 3);
    });
  });

  // --- the point-size oracle -------------------------------------------------

  group('fitsRegionAt budgets the stroke (horizontal)', () {
    // 12 CJK glyphs, one line at the tested size; the box height is chosen so
    // that the 42px rung fits with the default 5.9px outline but not with the
    // 14.7px outline a 0.35 ratio demands. The width carries a ~7% margin
    // over the widest plausible CJK advance, so only the height decides —
    // height arithmetic, no font guess.
    final region = TranslatedRegion(
      rect: IntRect(0, 0, 560, 65),
      text: '汉字刚好占满一行测试预算',
      backgroundColor: 0xFFFFFFFF,
      textColor: 0xFF000000,
    );
    final box = ui.Rect.fromLTWH(0, 0, 560, 65);

    test('the same size fits without the stroke but not with it', () {
      expect(
        fitsRegionAt(region, box, vertical: false, size: 42),
        isTrue,
        reason: 'availH = 65 - 4 - 42×0.14 = 55.1 ≥ 42×1.2 = 50.4',
      );
      expect(
        fitsRegionAt(
          region,
          box,
          vertical: false,
          size: 42,
          sourceStrokeRatio: 0.35,
        ),
        isFalse,
        reason: 'availH = 65 - 4 - 14.7 = 46.3 < 50.4: the outline eats the box',
      );
    });
  });

  group('fitsRegionAt budgets the stroke (vertical)', () {
    // Pure arithmetic in the column model: 12 cells, box 60×200.
    final region = TranslatedRegion(
      rect: IntRect(0, 0, 60, 200),
      text: '十二个汉字竖排给描边留位',
      backgroundColor: 0xFFFFFFFF,
      textColor: 0xFF000000,
    );
    final box = ui.Rect.fromLTWH(0, 0, 60, 200);

    test('a size the default stroke fits, the heavy stroke does not', () {
      // Default: stroke 2.69 → availW 53.3; pitch 22.08+2.69=24.77 → 7 per
      // column; column width 25.73 → 12 cells = 2 columns → 51.5 ≤ 53.3 ✓
      expect(fitsRegionAt(region, box, vertical: true, size: 19.2), isTrue);
      // Heavy 0.35: stroke 6.72 → availW 49.3; column width 23.04+6.72=29.8
      // → 2 columns need 59.5 ✗ — before S4 the stroke was never asked.
      expect(
        fitsRegionAt(
          region,
          box,
          vertical:
              true,
          size: 19.2,
          sourceStrokeRatio: 0.35,
        ),
        isFalse,
      );
    });
  });

  // --- end-to-end: planRegions picks smaller for heavy strokes ---------------

  group('planRegions sizes shrink when the source stroke is heavy', () {
    final region = TranslatedRegion(
      rect: IntRect(100, 100, 660, 165),
      text: '汉字刚好占满一行测试预算',
      backgroundColor: 0xFFFFFFFF,
      textColor: 0xFF000000,
    );
    const page = ui.Size(1000, 1000);

    test('horizontal: a thick budgeted outline costs rungs, not pixels', () {
      final light = planRegions([region], page, normalizeGroups: false)[0];
      final heavy = planRegions(
        [region],
        page,
        strokeRatios: {0: 0.35},
        normalizeGroups: false,
      )[0];

      expect(light.size, greaterThan(0), reason: 'baseline must paint');
      expect(heavy.size, greaterThan(0), reason: 'still legible: shrink, keep');
      expect(
        heavy.size,
        lessThan(light.size),
        reason: 'the heavy ring costs the 42px rung it used to fake',
      );
      expect(heavy.sourceStrokeRatio, 0.35);
      expect(
        fitsRegionAt(
          region,
          heavy.box,
          vertical: heavy.vertical,
          size: heavy.size,
          sourceStrokeRatio: 0.35,
        ),
        isTrue,
        reason: 'whatever it chose, it chose it *with* the stroke',
      );
    });

    test('vertical: the column model now pays for the outline too', () {
      final tall = TranslatedRegion(
        rect: IntRect(100, 100, 160, 300),
        text: '十二个汉字竖排也要给描边留位置',
        backgroundColor: 0xFFFFFFFF,
        textColor: 0xFF000000,
      );
      final light = planRegions([tall], page, normalizeGroups: false)[0];
      final heavy = planRegions(
        [tall],
        page,
        strokeRatios: {0: 0.35},
        normalizeGroups: false,
      )[0];
      expect(light.vertical, isTrue, reason: 'narrow + tall + CJK: a column');
      expect(heavy.size, lessThan(light.size));
      expect(
        fitsRegionAt(
          tall,
          heavy.box,
          vertical: true,
          size: heavy.size,
          sourceStrokeRatio: 0.35,
        ),
        isTrue,
      );
    });

    test('a default-ish detection changes nothing (ratio 0.14 == null)', () {
      final a = planRegions([region], page, normalizeGroups: false)[0];
      final b = planRegions(
        [region],
        page,
        strokeRatios: {0: 0.14},
        normalizeGroups: false,
      )[0];
      expect(b.size, a.size);
      expect(b.sourceStrokeRatio, 0.14);
    });

    test('no stroke info keeps the pre-S4 behaviour exactly', () {
      expect(
        planRegions([region], page, normalizeGroups: false)[0].size,
        planRegions(
          [region],
          page,
          strokeRatios: {},
          normalizeGroups: false,
        )[0].size,
      );
    });
  });

  // --- the source-artwork probe ----------------------------------------------

  group('estimateStrokeRatio on synthetic lettering', () {
    // White canvas; "ink" differs from 0xFFFFFFFF by more than the threshold.
    Uint8List canvas(int w, int h) {
      final px = Uint8List(w * h * 4);
      for (var i = 0; i < w * h; i++) {
        px[i * 4] = 255;
        px[i * 4 + 1] = 255;
        px[i * 4 + 2] = 255;
        px[i * 4 + 3] = 255;
      }
      return px;
    }

    void ring(
      Uint8List px,
      int w,
      int left,
      int top,
      int outerW,
      int outerH,
      int thickness,
    ) {
      for (var y = top; y < top + outerH; y++) {
        for (var x = left; x < left + outerW; x++) {
          final inHole =
              x >= left + thickness &&
              x < left + outerW - thickness &&
              y >= top + thickness &&
              y < top + outerH - thickness;
          if (inHole) continue;
          final i = (y * w + x) * 4;
          px[i] = 0;
          px[i + 1] = 0;
          px[i + 2] = 0;
        }
      }
    }

    test('a 10px outline on 40px lettering measures ≈ 0.25', () {
      final px = canvas(120, 120);
      ring(px, 120, 30, 40, 60, 40, 10);
      final est = estimateStrokeRatio(
        rgba: px,
        width: 120,
        height: 120,
        box: IntRect(25, 35, 95, 85),
        backgroundArgb: 0xFFFFFFFF,
        referenceSizePx: 40,
      );
      expect(est.inkArea, greaterThan(1000));
      expect(est.ratio, isNotNull);
      expect(est.ratio!, inInclusiveRange(0.18, 0.32));
    });

    test('a hairline 2px outline stays light', () {
      final px = canvas(120, 120);
      ring(px, 120, 30, 40, 60, 40, 2);
      final est = estimateStrokeRatio(
        rgba: px,
        width: 120,
        height: 120,
        box: IntRect(25, 35, 95, 85),
        backgroundArgb: 0xFFFFFFFF,
        referenceSizePx: 40,
      );
      expect(est.ratio, isNotNull);
      expect(est.ratio!, lessThan(0.08));
    });

    test('an empty sample says nothing', () {
      final px = canvas(120, 120);
      final est = estimateStrokeRatio(
        rgba: px,
        width: 120,
        height: 120,
        box: IntRect(20, 20, 100, 100),
        backgroundArgb: 0xFFFFFFFF,
        referenceSizePx: 40,
      );
      expect(est.ratio, isNull);
    });

    test('a solid blob is not lettering: implausible thickness → no answer',
        () {
      final px = canvas(120, 120);
      for (var y = 20; y < 100; y++) {
        for (var x = 20; x < 100; x++) {
          final i = (y * 120 + x) * 4;
          px[i] = 0;
          px[i + 1] = 0;
          px[i + 2] = 0;
        }
      }
      final est = estimateStrokeRatio(
        rgba: px,
        width: 120,
        height: 120,
        box: IntRect(15, 15, 105, 105),
        backgroundArgb: 0xFFFFFFFF,
        referenceSizePx: 40,
      );
      expect(est.ratio, isNull);
    });

    test('boxes clipped out of the image cannot crash the probe', () {
      final px = canvas(60, 60);
      final est = estimateStrokeRatio(
        rgba: px,
        width: 60,
        height: 60,
        box: IntRect(-30, 40, 200, 900),
        backgroundArgb: 0xFFFFFFFF,
        referenceSizePx: 40,
      );
      expect(est.ratio, isNull);
    });

    test('big blocks survive the sampling grid and keep the ratio honest', () {
      // 600×400 ring, 30px stroke, far above maxSamples → stride > 1. Grid
      // erosion measures in stride units and scales back; ±1 cell of
      // aliasing must not move the verdict out of band.
      final px = canvas(640, 440);
      ring(px, 640, 20, 20, 600, 400, 30);
      final est = estimateStrokeRatio(
        rgba: px,
        width: 640,
        height: 440,
        box: IntRect(15, 15, 625, 425),
        backgroundArgb: 0xFFFFFFFF,
        referenceSizePx: 400,
        maxSamples: 20000,
      );
      expect(est.ratio, isNotNull);
      expect(est.ratio!, inInclusiveRange(0.05, 0.11));
    });

    test('a dark background measures the white ink around it', () {
      // 0xFF000000 canvas, white ring: the *distance* to backgroundArgb is
      // what matters, not the sign of the contrast.
      final px = Uint8List(120 * 120 * 4);
      for (var i = 0; i < 120 * 120; i++) {
        px[i * 4 + 3] = 255;
      }
      ring(px, 120, 30, 40, 60, 40, 10);
      // ring() paints black — invert it manually into white on black:
      for (var y = 40; y < 80; y++) {
        for (var x = 30; x < 90; x++) {
          final inHole =
              x >= 40 && x < 80 && y >= 50 && y < 70;
          final i = (y * 120 + x) * 4;
          final v = inHole ? 0 : 255;
          px[i] = v;
          px[i + 1] = v;
          px[i + 2] = v;
        }
      }
      final est = estimateStrokeRatio(
        rgba: px,
        width: 120,
        height: 120,
        box: IntRect(25, 35, 95, 85),
        backgroundArgb: 0xFF000000,
        referenceSizePx: 40,
      );
      expect(est.ratio, isNotNull);
      expect(est.ratio!, inInclusiveRange(0.18, 0.32));
    });
  });

  group('detectStrokeRatios is unfailable by design', () {
    test('empty source bytes → no measurements, no throw', () async {
      final decoded = RgbaImage(10, 10, Uint8List(10 * 10 * 4));
      final out = await detectStrokeRatios(Uint8List(0), decoded, [
        TranslatedRegion(
          rect: IntRect(0, 0, 8, 8),
          text: 'x',
          backgroundColor: 0xFFFFFFFF,
          textColor: 0xFF000000,
        ),
      ]);
      expect(out, isEmpty);
    });

    test('undecodable bytes are logged and swallowed, never fatal', () async {
      final decoded = RgbaImage(10, 10, Uint8List(10 * 10 * 4));
      final out = await detectStrokeRatios(
        Uint8List.fromList([1, 2, 3, 4, 5]),
        decoded,
        [
          TranslatedRegion(
            rect: IntRect(0, 0, 8, 8),
            text: 'x',
            backgroundColor: 0xFFFFFFFF,
            textColor: 0xFF000000,
          ),
        ],
      );
      expect(out, isEmpty);
    });
  });
}
