import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/image_translation/inpaint.dart';
import 'package:venera/foundation/image_translation/translation_types.dart';

/// Defect A (black blocks), eraser side.
///
/// What this file pins down is the *promise*, not the algorithm: a rectangle
/// the eraser cannot reconstruct honestly goes back to the bytes the page had
/// before, so the worst the eraser can do is leave the original lettering
/// readable. A black rectangle is a worse outcome than a leftover glyph — the
/// glyph was on the page to begin with, the block was not — so every failure
/// path below has to answer `kept*` and leave the buffer untouched.
///
/// The tests hand [TextInpainter.eraseWindow] masks directly instead of going
/// through the classifier wherever the point is what the *fill* does with a
/// given mask; the classifier's own judgement (including the two cases that
/// must NOT be rolled back) is covered by the `computeMask`-driven groups.
///
/// NOT VERIFIED LOCALLY: this file is never executed in this workspace (no
/// `flutter test` allowed). It is listed under "待云端 Test job 验证".
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

void _paintRect(RgbaImage img, IntRect r, int v) {
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

/// A window-sized mask: `1` inside [band], `0` in the [keep] columns at the
/// window's left edge (the only pixels the nearest-fill can borrow from).
TextMask _bandMask(int left, int top, int rw, int rh, {required int keepCols}) {
  final mask = Uint8List(rw * rh);
  for (var y = 0; y < rh; y++) {
    for (var x = keepCols; x < rw; x++) {
      mask[y * rw + x] = 1;
    }
  }
  return TextMask(left, top, rw, rh, mask);
}

void main() {
  group('eraseWindow — a fill that cannot finish is undone', () {
    test('an all-masked window keeps its original bytes, pixel for pixel', () {
      final img = _solid(60, 60, 250);
      final before = _copy(img);
      final mask = Uint8List(40 * 40);
      mask.fillRange(0, mask.length, 1);

      final (outcome, detail) = TextInpainter.eraseWindow(
        img,
        TextMask(10, 10, 40, 40, mask),
      );

      expect(outcome, EraseOutcome.keptUnfilled);
      expect(detail, contains('original pixels restored'));
      expect(img.pixels, equals(before), reason: 'nothing was invented');
    });

    test('bright artwork is never repainted near-black', () {
      // The inverted-classifier shape: almost the whole window was claimed as
      // "text" and the only pixels left to borrow from are black. The
      // reconstruction therefore *runs* — nothing is unfilled — and finishes
      // with a black block, which is exactly the reported defect.
      final img = _solid(60, 60, 250);
      _paintRect(img, IntRect(10, 10, 16, 50), 0); // the 6 borrowable columns
      final before = _copy(img);

      final (outcome, detail) = TextInpainter.eraseWindow(
        img,
        _bandMask(10, 10, 40, 40, keepCols: 6),
      );

      expect(outcome, EraseOutcome.keptDarkMass);
      expect(detail, contains('original pixels restored'));
      expect(img.pixels, equals(before), reason: 'the block was undone');
      // And the reason it was undone is still visible in the numbers: the
      // window is bright again because it was never allowed to go dark.
      expect(_lum(img, 40, 30), greaterThan(200));
    });

    test('a window that does not fit the buffer writes nothing and throws '
        'nothing', () {
      final img = _solid(60, 60, 250);
      final before = _copy(img);
      final mask = Uint8List(10 * 10)..fillRange(0, 100, 1);

      final (outcome, _) = TextInpainter.eraseWindow(
        img,
        TextMask(55, 55, 10, 10, mask), // runs off the right and bottom edge
      );

      expect(outcome, EraseOutcome.keptBadBuffer);
      expect(img.pixels, equals(before));
    });
  });

  group('eraseReport — the honest cases stay erased', () {
    test('dark lettering on a light bubble is erased, and no black block is '
        'left behind', () {
      final img = _solid(120, 120, 245);
      // Three bars of "lettering".
      _paintRect(img, IntRect(30, 34, 90, 40), 10);
      _paintRect(img, IntRect(30, 46, 82, 52), 10);
      _paintRect(img, IntRect(30, 58, 88, 64), 10);

      final report = TextInpainter.eraseReport(img, [IntRect(28, 32, 92, 66)]);

      expect(report.erased, 1, reason: 'a normal erase is not rolled back');
      expect(report.rolledBack, 0);
      // Every pixel of the footprint is now bubble-coloured: the glyph bars are
      // gone and nothing replaced them with black.
      for (var y = 32; y < 66; y++) {
        for (var x = 28; x < 92; x++) {
          expect(
            _lum(img, x, y),
            greaterThan(150),
            reason: '($x,$y) must not end up a dark block',
          );
        }
      }
    });

    test('light lettering on a black bubble is still erased (the dark-mass '
        'guard must not bite here)', () {
      // This is the fixture that makes the rollback rule a *transition* test
      // rather than a "is it dark" test: removing white strokes from a black
      // bubble legitimately leaves a window that is almost entirely black, and
      // rolling that back would break every dark speech bubble in the medium.
      final img = _solid(120, 120, 8);
      _paintRect(img, IntRect(30, 34, 90, 40), 250);
      _paintRect(img, IntRect(30, 46, 82, 52), 250);
      _paintRect(img, IntRect(30, 58, 88, 64), 250);

      final report = TextInpainter.eraseReport(img, [IntRect(28, 32, 92, 66)]);

      expect(
        report.erased,
        1,
        reason: 'a dark bubble getting darker is not a black block',
      );
      for (var y = 32; y < 66; y++) {
        for (var x = 28; x < 92; x++) {
          expect(_lum(img, x, y), lessThan(90), reason: '($x,$y) stroke left');
        }
      }
    });

    test('a rectangle the classifier declines is reported as skipped, not as '
        'erased', () {
      final img = _solid(80, 80, 200); // no strokes at all
      final report = TextInpainter.eraseReport(img, [IntRect(20, 20, 60, 40)]);
      expect(report.erased, 0);
      expect(report.skipped, 1);
      expect(report.results.single.outcome, EraseOutcome.keptNoMask);
      expect(report.describe(), isNot(contains('rolled_back')));
    });

    test('describe() spells out a rollback so the log can be read as evidence',
        () {
      final img = _solid(60, 60, 250);
      _paintRect(img, IntRect(10, 10, 16, 50), 0);
      final (outcome, detail) = TextInpainter.eraseWindow(
        img,
        _bandMask(10, 10, 40, 40, keepCols: 6),
      );
      final report = EraseReport([
        EraseResult(IntRect(10, 10, 50, 50), outcome, detail),
      ]);
      expect(report.describe(), contains('rolled_back=1'));
      expect(report.describe(), contains('keptDarkMass@10,10'));
      expect(report.describe(), contains('original pixels restored'));
    });
  });

  group('erase() API stability', () {
    test('still returns the page it was handed, mutated in place', () {
      final img = _solid(120, 120, 245);
      _paintRect(img, IntRect(30, 34, 90, 40), 10);
      final out = TextInpainter.erase(img, [IntRect(28, 32, 92, 42)]);
      expect(identical(out, img), isTrue);
    });
  });
}
