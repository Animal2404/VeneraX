import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/image_translation/page_renderer.dart';
import 'package:venera/foundation/image_translation/translation_types.dart';

/// The black-block defect, judged at the *branch* that chooses the pen.
///
/// Evidence chain this file locks (see the reported real-device log):
///  * `erasure ledger: erased=32 skipped=0 rolled_back=0` — the eraser never
///    rolled a window back, so the black mass is not ink it left behind;
///  * `_drawErasedRegion` (page_renderer.dart) picks the pen from exactly one
///    bool: `backgroundReadsDark(decoded, placement.box)` -> `0xE6000000`
///    black halo, else `0xE6FFFFFF` white halo. A wrong `true` there is a
///    thick black outline (up to 35% of the glyph size, kStrokeRatioCeil)
///    around every glyph, and neighbouring CJK glyphs (0.1*fontSize apart)
///    fuse into one solid blob;
///  * the old rule asked "are most pixels dark?" — and a screentone is made of
///    dark pixels, so a light-grey toned bubble answered `true`.
///
/// The new rule asks the low-frequency question instead: a position is *solid
/// dark* when the mean of its 5x5 window is under [kSolidBackgroundLum] (60),
/// and the box takes the black pen only when solid dark is a strict majority
/// (> [kSolidBackgroundShare], 0.5). Every expectation below is hand-computed
/// from the fixture, not from a run.
///
/// NOT VERIFIED LOCALLY (no `flutter test` in this workspace) — see the
/// "待云端 Test job 验证" list in the hand-off report.
RgbaImage _image(int w, int h, int Function(int x, int y) lum) {
  final px = Uint8List(w * h * 4);
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      final i = (y * w + x) * 4;
      final v = lum(x, y);
      px[i] = v;
      px[i + 1] = v;
      px[i + 2] = v;
      px[i + 3] = 255;
    }
  }
  return RgbaImage(w, h, px);
}

/// One row per luminance, 40px wide (the shape [ocr_layout_black_halo_test]
/// uses, so the two files measure the same fixtures).
RgbaImage _rows(List<int> luminances) =>
    _image(40, luminances.length, (x, y) => luminances[y]);

/// A halftone: [dot]x[dot] ink squares on paper, [gap] px apart.
///
/// Coverage = dot^2 / (dot+gap)^2. This is the shape that used to answer
/// `true`: its near-black *share* is the coverage, so a dense enough tone
/// cleared the old `dark > bright` test without ever looking black.
RgbaImage _tone(
  int dot,
  int gap, {
  int ink = 10,
  int paper = 250,
  int w = 40,
  int h = 40,
}) {
  final pitch = dot + gap;
  return _image(
    w,
    h,
    (x, y) => (x % pitch) < dot && (y % pitch) < dot ? ink : paper,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final box = const ui.Rect.fromLTRB(0, 0, 40, 40);

  group('screentone takes the light branch (the reported black block)', () {
    test('a light halftone is not a black background', () {
      // 3px dots on a 5px pitch = 36% ink coverage, tone reads as ~164.
      // Every 5x5 window still holds paper, so no position is solid dark.
      expect(backgroundReadsDark(_tone(3, 2), box), isFalse);
    });

    test('a heavy halftone is still not a black background', () {
      // 4px dots on a 5px pitch = 64% ink coverage. The densest 5x5 window
      // sits on a dot centre and still averages (16*10 + 9*250)/25 = 96.4,
      // i.e. grey to the eye -> light branch. This is the case the old
      // coverage rule got wrong: 64% of the box IS near-black pixels.
      expect(backgroundReadsDark(_tone(4, 1), box), isFalse);
    });

    test('a flat mid-tone fill is not a black background', () {
      expect(backgroundReadsDark(_rows(List.filled(40, 120)), box), isFalse);
    });

    test('un-erased thin source ink cannot vote the box dark', () {
      // Leftover lettering is 1-3px strokes. A 5x5 window over 2px strokes on
      // 2px gaps holds 2 ink columns of 5, i.e. 10 ink pixels of 25, and
      // averages (10*10 + 15*250)/25 = 154 -> light branch. The handling of
      // "the sampled box catches un-erased ink" is therefore mechanical: thin
      // ink never reaches solid-dark, only a solid mass can.
      final strokes = _image(40, 40, (x, y) => (x % 4) < 2 ? 10 : 250);
      expect(backgroundReadsDark(strokes, box), isFalse);
    });
  });

  group('a real black bubble keeps the black pen (reverse test)', () {
    test('a solid black box is solid dark', () {
      expect(backgroundReadsDark(_rows(List.filled(40, 8)), box), isTrue);
    });

    test('a solid black fill is dark even at mid-dark grey', () {
      // 40/255 is a flat dark fill, not a halftone: it reads as a dark
      // background and keeps white lettering + black halo (old rule agreed).
      expect(backgroundReadsDark(_rows(List.filled(40, 40)), box), isTrue);
    });

    test('a black bubble whose grown box catches a bright page strip', () {
      // safeGrowRect borrows gutter, so a real bubble box is rarely pure:
      // 30 black rows + 10 bright ones = 0.725 solid dark -> still dark.
      final bubble = _rows(<int>[
        ...List.filled(30, 0),
        ...List.filled(10, 250),
      ]);
      expect(backgroundReadsDark(bubble, box), isTrue);
    });

    test('a black bubble with white lettering on it stays dark', () {
      // White text lines 2px tall on a black fill: 4 of 40 rows are white
      // (10% coverage), so 28 of 40 sampled rows are still surrounded by a
      // 5x5 window of pure black -> 0.7 solid dark. This is the shape the
      // black branch exists for: white lettering with no black halo
      // disappears into the bubble.
      final bubble = _image(40, 40, (x, y) {
        final r = y % 20;
        return (r == 6 || r == 7) ? 250 : 0;
      });
      expect(backgroundReadsDark(bubble, box), isTrue);
    });

    test('a half-white glyph field on black is not "mostly solid black"', () {
      // A 2px checkerboard is 50% white: every 5x5 window holds 12-13 white
      // pixels, so it averages 120-130 and no position is solid dark. The
      // boundary of the criterion lives between this and the 10%-white case
      // above; a box that is half white lettering is not a solid black
      // background and takes the safe branch (dark ink + white halo, which
      // also reads on the black half).
      final checker = _image(
        40,
        40,
        (x, y) => ((x ~/ 2 + y ~/ 2) % 2 == 0) ? 250 : 0,
      );
      expect(backgroundReadsDark(checker, box), isFalse);
    });

    test('a black mass that runs to the page edge is still a mass', () {
      final edge = _image(40, 40, (x, y) => y < 24 ? 0 : 250);
      expect(backgroundReadsDark(edge, const ui.Rect.fromLTRB(0, 0, 20, 20)),
          isTrue);
    });
  });

  group('the pinned majority fixtures still answer the same way', () {
    // Mirrors of ocr_layout_black_halo_test.dart, kept here so this file is a
    // self-contained lock on the criterion. Hand-computed shares under the
    // new rule: mixed 0.45, tie 0.475, dark 0.8, white 0.
    test('mixed box (bright majority, low mean) stays light', () {
      final mixed = _rows(<int>[
        ...List.filled(18, 250),
        ...List.filled(6, 60),
        ...List.filled(16, 0),
      ]);
      expect(backgroundReadsDark(mixed, box), isFalse);
    });

    test('half black / half bright stays light (ties go to the safe branch)',
        () {
      final tie = _rows(<int>[
        ...List.filled(20, 0),
        ...List.filled(20, 255),
      ]);
      expect(backgroundReadsDark(tie, box), isFalse);
    });

    test('a mostly-black box stays dark', () {
      final dark = _rows(<int>[
        ...List.filled(30, 0),
        ...List.filled(6, 60),
        ...List.filled(4, 250),
      ]);
      expect(backgroundReadsDark(dark, box), isTrue);
    });

    test('a clean white bubble stays light', () {
      expect(backgroundReadsDark(_rows(List.filled(40, 245)), box), isFalse);
    });
  });

  group('no evidence is never darkness', () {
    test('a box that does not fit the buffer is not evidence of darkness', () {
      final tiny = RgbaImage(40, 40, Uint8List(40 * 20 * 4));
      expect(
        backgroundReadsDark(tiny, const ui.Rect.fromLTRB(0, 0, 40, 40)),
        isFalse,
      );
    });

    test('a degenerate box still answers without reading past the buffer', () {
      final page = _rows(List.filled(40, 250));
      expect(backgroundReadsDark(page, const ui.Rect.fromLTRB(0, 0, 0, 0)),
          isFalse);
      expect(backgroundReadsDark(page, const ui.Rect.fromLTRB(39, 39, 40, 40)),
          isFalse);
    });

    test('the pen itself is untouched: thickness still tracks the source', () {
      // The black block was a wrong *branch*, never a wrong thickness. S4's
      // measured-equals-painted contract stays where its own tests left it.
      expect(strokeWidthForSize(20, sourceStrokeRatio: 0.3), 6.0);
      expect(strokeRatioFor(0.9), kStrokeRatioCeil);
      expect(strokeRatioFor(null), kDefaultStrokeRatio);
    });
  });
}
