import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/image_translation/page_renderer.dart';
import 'package:venera/foundation/image_translation/translation_types.dart';

/// Phase 13-F13.2: `keepOriginal` blocks are an **obstacle**, and the collision
/// pass was blind to them.
///
/// [resolvePlacementOverlaps] compared only blocks that *paint*. A
/// [Placement.keptOriginal] block paints nothing, so it entered no pair, and
/// the conclusion drawn from that was "it is in nobody's way". The paint path
/// disagrees: in the erase modes a kept-original block gets the untouched
/// source artwork **stamped back into its box** (the `pristine` pass in
/// [renderTranslatedPageWithReport]) and that happens *before* any neighbour's
/// lettering lands. A detected box that merely overlaps a kept-original box
/// therefore leaves the original text and a translation printed on the same
/// pixels — "两个气泡的文字还是重叠", with the eraser nowhere in the story.
///
/// No existing test could catch it. `ocr_layout_overlap_test.dart` asserts that
/// *painting* boxes are pairwise disjoint, which stays true while a restore is
/// buried under a neighbour; and its one kept-original case asserts only that
/// the restore is left alone — never what landed on top of it. That
/// **painted × restore** pair is what this file adds.
///
/// The invariant is about pixels, not about pairs of texts:
///
/// > no area of the page carries both restored source artwork and fresh
/// > lettering.
///
/// plus the two rules that make it reachable without bargaining with S1: the
/// restore is never moved and never cut (that stamp *is* the decision), and a
/// painting box that cannot get clear of one stands down instead of printing
/// over it.
///
/// NOT VERIFIED LOCALLY: no `flutter test` is run in this workspace. Everything
/// here is listed under "待云端 Test job 验证".
TranslatedRegion _region(IntRect rect, String text, {int lineHeight = 24}) {
  return TranslatedRegion(
    rect: rect,
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

/// A block that will be drawn.
Placement _paint(int i, ui.Rect box, {double size = 20}) => Placement(
  index: i,
  box: box,
  size: size,
  vertical: false,
  decision: OverflowDecision.shrinkToFit,
);

/// A block S1 dropped: it paints nothing, and the paint pass puts the pristine
/// artwork back inside exactly this box.
Placement _restore(int i, ui.Rect box) => Placement(
  index: i,
  box: box,
  size: 0,
  vertical: false,
  decision: OverflowDecision.keepOriginal,
);

/// **The invariant the report asked for.** Nothing that paints may cover a
/// single pixel of an area the renderer restores from the pristine source.
///
/// Ink cannot leave its box in the erase modes — [_placeText] clips to it, and
/// a box only paints what measured a fit inside it — so "boxes disjoint" *is*
/// "no pixel covered by both". This is the painted × restore half of the
/// statement `ocr_layout_overlap_test.dart` makes about painted × painted.
void _expectNoRestoreUnderInk(List<Placement> placements) {
  final painted = placements.where((p) => p.paints).toList();
  final restored = placements.where((p) => p.keptOriginal).toList();
  for (final p in painted) {
    for (final r in restored) {
      final inter = p.box.intersect(r.box);
      expect(
        inter.isEmpty,
        isTrue,
        reason:
            'no pixel area may carry restored source artwork and a '
            'translation at once: painted #${p.index} ${p.box} vs '
            'restored #${r.index} ${r.box} overlap by $inter',
      );
    }
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('painted × restore — the pair the pass never compared', () {
    test('a restore that cannot be moved makes the *translation* stand down',
        () {
      // Block 0 is already at its own detected floor, so it has no gutter to
      // give back; it is the *leading* box of the pair, so no step aside is on
      // offer either (only the trailing block can move away from a neighbour).
      // The one cut that would clear the restore leaves 95×80px, and 400
      // full-width glyphs fit in no such box at any legible size. Every rung of
      // the ladder is refused: that is what "cannot be resolved" means here.
      final regions = [
        _region(IntRect(100, 100, 200, 180), '字' * 400),
        _region(IntRect(195, 100, 400, 400), '这一块的原文被保留了下来'),
      ];
      const kept = ui.Rect.fromLTRB(195, 100, 400, 400);
      final out = resolvePlacementOverlaps(
        placements: [
          _paint(0, const ui.Rect.fromLTRB(100, 100, 200, 180)),
          _restore(1, kept),
        ],
        regions: regions,
        page: _page,
      );

      // S1 is immutable: the restored area is byte-for-byte the box it was
      // decided at — not moved, not cut, not "trimmed to the middle line".
      expect(out[1].box, kept, reason: 'the restore did not move');
      expect(out[1].decision, OverflowDecision.keepOriginal);

      // The lettering is the thing that gave way.
      expect(
        out[0].paints,
        isFalse,
        reason: 'an unresolvable painted × restore overlap must not be solved '
            'by printing on top of the original',
      );
      expect(out[0].decision, OverflowDecision.keepOriginal);
      expect(out[0].size, 0, reason: 'a stood-down block draws nothing');
      expect(
        out[0].box,
        const ui.Rect.fromLTRB(100, 100, 200, 180),
        reason: 'and it keeps the box it came in with: a cut it then cannot '
            'pay for would restore *less* than the block covers, which is a '
            'hole in the page, not a fallback',
      );
      _expectNoRestoreUnderInk(out);
    });

    test('a box that only borrowed gutter gives it back and keeps painting',
        () {
      // The cheap resolution, and the one that must not cost a translation:
      // block 0's *detected* rect ends at x=260, its box was grown to 320, and
      // the restored area starts at 300. Retreating to its own floor already
      // clears the pair, so the pass must take that and stop.
      final regions = [
        _region(IntRect(100, 100, 260, 180), '短句一条'),
        _region(IntRect(300, 120, 500, 200), '这一块的原文被保留了'),
      ];
      const kept = ui.Rect.fromLTRB(300, 120, 500, 200);
      final out = resolvePlacementOverlaps(
        placements: [
          _paint(0, const ui.Rect.fromLTRB(100, 100, 320, 180)),
          _restore(1, kept),
        ],
        regions: regions,
        page: _page,
      );
      expect(
        out[0].paints,
        isTrue,
        reason: 'it only had borrowed gutter to give: the lettering survives',
      );
      expect(out[0].box.right, lessThanOrEqualTo(300));
      expect(
        out[0].box.left,
        100,
        reason: 'the edge facing away from the restore is not moved',
      );
      expect(out[1].box, kept, reason: 'the restore did not move');
      _expectNoRestoreUnderInk(out);
    });

    test('a restore between two painting blocks: both give way, it does not',
        () {
      // The pair order matters here: the pass picks the *worst* overlap first,
      // settles both painting blocks against the restore in the middle, and the
      // assertable part is that neither of them ends up on it — while the
      // middle box is still exactly the rectangle S1 chose.
      final regions = [
        _region(IntRect(100, 100, 200, 180), '一二三四五六七八九十十一十二'),
        _region(IntRect(150, 120, 320, 200), '这一块放不下'),
        _region(IntRect(300, 100, 420, 180), '十五十六十七十八十九二十廿一'),
      ];
      const kept = ui.Rect.fromLTRB(150, 120, 320, 200);
      final out = resolvePlacementOverlaps(
        placements: [
          _paint(0, const ui.Rect.fromLTRB(100, 100, 200, 180)),
          _restore(1, kept),
          _paint(2, const ui.Rect.fromLTRB(300, 100, 420, 180)),
        ],
        regions: regions,
        page: _page,
      );
      expect(out[1].box, kept, reason: 'the restore never moved, whatever '
          'pressed on it from either side');
      for (final p in out.where((p) => p.keptOriginal)) {
        expect(
          p.size,
          0,
          reason: 'block #${p.index} restores the source and must paint '
              'nothing — a size on a non-painting block is a lie in the log',
        );
      }
      _expectNoRestoreUnderInk(out);
    });

    test('two restores may overlap: they are the same source pixels', () {
      final regions = [
        _region(IntRect(100, 100, 220, 180), '第一块放不下'),
        _region(IntRect(180, 120, 300, 200), '第二块也放不下'),
      ];
      final placements = [
        _restore(0, const ui.Rect.fromLTRB(100, 100, 220, 180)),
        _restore(1, const ui.Rect.fromLTRB(180, 120, 300, 200)),
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
        reason: 'nothing paints, so nothing is in anybody\'s way: the pass must '
            'still answer with the same list object',
      );
    });

    test('a page with no painted × restore overlap is provably untouched', () {
      // The identity guarantee, re-asked now that restores take part in the
      // pairwise check: including them must not cost a clean page its "nothing
      // happened here" answer.
      final regions = [
        _region(IntRect(100, 100, 200, 160), '第一块'),
        _region(IntRect(400, 400, 520, 460), '第二块放不下'),
      ];
      final placements = [
        _paint(0, const ui.Rect.fromLTRB(100, 100, 200, 160)),
        _restore(1, const ui.Rect.fromLTRB(400, 400, 520, 460)),
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
      );
    });

    test('in patch mode the pass behaves exactly as it did', () {
      // The restore rule is gated on the same condition the paint pass uses to
      // decide whether it restores anything at all: in patch mode the base *is*
      // the pristine original and a kept-original block is an absence of plate
      // rather than a stamp of artwork, so there is no restored area to keep
      // clear of. `blocks(i)` must collapse to `paints(i)` — which means this
      // input comes back untouched, exactly as before F13.2.
      final regions = [
        _region(IntRect(100, 100, 200, 180), '第一块'),
        _region(IntRect(150, 120, 300, 200), '第二块放不下'),
      ];
      final placements = [
        _paint(0, const ui.Rect.fromLTRB(100, 100, 200, 180)),
        _restore(1, const ui.Rect.fromLTRB(150, 120, 300, 200)),
      ];
      expect(
        identical(
          resolvePlacementOverlaps(
            placements: placements,
            regions: regions,
            page: _page,
            outlined: false,
          ),
          placements,
        ),
        isTrue,
        reason: 'patch mode: no restore is stamped, so nothing new is in the '
            'way — and no translation is lost to a rule that cannot apply',
      );
    });
  });

  group('planRegions: the grey zone the merge gate declines, closed', () {
    test('no painting box covers a kept-original box on a planned page', () {
      // The real entry point, so growth, the reality gate, the sweep and the
      // settle all run. Block 1 is the S1 case: 400 glyphs into a 300×40 band
      // pinched between its neighbours, so nothing fits and its artwork goes
      // back. Block 2's rectangle bites into that band by 50×20px = 8% of the
      // smaller rect, which is *below* `kMergeOverlapCov` — the merge
      // demonstrably declines it, and it is exactly where F13.2 lives: two
      // separate detections whose boxes overlap, below the gate that would have
      // folded them into one block.
      final crowded = [
        _region(IntRect(105, 180, 615, 220), '十二个汉字刚好占满一行测试预算'),
        _region(IntRect(100, 230, 400, 270), '字' * 400),
        _region(IntRect(350, 250, 700, 330), '下方这块压在它上面'),
      ];
      expect(
        resolveRegionCollisions(crowded),
        hasLength(3),
        reason: 'precondition: below kMergeOverlapCov, so the overlapping pair '
            'stays two blocks — which is the shape F13.2 is about',
      );

      final placements = planRegions(crowded, _page);
      expect(
        placements[1].decision,
        OverflowDecision.keepOriginal,
        reason: 'precondition: 400 glyphs into a 300×40 sliver is S1 territory',
      );
      // The restored area does reach under block 2's rectangle, so the pair
      // this file is about really exists on this page.
      expect(
        placements[1].box.intersect(_rectOf(crowded[2].rect)).isEmpty,
        isFalse,
        reason: 'precondition: painted × restore overlap in the input',
      );
      _expectNoRestoreUnderInk(placements);
      // And the blocks that *can* be placed are still placed: closing the
      // restore hole must not turn into "stop translating the page".
      expect(
        placements.where((p) => p.paints).length,
        greaterThan(1),
        reason: 'at least one neighbour kept its translation',
      );
    });
  });

  group('end to end: the restored rectangle comes off the page pristine', () {
    /// Artwork that cannot be mistaken for either the erased base (white) or
    /// for lettering (near-black): a hard red/blue checker, so "this pixel is
    /// the source artwork" is one integer comparison.
    Future<Uint8List> checkeredPng(int width, int height) async {
      final pixels = Uint8List(width * height * 4);
      for (var y = 0; y < height; y++) {
        for (var x = 0; x < width; x++) {
          final i = (y * width + x) * 4;
          final a = ((x >> 2) + (y >> 2)).isEven;
          pixels[i] = a ? 255 : 0;
          pixels[i + 1] = 0;
          pixels[i + 2] = a ? 0 : 255;
          pixels[i + 3] = 255;
        }
      }
      final completer = Completer<ui.Image>();
      ui.decodeImageFromPixels(
        pixels,
        width,
        height,
        ui.PixelFormat.rgba8888,
        completer.complete,
      );
      final image = await completer.future;
      try {
        final data = await image.toByteData(format: ui.ImageByteFormat.png);
        return data!.buffer.asUint8List();
      } finally {
        image.dispose();
      }
    }

    RgbaImage whiteImage(int width, int height) {
      final px = Uint8List(width * height * 4);
      for (var i = 0; i < width * height; i++) {
        px[i * 4] = 255;
        px[i * 4 + 1] = 255;
        px[i * 4 + 2] = 255;
        px[i * 4 + 3] = 255;
      }
      return RgbaImage(width, height, px);
    }

    Future<Uint8List> rawRgba(Uint8List png) async {
      final codec = await ui.instantiateImageCodec(png);
      final frame = await codec.getNextFrame();
      try {
        final data = await frame.image.toByteData(
          format: ui.ImageByteFormat.rawRgba,
        );
        return data!.buffer.asUint8List();
      } finally {
        frame.image.dispose();
        codec.dispose();
      }
    }

    test('a neighbour whose box overlaps a kept-original box does not print '
        'into it', () async {
      const width = 240, height = 120;
      final original = await checkeredPng(width, height);
      final decoded = whiteImage(width, height);
      // K: 30×30 holding a sentence with no chance above the legibility floor
      // — the forced-`keepOriginal` recipe from ocr_layout_collision_test.dart.
      final k = IntRect(10, 20, 40, 50);
      final keep = _region(
        k,
        'This source caption is deliberately far too long for the box.',
      );
      // P: starts *inside* K's box and runs off to the right, packed with
      // lettering, so a pass that cannot see the restore prints into
      // x ∈ [35, 40) of a rectangle whose artwork the renderer has just put
      // back. Below kMergeDuplicateCov and kMergeOverlapCov, so the merge is
      // not what settles this.
      final paint = _region(
        IntRect(35, 8, 235, 60),
        '这一块的译文横跨了两个气泡的检测框所以它压到了左边那块被保留的原文上面去了',
      );
      expect(
        _rectOf(k).intersect(_rectOf(paint.rect)).isEmpty,
        isFalse,
        reason: 'precondition: this fixture really is the painted × restore '
            'shape the report describes',
      );

      final result = await renderTranslatedPageWithReport(original, decoded, [
        keep,
        paint,
      ]);
      expect(
        result.report.keepOriginal,
        contains(0),
        reason: 'precondition: K kept its original',
      );

      final pristine = await rawRgba(original);
      final rendered = await rawRgba(result.png);
      var overpainted = 0;
      ui.Rect? where;
      for (var y = k.top; y < k.bottom; y++) {
        for (var x = k.left; x < k.right; x++) {
          final i = (y * width + x) * 4;
          final same =
              rendered[i] == pristine[i] &&
              rendered[i + 1] == pristine[i + 1] &&
              rendered[i + 2] == pristine[i + 2];
          if (!same) {
            overpainted++;
            where ??= ui.Rect.fromLTWH(x.toDouble(), y.toDouble(), 1, 1);
          }
        }
      }
      expect(
        overpainted,
        0,
        reason:
            'every pixel of a kept-original box must be the source artwork: '
            '$overpainted of them were overpainted by somebody\'s lettering '
            '(first at $where)',
      );
    });
  });
}
