import 'dart:math' as math;
import 'dart:typed_data';

import 'package:venera/foundation/image_translation/translation_types.dart';

/// Working window + per-pixel 0/1 stroke mask for one text region.
class TextMask {
  TextMask(this.left, this.top, this.rw, this.rh, this.mask);

  final int left;
  final int top;
  final int rw;
  final int rh;
  final Uint8List mask;
}

/// How one erase attempt ended. Naming these is the point: every `kept*`
/// outcome means **the source pixels are still there, byte for byte**, because
/// a leftover piece of original lettering is a readable page while a black
/// rectangle is not. Defect A's rule — "a failed erase falls back to the
/// original pixels, never to black" — is enforced per window in
/// [TextInpainter.eraseWindow], not by hoping the classifier behaved.
enum EraseOutcome {
  /// Masked pixels were reconstructed from the surrounding artwork.
  erased,

  /// Nothing plausible was classified as lettering ([computeMask] declined):
  /// the window was never touched.
  keptNoMask,

  /// The reconstruction could not finish — a masked pixel had no unmasked
  /// source anywhere in its own window, which means the classifier had taken
  /// the entire background for text. The window was put back.
  keptUnfilled,

  /// The reconstruction ran and left the window a near-black mass it had not
  /// been before: the contrast test had the two classes the wrong way round
  /// and "filled" bright artwork with the darkest pixel in reach. The window
  /// was put back. [kDarkMassAfterShare] explains why this is a *transition*
  /// test rather than a "is it dark?" test.
  keptDarkMass,

  /// The window does not fit the pixel buffer (a stride/length disagreement
  /// between the decoded page and the rectangles handed to us). Nothing was
  /// written: a short buffer reads as zero bytes, and zeros are black pixels.
  keptBadBuffer,
}

/// One line of the erase ledger: what happened to one requested rectangle.
class EraseResult {
  const EraseResult(this.rect, this.outcome, [this.detail]);

  /// The rectangle as the caller asked for it.
  final IntRect rect;

  final EraseOutcome outcome;

  /// Short machine-readable reason for a rollback (`null` otherwise), carried
  /// straight into the log so a rollback can be told apart from a skip
  /// without re-running the eraser.
  final String? detail;

  /// Whether any pixel of the page changed because of this rectangle.
  bool get wrotePixels => outcome == EraseOutcome.erased;
}

/// What an erase pass did to a page, per rectangle. The caller logs it: this
/// file stays free of `dart:ui` *and* of the app logger, so it can keep
/// running anywhere a plain RGBA buffer can be handed to it.
class EraseReport {
  const EraseReport(this.results);

  final List<EraseResult> results;

  int get erased => results.where((r) => r.wrotePixels).length;

  int get rolledBack =>
      results
      .where(
        (r) =>
            r.outcome == EraseOutcome.keptUnfilled ||
            r.outcome == EraseOutcome.keptDarkMass ||
            r.outcome == EraseOutcome.keptBadBuffer,
      )
      .length;

  int get skipped =>
      results.where((r) => r.outcome == EraseOutcome.keptNoMask).length;

  /// One grep-able line. Only the first few rollback reasons are spelled out:
  /// a page carries dozens of rectangles, and a log that repeats one failure
  /// forty times hides every other line in it.
  ///
  /// Note what this line is *not*: it says nothing when nothing was rolled
  /// back. That is deliberate here — but the caller must never use it as "the
  /// ledger", which is why [describeLedger] exists.
  String describe({int detailLimit = 4}) {
    final parts = <String>['erased=$erased', 'skipped=$skipped'];
    if (rolledBack > 0) {
      parts.add('rolled_back=$rolledBack');
      final reasons =
          results
              .where((r) => r.detail != null)
              .take(detailLimit)
              .map(
                (r) =>
                    '${r.outcome.name}@${r.rect.left},${r.rect.top}(${r.detail})',
              )
              .join(' ');
      parts.add('reasons={$reasons}');
    }
    return parts.join(' ');
  }

  /// The full ledger, always: **every** one of the three numbers, whatever the
  /// page did. Phase 13-F13.3.
  ///
  /// [describe] hides `rolled_back` when it is zero, which is right for a
  /// reasons line and wrong for a count. Until now the pipeline printed an
  /// erasure line *only* when something was rolled back, so the two states that
  /// mean opposite things to whoever is reading a screenshot — "the eraser
  /// never ran on this page" (`erased=0 skipped=N`) and "the eraser ran and did
  /// its job" (`erased=N skipped=0`) — were indistinguishable by being
  /// indistinguishable from printing nothing at all. A black block left behind
  /// by a window that was judged `erased` is exactly the case that reads as
  /// "the guard failed" and is in fact "the guard never fired". So count it out
  /// loud every time, on every page.
  String describeLedger() =>
      'erased=$erased skipped=$skipped rolled_back=$rolledBack '
      'rectangles=${results.length}';
}

/// A window whose luminance distribution went from "mostly not black" to
/// "mostly black" across one reconstruction did not have its lettering
/// removed — it had its background replaced by ink. These two numbers are the
/// definition of "mostly", and the delta between them is what a *legitimate*
/// erase can never produce.
const double kDarkMassAfterShare = 0.55;
const double kDarkMassRise = 0.35;

/// How dark the artwork *around* the window has to be for a dark result to be
/// believed. Above this share the neighbourhood is itself black — a dark speech
/// bubble, a night panel — and a window that ends up black there is the eraser
/// doing its job, so the guard stands down.
///
/// Phase 13-F13.3: this share is **no longer sufficient on its own**. A dense
/// screentone is a ring of separated black dots on paper, and at high coverage
/// the near-black *share* of that ring clears 0.35 as a matter of arithmetic —
/// which hands the guard its own disarming wire in exactly the scene the black
/// blocks come from. A tonal ring is therefore believed only when it is also
/// black *to the eye* — see [kRingDarkLumMean].
const double kDarkMassRingLimit = 0.35;

/// Mean luminance under which the neighbourhood counts as genuinely black
/// rather than merely dotted. Phase 13-F13.3's other half.
///
/// The number is deliberately nowhere near a halftone's operating range: a
/// screentone dark enough to sit at a 60/255 *average* is a screen the page
/// reads as shadow, and a window going black inside it is the eraser following
/// the artwork. A black speech bubble is at 0–20; a night panel's fill is under
/// 50; a 50%-coverage tone on paper averages ~127 and a heavy 70% one still
/// sits over 75. Mean rather than median on purpose: the median of a dense dot
/// lattice *is* the dot, so a median would let the very texture that defeats
/// the [kDarkMassRingLimit] share disarm this guard too.
const int kRingDarkLumMean = 60;

/// Luminance below which a pixel counts as black enough to be a block. Set
/// well under any screentone: a grey bubble (lum ≈ 60) that legitimately
/// receives dark lettering must not read as a black block, and a *real* one of
/// these is what the roll back exists for.
const int kNearBlackLum = 24;

/// Radius of the probe used to tell a *mass* of near-black from a *pattern* of
/// it, and the share of that probe that has to be near-black for the pixel to
/// count as part of a mass. Phase 13-F13.3.
///
/// A screentone is high frequency: black islands a pixel or two across on
/// paper, so a dot's own neighbourhood is mostly paper. Solid ink is low
/// frequency: any pixel inside it, pushed a couple of px in any direction, is
/// still inside it. That is the whole difference, and it is the difference the
/// old `darkBefore` could not see — on a toned window the near-black share
/// starts at 0.4–0.7 *because of the dots*, so the "did this window go from
/// bright to black" rise became arithmetically unreachable and the guard
/// against painting a black block over a tonal background simply never ran.
const int kSolidDarkProbe = 2;
const double kSolidDarkShare = 0.8;

/// Pure-Dart text removal: erases the original lettering inside each text region
/// and reconstructs the pixels underneath from the surrounding artwork, so the
/// translated text sits on a clean background instead of a pasted-on patch.
/// Keeps bubble shape, screentone and gradients intact, at zero model download.
///
/// No `dart:ui` — runs on the render path and could run in the worker isolate,
/// and stays unit-testable with a plain RGBA buffer. [image.pixels] is mutated
/// in place to avoid cloning a possibly-huge page.
abstract final class TextInpainter {
  static RgbaImage erase(RgbaImage image, List<IntRect> regions) {
    eraseReport(image, regions);
    return image;
  }

  /// [erase], with a per-rectangle account of what it decided.
  ///
  /// The page is still mutated in place; the report only *describes* it. Two
  /// of the outcomes change behaviour and not merely wording: a reconstruction
  /// that cannot finish, and one that finishes by turning a bright window into
  /// a black mass, are both undone — the window goes back to the bytes it had
  /// before the rectangle. So the eraser's failure mode is "the original
  /// lettering is still readable", never "there is a black block where the
  /// lettering was".
  static EraseReport eraseReport(RgbaImage image, List<IntRect> regions) {
    final results = <EraseResult>[];
    for (final rect in regions) {
      final m = computeMask(image, rect);
      if (m == null) {
        results.add(EraseResult(rect, EraseOutcome.keptNoMask));
        continue;
      }
      final (outcome, detail) = eraseWindow(image, m);
      results.add(EraseResult(rect, outcome, detail));
    }
    return EraseReport(results);
  }

  /// Erases a single already-computed mask, best effort. Used by the AI path as
  /// a fallback when the model rejects a tile, so both paths share the fill.
  /// See [eraseWindow] for the variant that reports what it could not do — and
  /// puts the pixels back when it could not.
  static void eraseWithMask(RgbaImage image, TextMask m) {
    eraseWindow(image, m);
  }

  /// Reconstruct one mask window, atomically.
  ///
  /// The window is snapshotted before a single pixel is written, and the
  /// snapshot goes back over it if either check fails: [EraseOutcome.keptUnfilled]
  /// when some masked pixel had no source at all (the classifier had taken the
  /// whole background for text), [EraseOutcome.keptDarkMass] when the finished
  /// fill left a window mostly near-black where it had mostly not been **and
  /// the artwork around it is bright** — a black result inside a black
  /// neighbourhood is a correctly cleaned dark bubble, not a block.
  /// [EraseOutcome.keptBadBuffer] means the window was never touched because it
  /// does not fit the buffer it would be written into.
  ///
  /// Nothing here ever *invents* a colour: the only pixels this function can
  /// leave behind are ones that already existed on the page, or the page's own
  /// originals.
  static (EraseOutcome, String?) eraseWindow(RgbaImage image, TextMask m) {
    final pixels = image.pixels;
    final w = image.width;
    if (m.rw <= 0 || m.rh <= 0) {
      return (EraseOutcome.keptBadBuffer, 'window=${m.rw}x${m.rh}');
    }
    if (m.left < 0 ||
        m.top < 0 ||
        m.left + m.rw > w ||
        m.top + m.rh > image.height) {
      return (
        EraseOutcome.keptBadBuffer,
        'window ${m.left},${m.top} ${m.rw}x${m.rh} vs page ${w}x${image.height}',
      );
    }
    final needed = (m.top + m.rh) * w * 4;
    if (pixels.length < needed) {
      return (
        EraseOutcome.keptBadBuffer,
        'buffer=${pixels.length}B < ${needed}B for ${w}x${image.height}',
      );
    }

    final before = _snapshotWindow(pixels, w, m.left, m.top, m.rw, m.rh);
    final darkBefore = _darkShare(pixels, w, m.left, m.top, m.rw, m.rh);
    // Phase 13-F13.3: the same window, measured for *mass* instead of for
    // ink-anywhere. A tonal window is already half near-black before a single
    // pixel is touched, and that is precisely how it defeats the rise test
    // below — so the rise is also measured on the low-frequency number, the one
    // a dot lattice cannot fake.
    final solidBefore = _solidDarkShare(
        pixels,
        w,
        image.height,
        m.left,
        m.top,
        m.rw,
        m.rh,
      );

    final unfilled = _fillNearest(pixels, w, m.left, m.top, m.rw, m.rh, m.mask);
    if (unfilled > 0) {
      _restoreWindow(pixels, w, m.left, m.top, m.rw, m.rh, before);
      return (
        EraseOutcome.keptUnfilled,
        'unfilled=$unfilled/${m.rw * m.rh} original pixels restored',
      );
    }
    _relax(pixels, w, m.left, m.top, m.rw, m.rh, m.mask, 2);

    final darkAfter = _darkShare(pixels, w, m.left, m.top, m.rw, m.rh);
    final solidAfter = _solidDarkShare(
        pixels,
        w,
        image.height,
        m.left,
        m.top,
        m.rw,
        m.rh,
      );
    final (ringDark, ringLum) = _ringProfile(
      pixels,
      w,
      image.height,
      m.left,
      m.top,
      m.rw,
      m.rh,
    );
    // "A black area inside bright surroundings" is the whole definition of the
    // defect, so the surroundings test is what decides whether the guard fires
    // at all — but Phase 13-F13.3 is the reason it now asks *two* questions of
    // the ring. Near-black share alone reads a dense screentone as a black
    // neighbourhood and stands down on exactly the pages that produce the
    // blocks, so a ring only counts as black when it is also black to the eye:
    // mean luminance under [kRingDarkLumMean]. A light lettering lift out of a
    // real black bubble keeps both (share 1.0, mean ≈ 8), which is the case this
    // guard must never touch.
    final ringIsBlack =
        ringDark >= kDarkMassRingLimit && ringLum < kRingDarkLumMean;
    final massRise = darkAfter - darkBefore > kDarkMassRise;
    final solidRise = solidAfter - solidBefore > kDarkMassRise;
    if (darkAfter > kDarkMassAfterShare &&
        (massRise || solidRise) &&
        !ringIsBlack) {
      _restoreWindow(pixels, w, m.left, m.top, m.rw, m.rh, before);
      final which = [
        if (massRise) 'ink',
        if (solidRise) 'solid',
      ].join('+');
      return (
        EraseOutcome.keptDarkMass,
        'black=${(darkBefore * 100).round()}%->${(darkAfter * 100).round()}% '
        'solid=${(solidBefore * 100).round()}%->${(solidAfter * 100).round()}% '
        'around=${(ringDark * 100).round()}%/${ringLum.round()}lum '
        '($which rose) original pixels restored',
      );
    }
    return (EraseOutcome.erased, null);
  }

  /// The frame just outside the window, read two ways: the share of it that is
  /// near-black, and its **mean luminance**.
  ///
  /// This is what turns the mass test from a guess into a *contrast* judgement:
  /// a black block is a black area inside bright surroundings. Take away that
  /// precondition and the guard would roll back every legitimate erase of light
  /// lettering out of a **black** speech bubble — there, the window going fully
  /// black is the eraser working correctly, and the ring says so.
  ///
  /// Phase 13-F13.3 is why one number is not enough. A screentone ring is
  /// black *dots* on paper: its near-black share is the dot coverage and walks
  /// past 0.35 on any heavy screen, while what the reader sees is a grey band.
  /// The share answers "is there black here", the mean answers "is this area
  /// black", and only the second one is a reason to stand down.
  static (double darkShare, double lumMean) _ringProfile(
    Uint8List pixels,
    int imgW,
    int imgH,
    int left,
    int top,
    int rw,
    int rh,
  ) {
    const band = 4;
    final x0 = math.max(0, left - band),
        x1 = math.min(imgW - 1, left + rw + band);
    final y0 = math.max(0, top - band),
        y1 = math.max(0, math.min(imgH - 1, top + rh + band));
    var dark = 0, count = 0;
    var sum = 0.0;
    void sample(int x, int y) {
      final i = (y * imgW + x) * 4;
      if (i + 2 >= pixels.length) return;
      final lum =
          0.299 * pixels[i] + 0.587 * pixels[i + 1] + 0.114 * pixels[i + 2];
      if (lum < kNearBlackLum) dark++;
      sum += lum;
      count++;
    }

    for (var y = y0; y <= y1; y += 2) {
      for (var x = x0; x <= x1; x += 2) {
        final outside = x < left || x >= left + rw || y < top || y >= top + rh;
        if (outside) sample(x, y);
      }
    }
    // "No ring at all" means the window is the whole page: there is nothing to
    // contrast against, so nothing may be believed about a black result —
    // share 1 ("as dark as it gets") with a mean of 0 would stand the guard
    // down, and a full-page mask is exactly the case that needs it. Both
    // readings say "unknown", so the pair is the conservative one: the share
    // says *not* black (0) and the mean says 255, and the guard stays armed.
    if (count == 0) return (0, 255);
    return (dark / count, sum / count);
  }

  /// Share of a window's pixels that are near-black **and stay near-black when
  /// the probe walks away from them** — the low-frequency half of the same
  /// question [_darkShare] asks. See [kSolidDarkProbe] for why the two are not
  /// interchangeable.
  static double _solidDarkShare(
    Uint8List pixels,
    int imgW,
    int imgH,
    int left,
    int top,
    int rw,
    int rh,
  ) {
    final step = math.max(1, math.min(rw, rh) ~/ 20);
    var solid = 0, count = 0;
    bool nearBlack(int x, int y) {
      // Off-page is not "bright": a mass that runs to the edge is still a mass.
      if (x < 0 || y < 0 || x >= imgW || y >= imgH) return true;
      final i = (y * imgW + x) * 4;
      if (i + 2 >= pixels.length) return true;
      return 0.299 * pixels[i] +
              0.587 * pixels[i + 1] +
              0.114 * pixels[i + 2] <
          kNearBlackLum;
    }

    for (var y = 0; y < rh; y += step) {
      for (var x = 0; x < rw; x += step) {
        count++;
        if (!nearBlack(left + x, top + y)) continue;
        var dark = 0, probe = 0;
        for (var dy = -kSolidDarkProbe; dy <= kSolidDarkProbe; dy++) {
          for (var dx = -kSolidDarkProbe; dx <= kSolidDarkProbe; dx++) {
            probe++;
            if (nearBlack(left + x + dx, top + y + dy)) dark++;
          }
        }
        if (probe > 0 && dark / probe >= kSolidDarkShare) solid++;
      }
    }
    return count == 0 ? 0 : solid / count;
  }

  /// Share of a window's pixels whose luminance is under [kNearBlackLum].
  /// Sampled on a stride grid: the number decides "was this window turned into
  /// a black block", and a few hundred samples say that without doubt.
  ///
  /// Note what this cannot tell apart, which is why [_solidDarkShare] exists
  /// alongside it rather than after it: 60% of a window being near-black is
  /// equally true of a solid ink mass and of a paper covered in a heavy dot
  /// screen. Only the *transition* between the two states is the defect, and a
  /// share that already counts the dots cannot see a transition.
  static double _darkShare(
    Uint8List pixels,
    int imgW,
    int left,
    int top,
    int rw,
    int rh,
  ) {
    final step = math.max(1, math.min(rw, rh) ~/ 20);
    var dark = 0, count = 0;
    for (var y = 0; y < rh; y += step) {
      final row = (top + y) * imgW + left;
      for (var x = 0; x < rw; x += step) {
        final i = (row + x) * 4;
        final lum =
            0.299 * pixels[i] + 0.587 * pixels[i + 1] + 0.114 * pixels[i + 2];
        if (lum < kNearBlackLum) dark++;
        count++;
      }
    }
    return count == 0 ? 0 : dark / count;
  }

  static Uint8List _snapshotWindow(
    Uint8List pixels,
    int imgW,
    int left,
    int top,
    int rw,
    int rh,
  ) {
    final snap = Uint8List(rw * rh * 4);
    for (var y = 0; y < rh; y++) {
      final src = ((top + y) * imgW + left) * 4;
      snap.setRange(y * rw * 4, y * rw * 4 + rw * 4, pixels, src);
    }
    return snap;
  }

  static void _restoreWindow(
    Uint8List pixels,
    int imgW,
    int left,
    int top,
    int rw,
    int rh,
    Uint8List snap,
  ) {
    for (var y = 0; y < rh; y++) {
      final dst = ((top + y) * imgW + left) * 4;
      pixels.setRange(dst, dst + rw * 4, snap, y * rw * 4);
    }
  }

  /// Splits the region's luminance (Otsu) into background and text strokes,
  /// then dilates to swallow anti-aliased edges. Returns null when nothing
  /// plausible should be erased (too small, or the "text" class swallows the
  /// window — a near-uniform crop or heavy screentone the threshold misread).
  /// Shared by the Dart fill and the AI model path so both agree on what is text.
  static TextMask? computeMask(RgbaImage image, IntRect region) {
    var w = image.width;
    var h = image.height;
    // Region plus a border: the fill needs known pixels to borrow, and the ring
    // sampling needs to see the true background.
    var pad = math.max(
      4,
      (math.min(region.width, region.height) * 0.25).round(),
    );
    var left = (region.left - pad).clamp(0, w - 1);
    var top = (region.top - pad).clamp(0, h - 1);
    var right = (region.right + pad).clamp(1, w);
    var bottom = (region.bottom + pad).clamp(1, h);
    var rw = right - left;
    var rh = bottom - top;
    if (rw < 6 || rh < 6) return null;

    var pixels = image.pixels;
    var n = rw * rh;

    var lum = Uint8List(n);
    for (var y = 0; y < rh; y++) {
      var srcRow = (top + y) * w + left;
      var dstRow = y * rw;
      for (var x = 0; x < rw; x++) {
        var i = (srcRow + x) * 4;
        lum[dstRow + x] =
            (0.299 * pixels[i] + 0.587 * pixels[i + 1] + 0.114 * pixels[i + 2])
                .round()
                .clamp(0, 255);
      }
    }

    var bgLum = _ringMeanLuminance(lum, rw, rh);
    var threshold = _otsu(lum);

    // Class means around the split, so the text class is chosen by which mean
    // sits farther from the background — robust when the threshold lands on the
    // background value itself (a clean two-tone crop), where a threshold sign
    // test would misclassify.
    var (lowMean, highMean) = _classMeans(lum, threshold);
    var bgIsHigh = (highMean - bgLum).abs() <= (lowMean - bgLum).abs();
    var textMean = bgIsHigh ? lowMean : highMean;

    // A contrast margin keeps low-contrast noise from being erased.
    const minMargin = 24;
    var mask = Uint8List(n);
    var maskCount = 0;
    var textIsDark = textMean < bgLum;
    // The padded window is context for background sampling and filling only.
    // Candidate strokes must stay close to the detector's text rectangle;
    // otherwise high-contrast line art in that context gets erased as well.
    var guard = math
        .max(1, (math.min(region.width, region.height) * 0.04).round())
        .clamp(1, 3);
    var allowedLeft = (region.left - guard - left).clamp(0, rw);
    var allowedTop = (region.top - guard - top).clamp(0, rh);
    var allowedRight = (region.right + guard - left).clamp(0, rw);
    var allowedBottom = (region.bottom + guard - top).clamp(0, rh);
    for (var y = allowedTop; y < allowedBottom; y++) {
      for (var x = allowedLeft; x < allowedRight; x++) {
        var i = y * rw + x;
        var l = lum[i];
        var isText = textIsDark
            ? l <= threshold && (bgLum - l) >= minMargin
            : l > threshold && (l - bgLum) >= minMargin;
        if (isText) {
          mask[i] = 1;
          maskCount++;
        }
      }
    }
    // Judge density against the detector rectangle, not the padded sampling
    // window. Near a page edge that padding is clipped; using the smaller
    // clipped window made dense title lettering look like an invalid mask and
    // left the source text underneath the translation. Still reject a crop
    // where almost the whole OCR rectangle became foreground, which is much
    // more likely to be line art or screentone than glyphs.
    var allowedArea = math.max(
      1,
      (allowedRight - allowedLeft) * (allowedBottom - allowedTop),
    );
    if (maskCount == 0 || maskCount > allowedArea * 0.85) return null;

    // Drop isolated speck components (threshold noise) before erasing: an
    // erased+filled speck becomes a faint smudge on otherwise clean art. Only
    // size is used — see [_filterComponents] for why a solid/large component is
    // never rejected (it would erase bold lettering).
    maskCount = _filterComponents(mask, rw, rh);
    if (maskCount == 0) return null;

    // Dilate to swallow the anti-aliased halo around each stroke — leftover
    // grey fringe reads as "text not fully erased". The radius scales with the
    // stroke thickness (approximated from the region size) so thin lettering
    // gets a tight grow and bold/large text a wider one, instead of a fixed 2px
    // that under-covers big glyphs.
    var radius = math.max(2, (math.min(rw, rh) * 0.03).round()).clamp(2, 5);
    mask = _dilate(mask, rw, rh, radius);
    // Dilation covers anti-aliased glyph edges but must not grow into artwork.
    for (var y = 0; y < rh; y++) {
      for (var x = 0; x < rw; x++) {
        if (x < allowedLeft ||
            x >= allowedRight ||
            y < allowedTop ||
            y >= allowedBottom) {
          mask[y * rw + x] = 0;
        }
      }
    }
    return TextMask(left, top, rw, rh, mask);
  }

  static int _ringMeanLuminance(Uint8List lum, int rw, int rh) {
    var sum = 0, count = 0;
    for (var x = 0; x < rw; x++) {
      sum += lum[x];
      sum += lum[(rh - 1) * rw + x];
      count += 2;
    }
    for (var y = 1; y < rh - 1; y++) {
      sum += lum[y * rw];
      sum += lum[y * rw + rw - 1];
      count += 2;
    }
    return count == 0 ? 255 : (sum / count).round();
  }

  /// Otsu's method: luminance threshold maximising between-class variance.
  static int _otsu(Uint8List lum) {
    var hist = Int32List(256);
    for (var l in lum) {
      hist[l]++;
    }
    var total = lum.length;
    var sum = 0.0;
    for (var t = 0; t < 256; t++) {
      sum += t * hist[t];
    }
    var sumB = 0.0;
    var wB = 0;
    var maxVar = -1.0;
    var threshold = 127;
    for (var t = 0; t < 256; t++) {
      wB += hist[t];
      if (wB == 0) continue;
      var wF = total - wB;
      if (wF == 0) break;
      sumB += t * hist[t];
      var mB = sumB / wB;
      var mF = (sum - sumB) / wF;
      var between = wB * wF * (mB - mF) * (mB - mF);
      if (between > maxVar) {
        maxVar = between;
        threshold = t;
      }
    }
    return threshold;
  }

  /// Mean luminance of the pixels at or below [threshold] and above it. Empty
  /// classes fall back to the threshold value.
  static (double, double) _classMeans(Uint8List lum, int threshold) {
    var loSum = 0, loN = 0, hiSum = 0, hiN = 0;
    for (var l in lum) {
      if (l <= threshold) {
        loSum += l;
        loN++;
      } else {
        hiSum += l;
        hiN++;
      }
    }
    var lo = loN == 0 ? threshold.toDouble() : loSum / loN;
    var hi = hiN == 0 ? threshold.toDouble() : hiSum / hiN;
    return (lo, hi);
  }

  /// Removes mask components that are not text strokes, in place, and returns
  /// the surviving on-pixel count. Two rejects: a speck too small to be a glyph
  /// (threshold noise), and a component that fills a large fraction of its own
  /// bounding box (a solid blob — bubble edge or artwork the contrast test
  /// caught — rather than thin lettering). 4-connected flood fill per component.
  static int _filterComponents(Uint8List mask, int rw, int rh) {
    var n = rw * rh;
    var seen = Uint8List(n);
    var stack = <int>[];
    // Specks below this many pixels are threshold noise (isolated dust that
    // would otherwise be erased+filled into a faint smudge), scaled to the
    // region so a large crop tolerates larger dust without dropping real
    // punctuation. Deliberately does NOT reject large/solid components: a bold
    // stroke or a bar is solid within its own bounding box and is
    // indistinguishable from artwork by fill-ratio, so a fill test would erase
    // real lettering. The "text class swallowed the window" case is already
    // guarded by the maskCount ceiling in computeMask.
    var minPixels = math.max(6, (n * 0.0008).round());
    var kept = 0;
    for (var start = 0; start < n; start++) {
      if (mask[start] == 0 || seen[start] != 0) continue;
      var count = 0;
      var members = <int>[];
      stack.add(start);
      seen[start] = 1;
      while (stack.isNotEmpty) {
        var i = stack.removeLast();
        members.add(i);
        var x = i % rw;
        count++;
        if (x > 0 && mask[i - 1] == 1 && seen[i - 1] == 0) {
          seen[i - 1] = 1;
          stack.add(i - 1);
        }
        if (x < rw - 1 && mask[i + 1] == 1 && seen[i + 1] == 0) {
          seen[i + 1] = 1;
          stack.add(i + 1);
        }
        if (i - rw >= 0 && mask[i - rw] == 1 && seen[i - rw] == 0) {
          seen[i - rw] = 1;
          stack.add(i - rw);
        }
        if (i + rw < n && mask[i + rw] == 1 && seen[i + rw] == 0) {
          seen[i + rw] = 1;
          stack.add(i + rw);
        }
      }
      if (count < minPixels) {
        for (var i in members) {
          mask[i] = 0;
        }
      } else {
        kept += count;
      }
    }
    return kept;
  }

  /// Separable box dilation (two 1-D passes).
  static Uint8List _dilate(Uint8List mask, int rw, int rh, int radius) {
    var tmp = Uint8List(mask.length);
    for (var y = 0; y < rh; y++) {
      var row = y * rw;
      for (var x = 0; x < rw; x++) {
        var on = false;
        for (var dx = -radius; dx <= radius && !on; dx++) {
          var nx = x + dx;
          if (nx >= 0 && nx < rw && mask[row + nx] == 1) on = true;
        }
        tmp[row + x] = on ? 1 : 0;
      }
    }
    var out = Uint8List(mask.length);
    for (var x = 0; x < rw; x++) {
      for (var y = 0; y < rh; y++) {
        var on = false;
        for (var dy = -radius; dy <= radius && !on; dy++) {
          var ny = y + dy;
          if (ny >= 0 && ny < rh && tmp[ny * rw + x] == 1) on = true;
        }
        out[y * rw + x] = on ? 1 : 0;
      }
    }
    return out;
  }

  /// Fills each masked pixel with its nearest non-masked colour via a two-pass
  /// chamfer sweep. Clean flat fill on solid bubbles, good over gradients.
  ///
  /// Returns how many masked pixels had **no** source to borrow — the whole
  /// window was masked, so the sweep had nowhere to start from. Those pixels
  /// are left exactly as they were (this function never writes a substitute
  /// colour), and the caller uses the count to decide whether to keep the
  /// result or roll the window back.
  static int _fillNearest(
    Uint8List pixels,
    int imgW,
    int left,
    int top,
    int rw,
    int rh,
    Uint8List mask,
  ) {
    const inf = 1 << 29;
    var dist = Int32List(rw * rh);
    var srcOf = Int32List(rw * rh);
    for (var i = 0; i < rw * rh; i++) {
      if (mask[i] == 0) {
        dist[i] = 0;
        var x = i % rw, y = i ~/ rw;
        srcOf[i] = (top + y) * imgW + (left + x);
      } else {
        dist[i] = inf;
        srcOf[i] = -1;
      }
    }

    void consider(int i, int fromIndex, int stepCost) {
      if (dist[fromIndex] >= inf) return;
      var nd = dist[fromIndex] + stepCost;
      if (nd < dist[i]) {
        dist[i] = nd;
        srcOf[i] = srcOf[fromIndex];
      }
    }

    // Chamfer weights 3 (orthogonal) / 4 (diagonal).
    for (var y = 0; y < rh; y++) {
      for (var x = 0; x < rw; x++) {
        var i = y * rw + x;
        if (mask[i] == 0) continue;
        if (x > 0) consider(i, i - 1, 3);
        if (y > 0) consider(i, i - rw, 3);
        if (x > 0 && y > 0) consider(i, i - rw - 1, 4);
        if (x < rw - 1 && y > 0) consider(i, i - rw + 1, 4);
      }
    }
    for (var y = rh - 1; y >= 0; y--) {
      for (var x = rw - 1; x >= 0; x--) {
        var i = y * rw + x;
        if (mask[i] == 0) continue;
        if (x < rw - 1) consider(i, i + 1, 3);
        if (y < rh - 1) consider(i, i + rw, 3);
        if (x < rw - 1 && y < rh - 1) consider(i, i + rw + 1, 4);
        if (x > 0 && y < rh - 1) consider(i, i + rw - 1, 4);
      }
    }

    var unfilled = 0;
    for (var y = 0; y < rh; y++) {
      for (var x = 0; x < rw; x++) {
        var i = y * rw + x;
        if (mask[i] == 0) continue;
        var src = srcOf[i];
        if (src < 0) {
          // No colour to borrow: leave the original pixel standing — it is
          // either lettering or artwork, and both beat an invented fill — and
          // count it, so the caller can roll the whole window back instead of
          // shipping a half-cleaned rectangle.
          unfilled++;
          continue;
        }
        var di = ((top + y) * imgW + (left + x)) * 4;
        var si = src * 4;
        pixels[di] = pixels[si];
        pixels[di + 1] = pixels[si + 1];
        pixels[di + 2] = pixels[si + 2];
        pixels[di + 3] = pixels[si + 3];
      }
    }
    return unfilled;
  }

  /// Jacobi relaxation over masked pixels only: softens seams left by the
  /// nearest-fill along the boundary between two source regions.
  static void _relax(
    Uint8List pixels,
    int imgW,
    int left,
    int top,
    int rw,
    int rh,
    Uint8List mask,
    int passes,
  ) {
    for (var p = 0; p < passes; p++) {
      var snap = Uint8List(rw * rh * 4);
      for (var y = 0; y < rh; y++) {
        for (var x = 0; x < rw; x++) {
          var di = ((top + y) * imgW + (left + x)) * 4;
          var oi = (y * rw + x) * 4;
          snap[oi] = pixels[di];
          snap[oi + 1] = pixels[di + 1];
          snap[oi + 2] = pixels[di + 2];
          snap[oi + 3] = pixels[di + 3];
        }
      }
      for (var y = 0; y < rh; y++) {
        for (var x = 0; x < rw; x++) {
          var i = y * rw + x;
          if (mask[i] == 0) continue;
          var r = 0, g = 0, b = 0, a = 0, c = 0;
          void acc(int nx, int ny) {
            if (nx < 0 || ny < 0 || nx >= rw || ny >= rh) return;
            var oi = (ny * rw + nx) * 4;
            r += snap[oi];
            g += snap[oi + 1];
            b += snap[oi + 2];
            a += snap[oi + 3];
            c++;
          }

          acc(x - 1, y);
          acc(x + 1, y);
          acc(x, y - 1);
          acc(x, y + 1);
          if (c == 0) continue;
          var di = ((top + y) * imgW + (left + x)) * 4;
          pixels[di] = (r / c).round();
          pixels[di + 1] = (g / c).round();
          pixels[di + 2] = (b / c).round();
          pixels[di + 3] = (a / c).round();
        }
      }
    }
  }
}
