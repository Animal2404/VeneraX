import 'dart:math' as math;
import 'dart:typed_data';

import 'package:venera/foundation/image_translation/translation_types.dart';

/// Speech-balloon segmentation on the page's own pixels.
///
/// Why this exists, and why it is not another threshold on box geometry:
/// two neighbouring bubbles fuse when their text blocks are close enough for the
/// clustering gates to link them, and at that distance the *geometry* of the two
/// blocks is indistinguishable from one tightly-set block inside a single bubble
/// (the narration-gap arithmetic in the plan shows the two cases overlap). The
/// signal that does separate them is the balloon itself: a bubble is a closed
/// bright region bounded by an outline, so two blocks belong to the same bubble
/// exactly when a flood fill from one block's centre reaches the other.
///
/// This is the approach both real-world projects converged on —
/// `manga-image-translator`'s `rendering/ballon_extractor.py` and
/// `BallonsTranslator`'s `utils/textblock_mask.py::canny_flood` — reduced to the
/// part that matters here: no Canny dependency, a bounded window per block, and
/// an explicit `enclosed` verdict so a block sitting on open artwork (where the
/// fill leaks out) falls back to geometry instead of guessing.
///
/// Pure Dart over an RGBA buffer: no isolate, no model, no IO, no `dart:ui` —
/// so every rule below is pinned by a test on synthetic pixels.

/// The balloon a text block sits in, or the verdict that it is not enclosed.
class BalloonRegion {
  const BalloonRegion({
    required this.bounds,
    required this.mask,
    required this.maskWidth,
    required this.maskHeight,
    required this.seedX,
    required this.seedY,
    required this.area,
    required this.enclosed,
  });

  /// The window the fill was confined to, in page px.
  final IntRect bounds;

  /// 1 = inside the balloon, 0 = outside. Row-major, `maskWidth × maskHeight`.
  final Uint8List mask;

  final int maskWidth;
  final int maskHeight;

  /// The fill's origin, in page px — the block's centre, or a nearby bright
  /// pixel when the centre itself is ink.
  final int seedX;
  final int seedY;

  /// Pixels the fill reached.
  final int area;

  /// Whether the fill stopped at ink rather than at the window's edge. False
  /// means "this block is not inside a closed shape I can see", which is the
  /// case the caller must treat as *unknown*, never as "same balloon".
  final bool enclosed;

  /// Whether [x],[y] (page px) is inside this balloon.
  bool contains(int x, int y) {
    final mx = x - bounds.left;
    final my = y - bounds.top;
    if (mx < 0 || my < 0 || mx >= maskWidth || my >= maskHeight) return false;
    return mask[my * maskWidth + mx] != 0;
  }
}

/// Default luma margin: a pixel counts as balloon interior while it is at least
/// this share of the window's own mean luma. Lettering and outlines are far
/// darker than the paper they sit on, so a window-relative threshold travels
/// between a white page, a grey screentone and a scanned-yellow page without a
/// second constant.
const double kBalloonInteriorShare = 0.62;

/// How far past the block the fill window reaches, as a share of the block's
/// longer side. The reference implementations grow the window to about the
/// balloon's own size (they start from a detected balloon rectangle); a text
/// block is smaller than its balloon, so this is generous on purpose — a window
/// that is too small turns every block into `enclosed: false` and disables the
/// veto entirely.
const double kBalloonWindowGrow = 1.2;

/// Smallest fill, as a share of the window, that may be called a balloon. Below
/// this the fill only found a crack between strokes (a letter counter, a gap in
/// the screentone) and says nothing about the block's neighbourhood.
const double kBalloonMinAreaShare = 0.06;

/// Finds the bright region around [box].
///
/// Returns null when the window cannot be placed (box outside the image, or a
/// degenerate box). A non-null result with `enclosed: false` is a real answer:
/// the fill reached the window's edge, so this block is not inside a shape we
/// can bound — the caller must not read that as "same balloon as its
/// neighbour".
BalloonRegion? balloonRegionOf(
  RgbaImage image,
  IntRect box, {
  double interiorShare = kBalloonInteriorShare,
  double windowGrow = kBalloonWindowGrow,
  double minAreaShare = kBalloonMinAreaShare,
  int? seedX,
  int? seedY,
}) {
  final imageWidth = image.width;
  final imageHeight = image.height;
  if (imageWidth <= 0 || imageHeight <= 0) return null;
  if (box.width <= 0 || box.height <= 0) return null;

  final grow = math.max(
    6,
    (math.max(box.width, box.height) * windowGrow).round(),
  );
  final left = math.max(0, box.left - grow);
  final top = math.max(0, box.top - grow);
  final right = math.min(imageWidth, box.right + grow);
  final bottom = math.min(imageHeight, box.bottom + grow);
  final windowWidth = right - left;
  final windowHeight = bottom - top;
  if (windowWidth < 3 || windowHeight < 3) return null;

  final pixels = image.pixels;
  final stride = imageWidth * 4;
  final count = windowWidth * windowHeight;

  // The window's own mean luma is the yardstick: the fill stops at anything
  // clearly darker than the paper around it (lettering, outline, artwork),
  // which is what makes it a *balloon* fill rather than a page-wide one.
  var sum = 0;
  for (var y = top; y < bottom; y++) {
    final rowBase = y * stride;
    for (var x = left; x < right; x++) {
      final base = rowBase + x * 4;
      sum += _luma(pixels[base], pixels[base + 1], pixels[base + 2]);
    }
  }
  final mean = sum / count;
  final floorLuma = mean * interiorShare;

  var sx = seedX ?? (box.left + box.right) ~/ 2;
  var sy = seedY ?? (box.top + box.bottom) ~/ 2;
  sx = sx.clamp(left, right - 1);
  sy = sy.clamp(top, bottom - 1);
  // A seed dropped on a glyph stroke would fill the glyph's counter and stop.
  // Walk out to the nearest bright pixel first (bounded, and the block's centre
  // is inside its own text so this is a few px at most).
  if (_lumaAt(pixels, stride, sx, sy) < floorLuma) {
    final found = _nearestBright(pixels, stride, sx, sy, left, top, right, bottom, floorLuma);
    if (found == null) {
      return BalloonRegion(
        bounds: IntRect(left, top, right, bottom),
        mask: Uint8List(count),
        maskWidth: windowWidth,
        maskHeight: windowHeight,
        seedX: sx,
        seedY: sy,
        area: 0,
        enclosed: false,
      );
    }
    sx = found[0];
    sy = found[1];
  }

  final mask = Uint8List(count);
  var area = 0;
  var touchedEdge = false;
  // Iterative scanline flood fill: a queue of pixel indices, 4-connected. A
  // recursive fill would blow the stack on a full-page white area.
  final stack = <int>[((sy - top) * windowWidth) + (sx - left)];
  mask[stack[0]] = 1;
  while (stack.isNotEmpty) {
    final index = stack.removeLast();
    final my = index ~/ windowWidth;
    final mx = index - my * windowWidth;
    final x = left + mx;
    final y = top + my;
    area++;
    if (mx == 0 || my == 0 || mx == windowWidth - 1 || my == windowHeight - 1) {
      touchedEdge = true;
    }
    for (var d = 0; d < 4; d++) {
      final nx = x + (d == 0 ? 1 : d == 1 ? -1 : 0);
      final ny = y + (d == 2 ? 1 : d == 3 ? -1 : 0);
      if (nx < left || ny < top || nx >= right || ny >= bottom) continue;
      final nIndex = (ny - top) * windowWidth + (nx - left);
      if (mask[nIndex] != 0) continue;
      if (_lumaAt(pixels, stride, nx, ny) < floorLuma) continue;
      mask[nIndex] = 1;
      stack.add(nIndex);
    }
  }

  final enough = area >= count * minAreaShare;
  return BalloonRegion(
    bounds: IntRect(left, top, right, bottom),
    mask: mask,
    maskWidth: windowWidth,
    maskHeight: windowHeight,
    seedX: sx,
    seedY: sy,
    area: area,
    // A fill that reaches the window's edge did not find a closed outline: the
    // bright area continues past what we looked at. Big enough *and* closed is
    // the only combination that may be called a balloon.
    enclosed: enough && !touchedEdge,
  );
}

/// Whether two blocks share a balloon, as far as the page's ink can say.
///
/// `true` only when both blocks were found enclosed **and** each one's centre
/// falls inside the other's region — the same test the reference extractors use
/// when they ask "is this block inside that balloon". Any other combination
/// (either side not enclosed, either side empty) is *unknown* and returns true
/// so the caller keeps its geometric behaviour; a veto is only ever issued on
/// positive evidence.
bool sameBalloon(BalloonRegion? a, BalloonRegion? b) {
  if (a == null || b == null) return true;
  if (!a.enclosed || !b.enclosed) return true;
  if (a.area == 0 || b.area == 0) return true;
  return a.contains(b.seedX, b.seedY) || b.contains(a.seedX, a.seedY);
}

int _luma(int r, int g, int b) => (299 * r + 587 * g + 114 * b) ~/ 1000;

int _lumaAt(Uint8List pixels, int stride, int x, int y) {
  final base = y * stride + x * 4;
  return _luma(pixels[base], pixels[base + 1], pixels[base + 2]);
}

/// Breadth-limited search for the closest bright pixel to ([x],[y]) — the seed
/// rescue for a block whose centre lands on a stroke.
List<int>? _nearestBright(
  Uint8List pixels,
  int stride,
  int x,
  int y,
  int left,
  int top,
  int right,
  int bottom,
  double floorLuma,
) {
  const radius = 24;
  for (var r = 1; r <= radius; r++) {
    for (var dy = -r; dy <= r; dy++) {
      for (var dx = -r; dx <= r; dx++) {
        if (dx.abs() != r && dy.abs() != r) continue;
        final nx = x + dx;
        final ny = y + dy;
        if (nx < left || ny < top || nx >= right || ny >= bottom) continue;
        if (_lumaAt(pixels, stride, nx, ny) >= floorLuma) return [nx, ny];
      }
    }
  }
  return null;
}
