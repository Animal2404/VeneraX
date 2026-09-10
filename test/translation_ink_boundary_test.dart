import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/image_translation/translation_performance_config.dart';
import 'package:venera/foundation/image_translation/translation_types.dart';
import 'package:venera/foundation/image_translation/translation_worker.dart';

/// Locks the **ink-boundary experiment** added for the "two bubbles' translations
/// were fused into one" complaint.
///
/// Why the rule is ink and not geometry: the narration gap inside one bubble
/// that must survive is 1.00× line thickness, while the cross-bubble gap that
/// must be split is 0.57× — so any threshold on the gap cuts the legitimate
/// narration first. The only reliable signal is the page's own ink: a bubble
/// outline is a *thin* dark stroke with bright pixels above **and** below it,
/// inside the gap band. Both of those extra conditions are what keep artwork,
/// hair and panel edges from being mistaken for an outline, and both are pinned
/// below (fixtures ③ and ④).
///
/// The experiment is **off** by default. Everything here is pure Dart over
/// synthetic pixels: no isolate, no ONNX session, no GPU (R3), no file, no
/// network.
void main() {
  /// A 200×200 RGBA page filled with [background] (r=g=b=background).
  RgbaImage page(int background) {
    final pixels = Uint8List(200 * 200 * 4);
    for (var i = 0; i < pixels.length; i += 4) {
      pixels[i] = background;
      pixels[i + 1] = background;
      pixels[i + 2] = background;
      pixels[i + 3] = 255;
    }
    return RgbaImage(200, 200, pixels);
  }

  void paint(RgbaImage image, int left, int top, int right, int bottom, int v) {
    for (var y = top; y < bottom; y++) {
      for (var x = left; x < right; x++) {
        final base = (y * image.width + x) * 4;
        image.pixels[base] = v;
        image.pixels[base + 1] = v;
        image.pixels[base + 2] = v;
      }
    }
  }

  /// Two facing horizontal lines, both 80×14 (short side = 14 px = "line
  /// thickness"). The gap band is x ∈ [24,100], y ∈ [34,40] — six rows tall.
  final upper = IntRect(20, 20, 100, 34);
  final lower = IntRect(24, 40, 104, 54);

  group('ocrInkGap: the bubble-outline discriminator', () {
    test('fixture ①: a thin dark outline across the band ⇒ refuse the merge', () {
      final image = page(255);
      // Two rows of outline (≤ 0.6 × 14 = 8 px), bright rows above and below.
      paint(image, 0, 36, 200, 38, 0);

      final verdict = ocrInkGap(image, upper, lower);

      expect(verdict.allow, isFalse);
      final gap = verdict.gap!;
      expect(gap.gapWidth, 76, reason: 'min(a.right,b.right) - max(a.left,b.left)');
      expect(gap.gapHeight, 6, reason: 'b.top - a.bottom');
      expect(gap.inkRatio, 1.0);
      expect(gap.runPx, 2);
      expect(gap.backgroundLuma, lessThan(255), reason: 'the stroke lowers the mean');
    });

    test('fixture ②: a blank band (paragraph gap inside one bubble) ⇒ allow', () {
      final verdict = ocrInkGap(page(255), upper, lower);

      expect(verdict.allow, isTrue);
      expect(verdict.gap!.inkRatio, 0.0);
      expect(verdict.gap!.runPx, 0);
    });

    test('fixture ③: a thick dark mass (taller than 0.6× line thickness) ⇒ '
        'allow, never killed as an outline', () {
      final image = page(255);
      // 12 px tall: 2× the 8 px ceiling, so it is a mass, not an outline.
      paint(image, 0, 34, 200, 46, 0);

      final verdict = ocrInkGap(image, upper, lower);

      expect(verdict.allow, isTrue);
      expect(verdict.gap!.runPx, 0, reason: 'no run is short enough to qualify');
    });

    test('fixture ④: a dark surround (black background) ⇒ allow, because the '
        'run has no bright pixel above or below', () {
      final verdict = ocrInkGap(page(0), upper, lower);

      expect(verdict.allow, isTrue);
      expect(verdict.gap!.runPx, 0);
    });

    test('a single dark row with no bright row on one side ⇒ allow', () {
      final image = page(255);
      // Flush with the bottom of the band: bright above only.
      paint(image, 0, 39, 200, 40, 0);

      expect(ocrInkGap(image, upper, lower).allow, isTrue);
    });

    test('below the 80% column share ⇒ allow', () {
      final image = page(255);
      paint(image, 0, 36, 200, 38, 0);
      // Blank out 20 of the 76 band columns (76 × 0.2 = 15.2) so only 56
      // columns carry the outline: 0.74 < 0.80.
      paint(image, 24, 34, 40, 40, 255);

      final verdict = ocrInkGap(image, upper, lower);

      expect(verdict.gap!.inkRatio, lessThan(0.8));
      expect(verdict.allow, isTrue);
    });

    test('an empty band, a single-column band and an out-of-image band are all '
        'allowed and never throw', () {
      // Boxes that touch: no band at all.
      expect(
        ocrInkGap(
          page(255),
          IntRect(20, 20, 100, 34),
          IntRect(20, 34, 100, 54),
        ).allow,
        isTrue,
      );
      // Boxes that overlap vertically: not a facing pair.
      expect(
        ocrInkGap(
          page(255),
          IntRect(20, 20, 100, 34),
          IntRect(20, 30, 100, 54),
        ).allow,
        isTrue,
      );
      // Boxes side by side: no vertical gap.
      expect(
        ocrInkGap(
          page(255),
          IntRect(20, 20, 40, 34),
          IntRect(60, 20, 90, 34),
        ).allow,
        isTrue,
      );
      // One column of overlap only.
      final singleColumn = ocrInkGap(
        page(255),
        IntRect(20, 20, 60, 34),
        IntRect(59, 40, 90, 54),
      );
      expect(singleColumn.allow, isTrue);
      // Entirely off the page.
      final offPage = ocrInkGap(
        page(255),
        IntRect(500, 500, 600, 514),
        IntRect(500, 520, 600, 534),
      );
      expect(offPage.allow, isTrue);
      expect(offPage.gap, isNull);
    });
  });

  group('clusterOcrBoxes: the switch off is byte-identical to no switch', () {
    final boxes = [IntRect(20, 20, 100, 34), IntRect(24, 40, 104, 54)];

    test('pixels cannot change the grouping while the switch is off', () {
      final blank = page(255);
      final outlined = page(255);
      paint(outlined, 0, 36, 200, 38, 0);

      final fromBlank = clusterOcrBoxes(
        boxes,
        200,
        200,
        pageIndex: 0,
        image: blank,
      );
      final fromOutline = clusterOcrBoxes(
        boxes,
        200,
        200,
        pageIndex: 0,
        image: outlined,
      );

      expect(fromBlank, hasLength(1));
      expect(
        fromOutline.map((g) => g.length).toList(),
        fromBlank.map((g) => g.length).toList(),
        reason: 'default off ⇒ the ink verdict is logged, never applied',
      );
    });

    test('passing no image at all reproduces the pre-experiment signature', () {
      final withoutImage = clusterOcrBoxes(boxes, 200, 200);
      final withImage = clusterOcrBoxes(
        boxes,
        200,
        200,
        pageIndex: 0,
        image: page(0),
      );

      expect(withoutImage, hasLength(1));
      expect(withImage, hasLength(1));
    });

    test('the audit is still measured with the switch off, so the log can '
        'answer "what would it have done?"', () {
      clearOcrInkTraces();
      final outlined = page(255);
      paint(outlined, 0, 36, 200, 38, 0);

      clusterOcrBoxes(boxes, 200, 200, pageIndex: 7, image: outlined);

      final trace = takeOcrInkTrace(7)!;
      expect(trace.pageIndex, 7);
      expect(trace.candidates, 1);
      expect(trace.rejected, 1);
      expect(trace.details, hasLength(1));
      final line = trace.line();
      expect(line, startsWith('OcrInk page=7 candidates=1 rejected=1 details=['));
      expect(line, contains('gap=76x6'));
      expect(line, contains('ink=1.00'));
      expect(line, contains('run=2px'));
      expect(line, contains('bg='));
      expect(line, isNot(contains('\n')));
    });

    test('the trace is consumed once, keyed by page, and details are capped at '
        '3', () {
      clearOcrInkTraces();
      final outlined = page(255);
      // Five stacked lines, 20 px apart. Every consecutive pair is a *facing*
      // pair: box height 14 and pitch 20 leave a 6 px band between them, so
      // there are four candidate gaps (not one).
      final five = [
        IntRect(20, 20, 100, 34),
        IntRect(24, 40, 104, 54),
        IntRect(24, 60, 104, 74),
        IntRect(24, 80, 104, 94),
        IntRect(24, 100, 104, 114),
      ];
      // Each band gets the bubble-outline stroke the probe is built to refuse:
      // a 2 px dark run with a bright row on both sides, well under the 0.6 ×
      // 14 = 8 px run ceiling. Painting only one band — which this fixture used
      // to do — leaves the other three gaps blank, so the probe *allows* those
      // merges and the trace honestly reports one rejection. The rejection
      // count is therefore a property of the pixels, and this test pins it by
      // giving every candidate the stroke.
      for (var i = 0; i + 1 < five.length; i++) {
        final gapTop = five[i].bottom;
        paint(outlined, 0, gapTop + 2, 200, gapTop + 4, 0);
      }

      clusterOcrBoxes(five, 200, 200, pageIndex: 3, image: outlined);

      final trace = takeOcrInkTrace(3)!;
      expect(trace.candidates, 4, reason: 'four facing pairs, four bands');
      expect(trace.rejected, 4);
      expect(trace.details.length, OcrInkTrace.maxDetails);
      expect(trace.line(), contains('more]'));
      expect(takeOcrInkTrace(3), isNull, reason: 'read once');
    });
  });

  group('side-by-side pairs: the layout vertical text actually presents', () {
    // Two columns of vertical text, 20 px wide and 120 px tall, 20 px apart —
    // the geometry of two neighbouring bubbles on a page whose text runs
    // vertically. Short side = 20 px, so the "thin run" ceiling is
    // 0.6 × 20 = 12 px, and the gap band is x ∈ [40,60), y ∈ [20,140).
    final leftColumn = IntRect(20, 20, 40, 140);
    final rightColumn = IntRect(60, 20, 80, 140);

    test('fixture ⑤: a thin vertical outline across the band ⇒ refuse', () {
      final image = page(255);
      paint(image, 48, 0, 50, 200, 0);

      final verdict = ocrInkGapSide(image, leftColumn, rightColumn);

      expect(verdict.allow, isFalse);
      final gap = verdict.gap!;
      expect(gap.gapWidth, 20, reason: 'the band is 20 px wide');
      expect(gap.gapHeight, 120, reason: 'the two columns overlap for 120 px');
      expect(gap.inkRatio, 1.0);
      expect(gap.runPx, 2);
    });

    test('fixture ⑥: a blank band (two columns of one bubble) ⇒ allow', () {
      final verdict = ocrInkGapSide(page(255), leftColumn, rightColumn);

      expect(verdict.allow, isTrue);
      expect(verdict.gap!.inkRatio, 0.0);
    });

    test('fixture ⑦: a wide dark mass ⇒ allow, never read as an outline', () {
      final image = page(255);
      // 16 px wide, over the 0.6 × 20 = 12 px ceiling: a mass, not a stroke.
      paint(image, 44, 0, 60, 200, 0);

      final verdict = ocrInkGapSide(image, leftColumn, rightColumn);

      expect(verdict.allow, isTrue);
      expect(verdict.gap!.runPx, 0);
    });

    test('fixture ⑧: a black page ⇒ allow, no bright pixel on either side', () {
      final verdict = ocrInkGapSide(page(0), leftColumn, rightColumn);

      expect(verdict.allow, isTrue);
      expect(verdict.gap!.runPx, 0);
    });

    test('pairs with no band between them are allowed and never throw', () {
      // Touching side by side.
      expect(
        ocrInkGapSide(
          page(255),
          IntRect(20, 20, 40, 140),
          IntRect(40, 20, 60, 140),
        ).allow,
        isTrue,
      );
      // Overlapping sideways.
      expect(
        ocrInkGapSide(
          page(255),
          IntRect(20, 20, 40, 140),
          IntRect(30, 20, 60, 140),
        ).allow,
        isTrue,
      );
      // Boxes that share no rows at all: the strip is empty.
      final noOverlap = ocrInkGapSide(
        page(255),
        IntRect(20, 500, 40, 620),
        IntRect(60, 700, 80, 820),
      );
      expect(noOverlap.allow, isTrue);
      expect(noOverlap.gap, isNull);
    });

    test('the switch decides: identical pixels, one block or two', () {
      final key = TranslationPerformanceConfig.inkBoundarySplitSettingKey;
      addTearDown(() => appdata.settings[key] = null);
      final outlined = page(255);
      paint(outlined, 48, 0, 50, 200, 0);

      appdata.settings[key] = false;
      final joined = clusterOcrBoxes(
        [leftColumn, rightColumn],
        200,
        200,
        pageIndex: 0,
        image: outlined,
      );
      expect(
        joined,
        hasLength(1),
        reason: 'switch off ⇒ the verdict is measured and logged, never applied',
      );
      final trace = takeOcrInkTrace(0)!;
      expect(trace.candidates, 1, reason: 'the side-by-side pair is a candidate now');
      expect(trace.rejected, 1);
      expect(trace.line(), contains('gap=20x120'));

      appdata.settings[key] = true;
      final split = clusterOcrBoxes(
        [leftColumn, rightColumn],
        200,
        200,
        pageIndex: 1,
        image: outlined,
      );
      expect(
        split,
        hasLength(2),
        reason: 'the outline says these two columns are in different bubbles',
      );

      final blank = page(255);
      final stillJoined = clusterOcrBoxes(
        [leftColumn, rightColumn],
        200,
        200,
        pageIndex: 2,
        image: blank,
      );
      expect(
        stillJoined,
        hasLength(1),
        reason: 'switch on but no outline ⇒ merge exactly as before',
      );
    });
  });

  group('the switch itself', () {
    test('defaults to false for every value that is not a literal true', () {
      expect(TranslationPerformanceConfig.inkBoundarySplitFromSetting(null), isFalse);
      expect(TranslationPerformanceConfig.inkBoundarySplitFromSetting('true'), isFalse);
      expect(TranslationPerformanceConfig.inkBoundarySplitFromSetting(1), isFalse);
      expect(TranslationPerformanceConfig.inkBoundarySplitFromSetting(false), isFalse);
      expect(TranslationPerformanceConfig.inkBoundarySplitFromSetting(true), isTrue);
    });

    test('has its own setting key, outside the preset value table', () {
      expect(
        TranslationPerformanceConfig.inkBoundarySplitSettingKey,
        'imageTranslationInkBoundarySplit',
      );
      expect(
        TranslationPerformanceConfig.inkBoundarySplitSettingKey,
        isNot(TranslationPerformanceConfig.settingKey),
      );
      expect(
        TranslationPerformanceConfig.inkBoundarySplitSettingKey,
        isNot(TranslationPerformanceConfig.pipelineModeSettingKey),
      );
    });
  });
}
