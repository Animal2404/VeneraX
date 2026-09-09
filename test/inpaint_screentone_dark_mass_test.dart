import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/image_translation/inpaint.dart';
import 'package:venera/foundation/image_translation/translation_types.dart';

/// Phase 13-F13.3: a black block where a **screentone** used to be.
///
/// The dark-mass guard is a *contrast* judgement — "a window that was mostly
/// not black became mostly black, inside artwork that is not black either". On
/// a tonal page all three of its terms disarmed themselves at once, and the
/// eraser's own behaviour is what disarmed them:
///
/// * `darkBefore` on a heavy screen is already 0.4–0.7, so "rose by more than
///   35 points" is arithmetically out of reach — the window went from *dotted*
///   black to *solid* black and the share barely moved;
/// * the ring test counted near-black **pixels** around the window, and a
///   dense screen's ring is full of them, so the guard read "black
///   neighbourhood" and stood down in exactly the scene the blocks come from;
/// * [`TextInpainter.eraseWindow`] then copies the nearest existing pixel into
///   every masked one — it invents no colour — and on a screen the nearest
///   existing pixel to a paper gap *is* a dot. Copying dots into gaps **is**
///   how a solid black mass is assembled out of nothing but faithful copies;
/// * and the result was counted `erased`, which printed nothing at all.
///
/// So this file locks the guard from **both sides**, which is the only way a
/// criterion change like this can be reviewed:
///
/// 1. a tonal window the reconstruction turns into a *mass* is rolled back (it
///    used to sail through as `erased`);
/// 2. light lettering out of a real black bubble is still erased — including a
///    bubble that sits **on a tonal page**, which is the case the old rule
///    survived only by accident;
/// 3. an honest tonal erase that leaves a tonal window behind is still erased.
///
/// Plus the ledger: "nothing was erased", "everything was erased" and "a black
/// window was erased *successfully*" used to be three names for the same
/// silence.
///
/// The fixture numbers below are not guessed: the *preconditions* are measured
/// with the same definitions the guard uses (see [_blackShare], [_solidShare],
/// [_ringProfile]), so if a future retune stops reproducing the reported
/// arithmetic, this file says so instead of passing vacuously.
///
/// NOT VERIFIED LOCALLY: no `flutter test` is run in this workspace. Everything
/// here is listed under "待云端 Test job 验证".
const _period = 6;

/// `dot × dot` near-black squares on a [_period] pitch, phase-shifted by one so
/// a stride-2 ring sample walks the lattice instead of landing only on dots.
/// With `dot: 5` the coverage is (5/6)² = **0.694** of the area in near-black —
/// the middle of the 0.4–0.7 the forensic round measured — and the paper gaps
/// are 1px channels, so the tone is *dotted* black and never a *mass*.
bool _dot(int x, int y, {int dot = _period - 1}) =>
    ((x + 1) % _period) < dot && ((y + 1) % _period) < dot;

RgbaImage _tonedPage(
  int w,
  int h, {
  int dot = _period - 1,
  int ink = 0,
  int paper = 250,
}) {
  final px = Uint8List(w * h * 4);
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      final v = _dot(x, y, dot: dot) ? ink : paper;
      final i = (y * w + x) * 4;
      px[i] = v;
      px[i + 1] = v;
      px[i + 2] = v;
      px[i + 3] = 255;
    }
  }
  return RgbaImage(w, h, px);
}

RgbaImage _solid(int w, int h, int v) {
  final px = Uint8List(w * h * 4);
  for (var i = 0; i < w * h; i++) {
    px[i * 4] = v;
    px[i * 4 + 1] = v;
    px[i * 4 + 2] = v;
    px[i * 4 + 3] = 255;
  }
  return RgbaImage(w, h, px);
}

void _fill(RgbaImage img, IntRect r, int v) {
  for (var y = r.top; y < r.bottom; y++) {
    for (var x = r.left; x < r.right; x++) {
      final i = (y * img.width + x) * 4;
      img.pixels[i] = v;
      img.pixels[i + 1] = v;
      img.pixels[i + 2] = v;
      img.pixels[i + 3] = 255;
    }
  }
}

int _lum(RgbaImage img, int x, int y) {
  final i = (y * img.width + x) * 4;
  return (0.299 * img.pixels[i] +
          0.587 * img.pixels[i + 1] +
          0.114 * img.pixels[i + 2])
      .round();
}

Uint8List _copy(RgbaImage img) => Uint8List.fromList(img.pixels);

/// Near-black share of [r], pixel for pixel — [kNearBlackLum]'s definition.
double _blackShare(RgbaImage img, IntRect r) {
  var dark = 0, count = 0;
  for (var y = r.top; y < r.bottom; y++) {
    for (var x = r.left; x < r.right; x++) {
      count++;
      if (_lum(img, x, y) < 24) dark++;
    }
  }
  return count == 0 ? 0 : dark / count;
}

/// Share of [r] that is near-black **and stays near-black 2px in every
/// direction**: the solid reading, the one a dot lattice cannot fake. Same
/// 5×5 probe and the same 0.8 pass mark as the guard's own [_solidShare].
double _solidShare(RgbaImage img, IntRect r) {
  var solid = 0, count = 0;
  for (var y = r.top; y < r.bottom; y++) {
    for (var x = r.left; x < r.right; x++) {
      count++;
      if (_lum(img, x, y) >= 24) continue;
      var dark = 0, probe = 0;
      for (var dy = -2; dy <= 2; dy++) {
        for (var dx = -2; dx <= 2; dx++) {
          probe++;
          final nx = x + dx, ny = y + dy;
          if (nx < 0 || ny < 0 || nx >= img.width || ny >= img.height) {
            dark++;
            continue;
          }
          if (_lum(img, nx, ny) < 24) dark++;
        }
      }
      if (probe > 0 && dark / probe >= 0.8) solid++;
    }
  }
  return count == 0 ? 0 : solid / count;
}

/// The 4px frame outside [r], sampled every other pixel — the guard's ring,
/// recomputed here from the fixture as (near-black share, mean luminance). The
/// bounds mirror `TextInpainter._ringProfile` exactly, including the inclusive
/// `+ band` edge, because a precondition that measures a different frame than
/// the one under test is worth nothing.
(double darkShare, double lumMean) _ringProfile(
  RgbaImage img,
  IntRect r, {
  int band = 4,
}) {
  var dark = 0, count = 0;
  var sum = 0.0;
  final x0 = (r.left - band).clamp(0, img.width - 1);
  final x1 = (r.right + band).clamp(0, img.width - 1);
  final y0 = (r.top - band).clamp(0, img.height - 1);
  final y1 = (r.bottom + band).clamp(0, img.height - 1);
  for (var y = y0; y <= y1; y += 2) {
    for (var x = x0; x <= x1; x += 2) {
      if (x >= r.left && x < r.right && y >= r.top && y < r.bottom) continue;
      final v = _lum(img, x, y);
      count++;
      sum += v;
      if (v < 24) dark++;
    }
  }
  return (count == 0 ? 0 : dark / count, count == 0 ? 255 : sum / count);
}

/// A window-sized mask: `1` wherever [inside] says the classifier took the
/// pixel for lettering. Handing the mask over rather than going through
/// [TextInpainter.computeMask] keeps these tests about what the *fill* and the
/// guard do, not about whether a threshold agrees with us on a synthetic
/// lattice.
TextMask _maskWhere(
  int left,
  int top,
  int rw,
  int rh,
  bool Function(int x, int y) inside,
) {
  final mask = Uint8List(rw * rh);
  for (var y = 0; y < rh; y++) {
    for (var x = 0; x < rw; x++) {
      if (inside(left + x, top + y)) mask[y * rw + x] = 1;
    }
  }
  return TextMask(left, top, rw, rh, mask);
}

/// The heavy-screen window used by the cases below: 36×36 at (12,12), which is
/// six whole periods of the lattice, and small enough on both axes that the
/// guard's own `_darkShare` step (`min(rw, rh) ~/ 20`) samples it pixel for
/// pixel rather than aliasing across the screen.
final _win = IntRect(12, 12, 48, 48);

void main() {
  group('preconditions: the tone really does disarm the old three terms', () {
    test('dotted black everywhere, but no mass anywhere', () {
      final img = _tonedPage(60, 60);
      // ① 69% of the window is near-black *before a pixel moves*, so even a
      //    fill that ends 100% black rises by only ~30 points — under the 35
      //    the guard has demanded since Defect A.
      expect(_blackShare(img, _win), greaterThan(0.65));
      expect(_blackShare(img, _win), lessThan(0.72));
      // ② the ring is just as dotted, so the "is the neighbourhood black" share
      //    test hands the guard its disarming wire… (kDarkMassRingLimit = 0.35)
      final (ringDark, ringLum) = _ringProfile(img, _win);
      expect(ringDark, greaterThanOrEqualTo(0.35), reason: 'the old disarm');
      // ③ …while what the reader sees around the window is **grey**: this is the
      //    whole difference the fix adds. (kRingDarkLumMean = 60)
      expect(ringLum, greaterThan(100), reason: 'a screen is grey, not black');
      // ④ and none of that ink is a *mass*: isolated dots are high frequency,
      //    and the solid share of the same rectangle is a quarter of it at
      //    most, so the dot-proof rise has ~0.75 of a jump left to see.
      expect(_solidShare(img, _win), lessThan(0.3));
    });
  });

  group('F13.3 — a mass assembled out of dots is rolled back', () {
    test('the fill copies dots into the paper gaps → keptDarkMass', () {
      // The mechanism, not a metaphor for it: on a screen whose ink is the
      // majority class a threshold takes the paper *between* the dots for
      // lettering, so every masked pixel's nearest existing pixel is a dot, and
      // a faithful copy of a dot repeated across the gaps is a solid black
      // rectangle. `_fillNearest` invents nothing and gets the block anyway.
      final img = _tonedPage(60, 60);
      final before = _copy(img);
      final (outcome, detail) = TextInpainter.eraseWindow(
        img,
        _maskWhere(12, 12, 36, 36, (x, y) => !_dot(x, y)),
      );

      expect(outcome, EraseOutcome.keptDarkMass, reason: '$detail');
      expect(detail, contains('original pixels restored'));
      expect(img.pixels, equals(before), reason: 'the window went back whole');
      // The reason it fired is legible, and it is the *new* term that fired: the
      // ink share only moved ~30 points, under the old limit, so it has to be
      // the solid rise that noticed — with the ring read by eye, not by count.
      expect(detail, contains('solid='));
      expect(detail, contains('lum'));
      expect(
        detail,
        contains('(solid rose)'),
        reason: 'the dot-proof arm is the one that caught it: $detail',
      );
      // And what is left on the page is the *screen*, not the block: the solid
      // share is back where the tone started. That is the argument for rolling
      // the window back rather than clamping its brightness or inventing a
      // colour — the rollback is the only outcome that cannot make art up.
      expect(_solidShare(img, _win), lessThan(0.3));
    });

    test('a light screen reaches the same verdict the classic way (control)',
        () {
      // The same construction on a *sparse* screen (2 dots per 6 pixels, 11%
      // coverage): here `darkBefore` is low, so the ordinary ink rise fires
      // with room to spare. The control says the new arm did not *invent* this
      // verdict — it extends an existing one to the pages where the ink rise
      // could not add up. Both arms fire, and the reason says so.
      final img = _tonedPage(60, 60, dot: 2);
      final before = _copy(img);
      final (outcome, detail) = TextInpainter.eraseWindow(
        img,
        _maskWhere(12, 12, 36, 36, (x, y) => !_dot(x, y, dot: 2)),
      );
      expect(outcome, EraseOutcome.keptDarkMass, reason: '$detail');
      expect(detail, contains('ink+solid'), reason: 'both arms saw it: $detail');
      expect(img.pixels, equals(before));
    });
  });

  group('F13.3 — the honest dark cases still go through', () {
    test('light lettering out of a black bubble *on a tonal page* is erased',
        () {
      // The version that matters, and the one the old rule passed only by
      // accident. The page is a heavy screen; the bubble is solid black and big
      // enough that the 4px ring around the window is inside it, so the ring is
      // black both by count *and* to the eye; lifting the white strokes ends
      // with a fully black window whose rise is enormous on **both** arms. It
      // must still be kept: a black result inside a black neighbourhood is the
      // eraser following the artwork, and rolling it back would break every
      // dark speech bubble in the medium.
      final img = _tonedPage(120, 120);
      final bubble = IntRect(20, 20, 100, 75);
      _fill(img, bubble, 0);
      final bars = [
        IntRect(34, 34, 86, 40),
        IntRect(34, 46, 78, 52),
        IntRect(34, 58, 84, 64),
      ];
      for (final b in bars) {
        _fill(img, b, 250);
      }
      final window = IntRect(30, 30, 90, 64);
      // Preconditions, on the fixture rather than on the code: both rises are
      // there, so only the ring's verdict can save this window.
      expect(_blackShare(img, window), greaterThan(0.4));
      final (ringDark, ringLum) = _ringProfile(img, window);
      expect(ringDark, greaterThan(0.9), reason: 'the ring is the bubble');
      expect(ringLum, lessThan(60), reason: 'and it is black to the eye');

      final before = _copy(img);
      final (outcome, detail) = TextInpainter.eraseWindow(
        img,
        _maskWhere(30, 30, 60, 34, (x, y) {
          for (final b in bars) {
            if (x >= b.left && x < b.right && y >= b.top && y < b.bottom) {
              return true;
            }
          }
          return false;
        }),
      );
      expect(outcome, EraseOutcome.erased, reason: '$detail');
      expect(img.pixels, isNot(equals(before)), reason: 'the window was '
          'written: a guard that stood down by leaving it untouched would be '
          'fooling itself');
      for (final b in bars) {
        for (var y = b.top; y < b.bottom; y++) {
          for (var x = b.left; x < b.right; x++) {
            expect(
              _lum(img, x, y),
              lessThan(60),
              reason: 'the stroke at $x,$y was lifted out of the bubble',
            );
          }
        }
      }
    });

    test('an honest erase on a sparse screen keeps its screen', () {
      // Lettering on a lightly toned bubble: removing it returns the window to
      // the tone, so `darkAfter` never crosses the mass line and neither rise
      // term is even asked. This is the direction the change is most likely to
      // go wrong in — a guard that fires here eats every toned page — so it is
      // locked explicitly rather than assumed.
      final img = _tonedPage(60, 60, dot: 2);
      _fill(img, IntRect(16, 20, 44, 26), 0);
      final before = _copy(img);
      final (outcome, detail) = TextInpainter.eraseWindow(
        img,
        _maskWhere(
          12,
          12,
          36,
          36,
          (x, y) => y >= 20 && y < 26 && x >= 16 && x < 44,
        ),
      );
      expect(outcome, EraseOutcome.erased, reason: '$detail');
      expect(img.pixels, isNot(equals(before)));
      expect(_blackShare(img, _win), lessThan(0.55));
      expect(_solidShare(img, _win), lessThan(0.3));
    });

    test('the classic bright-artwork block is still caught, with numbers', () {
      // The `inpaint_no_black_block_test.dart` shape kept here so this file is
      // a complete two-sided lock on its own: a white page, one black band as
      // the only source to borrow from, a window that ends up entirely black
      // inside a bright ring.
      final img = _solid(60, 60, 250);
      _fill(img, IntRect(10, 10, 16, 50), 0);
      final before = _copy(img);
      final mask = Uint8List(40 * 40);
      for (var y = 0; y < 40; y++) {
        for (var x = 6; x < 40; x++) {
          mask[y * 40 + x] = 1;
        }
      }
      final (outcome, detail) = TextInpainter.eraseWindow(
        img,
        TextMask(10, 10, 40, 40, mask),
      );
      expect(outcome, EraseOutcome.keptDarkMass, reason: '$detail');
      expect(detail, contains('ink'), reason: 'the classic rise term fired');
      expect(detail, contains('original pixels restored'));
      expect(img.pixels, equals(before));
    });
  });

  group('F13.3 — the erase ledger is printed whatever it says', () {
    test('a clean page still reports all three counts, including the zero', () {
      // The blind spot the report named: with the line printed only inside the
      // `rolledBack > 0` branch, "the eraser never ran here", "the eraser ran
      // and the page is clean" and "a black window went out counted as a
      // success" were three names for the same silence.
      final img = _solid(120, 120, 245);
      _fill(img, IntRect(30, 34, 90, 40), 10);
      _fill(img, IntRect(30, 46, 82, 52), 10);
      _fill(img, IntRect(30, 58, 88, 64), 10);
      final report = TextInpainter.eraseReport(img, [IntRect(28, 32, 92, 66)]);
      expect(report.erased, 1, reason: 'precondition: a normal erase');
      expect(report.rolledBack, 0);

      final ledger = report.describeLedger();
      expect(ledger, contains('erased=1'));
      expect(ledger, contains('skipped=0'));
      expect(ledger, contains('rolled_back=0'), reason: 'the zero *is* the news');
      expect(ledger, contains('rectangles=1'));
      // describe() keeps its own contract untouched: it is the *reasons* line,
      // and it still stays quiet about a rollback that did not happen — which is
      // what `inpaint_no_black_block_test.dart` locks.
      expect(report.describe(), isNot(contains('rolled_back')));
    });

    test('a page the classifier declined is not mistaken for a clean one', () {
      final img = _solid(80, 80, 200); // no strokes at all
      final report = TextInpainter.eraseReport(img, [IntRect(20, 20, 60, 40)]);
      final ledger = report.describeLedger();
      expect(ledger, contains('erased=0'));
      expect(ledger, contains('skipped=1'));
      expect(ledger, contains('rolled_back=0'));
    });

    test('a rolled-back page says so in the ledger as well as in the alarm',
        () {
      final img = _solid(60, 60, 250);
      _fill(img, IntRect(10, 10, 16, 50), 0);
      final mask = Uint8List(40 * 40);
      for (var y = 0; y < 40; y++) {
        for (var x = 6; x < 40; x++) {
          mask[y * 40 + x] = 1;
        }
      }
      final (outcome, detail) = TextInpainter.eraseWindow(
        img,
        TextMask(10, 10, 40, 40, mask),
      );
      final report = EraseReport([
        EraseResult(IntRect(10, 10, 50, 50), outcome, detail),
      ]);
      expect(report.describeLedger(), contains('rolled_back=1'));
      expect(report.describe(), contains('keptDarkMass@10,10'));
    });
  });
}
