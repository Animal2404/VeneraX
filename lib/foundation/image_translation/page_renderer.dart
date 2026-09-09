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
///
/// Phase 11-S4 makes the outline part of the deal: a block that will be drawn
/// with a stroke *pays for that stroke in its fit budget* (both orientations),
/// and the stroke is as thick, relative to the glyphs, as the source
/// lettering's own outline measured on the artwork ([estimateStrokeRatio]) —
/// falling back to [kDefaultStrokeRatio] of the font size when the probe
/// cannot say anything about the block.
///
/// Phase 11-S5 harmonises blocks that share a bubble: [unifyPlacementGroups]
/// gives every member of a cluster one size — the largest the whole group can
/// carry — instead of letting each line pick a size off its own box.
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
  // Defect A: one caption can reach the renderer as two (or more) regions
  // whose boxes cover the same art — the detector emits connected-component
  // bounding boxes, and two clusters whose boxes overlap both get recognized
  // whole, so the same paragraph arrives twice. The renderer paints exactly
  // one text pass per region (`placements` ↔ `regions` is 1:1 — there is no
  // double-draw path here), so the only way two blocks can share pixels is a
  // colliding *input list*. Colliding regions therefore merge into a single
  // reading-order block before anything else looks at them. A collision-free
  // list passes through unchanged, byte for byte — every existing single-
  // block behaviour is untouched.
  regions = resolveRegionCollisions(regions);
  final page = ui.Size(decoded.width.toDouble(), decoded.height.toDouble());
  final outlined = mode != InpaintMode.patch;
  // Phase 11-S4: weigh the source lettering's outline before budgeting ours.
  // The probe reads the untouched artwork (`decoded` has already been erased
  // in the smart modes), so a page whose source bytes cannot be re-read
  // simply gets the default stroke ratio — the pre-probe behaviour.
  final strokeRatios = outlined
      ? await detectStrokeRatios(originalBytes, decoded, regions)
      : const <int, double>{};
  final placements = planRegions(
    regions,
    page,
    outlined: outlined,
    // A patch plate covers more than its region's box, so the neighbour's
    // plate — not just the neighbour's box — is the obstacle to keep clear of.
    obstacleInflate: mode == InpaintMode.patch ? _patchPlateCoverage : null,
    strokeRatios: strokeRatios,
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
        final pageRect = ui.Rect.fromLTRB(
          0,
          0,
          pristine.width.toDouble(),
          pristine.height.toDouble(),
        );
        for (final placement in placements) {
          if (!placement.keptOriginal) continue;
          // Restore the same pixel area the box names on the page: pristine
          // was decoded at exactly the working resolution, so src == dst.
          // (src used to be the FULL page, which stamped a shrunken thumbnail
          // of the whole artwork into every kept-original box — the opposite
          // of "leave the source artwork untouched".)
          final restore = placement.box.intersect(pageRect);
          if (restore.isEmpty) continue;
          canvas.drawImageRect(
            pristine,
            restore,
            restore,
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

/// Answers "would this region's text fit in that box, painted this way?" —
/// outline included, because an outline that is not paid for in the budget is
/// how lettering gets clipped (Phase 11-S4).
///
/// Injected into [decideOverflow] so the policy stays a pure function: the
/// real implementation runs the layout engines below, a test answers with a
/// closure. The production oracle *is* stroke-aware — [planRegions] closes it
/// over the block's resolved stroke ratio (see [strokeWidthForSize] and
/// [fitsRegionAt]), so a grown box that only "fits" by ignoring the outline
/// never wins an expansion. The signature deliberately does not carry the
/// stroke width itself: S1's fixtures inject two-argument closures, and what
/// the oracle needs to know about the stroke is its own private business.
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
    this.sourceStrokeRatio,
    this.layoutGroup = -1,
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

  /// Stroke thickness of the source lettering, as a fraction of its own glyph
  /// size, as measured by [estimateStrokeRatio]; `null` when the probe could
  /// not say anything about this block (default ratio applies).
  final double? sourceStrokeRatio;

  /// Index of the first region this block's font size was harmonised with
  /// (Phase 11-S5), or `-1` when the block stands alone.
  final int layoutGroup;

  /// The same placement re-measured at one harmonised size.
  Placement sized(double newSize, int group) => Placement(
    index: index,
    box: box,
    size: newSize,
    vertical: vertical,
    decision: decision,
    skips: skips,
    sourceStrokeRatio: sourceStrokeRatio,
    layoutGroup: group,
  );

  /// The same placement decided for a different box (defect B's collision
  /// pass). Only the box, the size that box pays for and — when the new box
  /// cannot hold the text at all — the decision move; orientation, stroke
  /// weight and group membership are the block's own and stay put.
  Placement boxed(
    ui.Rect newBox,
    double newSize,
    OverflowDecision newDecision,
  ) => Placement(
    index: index,
    box: newBox,
    size: newSize,
    vertical: vertical,
    decision: newDecision,
    skips: skips,
    sourceStrokeRatio: sourceStrokeRatio,
    layoutGroup: layoutGroup,
  );

  /// A degenerate region (tiny box, empty text): never entered layout, so it
  /// is not an overflow either — and never painted.
  Placement.of(this.index, TranslatedRegion region)
    : box = _rectOf(region),
      size = 0,
      vertical = false,
      decision = OverflowDecision.keepOriginal,
      skips = true,
      sourceStrokeRatio = null,
      layoutGroup = -1;
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
/// and [_fitRegion].
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
///
/// [strokeRatios] carries the source lettering's measured outline weight
/// (region index → ratio, from [detectStrokeRatios]); blocks absent from it
/// fall back to [kDefaultStrokeRatio]. Every fit test on this page — the
/// search, [decideOverflow]'s oracle, and the later group harmonisation —
/// budgets the stroke that will actually be painted.
///
/// [normalizeGroups] turns Phase 11-S5's per-page harmonisation off; see
/// [unifyPlacementGroups].
List<Placement> planRegions(
  List<TranslatedRegion> regions,
  ui.Size page, {
  bool outlined = true,
  double Function(ui.Rect rect)? obstacleInflate,
  Map<int, double>? strokeRatios,
  bool normalizeGroups = true,
}) {
  final placements = <Placement>[];
  for (var i = 0; i < regions.length; i++) {
    final region = regions[i];
    final rect = _rectOf(region);
    if (rect.width <= 4 || rect.height <= 4 || region.text.trim().isEmpty) {
      placements.add(Placement.of(i, region));
      continue;
    }
    final ratio = strokeRatios?[i];
    final obstacles = <ui.Rect>[];
    for (var j = 0; j < regions.length; j++) {
      if (j == i) continue;
      obstacles.add(_obstacleOf(regions[j], obstacleInflate));
    }
    final eraseBounds = _eraseBoundsOf(region);
    var vertical = _prefersVertical(region.text, rect);
    var fit = _fitRegion(
      region,
      rect,
      vertical,
      outlined: outlined,
      sourceStrokeRatio: ratio,
    );
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
            // Stroke-aware by capture: whatever the chosen size paints, the
            // oracle paid for in the budget.
            fitsIn: (candidate, mode) => _fitRegion(
              region,
              candidate,
              mode,
              outlined: outlined,
              sourceStrokeRatio: ratio,
            ).fits,
          );

    if (decision == OverflowDecision.expandRect) {
      box = safeGrowRect(
        rect: rect,
        eraseBounds: eraseBounds,
        obstacles: obstacles,
        pageWidth: page.width,
        pageHeight: page.height,
      );
      fit = _fitRegion(
        region,
        box,
        vertical,
        outlined: outlined,
        sourceStrokeRatio: ratio,
      );
    } else if (decision == OverflowDecision.switchOrientation) {
      vertical = true;
      fit = _fitRegion(
        region,
        box,
        vertical,
        outlined: outlined,
        sourceStrokeRatio: ratio,
      );
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
        sourceStrokeRatio: ratio,
      ),
    );
  }
  // Defect B: the per-block decisions are made, and every one of them was
  // taken against its *own* box. Two blocks that each fit themselves can still
  // cover the same pixels — the merge only folds a pair up when the overlap is
  // big enough to be one detection twice, and safeGrowRect is a growth rule,
  // so it never runs on a block that already fitted. This is where the page
  // gets checked as a whole.
  final resolved = resolvePlacementOverlaps(
    placements: placements,
    regions: regions,
    page: page,
    outlined: outlined,
  );
  if (!normalizeGroups) return resolved;
  // S5: the per-block decisions are made and the boxes no longer overlap; the
  // sizes within a shared bubble are not yet agreed. Harmonisation only ever
  // *shrinks* (to a size every member was itself measured to fit, against the
  // box this pass settled on), so no decision can be invalidated by it and no
  // ink can grow back into a neighbour.
  return unifyPlacementGroups(resolved, regions, outlined: outlined);
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
// Defect B: two blocks of lettering must never cover one pixel area
// ---------------------------------------------------------------------------

/// Pull colliding *placements* apart, after the merge could not.
///
/// [resolveRegionCollisions] folds two regions into one only when they really
/// are the same detection twice (overlap ≥ [kMergeOverlapCov], or ≥
/// [kMergeDuplicateCov] with identical text). Two separate bubbles whose
/// detected boxes overlap by, say, a fifth of the smaller one sit below that
/// gate — and [safeGrowRect], which *does* treat neighbours as obstacles,
/// never runs on them: it is only consulted once a block has bottomed out in
/// the shrink search and wants to grow (see [decideOverflow]). A block that
/// fits its own box paints it as it arrived, so on a grey-zone pair both
/// blocks lay their centred paragraph into the shared band and the reader sees
/// two sentences woven through each other. The grow path is safe; **the base
/// path was unchecked**, and that is what this pass closes.
///
/// It resolves a collision in the order of what the reader can least afford:
///
/// 1. **give the borrowed gutter back** — the block that grew pulls its inner
///    edge off the neighbour's box, stopping at its own detected box plus erase
///    footprint. Only the borrower is asked, because only the borrower has
///    anything to give, and a cut can only ever *shrink* a box: it cannot
///    create a collision somewhere else on the page.
/// 2. **step aside along the cut axis** — only as far as the block's own
///    [safeGrowRect] envelope already permits (the same 40%-of-the-gutter
///    budget, never more), and only if the destination is clear of every other
///    block and wholly on the artwork. This is the one move that can put ink
///    somewhere new, so it is gated by the envelope the rest of the layout
///    already trusts.
/// 3. **share the band** — when the two floors genuinely overlap, both are cut
///    to the middle line. Neither moves; every pixel of the page is now
///    claimed by at most one block.
///
/// Then every box that was touched is **re-measured**, not re-guessed: if its
/// text no longer fits at a legible size, the block goes the way [S1] sends
/// anything that cannot be placed — `keepOriginal`, drawn as nothing at all.
/// No text is ever clipped (the reality gate in [planRegions] and the
/// `clipRect` in [_placeText] both still hold), nothing is pushed off the page,
/// and no block is moved onto another's ink.
///
/// **Phase 13-F13.2: the restore is an obstacle too.** Until this pass only
/// compared blocks that *paint*, and [Placement.keptOriginal] blocks paint
/// nothing — so they were invisible here. But a kept-original block is not
/// "nothing happened there": in the erase modes the renderer stamps the
/// untouched source artwork back into its box *first* (see
/// [renderTranslatedPageWithReport]) and lays the neighbours' lettering over
/// the page *after*. Two boxes that merely neighbour each other on the page are
/// therefore enough for the reader's complaint — the restored source text and
/// a translation that overlaps it land on the same pixels. A restore is asked
/// to give up nothing (it is immovable and uncutable: that stamp *is* the
/// S1 decision), so on such a pair only the painting block may act, and if it
/// cannot get clear of the restore it keeps its own original too — never a
/// translation printed on top of the text it was told to leave alone.
///
/// Returns a new list when anything changed; otherwise the same list object,
/// so a collision-free page is provably untouched by this pass.
@visibleForTesting
List<Placement> resolvePlacementOverlaps({
  required List<Placement> placements,
  required List<TranslatedRegion> regions,
  required ui.Size page,
  bool outlined = true,
}) {
  final n = placements.length;
  if (n < 2) return placements;

  final boxes = [for (final p in placements) p.box];
  final sizes = [for (final p in placements) p.size];
  final decisions = [for (final p in placements) p.decision];
  final touched = <int>{};
  var cuts = 0, pushes = 0, shares = 0, drops = 0, yields = 0;

  bool paints(int i) =>
      !placements[i].skips &&
      decisions[i] != OverflowDecision.keepOriginal &&
      !boxes[i].isEmpty;

  /// A block whose *restored source artwork* covers page area: exactly what
  /// the paint pass stamps back from the pristine image (`!paints(i) &&
  /// keptOriginal`, plus a non-empty box, which is what makes the stamp do
  /// anything at all). This is an obstacle the pass may never move.
  ///
  /// Gated on [outlined] because that is the same condition the paint pass
  /// uses to decide whether it restores anything at all: in patch mode the base
  /// image *is* the pristine original, so a kept-original block is an absence
  /// of plate rather than a stamp of artwork, and the pixel-level "original and
  /// translation on one area" this pass exists to prevent cannot occur there.
  /// Leaving this empty in patch mode is therefore not an exception — it makes
  /// `blocks(i)` answer exactly what it used to, and the whole pass degenerates
  /// to its previous, tested behaviour.
  bool restores(int i) =>
      outlined &&
      !placements[i].skips &&
      decisions[i] == OverflowDecision.keepOriginal &&
      !boxes[i].isEmpty;

  /// Anything that can put pixels on the page: fresh lettering, or the source
  /// artwork going back under it. No painting box may end up on top of either.
  bool blocks(int i) => paints(i) || restores(i);

  TranslatedRegion regionOf(int i) => regions[placements[i].index];

  /// The floor a box may be pulled back to: its detected rect with the erase
  /// footprint unioned in. Everything outside it was borrowed from the gutter.
  ui.Rect floorOf(int i) => _rectOf(regionOf(i)).expandToInclude(
    _eraseBoundsOf(regionOf(i)),
  );

  /// Move [box]'s inner edge (the one facing [cutAt]) onto the cut line,
  /// keeping everything on the artwork. Shrinking only ever *removes* area, so
  /// a cut can never manufacture a collision with a third block.
  ui.Rect cutTo(
    ui.Rect box,
    double cutAt, {
    required bool alongX,
    required bool fromLeft,
  }) {
    if (!alongX) {
      return fromLeft
          ? box.intersect(ui.Rect.fromLTRB(0, 0, page.width, cutAt))
          : box.intersect(ui.Rect.fromLTRB(0, cutAt, page.width, page.height));
    }
    return fromLeft
        ? box.intersect(ui.Rect.fromLTRB(0, 0, cutAt, page.height))
        : box.intersect(ui.Rect.fromLTRB(cutAt, 0, page.width, page.height));
  }

  /// F13.2: settle **one painting box against one restore area**. [paint] is
  /// the block that may move; [ground] is the restore, which may not — that
  /// stamp of the source artwork *is* S1's decision, so this helper's whole
  /// design is "the translation gives, never the original".
  ///
  /// The ladder is the one painting pairs use, minus every move that would
  /// touch the restore:
  ///
  /// 1. **give the borrowed gutter back** — retreat to the restore's edge, but
  ///    never past this block's own detected floor;
  /// 2. **step aside** — only when the move carries the block *away* from the
  ///    restore (a leading block can only be pushed deeper into it), inside the
  ///    envelope the layout already trusts, landing clear of every block *and*
  ///    every restore;
  /// 3. **hand over the shared band** — cut the painting box at the restore's
  ///    edge, which is allowed to reach inside the block's own floor.
  ///
  /// Steps 1 and 3 are measured *before* they are taken: cutting a box is
  /// cheap, but a box the lettering no longer fits turns into a `keepOriginal`
  /// whose restore would be **smaller than the text it is giving back** — the
  /// eraser already removed those strokes from the base image, and only the box
  /// puts them back. A block that cannot pay for a move therefore takes none of
  /// it, and stands down with the box it came in with: the reader loses the
  /// translation, never the original. A move that pays for itself is taken
  /// immediately and the pair is settled.
  ///
  /// Returns whether the two areas are clear of each other afterwards.
  bool yieldToRestore(int paint, int ground) {
    final inter = boxes[paint].intersect(boxes[ground]);
    if (inter.isEmpty) return true;
    // Cut along the shallower intrusion, as between two painting blocks: it is
    // the move that disturbs the fewest pixels of lettering.
    final alongX = inter.width <= inter.height;
    final paintLeads = alongX
        ? boxes[paint].left <= boxes[ground].left
        : boxes[paint].top <= boxes[ground].top;

    /// Take a box for [paint] if its own text fits it; report whether it was
    /// taken. A box that cannot be paid for is refused here rather than handed
    /// to the re-measure, because the re-measure's fallback — keep the original
    /// — is only safe on a box that still covers the source text.
    bool tryBox(ui.Rect next) {
      if (next == boxes[paint] || next.isEmpty) return false;
      final fit = _fitRegion(
        regionOf(paint),
        next,
        placements[paint].vertical,
        outlined: outlined,
        sourceStrokeRatio: placements[paint].sourceStrokeRatio,
      );
      if (!fit.fits) return false;
      boxes[paint] = next;
      sizes[paint] = fit.size;
      touched.add(paint);
      cuts++;
      return true;
    }

    ui.Rect toward(double edge) => cutTo(
      boxes[paint],
      edge,
      alongX: alongX,
      fromLeft: paintLeads,
    );

    // 1. Give the gutter back, stopping at this block's own floor.
    final floor = floorOf(paint);
    final floorEdge = (alongX
            ? (paintLeads ? floor.right : floor.left)
            : (paintLeads ? floor.bottom : floor.top))
        .toDouble();
    final restoreEdge = (alongX
            ? (paintLeads ? boxes[ground].left : boxes[ground].right)
            : (paintLeads ? boxes[ground].top : boxes[ground].bottom))
        .toDouble();
    final backTo = paintLeads
        ? math.max(restoreEdge, floorEdge)
        : math.min(restoreEdge, floorEdge);
    if (tryBox(toward(backTo))) {
      return boxes[paint].intersect(boxes[ground]).isEmpty;
    }

    // 2. Step aside inside the envelope — the trailing side only, so the move
    //    is away from the restored text and the reading order holds. A slide
    //    costs no area, so the block's own measurement still stands.
    if (!paintLeads) {
      final need = alongX
          ? boxes[ground].right - boxes[paint].left
          : boxes[ground].bottom - boxes[paint].top;
      if (need > 0 &&
          _pushClears(
            region: regionOf(paint),
            from: boxes[paint],
            need: need,
            alongX: alongX,
            page: page,
            boxes: boxes,
            blocked: blocks,
            skip: paint,
            ignore: ground,
          )) {
        boxes[paint] = boxes[paint].translate(
          alongX ? need : 0,
          alongX ? 0 : need,
        );
        touched.add(paint);
        pushes++;
        return true;
      }
    }

    // 3. Hand over the whole shared band, past the floor if that is what it
    //    takes — and only if the lettering still fits what is left.
    if (tryBox(toward(restoreEdge))) {
      return boxes[paint].intersect(boxes[ground]).isEmpty;
    }

    // 4. Nothing it can afford clears the restored artwork, so this block keeps
    //    its own original too and paints nothing. It is a restore from here on,
    //    which is also why the pair can never be offered again: two restores
    //    cannot collide, they are the same source pixels.
    if (decisions[paint] != OverflowDecision.keepOriginal) {
      decisions[paint] = OverflowDecision.keepOriginal;
      sizes[paint] = 0;
      yields++;
    }
    return true;
  }

  for (var sweep = 0; sweep < 8 * n; sweep++) {
    int? first, second;
    var worst = 0.0;
    for (var i = 0; i < n; i++) {
      // F13.2: a block that restores the source artwork is a thing the reader
      // sees, so it takes part in the pairwise check — it is only ever the
      // immovable side of a pair.
      if (!blocks(i)) continue;
      for (var j = i + 1; j < n; j++) {
        if (!blocks(j)) continue;
        // Two restores cannot collide: both are the same source pixels.
        if (!paints(i) && !paints(j)) continue;
        final inter = boxes[i].intersect(boxes[j]);
        if (inter.isEmpty) continue;
        final area = inter.width * inter.height;
        if (area > worst) {
          worst = area;
          first = i;
          second = j;
        }
      }
    }
    if (first == null || second == null) break;

    final inter = boxes[first].intersect(boxes[second]);
    // Cut along the shallower intrusion: it costs the fewer pixels of moved
    // lettering, and moved lettering is what this pass is trying to avoid.
    final alongX = inter.width <= inter.height;
    // Whichever box starts earlier on the cut axis keeps the near side.
    final leading =
        alongX
        ? (boxes[first].left <= boxes[second].left ? first : second)
        : (boxes[first].top <= boxes[second].top ? first : second);
    final trailing = leading == first ? second : first;
    final cutAt = alongX
        ? inter.left + inter.width / 2
        : inter.top + inter.height / 2;

    // 1. The box that borrowed gutter gives it back — all the way off the
    //    neighbour's box, and never past its own floor. Only the borrower moves
    //    (and only if it really has room), which is the point: a block that was
    //    never grown has nothing to apologise for. [safeGrowRect] already
    //    treated the neighbour as an obstacle *while growing*; this is the same
    //    rule applied afterwards, to the case growth never covered — a pair
    //    whose boxes overlap on their own, below the merge gate.
    double innerEdge(int i) => alongX
        ? (i == leading ? boxes[i].right : boxes[i].left)
        : (i == leading ? boxes[i].bottom : boxes[i].top);
    double innerFloor(int i) {
      final floor = floorOf(i);
      return (alongX
              ? (i == leading ? floor.right : floor.left)
              : (i == leading ? floor.bottom : floor.top))
          .toDouble();
    }

    double innerRoom(int i) => (innerEdge(i) - innerFloor(i)).abs();

    double pullTarget(int i) {
      final facing = alongX
          ? (i == leading ? boxes[trailing].left : boxes[leading].right)
          : (i == leading ? boxes[trailing].top : boxes[leading].bottom);
      return i == leading
          ? math.max(facing, innerFloor(i))
          : math.min(facing, innerFloor(i));
    }

    bool pull(int i, double to) {
      final box = boxes[i];
      final next = alongX
          ? (i == leading
                ? box.intersect(ui.Rect.fromLTRB(0, 0, to, page.height))
                : box.intersect(ui.Rect.fromLTRB(to, 0, page.width, page.height)))
          : (i == leading
                ? box.intersect(ui.Rect.fromLTRB(0, 0, page.width, to))
                : box.intersect(ui.Rect.fromLTRB(0, to, page.width, page.height)));
      if (next == box || next.isEmpty) return false;
      boxes[i] = next;
      touched.add(i);
      cuts++;
      return true;
    }

    final giveFirst = innerRoom(leading) >= innerRoom(trailing)
        ? leading
        : trailing;
    final giveSecond = giveFirst == leading ? trailing : leading;

    // F13.2: exactly one of the two is a restore — the source artwork going
    // back onto the page under (part of) the other one's box. That pair is not
    // settled by the three moves below (the third one would cut the restore,
    // and cutting a restore is not a thing this pass may do to a `keepOriginal`
    // decision); it goes to [yieldToRestore], which asks only the painting
    // block and ends in "draw nothing".
    if (!paints(leading) || !paints(trailing)) {
      yieldToRestore(
        paints(leading) ? leading : trailing,
        paints(leading) ? trailing : leading,
      );
      continue;
    }

    pull(giveFirst, pullTarget(giveFirst));
    if (!boxes[leading].intersect(boxes[trailing]).isEmpty) {
      pull(giveSecond, pullTarget(giveSecond));
    }
    if (!paints(leading) || !paints(trailing)) continue;
    if (boxes[leading].intersect(boxes[trailing]).isEmpty) continue;

    // 2. One of them may still be able to step aside — inside the very
    //    envelope the gutter growth would already have allowed it, never
    //    further, and only into space no other block claims. It is always the
    //    *trailing* block that moves: pushing it forward keeps the reading
    //    order the merged blocks were sorted by, and the leading one is the
    //    one whose bubble the eye reaches first.
    final need =
        alongX
        ? boxes[leading].right - boxes[trailing].left
        : boxes[leading].bottom - boxes[trailing].top;
    if (need > 0 &&
        _pushClears(
          region: regionOf(trailing),
          from: boxes[trailing],
          need: need,
          alongX: alongX,
          page: page,
          boxes: boxes,
          blocked: blocks,
          skip: trailing,
          // The neighbour is the thing being stepped away from: counting it as
          // an obstacle would zero the very slack the move needs (its edge is
          // inside this box by definition, so the gap is negative and
          // [safeGrowRect] hands back no room on that side). Every *third*
          // block stays an obstacle, and the landing spot is still checked
          // against the neighbour below.
          ignore: leading,
        )) {
      boxes[trailing] = boxes[trailing].translate(
        alongX ? need : 0,
        alongX ? 0 : need,
      );
      touched.add(trailing);
      pushes++;
      continue;
    }

    // 3. The floors themselves overlap: split the band down the middle. Both
    //    boxes shrink, neither moves, so this cannot disturb a third block and
    //    cannot leave the artwork.
    boxes[leading] = cutTo(
      boxes[leading],
      cutAt,
      alongX: alongX,
      fromLeft: true,
    );
    boxes[trailing] = cutTo(
      boxes[trailing],
      cutAt,
      alongX: alongX,
      fromLeft: false,
    );
    touched.add(leading);
    touched.add(trailing);
    shares++;
    if (!boxes[leading].intersect(boxes[trailing]).isEmpty) {
      // Numerically impossible — the two halves meet on one line. If the
      // floating point ever says otherwise, stop here rather than spin: the
      // re-measure below turns a box that cannot hold its text into a block
      // that keeps the original, which is the safe end state.
      break;
    }
  }

  // Re-measure what moved: the box is the budget, and a box that was cut is a
  // smaller budget. Nothing is painted that has not fitted its own box.
  for (final i in touched) {
    if (placements[i].skips) continue;
    // F13.2: a block that already stood down for a restore has *chosen* its
    // size-zero state; re-fitting it would hand a font size back to a block
    // that paints nothing, and `keepOriginal` is not a decision this pass
    // reverses.
    if (decisions[i] == OverflowDecision.keepOriginal) continue;
    final fit = _fitRegion(
      regionOf(i),
      boxes[i],
      placements[i].vertical,
      outlined: outlined,
      sourceStrokeRatio: placements[i].sourceStrokeRatio,
    );
    if (fit.fits) {
      sizes[i] = fit.size;
      continue;
    }
    if (decisions[i] != OverflowDecision.keepOriginal) {
      decisions[i] = OverflowDecision.keepOriginal;
      sizes[i] = 0;
      drops++;
    }
  }

  // F13.2: closing the loop. The sweep above compared every pair, but a box
  // only became a *restore* when the re-measure — or the ladder's last rung —
  // took its lettering away, and that happens after the comparison. So walk the
  // finished plan once more and settle any painting box now sitting on a
  // freshly restored area. Each step of this loop settles one pair by moving
  // lettering or by taking it away, and never the reverse, so the number of
  // unresolved pairs strictly falls: the bound below is belt-and-braces, not
  // the thing that stops it.
  for (var settle = 0; settle < n * n + n; settle++) {
    int? paint, ground;
    for (var i = 0; i < n && paint == null; i++) {
      if (!paints(i)) continue;
      for (var r = 0; r < n; r++) {
        if (r == i || !restores(r)) continue;
        if (!boxes[i].intersect(boxes[r]).isEmpty) {
          paint = i;
          ground = r;
          break;
        }
      }
    }
    if (paint == null || ground == null) break;
    yieldToRestore(paint, ground);
  }

  // Nothing moved, nothing stood down: the page is provably untouched by this
  // pass, and it comes back as the very list that went in.
  if (touched.isEmpty && yields == 0) return placements;

  Log.info(
    'OCR Layout',
    'collision pass: $cuts side(s) gave back grown gutter, $pushes stepped '
    'aside, $shares band(s) split — ${touched.length} box(es) re-measured, '
    '$drops of them now keep the original (nothing is drawn twice)'
    // F13.2: counted apart, because it is a different sentence: these blocks
    // were not dropped for want of room, they stood down so the *source*
    // lettering under them stays readable.
    '${yields > 0 ? ', $yields stood down over restored artwork' : ''}',
  );
  return [
    for (var i = 0; i < n; i++)
      placements[i].boxed(boxes[i], sizes[i], decisions[i]),
  ];
}

/// Whether block [from] can slide [need] px forward along the cut axis and land
/// inside its own [safeGrowRect] envelope with nothing in the way.
///
/// The envelope is the same budget the layout already spends when it grows a
/// box into the gutter (40% of the clear distance to the nearest obstacle,
/// clipped to the page), so a step aside can never reach further than a growth
/// would have been allowed to, can never leave the artwork, and is refused
/// outright if the destination touches a third block's ink.
///
/// [blocked] says which *other* blocks are in the way. It is a predicate rather
/// than "the other placements" because of Phase 13-F13.2: a slide has to land
/// clear of the areas that get the source artwork stamped back into them just
/// as much as clear of the areas that get lettering — ink put there by the
/// restore pass is ink the reader sees, and a step aside that lands on it
/// reproduces the very overlap this pass exists to remove.
///
/// [ignore] is the neighbour this block is stepping away from. It is left out of
/// the *envelope* on purpose: its edge currently lies inside this box, so the
/// clear gap on the side of the move is negative and [safeGrowRect] would hand
/// back no room at all there — the push could never be offered. It is still one
/// of the boxes the *destination* is checked against, so excluding it from the
/// budget does not mean the move may land on it.
bool _pushClears({
  required TranslatedRegion region,
  required ui.Rect from,
  required double need,
  required bool alongX,
  required ui.Size page,
  required List<ui.Rect> boxes,
  required bool Function(int) blocked,
  required int skip,
  required int ignore,
}) {
  final shifted = from.translate(alongX ? need : 0, alongX ? 0 : need);
  if (shifted.width <= 4 || shifted.height <= 4) return false;
  final envelope = safeGrowRect(
    rect: _rectOf(region),
    eraseBounds: _eraseBoundsOf(region),
    obstacles: [
      for (var k = 0; k < boxes.length; k++)
        if (k != skip && k != ignore && blocked(k)) boxes[k],
    ],
    pageWidth: page.width,
    pageHeight: page.height,
  );
  if (!_envelopes(envelope, shifted)) return false;
  for (var k = 0; k < boxes.length; k++) {
    if (k == skip || !blocked(k)) continue;
    if (!shifted.intersect(boxes[k]).isEmpty) return false;
  }
  return true;
}

/// Whether [outer] holds [inner] whole. `Rect.contains` answers for a point,
/// not a box, so the containment a push needs is spelled out here.
bool _envelopes(ui.Rect outer, ui.Rect inner) =>
    inner.left >= outer.left &&
    inner.top >= outer.top &&
    inner.right <= outer.right &&
    inner.bottom <= outer.bottom;

// ---------------------------------------------------------------------------
// Defect A fix: colliding regions merge into one painting — never two texts
// on one rectangle
// ---------------------------------------------------------------------------

/// Share of the smaller box's area the intersection must cover before two
/// differently-worded regions count as "the same region detected twice".
///
/// When the detector's component boxes split one caption into a whole-block
/// box plus a line box (the thickness/direction guards in the worker's
/// clustering refuse to merge them), the smaller box sits almost fully
/// inside the bigger one — coverage near 1. Two genuinely separate bubbles
/// that merely neighbour each other overlap by far less than a third of the
/// smaller one. 0.35 sits between those worlds: it collapses the duplicate-
/// caption failure (interleaved lettering on real pages) while leaving
/// close-but-distinct bubbles to the normal per-block path, where
/// [safeGrowRect] already keeps them out of each other's gutter.
const double kMergeOverlapCov = 0.35;

/// The same test for regions whose texts are identical: two boxes over the
/// same art carrying the same string are one block twice whatever the
/// detector's opinion of their borders was — so the gate sits lower.
const double kMergeDuplicateCov = 0.15;

/// Collapse every whitespace run so "同一 段文字" and "同一 段文字 " compare
/// equal; only used to spot duplicate detections, never to rewrite text.
String _collapseWhitespace(String text) =>
    text.replaceAll(RegExp(r'\s+'), '');

/// Merge regions whose boxes collide (see [kMergeOverlapCov]).
///
/// A merged block paints once, in its members' reading order — top to
/// bottom, and right-to-left between same-row vertical columns (Japanese
/// manga order) — with identical texts collapsed to the first copy. Its rect
/// is the members' union, its erase footprint the members' line boxes, so
/// nothing the detector had cleaned stops being cleaned. The returned list
/// keeps one entry per collision group ordered by first member index;
/// collision-free input comes back as the same list object.
List<TranslatedRegion> resolveRegionCollisions(List<TranslatedRegion> regions) {
  final n = regions.length;
  if (n < 2) return regions;
  final rects = [for (final r in regions) r.rect.toRect()];
  final normed = [for (final r in regions) _collapseWhitespace(r.text)];
  final parent = List<int>.generate(n, (i) => i);
  int find(int x) {
    while (parent[x] != x) {
      parent[x] = parent[parent[x]];
      x = parent[x];
    }
    return x;
  }

  var collisions = 0;
  for (var i = 0; i < n; i++) {
    for (var j = i + 1; j < n; j++) {
      final a = rects[i], b = rects[j];
      if (a.width <= 0 || a.height <= 0 || b.width <= 0 || b.height <= 0) {
        continue;
      }
      final inter = a.intersect(b);
      if (inter.isEmpty) continue;
      final smaller =
          a.width * a.height < b.width * b.height
          ? a.width * a.height
          : b.width * b.height;
      final cov = inter.width * inter.height / smaller;
      final duplicateText =
          normed[i].isNotEmpty && normed[i] == normed[j] && cov >= kMergeDuplicateCov;
      if (cov >= kMergeOverlapCov || duplicateText) {
        final ri = find(i), rj = find(j);
        if (ri != rj) {
          collisions++;
          parent[rj] = ri;
        }
      }
    }
  }
  if (collisions == 0) return regions;

  final groups = <int, List<int>>{};
  for (var i = 0; i < n; i++) {
    (groups[find(i)] ??= <int>[]).add(i);
  }
  final ordered = groups.values.toList()
    ..sort((a, b) => a.first.compareTo(b.first));
  final out = <TranslatedRegion>[];
  for (final members in ordered) {
    if (members.length == 1) {
      out.add(regions[members.first]);
      continue;
    }
    out.add(_mergeRegionGroup(regions, members));
  }
  Log.info(
    'OCR Layout',
    'merged $n colliding region(s) into ${out.length} block(s): overlapping '
    'detections would have painted on top of each other',
  );
  return out;
}

/// One merged block from [members] (indices into [regions], ≥2 entries).
///
/// Text is joined in reading order with identical strings collapsed, which
/// is what turns "the same paragraph twice, interleaved" back into the
/// paragraph once. Colour is taken from the largest member (the plate colour
/// of the dominant bubble wins in patch mode); lineHeight is the median of
/// the members that carry one (the fit search's size cap stays honest).
TranslatedRegion _mergeRegionGroup(
  List<TranslatedRegion> regions,
  List<int> members,
) {
  final sorted = members.toList()
    ..sort((a, b) {
      final byReading = _compareReadingOrder(regions[a], regions[b]);
      return byReading != 0 ? byReading : a.compareTo(b);
    });
  var left = 1 << 30, top = 1 << 30, right = -(1 << 30), bottom = -(1 << 30);
  var eLeft = 1 << 30, eTop = 1 << 30, eRight = -(1 << 30), eBottom = -(1 << 30);
  final eraseLines = <IntRect>[];
  final heights = <int>[];
  final seen = <String>{};
  final parts = <String>[];
  TranslatedRegion? biggest;
  double biggestArea = -1;
  for (final i in sorted) {
    final r = regions[i];
    left = math.min(left, r.rect.left);
    top = math.min(top, r.rect.top);
    right = math.max(right, r.rect.right);
    bottom = math.max(bottom, r.rect.bottom);
    final srcErase = r.eraseRect;
    eLeft = math.min(eLeft, srcErase.left);
    eTop = math.min(eTop, srcErase.top);
    eRight = math.max(eRight, srcErase.right);
    eBottom = math.max(eBottom, srcErase.bottom);
    for (final line in r.eraseRects) {
      if (line.width > 0 && line.height > 0) eraseLines.add(line);
    }
    if (r.lineHeight > 0) heights.add(r.lineHeight);
    final area = (r.rect.width * r.rect.height).toDouble();
    if (area > biggestArea) {
      biggestArea = area;
      biggest = r;
    }
    final key = _collapseWhitespace(r.text);
    if (key.isEmpty || !seen.add(key)) continue;
    parts.add(r.text.trim());
  }
  heights.sort();
  return TranslatedRegion(
    rect: IntRect(left, top, right, bottom),
    eraseRect: IntRect(eLeft, eTop, eRight, eBottom),
    eraseRects: eraseLines,
    text: parts.join('\n'),
    backgroundColor: biggest!.backgroundColor,
    textColor: biggest.textColor,
    lineHeight: heights.isEmpty ? 0 : heights[heights.length ~/ 2],
  );
}

/// Manga reading order over two regions: down the page first, and between
/// boxes sharing a row band, vertical columns read right-to-left while
/// horizontal runs read left-to-right. The tie-break on original index (in
/// the caller) keeps the sort deterministic for equal boxes.
int _compareReadingOrder(TranslatedRegion a, TranslatedRegion b) {
  final ra = a.rect, rb = b.rect;
  final minH = math.min(ra.height, rb.height);
  final rowOverlap =
      math.min(ra.bottom, rb.bottom) - math.max(ra.top, rb.top);
  if (minH > 0 && rowOverlap >= 0.5 * minH) {
    final bothColumns =
        ra.height >= ra.width * 1.25 && rb.height >= rb.width * 1.25;
    return bothColumns
        ? rb.left.compareTo(ra.left)
        : ra.left.compareTo(rb.left);
  }
  return ra.top.compareTo(rb.top);
}

// ---------------------------------------------------------------------------
// Phase 11-S4: the stroke is part of the layout, not a garnish on it
// ---------------------------------------------------------------------------

/// Default outline weight when the source block's own lettering cannot be
/// measured: 14% of the glyph size — the ratio every block used before S4.
const double kDefaultStrokeRatio = 0.14;

/// Outlines are drawn at least this many px wide, whatever the ratio says:
/// below it the ink simply stops being visible at manga page sizes.
const double kMinStrokeWidth = 1.5;

/// Plausible bounds for a *detected* source stroke ratio. Outside them the
/// measurement is saying more about screentone or a black blob than about
/// lettering, so the ratio is clamped back into this range before it reaches
/// either the fit budget or the pen.
const double kStrokeRatioFloor = 0.03;
const double kStrokeRatioCeil = 0.35;

/// The ratio to paint and budget with: the source lettering's measured
/// weight when [estimateStrokeRatio] could say something about the block,
/// [kDefaultStrokeRatio] otherwise, always clamped into the plausible band.
double strokeRatioFor(double? detectedSourceRatio) =>
    detectedSourceRatio == null || !detectedSourceRatio.isFinite
    ? kDefaultStrokeRatio
    : detectedSourceRatio.clamp(kStrokeRatioFloor, kStrokeRatioCeil);

/// How thick an outline this block draws at this glyph size.
///
/// The single place that answer exists — the fit budget, the horizontal pen
/// and the vertical column geometry all ask here, so they can never disagree
/// about how much ink hangs off a glyph.
double strokeWidthForSize(double fontSize, {double? sourceStrokeRatio}) =>
    math.max(kMinStrokeWidth, fontSize * strokeRatioFor(sourceStrokeRatio));

/// What a fit budget must reserve beyond the fixed 4px of breathing room:
/// the outline that extends past the measured glyph box on every side.
double strokeInset(
  double fontSize,
  bool outlined, {
  double? sourceStrokeRatio,
}) => 4.0 + (outlined ? strokeWidthForSize(fontSize, sourceStrokeRatio: sourceStrokeRatio) : 0.0);

/// Cell pitch down a column: 15% leading plus the outline — two stacked
/// ideographs each ringed in ink need the stroke width between them or their
/// rings touch and the column reads as one smear.
double columnPitchFor(double size, double strokeWidth) =>
    size * 1.15 + strokeWidth;

/// Distance between two columns: a hair wider than a cell, plus the outline
/// for the same reason.
double columnWidthFor(double size, double strokeWidth) =>
    size * 1.2 + strokeWidth;

/// Measure one block at one exact size, stroke included.
///
/// The one question every layer asks, phrased once: the fit search, S1's
/// [decideOverflow] oracle and S5's group harmonisation all answer through
/// here, so "measured to fit", "grew because it fits" and "painted at this
/// size" cannot drift apart. [size] is not judged against the legibility
/// floor — that is the caller's decision — only against what the box and the
/// stroke leave for it.
bool fitsRegionAt(
  TranslatedRegion region,
  ui.Rect box, {
  required bool vertical,
  required double size,
  bool outlined = true,
  double? sourceStrokeRatio,
}) {
  if (size <= 0 || box.width <= 0 || box.height <= 0) return false;
  final stroke = outlined
      ? strokeWidthForSize(size, sourceStrokeRatio: sourceStrokeRatio)
      : 0.0;
  final inset = 4.0 + stroke;
  final availW = box.width - inset;
  final availH = box.height - inset;
  if (availW <= 0 || availH <= 0) return false;
  if (vertical) {
    final spans = layoutVerticalSpans(region.text);
    if (spans.isEmpty) return false;
    final cells = spans.fold<int>(0, (sum, span) => sum + span.cells);
    final pitch = columnPitchFor(size, stroke);
    final columnW = columnWidthFor(size, stroke);
    if (pitch > availH || columnW > availW) return false;
    final perColumn = math.max(1, (availH / pitch).floor());
    final columns = (cells / perColumn).ceil();
    return columns * columnW <= availW;
  }
  final painter = _layoutBlock(
    region.text,
    size,
    _fillStyle(const ui.Color(0xFF000000), size),
    availW,
  );
  final fits = painter.height <= availH && painter.width <= availW;
  painter.dispose();
  return fits;
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
///
/// Every candidate size is tested with the outline that size would draw —
/// heavier stroke, smaller lettering, which is the whole point of S4: a
/// translation that only "fits" by leaving its stroke to overflow the box was
/// never legible to begin with.
({double size, bool fits}) _fitRegion(
  TranslatedRegion region,
  ui.Rect box,
  bool vertical, {
  bool outlined = true,
  double? sourceStrokeRatio,
}) {
  var size = _upperBound(box.height, region.lineHeight);
  final floor = minReadableGlyphSize;
  while (size >= floor) {
    if (fitsRegionAt(
      region,
      box,
      vertical: vertical,
      size: size,
      outlined: outlined,
      sourceStrokeRatio: sourceStrokeRatio,
    )) {
      return (size: size, fits: true);
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

// ---------------------------------------------------------------------------
// Phase 11-S5: one size per bubble
// ---------------------------------------------------------------------------

/// Two boxes share a bubble when the clear gap between them is at most this
/// many line heights (the shorter box's) — one line of breathing room between
/// stacked lines of the same bubble, and far less than the space between
/// separate bubbles.
const double kGroupGapFactor = 0.55;

/// Floor for the same test: never split lines that are only a few pixels
/// apart just because the OCR boxes were short.
const double kGroupMinGap = 6.0;

/// How much of the narrower box's width the overlap must cover before
/// vertical closeness counts as "same bubble": two captions at the bottom of
/// *different* bubbles stacked in the page's y-range must not merge through
/// a side-by-side layout.
const double kGroupMinWidthOverlap = 0.3;

/// Blocks whose source line heights differ by more than this factor are not
/// the same lettering — a huge SFX word sitting on a small caption is two
/// groups by definition, however close their boxes are.
const double kGroupScaleTolerance = 0.4;

/// Connected components of "looks like the same bubble".
///
/// Pure geometry over the boxes (indices into [boxes], groups ordered by
/// first member). Pairwise link: stacked with a small vertical gap and real
/// horizontal overlap, or inline with a small horizontal gap and near-full
/// vertical overlap — plus a [sourceGlyphSizes] compatibility check so
/// different lettering scales never merge.
List<List<int>> clusterLayoutGroups({
  required List<ui.Rect> boxes,
  List<double?> sourceGlyphSizes = const [],
  double gapFactor = kGroupGapFactor,
  double minGap = kGroupMinGap,
  double minOverlap = kGroupMinWidthOverlap,
}) {
  final n = boxes.length;
  final parent = List<int>.generate(n, (i) => i);
  int find(int x) {
    while (parent[x] != x) {
      parent[x] = parent[parent[x]];
      x = parent[x];
    }
    return x;
  }

  for (var i = 0; i < n; i++) {
    for (var j = i + 1; j < n; j++) {
      if (!_sharesBubble(
        boxes[i],
        boxes[j],
        sourceGlyphSizes.length > i ? sourceGlyphSizes[i] : null,
        sourceGlyphSizes.length > j ? sourceGlyphSizes[j] : null,
        gapFactor: gapFactor,
        minGap: minGap,
        minOverlap: minOverlap,
      )) {
        continue;
      }
      final ri = find(i), rj = find(j);
      if (ri != rj) parent[rj] = ri;
    }
  }

  final roots = <int, List<int>>{};
  for (var i = 0; i < n; i++) {
    (roots[find(i)] ??= <int>[]).add(i);
  }
  final groups = roots.values.toList()
    ..sort((a, b) => a.first.compareTo(b.first));
  return groups;
}

bool _sharesBubble(
  ui.Rect a,
  ui.Rect b,
  double? sizeA,
  double? sizeB, {
  required double gapFactor,
  required double minGap,
  required double minOverlap,
}) {
  if (sizeA != null && sizeB != null && sizeA > 0 && sizeB > 0) {
    final ratio = sizeA > sizeB ? sizeA / sizeB : sizeB / sizeA;
    if (ratio > 1.0 + kGroupScaleTolerance) return false;
  }
  final base = math.min(a.height, b.height);
  if (base <= 0) return false;
  final reach = math.max(minGap, gapFactor * base);
  // Stacked: close vertically, and wide enough side-by-side that a bubble
  // sitting *next to* this one (same y, no x overlap) is not a neighbour.
  final vGap = math.max(0.0, math.max(a.top, b.top) - math.min(a.bottom, b.bottom));
  final xOverlap = math.min(a.right, b.right) - math.max(a.left, b.left);
  if (vGap <= reach && xOverlap >= minOverlap * math.min(a.width, b.width)) {
    return true;
  }
  // Inline: one visual line the detector split into pieces.
  final hGap = math.max(0.0, math.max(a.left, b.left) - math.min(a.right, b.right));
  final yOverlap = math.min(a.bottom, b.bottom) - math.max(a.top, b.top);
  return hGap <= reach && yOverlap >= 0.75 * base;
}

/// The size every member of a group can be drawn at, or `null` when the
/// group cannot agree above the legibility floor.
///
/// Starts at the largest member size and steps ×0.8 — the same ladder as the
/// per-block search — down to the first size at which [fitsAll] (each member
/// re-measured in its own box at this size) is true. Under a size-monotone
/// fits predicate this always lands at or above the smallest member's own
/// fitted size, so harmonising never pushes a block below what it chose for
/// itself; [fitsAll] is *not* assumed monotone, which is why the descent, not
/// a simple `min`, is the search, and why it can still refuse (`null`) rather
/// than force a size one member would overflow — S1's keepOriginal stays
/// reachable through the caller's reality gate.
double? unifyGroupSize({
  required List<double> soloSizes,
  required bool Function(double size) fitsAll,
  double? minReadable,
}) {
  if (soloSizes.isEmpty) return null;
  final floor = minReadable ?? minReadableGlyphSize;
  var size = soloSizes.reduce(math.max);
  while (size >= floor) {
    if (fitsAll(size)) return size;
    size *= 0.8;
  }
  return null;
}

/// One page of placements with every bubble-sized group harmonised.
///
/// Only sizes shrink and only to sizes every member was independently
/// measured to fit, so no [Placement] can flip from `shrinkToFit` to
/// overflow, and a member that is already `keepOriginal` never drags its
/// group down (it is not paintable, so it is not in any group). A group that
/// cannot agree on a size keeps its members' own sizes — coordinated
/// *upwards* is not on the table, coordinated *forcing* least of all.
List<Placement> unifyPlacementGroups(
  List<Placement> placements,
  List<TranslatedRegion> regions, {
  bool outlined = true,
  double? minReadable,
}) {
  final paintable = placements.where((p) => p.paints).toList();
  if (paintable.length < 2) return placements;
  final groups = clusterLayoutGroups(
    boxes: [for (final p in paintable) p.box],
    sourceGlyphSizes: [
      for (final p in paintable)
        regions[p.index].lineHeight > 0
            ? regions[p.index].lineHeight.toDouble()
            : null,
    ],
  );
  final result = placements.toList();
  for (final group in groups) {
    if (group.length < 2) continue;
    final members = [for (final g in group) paintable[g]];
    final unified = unifyGroupSize(
      soloSizes: [for (final m in members) m.size],
      minReadable: minReadable,
      fitsAll: (size) => members.every(
        (m) => fitsRegionAt(
          regions[m.index],
          m.box,
          vertical: m.vertical,
          size: size,
          outlined: outlined,
          sourceStrokeRatio: m.sourceStrokeRatio,
        ),
      ),
    );
    if (unified == null) continue;
    final groupId = members.first.index;
    for (final m in members) {
      result[m.index] = m.sized(unified, groupId);
    }
  }
  return result;
}

// ---------------------------------------------------------------------------
// Phase 11-S4 probe: how thick is the lettering we are replacing?
// ---------------------------------------------------------------------------

/// Stroke weight of the source ink, measured from raw pixels — pure, no
/// image I/O, so a unit test can hand it a synthetic bubble.
///
/// Pixels inside [box] are classified as ink when far enough (RGB distance
/// over [inkDistance]) from [backgroundArgb] (0xAARRGGBB of the sampled
/// bubble interior). One erosion pass then measures the stroke: a stroke of
/// thickness t holds ≈ t × P ink pixels (P = midline length) and loses ≈ 2 × P
/// of them to the pass (both edges), so t ≈ 2·ink/lost. The returned ratio is
/// t relative to [referenceSizePx] — the source lettering's own size.
///
/// `ratio` is null when the sample cannot speak: too little ink to be
/// lettering, an undifferentiated fill (erosion removes nothing), or a
/// thickness implausible for glyph ink (outside 0.02–0.6 of the source size).
/// A solid-filled *stem* (no outline at all) measures as its half-width,
/// which is exactly what "this block's ink is heavy" should mean for the
/// replacement's outline weight — the probe is a visual-weight meter, not a
/// segmentation of text from its outline.
({double? ratio, double thicknessPx, int inkArea}) estimateStrokeRatio({
  required Uint8List rgba,
  required int width,
  required int height,
  required IntRect box,
  required int backgroundArgb,
  required double referenceSizePx,
  int maxSamples = 120000,
  double inkDistance = 60,
}) {
  final empty = (ratio: null, thicknessPx: 0.0, inkArea: 0);
  if (referenceSizePx < 4 || width < 2 || height < 2) return empty;
  if (rgba.length < width * height * 4) return empty;
  final left = box.left.clamp(0, math.max(0, width - 1)).toInt();
  final top = box.top.clamp(0, math.max(0, height - 1)).toInt();
  final right = box.right.clamp(left + 1, width).toInt();
  final bottom = box.bottom.clamp(top + 1, height).toInt();
  final bw = right - left, bh = bottom - top;
  if (bw < 8 || bh < 8) return empty;

  // Big blocks get a coarser grid; thickness scales back to real pixels.
  final stride = bw * bh > maxSamples
      ? math.max(1, math.sqrt(bw * bh / maxSamples).ceil())
      : 1;
  final gw = (bw - 1) ~/ stride + 1;
  final gh = (bh - 1) ~/ stride + 1;
  final ink = Uint8List(gw * gh);
  // rawRgba bytes are R,G,B,A; background arrives as 0xAARRGGBB.
  final br = (backgroundArgb >> 16) & 0xFF;
  final bg = (backgroundArgb >> 8) & 0xFF;
  final bb = backgroundArgb & 0xFF;
  final limit = inkDistance * inkDistance;
  var inkArea = 0;
  for (var y = 0; y < gh; y++) {
    final py = top + y * stride;
    for (var x = 0; x < gw; x++) {
      final i = ((py * width) + left + x * stride) * 4;
      final dr = rgba[i] - br, dg = rgba[i + 1] - bg, db = rgba[i + 2] - bb;
      if (dr * dr + dg * dg + db * db > limit) {
        ink[y * gw + x] = 1;
        inkArea++;
      }
    }
  }
  if (inkArea < 24) return empty;

  var boundary = 0;
  for (var y = 0; y < gh; y++) {
    for (var x = 0; x < gw; x++) {
      final g = y * gw + x;
      if (ink[g] == 0) continue;
      final edge = x == 0 ||
          y == 0 ||
          x == gw - 1 ||
          y == gh - 1 ||
          ink[g - 1] == 0 ||
          ink[g + 1] == 0 ||
          ink[g - gw] == 0 ||
          ink[g + gw] == 0;
      if (edge) boundary++;
    }
  }
  if (boundary == 0) return empty; // a fill with no shape inside it at all

  final thicknessPx = 2 * inkArea / boundary * stride;
  final ratio = thicknessPx / referenceSizePx;
  if (ratio < 0.02 || ratio > 0.6) {
    return (ratio: null, thicknessPx: thicknessPx, inkArea: inkArea);
  }
  return (ratio: ratio, thicknessPx: thicknessPx, inkArea: inkArea);
}

/// Measure every block's source outline weight in one pass over the page.
///
/// Reads the *original* bytes (in the smart erase modes [decoded] has already
/// been cleaned, so its pixels would report "no ink" everywhere), scales them
/// to the working resolution, and runs [estimateStrokeRatio] on each region's
/// tight source area. Anything unreadable yields `{}` — the renderer then
/// falls back to [kDefaultStrokeRatio] per block, exactly the pre-S4
/// behaviour. Never throws: a broken probe must not take a page down.
Future<Map<int, double>> detectStrokeRatios(
  Uint8List originalBytes,
  RgbaImage decoded,
  List<TranslatedRegion> regions,
) async {
  if (originalBytes.isEmpty || regions.isEmpty) return const {};
  final pristine = await _tryDecodeScaled(originalBytes, decoded);
  if (pristine == null) return const {};
  try {
    final data = await pristine.toByteData(format: ui.ImageByteFormat.rawRgba);
    if (data == null) return const {};
    final bytes = data.buffer.asUint8List();
    final out = <int, double>{};
    for (var i = 0; i < regions.length; i++) {
      final region = regions[i];
      final sample = _sourceSampleOf(region);
      if (sample == null) continue;
      final reference = region.lineHeight > 0
          ? region.lineHeight.toDouble()
          : sample.height.toDouble();
      final est = estimateStrokeRatio(
        rgba: bytes,
        width: pristine.width,
        height: pristine.height,
        box: sample,
        backgroundArgb: region.backgroundColor,
        referenceSizePx: reference,
      );
      final ratio = est.ratio;
      if (ratio != null) out[i] = ratio;
    }
    if (out.isNotEmpty) {
      final sorted = out.values.toList()..sort();
      Log.info(
        'OCR Layout',
        'stroke probe: ${out.length} of ${regions.length} blocks measured,'
        ' median ratio ${sorted[sorted.length ~/ 2].toStringAsFixed(3)}',
      );
    }
    return out;
  } catch (e) {
    Log.warning('OCR Layout', 'stroke probe failed: $e');
    return const {};
  } finally {
    pristine.dispose();
  }
}

/// Union of a region's per-line source boxes — where the original glyphs
/// actually are, not the looser layout rect the translation may grow into.
IntRect? _sourceSampleOf(TranslatedRegion region) {
  int? left, top, right, bottom;
  void add(IntRect r) {
    if (r.width <= 0 || r.height <= 0) return;
    left = left == null ? r.left : math.min(left!, r.left);
    top = top == null ? r.top : math.min(top!, r.top);
    right = right == null ? r.right : math.max(right!, r.right);
    bottom = bottom == null ? r.bottom : math.max(bottom!, r.bottom);
  }

  add(region.eraseRect);
  for (final rect in region.eraseRects) {
    add(rect);
  }
  if (left == null) return region.rect.width > 0 && region.rect.height > 0 ? region.rect : null;
  return IntRect(left!, top!, right!, bottom!);
}

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

/// Whether this block's lettering should be light-on-dark.
///
/// The old test was a plain mean over the box — and the box is a *grown* box
/// ([safeGrowRect] borrows gutter on every side). A caption living in a white
/// bubble whose grown box also caught a strip of night sky, a black panel or a
/// screentone shadow therefore averaged dark, took the dark branch, and painted
/// its outline in 90%-opaque black at up to 35% of the glyph size **across
/// bright artwork**. That halo covers three to five times the area of the ink
/// it rings and fuses neighbouring glyphs into one mass: it is the black block
/// the screenshots show. The eraser never wrote it — [TextInpainter] can only
/// ever copy a pixel that already existed on the page — this line chose the
/// colour, and a wrong choice of a thick black pen is a drawn black block.
///
/// So the question is answered as it is actually asked: which background does
/// this box *mostly contain*, rather than what does its average come to. A box
/// that is dark on the mean but bright on the majority is mixed, and a mixed
/// box goes to the light branch on purpose — dark lettering ringed in white
/// reads on a black bubble too, while white lettering ringed in black destroys
/// a bright page. Where the mean and the majority agree, nothing changes.
bool backgroundReadsDark(RgbaImage image, ui.Rect rect) {
  final w = image.width;
  final left = rect.left.round().clamp(0, math.max(0, w - 1)).toInt();
  final top =
      rect.top.round().clamp(0, math.max(0, image.height - 1)).toInt();
  final right = rect.right.round().clamp(left + 1, w).toInt();
  final bottom = rect.bottom.round().clamp(top + 1, image.height).toInt();
  final pixels = image.pixels;
  if (pixels.length < (bottom * w) * 4) {
    // The box does not fit the buffer it was measured against: no evidence,
    // and "no evidence" is the light branch (dark ink, white halo), never the
    // one that picks up a thick black pen.
    return false;
  }

  var sum = 0.0, bright = 0, dark = 0, count = 0;
  var stepX = math.max(1, (right - left) ~/ 24);
  var stepY = math.max(1, (bottom - top) ~/ 24);
  for (var y = top; y < bottom; y += stepY) {
    for (var x = left; x < right; x += stepX) {
      var i = (y * w + x) * 4;
      var lum = 0.299 * pixels[i] + 0.587 * pixels[i + 1] + 0.114 * pixels[i + 2];
      sum += lum;
      if (lum >= kBrightPixelLum) {
        bright++;
      } else if (lum <= kDarkPixelLum) {
        dark++;
      }
      count++;
    }
  }
  if (count == 0) return false;
  return dark > bright && sum / count < 128;
}

/// The two poles of the majority test. Anything between them is mid-tone
/// artwork that argues for neither branch, which is why it is counted by
/// exclusion rather than as a third class.
const double kBrightPixelLum = 140;
const double kDarkPixelLum = 90;

/// Mean-luminance test of the region on the (erased) base, choosing the text
/// colour. Sampled on a stride grid — a full read is needless for a summary.
bool _regionIsDark(RgbaImage image, ui.Rect rect) =>
    backgroundReadsDark(image, rect);

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
        sourceStrokeRatio: placement.sourceStrokeRatio,
      );
      return;
    }
    final size = placement.size;
    final stroke = strokeWidthForSize(
      size,
      sourceStrokeRatio: placement.sourceStrokeRatio,
    );
    // The same reservation the fit search made at this size, down to the
    // px: what was measured is what is painted.
    final inset = strokeInset(size, outline != null, sourceStrokeRatio: placement.sourceStrokeRatio);
    final availW = math.max(_minLayoutWidth, rect.width - inset);
    if (outline != null) {
      _paintBlock(
        canvas,
        region.text,
        size,
        _strokeStyle(outline, size, stroke),
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

TextStyle _fillStyle(ui.Color color, double fontSize) => TextStyle(
  color: color,
  fontSize: fontSize,
  height: 1.2,
  fontWeight: FontWeight.w500,
);

/// The outline paint for one glyph run. [strokeWidth] comes from
/// [strokeWidthForSize] — the same number the fit budget reserved — and the
/// round join keeps the ring continuous around corners instead of spiking.
TextStyle _strokeStyle(
  ui.Color outline,
  double fontSize,
  double strokeWidth,
) => TextStyle(
  fontSize: fontSize,
  height: 1.2,
  fontWeight: FontWeight.w500,
  foreground: ui.Paint()
    ..style = ui.PaintingStyle.stroke
    ..strokeWidth = strokeWidth
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
  double? sourceStrokeRatio,
}) {
  final spans = layoutVerticalSpans(text);
  if (spans.isEmpty || size <= 0) return;

  // Column geometry from the same numbers [fitsRegionAt] measured the fit
  // with — before S4 the outline extended past every reservation the search
  // had made and the clip ate whatever crossed the box edge.
  final stroke = outline == null
      ? 0.0
      : strokeWidthForSize(size, sourceStrokeRatio: sourceStrokeRatio);
  final inset = 4.0 + stroke;
  final availH = rect.height - inset;
  final availW = rect.width - inset;
  if (availH <= 0 || availW <= 0) return;
  final pitch = columnPitchFor(size, stroke);
  final columnW = columnWidthFor(size, stroke);
  final perColumn = math.max(1, (availH / pitch).floor());
  final cells = spans.fold<int>(0, (sum, span) => sum + span.cells);
  final columns = (cells / perColumn).ceil();
  if (columns * columnW > availW) return; // mirrors the fit; never force

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
      sourceStrokeRatio,
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
  double? sourceStrokeRatio,
) {
  // Tate-chu-yoko: the run keeps its horizontal shape, so it is scaled down
  // until `runeCount` glyphs fit into the cells it was allotted.
  final scale = span.kind == VerticalSpanKind.cluster
      ? math.min(1.0, (slot * 0.96) / math.max(1.0, size * span.runeCount))
      : 1.0;
  final glyphSize = size * scale;
  final stroke = outline == null
      ? 0.0
      : strokeWidthForSize(glyphSize, sourceStrokeRatio: sourceStrokeRatio);

  canvas.save();
  canvas.translate(center.dx + span.dxRatio * size, center.dy + span.dyRatio * size);
  if (span.isRotated) canvas.rotate(span.rotationRad);
  if (outline != null) {
    _paintCachedGlyph(
      canvas,
      span.text,
      glyphSize,
      _strokeStyle(outline, glyphSize, stroke).copyWith(height: 1.0),
      // The weight must be part of the key: two blocks of one page can share
      // glyph, size and colour yet carry different source strokes.
      '${span.text}|${glyphSize.toStringAsFixed(2)}'
      '|${outline.toARGB32()}|sw${stroke.toStringAsFixed(2)}',
    );
  }
  _paintCachedGlyph(
    canvas,
    span.text,
    glyphSize,
    _fillStyle(fill, glyphSize).copyWith(height: 1.0),
    '${span.text}|${glyphSize.toStringAsFixed(2)}|${fill.toARGB32()}',
  );
  canvas.restore();
}

void _paintCachedGlyph(
  ui.Canvas canvas,
  String glyph,
  double size,
  TextStyle style,
  String cacheKey,
) {
  final painter = _verticalPainters.obtain(
    cacheKey,
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
