import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/image_translation/page_renderer.dart';

/// S1 acceptance: a block that cannot be laid out must **decline**, not paint.
///
/// Before this, `_fitFontSize` returned the 4px floor when nothing fitted, the
/// text was drawn anyway, and the renderer's `clipRect` cut off whatever
/// overflowed — so a too-small bubble silently produced unreadable glyphs or a
/// half sentence, and the user was never told. Every case below pins one arm of
/// that decision, especially `keepOriginal`, whose whole meaning is "erase
/// nothing, draw nothing, report it".
void main() {
  const page = ui.Size(1000, 1000);
  final box = ui.Rect.fromLTWH(100, 100, 120, 40);

  // Rect defaults cannot be `const`, so the shared box is applied inside.
  OverflowDecision decide({
    bool fits = false,
    ui.Rect? box_,
    ui.Rect? erase,
    List<ui.Rect> neighbours = const [],
    double size = 4,
    required bool Function(ui.Rect box, bool vertical) fitsIn,
    bool vertical = false,
    double cjkRatio = 1.0,
  }) {
    final rect = box_ ?? box;
    return decideOverflow(
    fits: fits,
    rect: rect,
    eraseBounds: erase ?? rect,
    neighborRects: neighbours,
    size: size,
    pageWidth: page.width,
    pageHeight: page.height,
    fitsIn: fitsIn,
    vertical: vertical,
    cjkRatio: cjkRatio,
  );
  }

  test('a block that already fits just shrinks', () {
    expect(
      decide(fits: true, size: 99, fitsIn: (_, _) => false),
      OverflowDecision.shrinkToFit,
      reason: 'nothing to escalate when it already fits',
    );
  });

  test('still above the readable floor: keep shrinking, do not escalate', () {
    expect(
      decide(size: minReadableGlyphSize + 6, fitsIn: (_, _) => false),
      OverflowDecision.shrinkToFit,
      reason: 'throwing away legible size early is the old bug in reverse',
    );
  });

  test('bottomed out with clear gutter grows into the gutter', () {
    // No neighbours: the box may expand, and the grown box reports fitting.
    final d = decide(
      size: minReadableGlyphSize,
      fitsIn: (b, v) => b.width > box.width,
    );
    expect(d, OverflowDecision.expandRect);
  });

  test('growth is capped, and growth that does not help is refused', () {
    // The box can grow (page is huge) but even the grown box does not fit:
    // expanding would only punch a bigger hole for no benefit.
    final d = decide(
      size: minReadableGlyphSize,
      fitsIn: (_, _) => false,
    );
    expect(d, isNot(OverflowDecision.expandRect));
  });

  test('a narrow tall CJK block turns vertical instead of shrinking away', () {
    final tall = ui.Rect.fromLTWH(100, 100, 40, 260);
    final d = decide(
      box_: tall,
      size: minReadableGlyphSize,
      // Surround it so growing is genuinely unavailable.
      neighbours: [
        ui.Rect.fromLTWH(0, 0, 100, 1000),
        ui.Rect.fromLTWH(140, 0, 100, 1000),
      ],
      fitsIn: (_, v) => v,
    );
    expect(d, OverflowDecision.switchOrientation);
  });

  test('a short stubby block is not turned vertical', () {
    final wide = ui.Rect.fromLTWH(100, 100, 260, 40);
    final d = decide(
      box_: wide,
      size: minReadableGlyphSize,
      neighbours: [
        ui.Rect.fromLTWH(0, 0, 100, 1000),
        ui.Rect.fromLTWH(360, 0, 100, 1000),
      ],
      fitsIn: (_, v) => v,
    );
    expect(d, isNot(OverflowDecision.switchOrientation));
  });

  test('latin-heavy blocks stay horizontal', () {
    final tall = ui.Rect.fromLTWH(100, 100, 40, 260);
    final d = decide(
      box_: tall,
      size: minReadableGlyphSize,
      neighbours: [
        ui.Rect.fromLTWH(0, 0, 100, 1000),
        ui.Rect.fromLTWH(140, 0, 100, 1000),
      ],
      fitsIn: (_, v) => v,
      cjkRatio: 0.1,
    );
    expect(d, isNot(OverflowDecision.switchOrientation));
  });

  test('when every option fails, keep the original artwork', () {
    final d = decide(
      size: minReadableGlyphSize,
      neighbours: [
        ui.Rect.fromLTWH(0, 0, 100, 1000),
        ui.Rect.fromLTWH(140, 0, 100, 1000),
      ],
      fitsIn: (_, _) => false,
    );
    expect(d, OverflowDecision.keepOriginal);
  });

  test('keepOriginal covers the erase footprint, never the reverse', () {
    // A box sitting inside a bigger erase area must not be able to shrink the
    // cleaned region: lettering that escaped the detection box still has to be
    // covered, or the reader sees a hole punched in the art.
    final big = ui.Rect.fromLTWH(80, 80, 200, 120);
    final grown = safeGrowRect(
      rect: box,
      eraseBounds: big,
      obstacles: const [],
      pageWidth: page.width,
      pageHeight: page.height,
    );
    expect(grown.left, lessThanOrEqualTo(big.left));
    expect(grown.top, lessThanOrEqualTo(big.top));
    expect(grown.right, greaterThanOrEqualTo(big.right));
    expect(grown.bottom, greaterThanOrEqualTo(big.bottom));
  });

  test('an overlapping neighbour leaves no slack on that side', () {
    final overlapping = ui.Rect.fromLTWH(110, 110, 20, 20);
    final grown = safeGrowRect(
      rect: box,
      eraseBounds: box,
      obstacles: [overlapping],
      pageWidth: page.width,
      pageHeight: page.height,
    );
    // It must not expand past the obstacle it already touches.
    expect(grown.left, lessThanOrEqualTo(110));
  });
}
