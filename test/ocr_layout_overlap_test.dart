import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/image_translation/page_renderer.dart';
import 'package:venera/foundation/image_translation/translation_types.dart';

/// Defect B: two bubbles whose lettering interleaves.
///
/// [resolveRegionCollisions] (merged in 9e50326) folds a pair of regions into
/// one only above 35% overlap (15% when the texts are identical). That leaves a
/// grey zone — and, more importantly, a **hole**: [safeGrowRect] does treat
/// neighbours as obstacles, but it is only consulted by the *growth* path
/// ([decideOverflow] calls it after the shrink search has bottomed out, and
/// [planRegions] re-reads it at line "if (decision == expandRect)"). A block
/// that fits its own detected box never goes through it, so two detected boxes
/// that overlap by less than the merge gate both paint, centred, into the same
/// band.
///
/// So the geometry evidence this file asks for is: which of the two is it? The
/// fixtures below are built at a coverage the merge demonstrably declines, and
/// the assertion is the one the user asked for — **no pixel area of the page is
/// covered by two blocks of text**, which follows from the painted boxes being
/// disjoint (ink never leaves its box: [_placeText] clips to it and nothing
/// paints without having measured a fit inside it).
///
/// NOT VERIFIED LOCALLY (no `flutter test` in this workspace) — see the
/// "待云端 Test job 验证" list.

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

const _page = ui.Size(1200, 1600);

ui.Rect _rectOf(IntRect r) => ui.Rect.fromLTRB(
  r.left.toDouble(),
  r.top.toDouble(),
  r.right.toDouble(),
  r.bottom.toDouble(),
);

/// Every pair of *painting* placements must have a disjoint box.
void _expectNoDoubleCoverage(List<Placement> placements) {
  final painted = placements.where((p) => p.paints).toList();
  for (var i = 0; i < painted.length; i++) {
    for (var j = i + 1; j < painted.length; j++) {
      final inter = painted[i].box.intersect(painted[j].box);
      expect(
        inter.isEmpty,
        isTrue,
        reason:
            'no pixel area may be covered by two blocks of text: '
            '${painted[i].box} vs ${painted[j].box} overlap by $inter',
      );
    }
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('grey-zone overlap — the hole the merge gate leaves open', () {
    // Two bubbles side by side. The detector's component boxes bite into each
    // other by 30px: 30·80 = 2400px of the smaller box's 16000 → 15%, which is
    // *below* kMergeOverlapCov and above kMergeDuplicateCov, and the texts are
    // different, so neither merge rule fires.
    final left = _region(IntRect(100, 100, 300, 180), '左边的气泡里有六个汉字');
    final right = _region(IntRect(270, 100, 470, 180), '右边气泡里也是六个汉字');

    test('precondition: the merge really does decline this pair', () {
      final out = resolveRegionCollisions([left, right]);
      expect(
        out,
        hasLength(2),
        reason: 'below kMergeOverlapCov, so this is the grey zone',
      );
      final a = _rectOf(left.rect), b = _rectOf(right.rect);
      final inter = a.intersect(b);
      final smaller = a.width * a.height < b.width * b.height
          ? a.width * a.height
          : b.width * b.height;
      final cov = inter.width * inter.height / smaller;
      expect(cov, greaterThan(0));
      expect(cov, lessThan(kMergeOverlapCov));
    });

    test('the plan resolves it: nothing covers the same pixel twice', () {
      final placements = planRegions([left, right], _page);
      _expectNoDoubleCoverage(placements);
    });

    test('and it resolves it without clipping or inventing a placement', () {
      final placements = planRegions([left, right], _page);
      for (final p in placements) {
        if (!p.paints) continue;
        // Page-bound: a step aside may never leave the artwork.
        expect(p.box.left, greaterThanOrEqualTo(0));
        expect(p.box.top, greaterThanOrEqualTo(0));
        expect(p.box.right, lessThanOrEqualTo(_page.width));
        expect(p.box.bottom, lessThanOrEqualTo(_page.height));
        // No clipping: the block must have *measured* a fit in the box it is
        // going to paint into — the same oracle the paint path uses.
        final region = [left, right][p.index];
        expect(
          fitsRegionAt(
            region,
            p.box,
            vertical: p.vertical,
            size: p.size,
            outlined: true,
            sourceStrokeRatio: p.sourceStrokeRatio,
          ),
          isTrue,
          reason: 'a painting box must hold its own text at its own size',
        );
      }
    });
  });

  group('resolvePlacementOverlaps — the three moves, in the order of cost', () {
    Placement paint(int i, ui.Rect box, {double size = 20}) => Placement(
      index: i,
      box: box,
      size: size,
      vertical: false,
      decision: OverflowDecision.shrinkToFit,
    );

    test('1. a grown box gives the borrowed gutter back first', () {
      // Block 0's detected box ends at x=200; its *grown* box reaches into
      // block 1, whose own box starts at x=260.
      final regions = [
        _region(IntRect(100, 100, 200, 180), '第一块'),
        _region(IntRect(260, 100, 360, 180), '第二块'),
      ];
      final placements = [
        paint(0, const ui.Rect.fromLTRB(100, 100, 300, 180)),
        paint(1, const ui.Rect.fromLTRB(260, 100, 360, 180)),
      ];
      final out = resolvePlacementOverlaps(
        placements: placements,
        regions: regions,
        page: _page,
      );
      _expectNoDoubleCoverage(out);
      // The *neighbour* was never touched: only the box that had borrowed
      // extra gutter is allowed to shrink, and it shrinks to the cut line.
      expect(out[1].box, const ui.Rect.fromLTRB(260, 100, 360, 180));
      expect(out[0].box.right, lessThanOrEqualTo(260));
      expect(out[0].box.left, 100, reason: 'its own edge is not moved');
    });

    test('2. with free gutter on its far side, a block steps aside', () {
      // Neither box borrowed anything, so there is nothing to give back; the
      // trailing block has the whole page to its right, so the second move is
      // available and it is the one that keeps both texts at full width.
      final regions = [
        _region(IntRect(0, 100, 120, 180), '贴边的一块文字内容'),
        _region(IntRect(90, 100, 210, 180), '压在它上面的一块'),
      ];
      final out = resolvePlacementOverlaps(
        placements: [
          paint(0, const ui.Rect.fromLTRB(0, 100, 120, 180)),
          paint(1, const ui.Rect.fromLTRB(90, 100, 210, 180)),
        ],
        regions: regions,
        page: _page,
      );
      _expectNoDoubleCoverage(out);
      // The leading block is never the one moved: reading order stays in order.
      expect(out[0].box, const ui.Rect.fromLTRB(0, 100, 120, 180));
      expect(
        out[1].box.left,
        greaterThan(90),
        reason: 'the trailing box slid forward instead of being cut',
      );
      expect(out[1].box.width, 120, reason: 'a move costs no width');
      for (final p in out.where((p) => p.paints)) {
        expect(p.box.left, greaterThanOrEqualTo(0));
        expect(p.box.top, greaterThanOrEqualTo(0));
        expect(p.box.right, lessThanOrEqualTo(_page.width));
        expect(p.box.bottom, lessThanOrEqualTo(_page.height));
      }
    });

    test('3. with nowhere to step, two colliding floors share the band', () {
      // The trailing box is pinned against the right edge of the page, so its
      // own envelope offers no room to slide: the pass must fall back to
      // splitting the band — both boxes shrink, neither moves, nothing leaves
      // the artwork.
      const page = ui.Size(500, 600);
      final regions = [
        _region(IntRect(100, 100, 300, 180), '左边的气泡里有六个汉字'),
        _region(IntRect(270, 100, 500, 180), '右边气泡里也是六个汉字'),
      ];
      final out = resolvePlacementOverlaps(
        placements: [
          paint(0, const ui.Rect.fromLTRB(100, 100, 300, 180)),
          paint(1, const ui.Rect.fromLTRB(270, 100, 500, 180)),
        ],
        regions: regions,
        page: page,
      );
      _expectNoDoubleCoverage(out);
      expect(out[0].box.left, 100, reason: 'nothing was pushed off anything');
      expect(out[1].box.right, 500, reason: 'the pinned edge stayed put');
      expect(out[0].box.right, out[1].box.left, reason: 'tangent, not apart');
      expect(out[0].box.right, 285, reason: 'the band is split down the middle');
      // A block whose reduced box can no longer hold its text is *not drawn*
      // (S1's keepOriginal) rather than squeezed or clipped.
      for (final p in out) {
        if (p.decision == OverflowDecision.keepOriginal) {
          expect(p.paints, isFalse);
          expect(p.size, 0);
        }
      }
    });

    test('a page with no collision comes back as the same list object', () {
      final regions = [
        _region(IntRect(100, 100, 200, 160), '第一块'),
        _region(IntRect(300, 300, 420, 360), '第二块'),
      ];
      final placements = [
        paint(0, const ui.Rect.fromLTRB(100, 100, 200, 160)),
        paint(1, const ui.Rect.fromLTRB(300, 300, 420, 360)),
      ];
      expect(
        identical(
          resolvePlacementOverlaps(
            placements: placements,
            regions: regions,
            page: _page,
          ),
          placements,
        ),
        isTrue,
        reason: 'untouched means untouched: no re-measure, no re-decide',
      );
    });

    test('a block that was already keeping its original is left alone', () {
      // keepOriginal restores the source artwork; it paints nothing, so it is
      // not in anybody's way and must not be re-measured into something else.
      final regions = [
        _region(IntRect(100, 100, 200, 180), '第一块'),
        _region(IntRect(150, 120, 300, 200), '第二块'),
      ];
      final kept = Placement(
        index: 1,
        box: const ui.Rect.fromLTRB(150, 120, 300, 200),
        size: 0,
        vertical: false,
        decision: OverflowDecision.keepOriginal,
      );
      final out = resolvePlacementOverlaps(
        placements: [
          Placement(
            index: 0,
            box: const ui.Rect.fromLTRB(100, 100, 200, 180),
            size: 20,
            vertical: false,
            decision: OverflowDecision.shrinkToFit,
          ),
          kept,
        ],
        regions: regions,
        page: _page,
      );
      expect(out[1].decision, OverflowDecision.keepOriginal);
      expect(out[1].box, const ui.Rect.fromLTRB(150, 120, 300, 200));
      _expectNoDoubleCoverage(out);
    });
  });

  group('stacked lines in one bubble are not collateral', () {
    test('three disjoint lines keep their sizes and their group', () {
      // The S5 autosize fixture shape: same text, stacked, real gaps. The
      // collision pass must be a no-op for it.
      final line = '十二个汉字刚好占满一行测试预算';
      final regions = [
        _region(IntRect(100, 100, 620, 165), line),
        _region(IntRect(105, 180, 615, 220), line),
        _region(IntRect(102, 232, 618, 260), line),
      ];
      final before = planRegions(regions, _page, normalizeGroups: false);
      final after = planRegions(regions, _page);
      for (var i = 0; i < before.length; i++) {
        expect(after[i].box, before[i].box);
      }
      expect(after[0].size, after[1].size);
      expect(after[1].size, after[2].size);
      _expectNoDoubleCoverage(after);
    });
  });
}
