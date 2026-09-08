import 'dart:collection';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:venera/foundation/image_translation/translation_types.dart';
import 'package:venera/foundation/image_translation/vertical_typesetting.dart';
import 'package:venera/foundation/image_translation/word_wrap_cn.dart';
import 'package:venera/foundation/log.dart';
import 'package:venera/utils/translations.dart';

/// Renders the translated page: draws [decoded] as the base, then lays each
/// region's translated text over it. Returns PNG bytes.
///
/// In [InpaintMode.patch] the base is the untouched original and each region is
/// covered with an opaque rounded plate in the sampled background colour (the
/// legacy look). In [InpaintMode.smart] the caller has already
/// erased the original lettering in [decoded.pixels], so the base is clean and
/// each region only gets a backing plate where the placed text would otherwise
/// be hard to read against the artwork.
///
/// A region whose translation cannot be placed legibly is **not** painted: it
/// keeps the original artwork (Phase 11-S1, [decideOverflow]). Use
/// [renderTranslatedPageWithReport] to learn which ones, and why.
Future<Uint8List> renderTranslatedPage(
  Uint8List originalBytes,
  RgbaImage decoded,
  List<TranslatedRegion> regions, {
  InpaintMode mode = InpaintMode.smart,
}) async {
  final result = await renderTranslatedPageWithReport(
    originalBytes,
    decoded,
    regions,
    mode: mode,
  );
  return result.png;
}

/// Renders the page and reports what the layout policy decided.
Future<PageRenderResult> renderTranslatedPageWithReport(
  Uint8List originalBytes,
  RgbaImage decoded,
  List<TranslatedRegion> regions, {
  InpaintMode mode = InpaintMode.smart,
}) async {
  final page = ui.Size(decoded.width.toDouble(), decoded.height.toDouble());
  final placements = planRegions(
    regions,
    page,
    outlined: mode != InpaintMode.patch,
    // A patch plate covers more than its region's box, so the neighbour's
    // plate — not just the neighbour's box — is the obstacle to keep clear of.
    obstacleInflate: mode == InpaintMode.patch ? _patchPlateCoverage : null,
  );
  final report = PageRenderReport.build(placements, regions);

  var base = await _baseImage(originalBytes, decoded, mode);
  ui.Image? pristine;
  try {
    var recorder = ui.PictureRecorder();
    var canvas = ui.Canvas(recorder);
    canvas.drawImage(base, ui.Offset.zero, ui.Paint());

    // Kept-original blocks go back first, before any lettering lands: a
    // restore must never be able to wipe a neighbour's fresh text. In patch
    // mode the base already *is* the pristine original, so there is nothing to
    // put back there — those blocks simply never get a plate.
    if (report.keepOriginal.isNotEmpty && mode != InpaintMode.patch) {
      pristine = await _tryDecodeScaled(originalBytes, decoded);
      if (pristine != null) {
        final source = ui.Rect.fromLTRB(
          0,
          0,
          pristine.width.toDouble(),
          pristine.height.toDouble(),
        );
        for (final placement in placements) {
          if (!placement.keptOriginal) continue;
          canvas.drawImageRect(
            pristine,
            source,
            placement.box,
            ui.Paint()..filterQuality = ui.FilterQuality.none,
          );
        }
      } else {
        // Nothing to put back with: the block stays clean but empty. Say so —
        // a hole where the source text was is a different bug from an overflow
        // and needs to be distinguishable in the log.
        Log.warning(
          'OCR Layout',
          'cannot restore ${report.keepOriginal.length} block(s): source image'
          ' unreadable',
        );
      }
    }

    for (final placement in placements) {
      if (!placement.paints) continue;
      final region = regions[placement.index];
      if (mode == InpaintMode.patch) {
        _drawPatchRegion(canvas, region, placement);
      } else {
        _drawErasedRegion(canvas, decoded, region, placement);
      }
    }
    var picture = recorder.endRecording();
    var rendered = await picture.toImage(decoded.width, decoded.height);
    picture.dispose();
    try {
      var data = await rendered.toByteData(format: ui.ImageByteFormat.png);
      if (data == null) {
        throw Exception('Failed to encode translated page');
      }
      return PageRenderResult(
        png: data.buffer.asUint8List(),
        report: report,
      );
    } finally {
      rendered.dispose();
    }
  } finally {
    base.dispose();
    pristine?.dispose();
  }
}

/// One page's PNG plus the layout report behind it.
class PageRenderResult {
  const PageRenderResult({required this.png, required this.report});

  /// The encoded page.
  final Uint8List png;

  /// The per-block decisions behind it.
  final PageRenderReport report;
}

/// Per-page summary of [decideOverflow]'s outcomes.
///
/// The reader surfaces [notice] so a page that quietly lost three captions
/// does not read as a page that never had any (plan §8.2 S1).
class PageRenderReport {
  const PageRenderReport({
    required this.decisions,
    required this.keepOriginal,
    required this.expanded,
    required this.switchedToVertical,
  });

  factory PageRenderReport.build(
    List<Placement> placements,
    List<TranslatedRegion> regions,
  ) {
    final decisions = <int, OverflowDecision>{};
    final keep = <int>[];
    final expanded = <int>[];
    final vertical = <int>[];
    for (final placement in placements) {
      decisions[placement.index] = placement.decision;
      if (placement.skips) continue; // nothing was ever going to be drawn
      switch (placement.decision) {
        case OverflowDecision.expandRect:
          expanded.add(placement.index);
        case OverflowDecision.switchOrientation:
          vertical.add(placement.index);
        case OverflowDecision.keepOriginal:
          keep.add(placement.index);
          final region = regions[placement.index];
          Log.info(
            'OCR Layout',
            'block#${placement.index} kept original: nothing fits above '
            '${minReadableGlyphSize}px in '
            '${placement.box.width.round()}x${placement.box.height.round()}px '
            '(${placement.vertical ? 'vertical' : 'horizontal'} tried, '
            'no safe gutter left) — ${_preview(region.text)}',
          );
        case OverflowDecision.shrinkToFit:
          break;
      }
    }
    if (keep.isNotEmpty) {
      // One line per page: grep-able, and it carries the same count the reader
      // shows, so a log line and a toast can never disagree.
      Log.info(
        'OCR Layout',
        'page summary: ${keep.length} of ${placements.length} blocks kept '
        'original — ${overflowNoticeMessage(keep.length)}',
      );
    }
    return PageRenderReport(
      decisions: decisions,
      keepOriginal: keep,
      expanded: expanded,
      switchedToVertical: vertical,
    );
  }

  /// Decision per region index (skipped blocks included, as `keepOriginal`).
  final Map<int, OverflowDecision> decisions;

  /// Region indices left exactly as they arrived: not erased, not overpainted.
  final List<int> keepOriginal;

  /// Region indices whose text box was grown into the gutter.
  final List<int> expanded;

  /// Region indices forced onto the vertical path by the overflow policy.
  final List<int> switchedToVertical;

  /// How many translations could not be placed.
  int get overflowCount => keepOriginal.length;

  /// Whether anything at all was dropped (the reader's cheap check).
  bool get hasOverflow => keepOriginal.isNotEmpty;

  /// Localised page-level notice, or `null` when every block was placed.
  String? get notice =>
      hasOverflow ? overflowNoticeMessage(overflowCount) : null;
}

/// Localised "本话 N 处译文放不下" line.
///
/// Red line R8: user-facing text goes through `.tl`, never a hard-coded
/// string. Falls back to the English key when the translation table has not
/// been loaded — unit tests and headless runs never call
/// `AppTranslation.init()`, and a layout summary is no reason to crash one.
String overflowNoticeMessage(int count) {
  const key = '@n translated blocks did not fit';
  String text;
  try {
    text = key.tl;
  } catch (_) {
    text = key; // table not loaded (tests, headless)
  }
  return text.replaceAll('@n', '$count');
}

String _preview(String text) {
  const limit = 24;
  final flat = text.replaceAll('\n', ' ');
  return flat.length <= limit
      ? flat
      : '${flat.substring(0, limit)}…(${flat.length})';
}

// ---------------------------------------------------------------------------
// Phase 11-S1: the overflow policy
// ---------------------------------------------------------------------------

/// What to do with a translation that does not fit the space it was given.
enum OverflowDecision {
  /// Shrink the lettering until it fits; the normal, boring case.
  shrinkToFit,

  /// Grow the text box into the gutter between bubbles, capped at
  /// [kGutterGrowFraction] of the clear distance to the nearest neighbour.
  expandRect,

  /// Paint down a column instead of across: the box is narrow and tall, so a
  /// column has length the horizontal run threw away on short ragged lines.
  /// Bypasses the 1.6 aspect gate in [_prefersVertical] on purpose.
  switchOrientation,

  /// Nothing legible can be placed: leave the source artwork untouched —
  /// **no erase, no lettering** — and say so in the log and in the reader.
  keepOriginal,
}

/// Answers "would this region's text fit in that box, painted this way?".
///
/// Injected into [decideOverflow] so the policy stays a pure function: the
/// real implementation runs the layout engines below, a test answers with a
/// closure.
typedef FitsTest = bool Function(ui.Rect box, bool vertical);

/// A region's final layout, decided before a single pixel is touched.
class Placement {
  Placement({
    required this.index,
    required this.box,
    required this.size,
    required this.vertical,
    required this.decision,
    this.skips = false,
  });

  /// Index into the page's region list.
  final int index;

  /// Where the text is painted — grown from the region's own box when
  /// [OverflowDecision.expandRect] was chosen.
  final ui.Rect box;

  /// Font size in px, or `0` when nothing will be painted.
  final double size;

  /// Whether the column renderer handles this block.
  final bool vertical;

  final OverflowDecision decision;

  /// True when the region is degenerate (tiny box, empty text): it never
  /// entered layout, so it is not an overflow either.
  final bool skips;

  /// Whether any ink goes down for this block.
  bool get paints => !skips && decision != OverflowDecision.keepOriginal;

  /// Whether the source artwork under this block must be restored.
  bool get keptOriginal =>
      !skips && decision == OverflowDecision.keepOriginal;

  /// A degenerate region (tiny box, empty text): never entered layout, so it
  /// is not an overflow either — and never painted.
  Placement.of(this.index, TranslatedRegion region)
    : box = _rectOf(region),
      size = 0,
      vertical = false,
      decision = OverflowDecision.keepOriginal,
      skips = true;
}

/// How much of the clear gutter between two bubbles may be taken for text.
///
/// 40% leaves 60% of the original separation intact — enough that a patch-mode
/// plate (which inflates by up to 14% of its own short side, see
/// [_patchPlateCoverage]) and a stroked outline still stop short of the
/// neighbouring artwork. More than that starts painting over the bubble next
/// door, which is far more visible than the half line it was meant to save.
const double kGutterGrowFraction = 0.4;

/// Default floor for legible lettering, in px.
const double kDefaultMinReadableGlyphSize = 8.0;

/// Nothing is ever painted below this size; see [OverflowDecision.keepOriginal]
/// and [_fitFontSize].
///
/// It is a mutable setting rather than a `const` so the settings layer can
/// expose it without this renderer importing `appdata` (which is on the other
/// side of that dependency today). Read it through [minReadableGlyphSize] at
/// decision time, never cached, so a change applies to the next page.
double minReadableGlyphSize = kDefaultMinReadableGlyphSize;

/// Point the renderer at a different legibility floor.
///
/// Clamped to 1..42px: 42 is where the fit search starts, so a higher floor
/// would leave it nothing to try. Non-finite input is ignored.
void configureMinReadableGlyphSize(double value) {
  if (!value.isFinite) return;
  minReadableGlyphSize = value.clamp(1.0, 42.0);
}

/// Narrowest width [_layoutBlock] will lay out at. The fit test must use
/// this, not the caller's box: `TextPainter.width` reports the layout
/// constraint, so comparing against a narrower value is never satisfiable.
const double _minLayoutWidth = 8.0;

/// Aspect ratio at which a box is tall enough for a column to be worth trying
/// once the horizontal run failed. The *aesthetic* preference gate
/// ([_prefersVertical]) is 1.6 — that decides what looks right for the source;
/// this one only decides what is worth an attempt, so it sits lower.
const double _switchAspectGate = 1.2;

/// Minimum share of full-width characters before a column is considered for a
/// switched block: a Latin sentence marching down a column is worse than no
/// sentence at all.
const double _switchCjkGate = 0.6;

/// The overflow policy — pure: no painting, no logging, no side effects.
///
/// [fits] is the result of the shrink-to-fit search on the block's own box and
/// [size] the size it stopped at. [neighborRects] are the obstacles of every
/// other block on the page (their text boxes and erase footprints, inflated by
/// whatever a patch plate would cover). [cjkRatio] is [fullWidthRatio] of the
/// block's text. [pageWidth]/[pageHeight] bound the growth.
OverflowDecision decideOverflow({
  required bool fits,
  required ui.Rect rect,
  required ui.Rect eraseBounds,
  required List<ui.Rect> neighborRects,
  required double size,
  required double pageWidth,
  required double pageHeight,
  required FitsTest fitsIn,
  bool vertical = false,
  double cjkRatio = 1.0,
  double? minReadable,
}) {
  final floor = minReadable ?? minReadableGlyphSize;
  if (fits) return OverflowDecision.shrinkToFit;
  // Not bottomed out yet: the caller still has room to keep shrinking, and
  // escalating early would throw away legible size for nothing.
  if (size > floor) return OverflowDecision.shrinkToFit;

  final grown = safeGrowRect(
    rect: rect,
    eraseBounds: eraseBounds,
    obstacles: neighborRects,
    pageWidth: pageWidth,
    pageHeight: pageHeight,
  );
  if (grown != rect && fitsIn(grown, vertical)) {
    return OverflowDecision.expandRect;
  }

  final narrowTall = rect.height >= rect.width * _switchAspectGate;
  if (!vertical &&
      narrowTall &&
      cjkRatio >= _switchCjkGate &&
      fitsIn(rect, true)) {
    return OverflowDecision.switchOrientation;
  }

  return OverflowDecision.keepOriginal;
}

/// The largest box [rect] may grow into without crowding its neighbours.
///
/// Per side the slack is [kGutterGrowFraction] of the clear distance to the
/// nearest obstacle (or the page edge, whichever is closer); an obstacle that
/// already overlaps leaves no slack on that side. The block's own erase
/// footprint is always covered: lettering that sticks out of the detected box
/// has to stay inside the area the inpainter cleaned, or the reader sees a
/// hole punched in the art.
ui.Rect safeGrowRect({
  required ui.Rect rect,
  required ui.Rect eraseBounds,
  required List<ui.Rect> obstacles,
  required double pageWidth,
  required double pageHeight,
}) {
  final minimum = rect.expandToInclude(eraseBounds);
  final page = ui.Rect.fromLTRB(0, 0, pageWidth, pageHeight);

  double slack(_Side side) {
    final clear = _gapTo(minimum, obstacles, side, page);
    return clear <= 0 ? 0 : clear * kGutterGrowFraction;
  }

  final grown = ui.Rect.fromLTRB(
    minimum.left - slack(_Side.left),
    minimum.top - slack(_Side.top),
    minimum.right + slack(_Side.right),
    minimum.bottom + slack(_Side.bottom),
  ).intersect(page);
  if (grown.width <= 0 || grown.height <= 0) return rect;
  return grown;
}

enum _Side { left, right, top, bottom }

/// Clear distance from [rect] to the nearest obstacle on one side, the page
/// edge counting as an obstacle so a lone block can still grow but never off
/// the artwork.
///
/// Only obstacles overlapping the perpendicular span count: a bubble 2cm to
/// the right but a page above us is not in the way. One that already overlaps
/// leaves no slack at all.
double _gapTo(
  ui.Rect rect,
  List<ui.Rect> obstacles,
  _Side side,
  ui.Rect page,
) {
  var gap = switch (side) {
    _Side.left => rect.left - page.left,
    _Side.right => page.right - rect.right,
    _Side.top => rect.top - page.top,
    _Side.bottom => page.bottom - rect.bottom,
  };
  for (final other in obstacles) {
    if (other.width <= 0 || other.height <= 0) continue;
    final overlapsRows = other.bottom > rect.top && other.top < rect.bottom;
    final overlapsCols = other.right > rect.left && other.left < rect.right;
    double? clear;
    switch (side) {
      case _Side.left:
        if (overlapsRows) clear = rect.left - other.right;
      case _Side.right:
        if (overlapsRows) clear = other.left - rect.right;
      case _Side.top:
        if (overlapsCols) clear = rect.top - other.bottom;
      case _Side.bottom:
        if (overlapsCols) clear = other.top - rect.bottom;
    }
    if (clear != null) gap = math.min(gap, clear);
  }
  return gap < 0 ? 0 : gap;
}

/// Decide every region's placement up front.
///
/// A block's safe growth depends on where its neighbours are, so all decisions
/// share one page context — and painting has to wait for the last of them,
/// because kept-original restores go down before any lettering.
List<Placement> planRegions(
  List<TranslatedRegion> regions,
  ui.Size page, {
  bool outlined = true,
  double Function(ui.Rect rect)? obstacleInflate,
}) {
  final placements = <Placement>[];
  for (var i = 0; i < regions.length; i++) {
    final region = regions[i];
    final rect = _rectOf(region);
    if (rect.width <= 4 || rect.height <= 4 || region.text.trim().isEmpty) {
      placements.add(Placement.of(i, region));
      continue;
    }
    final obstacles = <ui.Rect>[];
    for (var j = 0; j < regions.length; j++) {
      if (j == i) continue;
      obstacles.add(_obstacleOf(regions[j], obstacleInflate));
    }
    final eraseBounds = _eraseBoundsOf(region);
    var vertical = _prefersVertical(region.text, rect);
    var fit = _fitRegion(region, rect, vertical, outlined: outlined);
    var box = rect;
    var decision = fit.fits
        ? OverflowDecision.shrinkToFit
        : decideOverflow(
            fits: fit.fits,
            rect: rect,
            eraseBounds: eraseBounds,
            neighborRects: obstacles,
            size: fit.size,
            pageWidth: page.width,
            pageHeight: page.height,
            minReadable: minReadableGlyphSize,
            vertical: vertical,
            cjkRatio: fullWidthRatio(region.text),
            fitsIn: (candidate, mode) =>
                _fitRegion(region, candidate, mode, outlined: outlined).fits,
          );

    if (decision == OverflowDecision.expandRect) {
      box = safeGrowRect(
        rect: rect,
        eraseBounds: eraseBounds,
        obstacles: obstacles,
        pageWidth: page.width,
        pageHeight: page.height,
      );
      fit = _fitRegion(region, box, vertical, outlined: outlined);
    } else if (decision == OverflowDecision.switchOrientation) {
      vertical = true;
      fit = _fitRegion(region, box, vertical, outlined: outlined);
    }
    // Reality gate: a policy recommendation the layout oracle cannot honour is
    // not a placement. This is what makes "drawn and then clipped" impossible
    // by construction — nothing paints unless its own box measured a fit.
    if (!fit.fits) decision = OverflowDecision.keepOriginal;

    placements.add(
      Placement(
        index: i,
        box: box,
        size: fit.fits ? fit.size : 0,
        vertical: vertical,
        decision: decision,
      ),
    );
  }
  return placements;
}

ui.Rect _obstacleOf(
  TranslatedRegion region,
  double Function(ui.Rect rect)? inflate,
) {
  var rect = _rectOf(region);
  rect = rect.expandToInclude(region.eraseRect.toRect());
  for (final line in region.eraseRects) {
    rect = rect.expandToInclude(line.toRect());
  }
  if (inflate == null) return rect;
  return rect.inflate(inflate(rect));
}

ui.Rect _eraseBoundsOf(TranslatedRegion region) {
  var rect = region.eraseRect.toRect();
  for (final line in region.eraseRects) {
    rect = rect.expandToInclude(line.toRect());
  }
  return rect;
}

/// Patch plates are inflated before they are drawn; this is the margin
/// [_drawPatchRegion] uses, needed to model the area a neighbour really covers.
double _patchPlateCoverage(ui.Rect rect) {
  final minSide = math.min(rect.width, rect.height);
  return math.max(3.0, minSide * 0.14);
}

// ---------------------------------------------------------------------------
// Fitting
// ---------------------------------------------------------------------------

/// Largest size whose layout fits [box], and whether one exists at all.
///
/// `size` is only meaningful when `fits` is true: when nothing legible fits,
/// the answer is `(size: 0, fits: false)` — **not** the floor. The old version
/// returned the 4px floor on failure, callers painted it anyway, and the page
/// ended up with unreadable lettering or a half sentence cut off by the clip.
({double size, bool fits}) _fitRegion(
  TranslatedRegion region,
  ui.Rect box,
  bool vertical, {
  bool outlined = true,
}) {
  if (vertical) {
    return _fitVerticalFontSize(
      region.text,
      box.width,
      box.height,
      lineHeight: region.lineHeight,
    );
  }
  return _fitFontSize(
    region.text,
    box.width,
    box.height,
    lineHeight: region.lineHeight,
    outlined: outlined,
  );
}

/// Largest font size whose wrapped horizontal layout fits the box.
///
/// [lineHeight] is the original lettering's approximate size (px, 0 = unknown).
/// When known it caps the glyph size so the translation stays close to the
/// source scale — a small caption stays small instead of being blown up to fill
/// the detected box. The detector's line box already spans the full line with
/// leading and CJK glyphs fill the em, so the cap sits slightly *below* the box
/// height (0.9x) to keep the translation from reading larger than the source.
({double size, bool fits}) _fitFontSize(
  String text,
  double maxWidth,
  double maxHeight, {
  int lineHeight = 0,
  bool outlined = true,
}) {
  var size = _upperBound(maxHeight, lineHeight);
  final floor = minReadableGlyphSize;
  while (size >= floor) {
    final inset = _insetSize(size, outlined);
    final availW = maxWidth - inset;
    final availH = maxHeight - inset;
    if (availW > 0 && availH > 0) {
      final painter = _layoutBlock(
        text,
        size,
        _fillStyle(const ui.Color(0xFF000000), size),
        availW,
      );
      final fits = painter.height <= availH && painter.width <= availW;
      painter.dispose();
      if (fits) return (size: size, fits: true);
    }
    size *= 0.8;
  }
  return (size: 0, fits: false);
}

/// The same question for a column layout: is there a size at or above the
/// legibility floor that runs the text down [maxHeight] in columns narrow
/// enough for [maxWidth]?
({double size, bool fits}) _fitVerticalFontSize(
  String text,
  double maxWidth,
  double maxHeight, {
  int lineHeight = 0,
}) {
  final spans = layoutVerticalSpans(text);
  if (spans.isEmpty) return (size: 0, fits: false);
  final cells = spans.fold<int>(0, (sum, span) => sum + span.cells);
  var size = _upperBound(maxHeight, lineHeight);
  final floor = minReadableGlyphSize;
  while (size >= floor) {
    final pitch = _columnPitch(size);
    final columnW = _columnWidth(size);
    final availH = maxHeight - 4.0;
    final availW = maxWidth - 4.0;
    if (pitch <= availH && columnW <= availW) {
      final perColumn = math.max(1, (availH / pitch).floor());
      final columns = (cells / perColumn).ceil();
      if (columns * columnW <= availW) return (size: size, fits: true);
    }
    size *= 0.8;
  }
  return (size: 0, fits: false);
}

/// Where a size search starts: never above the source lettering's own scale,
/// never above what the box can hold, never above 42px.
double _upperBound(double maxHeight, int lineHeight) {
  var cap = 42.0;
  if (lineHeight > 0) {
    cap = math.min(cap, math.max(10.0, lineHeight * 0.9));
  }
  return math.max(10.0, math.min(cap, maxHeight * 0.8));
}

/// Cell pitch down a column: 15% leading, enough that two stacked ideographs
/// read as separate cells without a visible gap.
double _columnPitch(double size) => size * 1.15;

/// Distance between two columns: a hair wider than a cell so neighbouring
/// columns (and their outlines) do not touch.
double _columnWidth(double size) => size * 1.2;

// ---------------------------------------------------------------------------
// Painting
// ---------------------------------------------------------------------------

/// The base image to draw under the text. patch mode re-decodes the pristine
/// original at the working resolution; the erase modes draw [decoded] itself,
/// whose pixels were already cleaned by the inpainter.
Future<ui.Image> _baseImage(
  Uint8List originalBytes,
  RgbaImage decoded,
  InpaintMode mode,
) async {
  if (mode != InpaintMode.patch) {
    return await _decodeRgbaImage(decoded);
  }
  return await _decodeScaled(originalBytes, decoded);
}

Future<ui.Image> _decodeRgbaImage(RgbaImage decoded) async {
  var buffer = await ui.ImmutableBuffer.fromUint8List(decoded.pixels);
  var descriptor = ui.ImageDescriptor.raw(
    buffer,
    width: decoded.width,
    height: decoded.height,
    pixelFormat: ui.PixelFormat.rgba8888,
  );
  var codec = await descriptor.instantiateCodec();
  var frame = await codec.getNextFrame();
  codec.dispose();
  descriptor.dispose();
  buffer.dispose();
  return frame.image;
}

Future<ui.Image> _decodeScaled(Uint8List bytes, RgbaImage decoded) async {
  var buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
  var descriptor = await ui.ImageDescriptor.encoded(buffer);
  var codec = await descriptor.instantiateCodec(
    targetWidth: decoded.width,
    targetHeight: decoded.height,
  );
  var frame = await codec.getNextFrame();
  codec.dispose();
  descriptor.dispose();
  buffer.dispose();
  return frame.image;
}

/// As [_decodeScaled], but gives up instead of throwing: a page whose source
/// bytes cannot be re-read simply keeps the base it was handed. The layout is
/// never worse than it was before the restore path existed.
Future<ui.Image?> _tryDecodeScaled(Uint8List bytes, RgbaImage decoded) async {
  if (bytes.isEmpty) return null;
  try {
    return await _decodeScaled(bytes, decoded);
  } catch (e) {
    Log.warning('OCR Layout', 'could not re-read source page: $e');
    return null;
  }
}

ui.Rect _rectOf(TranslatedRegion region) => region.rect.toRect();

extension on IntRect {
  ui.Rect toRect() => ui.Rect.fromLTRB(
    left.toDouble(),
    top.toDouble(),
    right.toDouble(),
    bottom.toDouble(),
  );
}

/// Legacy patch mode: opaque rounded plate + feathered halo, then the text.
void _drawPatchRegion(
  ui.Canvas canvas,
  TranslatedRegion region,
  Placement placement,
) {
  final rect = placement.box;
  var background = ui.Color(region.backgroundColor);

  // Coverage margin scales with the region so original text bleeding past the
  // detected box is still hidden instead of leaving edges poking out.
  var margin = _patchPlateCoverage(rect);
  var core = rect.inflate(margin);
  var radius = ui.Radius.circular(math.min(margin, 4.0));

  // Feathered halo blends the fill into textured/translucent bubbles; the
  // opaque core on top still guarantees the original text is covered.
  var sigma = math.max(1.5, margin * 0.6);
  canvas.drawRRect(
    ui.RRect.fromRectAndRadius(core.inflate(sigma * 0.5), radius),
    ui.Paint()
      ..color = background
      ..maskFilter = ui.MaskFilter.blur(ui.BlurStyle.normal, sigma),
  );
  canvas.drawRRect(
    ui.RRect.fromRectAndRadius(core, radius),
    ui.Paint()..color = background,
  );

  _placeText(canvas, region, placement, ui.Color(region.textColor));
}

/// Erase mode: the base is already clean, so the text only needs a contrast
/// outline (never an opaque plate) to stay readable over minor screentone or
/// gradient the erase left behind.
void _drawErasedRegion(
  ui.Canvas canvas,
  RgbaImage decoded,
  TranslatedRegion region,
  Placement placement,
) {
  var backgroundIsDark = _regionIsDark(decoded, placement.box);
  var textColor = backgroundIsDark
      ? const ui.Color(0xFFF5F5F5)
      : const ui.Color(0xFF202020);
  // Outline in the opposite colour keeps the text legible without covering the
  // art — this is what replaces the old opaque backing plate.
  var outline = backgroundIsDark
      ? const ui.Color(0xE6000000)
      : const ui.Color(0xE6FFFFFF);
  _placeText(canvas, region, placement, textColor, outline: outline);
}

/// Mean-luminance test of the region on the (erased) base, choosing the text
/// colour. Sampled on a stride grid — a full read is needless for a summary.
bool _regionIsDark(RgbaImage image, ui.Rect rect) {
  var w = image.width;
  var left = rect.left.round().clamp(0, w - 1);
  var top = rect.top.round().clamp(0, image.height - 1);
  var right = rect.right.round().clamp(1, w);
  var bottom = rect.bottom.round().clamp(1, image.height);
  var pixels = image.pixels;

  var sum = 0.0;
  var count = 0;
  var stepX = math.max(1, (right - left) ~/ 24);
  var stepY = math.max(1, (bottom - top) ~/ 24);
  for (var y = top; y < bottom; y += stepY) {
    for (var x = left; x < right; x += stepX) {
      var i = (y * w + x) * 4;
      sum += 0.299 * pixels[i] + 0.587 * pixels[i + 1] + 0.114 * pixels[i + 2];
      count++;
    }
  }
  if (count == 0) return false;
  return sum / count < 128;
}

/// Paints one already-decided placement.
///
/// [Placement.box] is the exact box the fit search measured, and the clip is a
/// final safety net around the stroke, not a layout tool: a placement reaches
/// here only if its own layout reported a fit, so nothing is ever cut by it.
void _placeText(
  ui.Canvas canvas,
  TranslatedRegion region,
  Placement placement,
  ui.Color color, {
  ui.Color? outline,
}) {
  final rect = placement.box;
  if (rect.width <= 4 || rect.height <= 4) return;
  canvas.save();
  canvas.clipRect(rect);
  try {
    if (placement.vertical) {
      _drawVerticalText(
        canvas,
        region.text,
        color,
        rect,
        outline: outline,
        size: placement.size,
      );
      return;
    }
    final size = placement.size;
    final inset = _insetSize(size, outline != null);
    final availW = math.max(_minLayoutWidth, rect.width - inset);
    if (outline != null) {
      _paintBlock(
        canvas,
        region.text,
        size,
        _strokeStyle(outline, size),
        availW,
        rect,
      );
    }
    _paintBlock(
      canvas,
      region.text,
      size,
      _fillStyle(color, size),
      availW,
      rect,
    );
  } finally {
    canvas.restore();
  }
}

/// Lays the block out once and paints it centred in [rect].
///
/// Same entry point the fit search uses, so "measured to fit" and "painted"
/// cannot drift apart.
void _paintBlock(
  ui.Canvas canvas,
  String text,
  double size,
  TextStyle style,
  double availW,
  ui.Rect rect,
) {
  final painter = _layoutBlock(text, size, style, availW);
  painter.paint(
    canvas,
    ui.Offset(
      rect.left + (rect.width - painter.width) / 2,
      rect.top + (rect.height - painter.height) / 2,
    ),
  );
  painter.dispose();
}

/// Stroke width scales with the glyph so the outline reads at any size.
double _strokeWidth(double fontSize) => math.max(1.5, fontSize * 0.14);

/// What a laid-out block loses to inner padding plus the outline that extends
/// past the glyph box. Measured by the fit and applied by the paint with the
/// same numbers — a stroke hanging outside the measured box is how lettering
/// used to get clipped, so the search reserves room for it up front.
double _insetSize(double fontSize, bool outlined) =>
    4.0 + (outlined ? _strokeWidth(fontSize) : 0.0);

TextStyle _fillStyle(ui.Color color, double fontSize) => TextStyle(
  color: color,
  fontSize: fontSize,
  height: 1.2,
  fontWeight: FontWeight.w500,
);

TextStyle _strokeStyle(ui.Color outline, double fontSize) => TextStyle(
  fontSize: fontSize,
  height: 1.2,
  fontWeight: FontWeight.w500,
  foreground: ui.Paint()
    ..style = ui.PaintingStyle.stroke
    ..strokeWidth = _strokeWidth(fontSize)
    ..strokeJoin = ui.StrokeJoin.round
    ..color = outline,
);

/// Whether this block's line breaks are ours ([wrapCJK]) or the engine's.
///
/// CJK-led text is wrapped here because the engine's UAX #14 loop cuts Chinese
/// words in half (S3). Latin-only text is left to the engine, which breaks it
/// better than a character budget can.
bool _ownsLineBreaks(String text) => fullWidthRatio(text) > 0;

/// The text with hard line breaks already in it, for the current size.
String _linesFor(String text, double fontSize, double maxWidth) {
  if (!_ownsLineBreaks(text)) return text;
  // An even budget lands whole lines on an even CJK count, which is what
  // 双字绑定 wants; the wrapper still enforces it at the ragged tail.
  var perLine = (maxWidth / math.max(1.0, fontSize)).floor();
  if (perLine.isOdd && perLine > 1) perLine -= 1;
  if (perLine < 1) return text;
  return wrapCJK(text, perLine).join('\n');
}

/// The one place a horizontal block is measured *and* painted.
///
/// When the breaks are ours, the paragraph is laid out unbounded: passing a
/// finite `maxWidth` would let the engine soft-wrap our lines a second time,
/// and the reported width would then be the constraint rather than the text —
/// precisely the "measured one thing, painted another" drift that used to end
/// up clipped by the region's `clipRect`.
TextPainter _layoutBlock(
  String text,
  double fontSize,
  TextStyle style,
  double maxWidth,
) {
  final own = _ownsLineBreaks(text);
  var painter = TextPainter(
    text: TextSpan(text: _linesFor(text, fontSize, maxWidth), style: style),
    textAlign: TextAlign.center,
    textDirection: TextDirection.ltr,
  );
  painter.layout(
    maxWidth: own ? double.infinity : math.max(_minLayoutWidth, maxWidth),
  );
  return painter;
}

/// Share of non-space characters that need a full-width cell (CJK, kana,
/// hangul, full-width forms). Exported for the overflow policy's gate.
double fullWidthRatio(String text) {
  var wide = 0, total = 0;
  for (var r in text.runes) {
    if (r <= 0x20) continue;
    total++;
    if (isVerticalCellChar(r) ||
        (r >= 0xAC00 && r <= 0xD7AF) ||
        (r >= 0xFF00 && r <= 0xFF60)) {
      wide++;
    }
  }
  if (total == 0) return 0;
  return wide / total;
}

/// Whether [text] should be laid out vertically inside [rect]: the region is
/// clearly taller than wide and the text is dominated by CJK characters.
bool _prefersVertical(String text, ui.Rect rect) {
  if (rect.height < rect.width * 1.6) return false;
  var cjk = 0, total = 0;
  for (var r in text.runes) {
    if (r <= 0x20) continue;
    total++;
    if ((r >= 0x4E00 && r <= 0x9FFF) ||
        (r >= 0x3400 && r <= 0x4DBF) ||
        (r >= 0x3040 && r <= 0x30FF) ||
        (r >= 0xAC00 && r <= 0xD7AF)) {
      cjk++;
    }
  }
  if (total < 2) return false;
  return cjk / total >= 0.7;
}

// ---------------------------------------------------------------------------
// Vertical drawing (Phase 11-S2)
// ---------------------------------------------------------------------------

/// Draws [text] as vertical right-to-left columns inside [rect] at [size].
///
/// The spans come from [layoutVerticalSpans]: punctuation is nudged into the
/// corner of its cell and turned where the mark only exists horizontally, and
/// digit / Latin runs are set sideways inside the column (tate-chu-yoko)
/// instead of being taken apart one character per cell.
void _drawVerticalText(
  ui.Canvas canvas,
  String text,
  ui.Color color,
  ui.Rect rect, {
  required double size,
  ui.Color? outline,
}) {
  final spans = layoutVerticalSpans(text);
  if (spans.isEmpty || size <= 0) return;

  final availH = rect.height - 4.0;
  final pitch = _columnPitch(size);
  final columnW = _columnWidth(size);
  final perColumn = math.max(1, (availH / pitch).floor());
  final cells = spans.fold<int>(0, (sum, span) => sum + span.cells);
  final columns = (cells / perColumn).ceil();

  final blockW = columns * columnW;
  final blockH = math.min(availH, perColumn * pitch);
  final startRight = rect.left + (rect.width + blockW) / 2;
  final top = rect.top + (rect.height - blockH) / 2;

  var cell = 0;
  for (final span in spans) {
    final column = (cell / perColumn).floor();
    final row = cell - column * perColumn;
    final center = ui.Offset(
      startRight - (column + 0.5) * columnW,
      top + row * pitch + pitch / 2,
    );
    // A cluster packs `span.cells` characters into that much column length.
    _paintVerticalSpan(
      canvas,
      span,
      center,
      pitch * span.cells,
      size,
      color,
      outline,
    );
    cell += span.cells;
  }
}

/// Paints one vertical span, honouring its offset and rotation.
void _paintVerticalSpan(
  ui.Canvas canvas,
  TextSpanV span,
  ui.Offset center,
  double slot,
  double size,
  ui.Color fill,
  ui.Color? outline,
) {
  // Tate-chu-yoko: the run keeps its horizontal shape, so it is scaled down
  // until `runeCount` glyphs fit into the cells it was allotted.
  final scale = span.kind == VerticalSpanKind.cluster
      ? math.min(1.0, (slot * 0.96) / math.max(1.0, size * span.runeCount))
      : 1.0;
  final glyphSize = size * scale;

  canvas.save();
  canvas.translate(center.dx + span.dxRatio * size, center.dy + span.dyRatio * size);
  if (span.isRotated) canvas.rotate(span.rotationRad);
  if (outline != null) {
    _paintCachedGlyph(
      canvas,
      span.text,
      glyphSize,
      _strokeStyle(outline, glyphSize).copyWith(height: 1.0),
      outline.toARGB32(),
    );
  }
  _paintCachedGlyph(
    canvas,
    span.text,
    glyphSize,
    _fillStyle(fill, glyphSize).copyWith(height: 1.0),
    fill.toARGB32(),
  );
  canvas.restore();
}

void _paintCachedGlyph(
  ui.Canvas canvas,
  String glyph,
  double size,
  TextStyle style,
  int colorKey,
) {
  final painter = _verticalPainters.obtain(
    // `TextStyle` compares its `Paint` by identity, so it can never be the key.
    '$glyph|${size.toStringAsFixed(2)}|$colorKey',
    () {
      var painter = TextPainter(
        text: TextSpan(text: glyph, style: style),
        textDirection: TextDirection.ltr,
      );
      painter.layout();
      return painter;
    },
  );
  painter.paint(canvas, ui.Offset(-painter.width / 2, -painter.height / 2));
}

/// LRU of measured vertical glyph painters.
///
/// A column re-measures the same handful of glyphs at the same size over and
/// over — every cell, every block, every page. Laying out one character is
/// cheap but not free, and this is the one place in the renderer where the
/// count was O(characters) instead of O(blocks).
class _GlyphPainterCache {
  _GlyphPainterCache(this.limit);

  final int limit;
  final LinkedHashMap<String, TextPainter> _entries = LinkedHashMap();

  TextPainter obtain(String key, TextPainter Function() create) {
    // `remove` then re-insert keeps the entry at the most-recently-used end.
    final painter = _entries.remove(key) ?? create();
    _entries[key] = painter;
    while (_entries.length > limit) {
      _entries.remove(_entries.keys.first)?.dispose();
    }
    return painter;
  }

  int get length => _entries.length;

  void clear() {
    for (final painter in _entries.values) {
      painter.dispose();
    }
    _entries.clear();
  }
}

/// 512 entries is roughly a page's distinct glyphs at two styles for a couple
/// of sizes; past that a manga page stops adding vocabulary. The cap bounds the
/// pile, not the hit rate.
final _verticalPainters = _GlyphPainterCache(512);

/// Number of cached vertical glyph painters.
@visibleForTesting
int verticalPainterCacheLength() => _verticalPainters.length;

/// Drop every cached vertical glyph painter (tests, or a font change).
@visibleForTesting
void clearVerticalPainterCache() => _verticalPainters.clear();
