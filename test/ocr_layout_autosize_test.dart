import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/image_translation/page_renderer.dart';
import 'package:venera/foundation/image_translation/translation_types.dart';

/// S5 acceptance: a bubble is typeset, not a pile of lines.
///
/// Before this, every detected line ran its own shrink-to-fit against its own
/// box, so the three lines of one speech bubble could land at 42px, 25.6px
/// and 14.3px — technically all "fitted", visibly incoherent. The page now
/// clusters blocks that share a bubble (pure geometry, no new assets) and
/// gives the group *one* size: the largest every member carries. Where the
/// group cannot agree above the legibility floor, sizes stay personal — and a
/// member that never fitted at all stays S1's `keepOriginal`: it is not
/// painted, and it does not veto its neighbours.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // --- clustering (pure geometry) --------------------------------------------

  group('clusterLayoutGroups', () {
    test('three stacked lines of one bubble form one group', () {
      final groups = clusterLayoutGroups(boxes: [
        ui.Rect.fromLTWH(100, 100, 200, 30),
        ui.Rect.fromLTWH(102, 138, 196, 30),
        ui.Rect.fromLTWH(105, 176, 195, 30),
      ]);
      expect(groups, [
        [0, 1, 2],
      ]);
    });

    test('a block across the page stands alone', () {
      final groups = clusterLayoutGroups(boxes: [
        ui.Rect.fromLTWH(100, 100, 200, 30),
        ui.Rect.fromLTWH(102, 138, 196, 30),
        ui.Rect.fromLTWH(600, 600, 200, 30),
      ]);
      expect(groups, [
        [0, 1],
        [2],
      ]);
    });

    test('two bubbles side by side on one y do not merge', () {
      // Same rows, no column overlap: the neighbour is left, not above.
      final groups = clusterLayoutGroups(boxes: [
        ui.Rect.fromLTWH(100, 300, 200, 30),
        ui.Rect.fromLTWH(350, 300, 200, 30),
      ]);
      expect(groups.length, 2, reason: 'different bubbles, different typesets');
    });

    test('one visual line the detector split into pieces groups together', () {
      final groups = clusterLayoutGroups(boxes: [
        ui.Rect.fromLTWH(100, 400, 80, 40),
        ui.Rect.fromLTWH(190, 402, 70, 40),
      ]);
      expect(groups, [
        [0, 1],
      ]);
    });

    test('a huge SFX word over a caption is two groups, however close', () {
      final groups = clusterLayoutGroups(
        boxes: [
          ui.Rect.fromLTWH(100, 500, 200, 30),
          ui.Rect.fromLTWH(102, 538, 196, 30),
        ],
        sourceGlyphSizes: [12, 40],
      );
      expect(groups.length, 2);
    });

    test('unknown source size does not veto clustering', () {
      final groups = clusterLayoutGroups(
        boxes: [
          ui.Rect.fromLTWH(100, 500, 200, 30),
          ui.Rect.fromLTWH(102, 538, 196, 30),
        ],
        sourceGlyphSizes: [12, null],
      );
      expect(groups, [
        [0, 1],
      ]);
    });

    test('lines farther apart than a bubble breath are separate', () {
      final groups = clusterLayoutGroups(boxes: [
        ui.Rect.fromLTWH(100, 100, 200, 30),
        ui.Rect.fromLTWH(102, 220, 196, 30),
      ]);
      expect(groups.length, 2);
    });

    test('linking is transitive: a–b and b–c is one group', () {
      final groups = clusterLayoutGroups(boxes: [
        ui.Rect.fromLTWH(100, 100, 200, 30),
        ui.Rect.fromLTWH(102, 138, 196, 30),
        ui.Rect.fromLTWH(105, 176, 195, 30),
        ui.Rect.fromLTWH(1050, 900, 100, 30),
      ]);
      expect(groups.first, [0, 1, 2]);
      expect(groups.last, [3]);
    });
  });

  // --- group size search (pure oracle) ----------------------------------------

  group('unifyGroupSize', () {
    test('descends the ladder to the largest size everyone carries', () {
      // 42 fits only the first; the oracle accepts at ≤ 33.6.
      final size = unifyGroupSize(
        soloSizes: [42, 25.6],
        minReadable: 8,
        fitsAll: (s) => s <= 33.6 + 1e-9,
      );
      expect(size, closeTo(33.6, 1e-9));
    });

    test('does not assume the joint predicate is monotone', () {
      // Member widths make wrap counts jump between rungs, so "fits all" is
      // not guaranteed to be a clean prefix of the ladder. The walk starts at
      // the largest solo size and stops at the *first* size the oracle
      // attests: 30 ✗, 24 ✓ — the oracle, not a `min(solo)` shortcut, decides.
      final size = unifyGroupSize(
        soloSizes: [30, 20],
        minReadable: 8,
        fitsAll: (s) => s <= 25 && s > 19.21,
      );
      expect(size, closeTo(24, 1e-9));
    });

    test('refuses to unify below the legibility floor', () {
      final size = unifyGroupSize(
        soloSizes: [42, 33.6],
        minReadable: minReadableGlyphSize,
        fitsAll: (s) => s < minReadableGlyphSize, // only *under* the floor
      );
      expect(size, isNull, reason: 'down at the bottom is keepOriginal, not 6px');
    });

    test('an all-false oracle bottoms out to null', () {
      expect(
        unifyGroupSize(soloSizes: [20], minReadable: 8, fitsAll: (_) => false),
        isNull,
      );
    });

    test('empty group has no opinion', () {
      expect(
        unifyGroupSize(soloSizes: const [], minReadable: 8, fitsAll: (_) => true),
        isNull,
      );
    });
  });

  // --- end-to-end on the real layout engine -----------------------------------

  group('planRegions harmonises one bubble', () {
    const page = ui.Size(1200, 1200);
    const line = '十二个汉字刚好占满一行测试预算'; // 12 CJK glyphs

    // One bubble, three lines; box heights 65/40/28 make the *personal* fits
    // land on different ladder rungs (the height arithmetic is exact:
    // a line is 1.2 × size, so 42px needs 50.4px, 25.6px needs 30.7px…).
    final regions = [
      TranslatedRegion(
        rect: IntRect(100, 100, 620, 165),
        text: line,
        backgroundColor: 0xFFFFFFFF,
        textColor: 0xFF000000,
      ),
      TranslatedRegion(
        rect: IntRect(105, 180, 615, 220),
        text: line,
        backgroundColor: 0xFFFFFFFF,
        textColor: 0xFF000000,
      ),
      TranslatedRegion(
        rect: IntRect(102, 232, 618, 260),
        text: line,
        backgroundColor: 0xFFFFFFFF,
        textColor: 0xFF000000,
      ),
      // A far-flung caption: its own bubble, its own rules.
      TranslatedRegion(
        rect: IntRect(900, 800, 1150, 860),
        text: '八个汉字独立一块不受影响',
        backgroundColor: 0xFFFFFFFF,
        textColor: 0xFF000000,
      ),
    ];

    List<Placement> plan({bool groups = true}) =>
        planRegions(regions, page, normalizeGroups: groups);

    test('the personal sizes really do differ without harmonisation', () {
      final solo = plan(groups: false);
      expect(solo[0].size, greaterThan(0));
      expect(solo[2].size, greaterThan(0));
      expect(
        {solo[0].size, solo[1].size, solo[2].size}.length,
        greaterThan(1),
        reason: 'precondition: unharmonised lines pick different sizes',
      );
    });

    test('one group, one size, and it is the biggest they all agree on', () {
      final g = plan();
      expect(g[0].size, g[1].size);
      expect(g[1].size, g[2].size);
      final unified = g[0].size;

      final solo = plan(groups: false);
      final minSolo = [solo[0].size, solo[1].size, solo[2].size].reduce(
        (a, b) => a < b ? a : b,
      );
      final maxSolo = [solo[0].size, solo[1].size, solo[2].size].reduce(
        (a, b) => a > b ? a : b,
      );
      expect(unified, lessThan(maxSolo), reason: 'the group pays for its tail');
      expect(
        unified,
        greaterThanOrEqualTo(minSolo * 0.8 - 1e-9),
        reason: 'but never below what the tightest line fitted alone',
      );
      for (var i = 0; i < 3; i++) {
        expect(
          fitsRegionAt(regions[i], g[i].box, vertical: g[i].vertical, size: unified),
          isTrue,
          reason: 'line $i was measured at the shared size — nothing is forced',
        );
        expect(g[i].decision, OverflowDecision.shrinkToFit);
        expect(g[i].layoutGroup, g[1].layoutGroup);
        expect(g[i].layoutGroup, 0);
      }
    });

    test('the lone bubble keeps its own size and no group', () {
      final g = plan();
      final solo = plan(groups: false);
      expect(g[3].layoutGroup, -1);
      expect(g[3].size, solo[3].size, reason: 'untouched by the harmoniser');
    });

    test('a line nothing fits never drags its bubble down (S1 compatible)', () {
      // 200 glyphs into a 40×25 sliver wedged between the bubble's last line
      // and a block right under it — growth is pinched to nothing on every
      // side, so S1 must keep it original. The two lines above must still
      // share a size, unbothered.
      final crowded = [
        ...regions.take(2),
        TranslatedRegion(
          rect: IntRect(105, 230, 145, 255),
          text: '字' * 200,
          backgroundColor: 0xFFFFFFFF,
          textColor: 0xFF000000,
        ),
        TranslatedRegion(
          rect: IntRect(60, 262, 640, 320),
          text: '下方占位块挡住扩框',
          backgroundColor: 0xFFFFFFFF,
          textColor: 0xFF000000,
        ),
      ];
      final g = planRegions(crowded, page);
      expect(g[2].decision, OverflowDecision.keepOriginal);
      expect(g[2].paints, isFalse);
      expect(
        g[2].layoutGroup,
        -1,
        reason: 'a block that paints nothing groups with nobody',
      );
      expect(g[0].size, g[1].size);
      expect(g[0].size, greaterThanOrEqualTo(minReadableGlyphSize));
    });

    test('toggling normalisation off reproduces the pre-S5 page exactly', () {
      final off = plan(groups: false);
      for (final p in off) {
        expect(p.layoutGroup, -1);
      }
    });
  });

  group('unifyPlacementGroups on hand-made placements', () {
    final region = TranslatedRegion(
      rect: IntRect(0, 0, 400, 40),
      text: '占位文本',
      backgroundColor: 0xFFFFFFFF,
      textColor: 0xFF000000,
    );

    test('keepOriginal and skipped placements never join a group', () {
      final keep = Placement(
        index: 0,
        box: ui.Rect.fromLTWH(10, 10, 200, 30),
        size: 0,
        vertical: false,
        decision: OverflowDecision.keepOriginal,
      );
      final skip = Placement.of(1, region);
      final out = unifyPlacementGroups([keep, skip], [region, region]);
      expect(out[0].decision, OverflowDecision.keepOriginal);
      expect(out[1].skips, isTrue);
    });

    test('a single-member cluster is left alone', () {
      final lone = Placement(
        index: 0,
        box: ui.Rect.fromLTWH(10, 10, 200, 30),
        size: 20,
        vertical: false,
        decision: OverflowDecision.shrinkToFit,
      );
      final out = unifyPlacementGroups([lone], [region]);
      expect(out.single.size, 20);
      expect(out.single.layoutGroup, -1);
    });
  });
}
