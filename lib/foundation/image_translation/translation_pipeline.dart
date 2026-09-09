import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:venera/foundation/image_translation/inpaint.dart';
import 'package:venera/foundation/image_translation/llm_translator.dart';
import 'package:venera/foundation/image_translation/page_renderer.dart';
import 'package:venera/foundation/image_translation/translation_models.dart';
import 'package:venera/foundation/image_translation/translation_types.dart';
import 'package:venera/foundation/image_translation/translation_worker.dart';
import 'package:venera/foundation/log.dart';
import 'package:venera/utils/opencc.dart';

/// Why a recognized block produced no drawn region.
///
/// Both of these used to be a bare `continue`: the block was recognized, the
/// page looked healthy, and the line was simply not translated — with nothing
/// in the log to say which of the two silent drops had eaten it (F13.7 named
/// the counts; this names each block).
enum BlockDropReason {
  /// [PageTranslationPipeline.classifyBlocks]: the block's detected
  /// language equals the target, so it is never sent to the model. An
  /// `auto`-mode page whose target is `zh` puts every pure-kanji line here,
  /// because the non-Japanese recognizer reads kanji-only Japanese as `zh`.
  targetLanguage,

  /// A `zh` block on a `zh-TW` target whose OpenCC conversion was a no-op, so
  /// there is nothing to draw: `erased` stays empty on purpose.
  targetUnconverted,

  /// The model answered with an empty string for this block (a dropped id, or
  /// an empty translation).
  modelEmpty,

  /// The model echoed the source text back unchanged.
  modelEchoed,
}

/// One block that reached the pipeline and left it without a region.
class BlockDrop {
  const BlockDrop({
    required this.index,
    required this.reason,
    required this.language,
    required this.text,
  });

  /// Position of the block in the list it was dropped from (`pending` for the
  /// model reasons, the recognized block list for the language reasons) —
  /// the same index the model's answer was aligned to.
  final int index;

  final BlockDropReason reason;

  final String language;

  /// The block's text, cut to [kBlockDropPreviewChars] so one line stays one
  /// line whatever the page holds.
  final String text;

  Map<String, dynamic> toJson() => {
    'i': index,
    'reason': reason.name,
    'lang': language,
    'text': text,
  };

  factory BlockDrop.fromJson(Map<String, dynamic> json) => BlockDrop(
    index: (json['i'] as num?)?.toInt() ?? 0,
    reason: BlockDropReason.values.firstWhere(
      (r) => r.name == json['reason'],
      orElse: () => BlockDropReason.modelEmpty,
    ),
    language: json['lang'] as String? ?? '',
    text: json['text'] as String? ?? '',
  );
}

/// How much of a dropped block's text a log line carries. Long enough to
/// recognize the line, short enough that a page of drops cannot bury the rest
/// of the log.
const int kBlockDropPreviewChars = 24;

/// Result of the analysis stage: render-ready regions plus the language
/// distribution of ALL translatable blocks (including ones skipped for
/// already being in the target language) — the service uses the votes to
/// lock a comic's dominant language.
class PageAnalysis {
  PageAnalysis(
    this.regions,
    this.languageVotes, [
    this.newGlossary = const {},
    this.dropped = const [],
  ]);

  final List<TranslatedRegion> regions;
  final Map<String, int> languageVotes;

  /// Name/proper-noun translations the model reported for this page, to be
  /// merged into the comic's running glossary for later pages.
  final Map<String, String> newGlossary;

  /// Blocks that were recognized and then dropped without a region, each with
  /// the reason it was dropped. Empty means "nothing was dropped", not "not
  /// measured": a page that produced regions and dropped nothing is exactly
  /// this. Used by the service's `BlockFunnel` line and by the log lines the
  /// drop sites emit — never for control flow.
  final List<BlockDrop> dropped;
}

/// Result of the OCR-only stage ([PageTranslationPipeline.ocrPage]): everything
/// known about a page before the LLM is called. Split out so a batch caller can
/// OCR several pages, send their [pending] blocks in ONE translation request,
/// then fold the results back per page. [ready] holds regions that need no LLM
/// (an already-target-language block converted zh→zh-TW).
class PageOcr {
  PageOcr(
    this.ready,
    this.pending,
    this.languageVotes, {
    this.error,
    this.dropped = const [],
  });

  /// Regions already finalized without translation (e.g. zh→zh-TW conversion).
  final List<TranslatedRegion> ready;

  /// Blocks awaiting LLM translation, in order. Empty means the page needs no
  /// request; combined with an empty [ready] it means nothing translatable.
  final List<OcrBlock> pending;

  final Map<String, int> languageVotes;

  final String? error;

  /// Blocks the language filter dropped while this page was recognized — see
  /// [BlockDropReason.targetLanguage] / [BlockDropReason.targetUnconverted].
  ///
  /// Carried on the OCR result (not only logged) so a caller that folds a
  /// batch back per page can still count *why* a block went nowhere. It is
  /// **not** part of [toJson]: the durable OCR cache is a performance
  /// artifact, and a page restored from it was never dropped on this run —
  /// reporting a cached drop as this run's would be a fabricated measurement.
  final List<BlockDrop> dropped;

  bool get hasError => error != null;

  bool get isEmpty => ready.isEmpty && pending.isEmpty;

  Map<String, dynamic> toJson() => {
    'ready': [for (var r in ready) r.toJson()],
    'pending': [for (var p in pending) p.toJson()],
    'votes': languageVotes,
    if (error != null) 'error': error,
  };

  factory PageOcr.fromJson(Map<String, dynamic> json) => PageOcr(
    (json['ready'] as List? ?? [])
        .map((e) => TranslatedRegion.fromJson(Map<String, dynamic>.from(e)))
        .toList(),
    (json['pending'] as List? ?? [])
        .map((e) => OcrBlock.fromJson(Map<String, dynamic>.from(e)))
        .toList(),
    Map<String, int>.from(json['votes'] as Map? ?? {}),
    error: json['error'] as String?,
  );
}

/// Per-page translation orchestrator. Runs on the main isolate but does no
/// heavy work itself: image decoding goes through the engine, detection/OCR
/// run inside the worker isolate, and translation is one request to the
/// user-configured LLM endpoint.
class PageTranslationPipeline {
  PageTranslationPipeline();

  /// OCR + translation. Returns render-ready regions; an empty list means
  /// the page has no text worth translating.
  ///
  /// [existingOcr] (null by default, so every existing caller keeps running
  /// the full OCR) lets a caller hand in a page already recognized by
  /// [ocrPage]/[ocrPages] — e.g. one restored from the durable OCR
  /// intermediate cache (plan D-8) — and skip the GPU stage entirely, paying
  /// only for the translation request. An [existingOcr] that records an
  /// error counts as absent: a half-failed recognition is re-run, never
  /// rendered.
  Future<PageAnalysis> analyzePage(
    Uint8List imageBytes, {
    required String sourceLang,
    required String targetLang,
    Map<String, String> glossary = const {},
    PageOcr? existingOcr,
    String page = '0',
  }) async {
    var ocr = (existingOcr != null && !existingOcr.hasError)
        ? existingOcr
        : await ocrPage(
            imageBytes,
            sourceLang: sourceLang,
            targetLang: targetLang,
          );
    if (ocr.pending.isEmpty) {
      return PageAnalysis(
        ocr.ready,
        ocr.languageVotes,
        const {},
        ocr.dropped,
      );
    }
    var result = await LlmTranslator.translateBatch(
      ocr.pending.map((b) => b.text).toList(),
      targetLang,
      glossary: glossary,
    );
    var folded = regionsFromTranslation(
      ocr.pending,
      result.texts,
      page: page,
    );
    var regions = [...ocr.ready, ...folded.regions];
    return PageAnalysis(
      regions,
      ocr.languageVotes,
      result.glossary,
      [...ocr.dropped, ...folded.dropped],
    );
  }

  /// Whether the OCR isolate already holds its models — see
  /// [TranslationWorker.isWarm]. Lets a caller tell "loading the model" apart
  /// from "recognizing", which look identical from the outside but differ by
  /// seconds on the first page.
  bool get ocrIsWarm => TranslationWorker.instance.isWarm;

  /// Super-batched OCR across multiple pages. Decodes images, groups tiles/crops
  /// into unified GPU/CPU batches, votes on language, applies zh->zh-TW conversion,
  /// and returns per-page [PageOcr] results.
  Future<List<PageOcr>> ocrPages(
    List<Uint8List> imageBytesList, {
    required String sourceLang,
    required String targetLang,
  }) async {
    if (imageBytesList.isEmpty) return const [];
    final images = await Future.wait([
      for (var bytes in imageBytesList) _decode(bytes),
    ]);
    final paths = TranslationModels.workerPaths();
    final pageResults = await TranslationWorker.instance.ocrPages(
      images,
      sourceLang: sourceLang,
      paths: paths,
    );

    final output = <PageOcr>[];
    var pageCounter = 0;
    for (var res in pageResults) {
      final pageIndex = pageCounter++;
      if (res.error != null) {
        output.add(PageOcr(const [], const [], const {}, error: res.error));
        continue;
      }
      var blocks = (res.blocks ?? const [])
          .where((b) => _isTranslatable(b.text))
          .toList();
      var votes = <String, int>{};
      for (var block in blocks) {
        votes[block.language] = (votes[block.language] ?? 0) + 1;
      }
      if (blocks.isEmpty) {
        output.add(PageOcr(const [], const [], votes));
        continue;
      }

      final classified = classifyBlocks(blocks, targetLang);
      for (final drop in classified.dropped) {
        // Defect B (drop site 1 of 2): this branch used to be a bare
        // `continue` with no line and no counter, so a line the recognizer
        // read as the target language — e.g. kanji-only Japanese read as `zh`
        // on an `auto`→`zh` page — vanished between two log lines that both
        // looked healthy. The block is still dropped: that is the right call
        // (there is nothing to translate), and changing it would spend a paid
        // LLM request on text the user already reads. What changes is that it
        // is now named. The decision itself lives in [classifyBlocks] so it
        // can be pinned without a GPU.
        _logDrop(
          pageIndex.toString(),
          drop.index,
          drop.reason,
          blocks[drop.index],
        );
      }
      output.add(
        PageOcr(
          classified.ready,
          classified.pending,
          votes,
          dropped: classified.dropped,
        ),
      );
    }
    return output;
  }

  /// The language-filter half of [ocrPages], as a pure function: which blocks
  /// are render-ready, which still await the model, and which are dropped with
  /// what reason.
  ///
  /// Split out so the drop reasons — and above all the fact that this filter
  /// still *drops* rather than translating — can be asserted in a unit test
  /// without a GPU, a model file or an image. [ocrPages] calls it with its own
  /// target base and converts the dropped list to log lines; the classification
  /// is identical either way, which is what makes the test meaningful.
  @visibleForTesting
  static ({
    List<TranslatedRegion> ready,
    List<OcrBlock> pending,
    List<BlockDrop> dropped,
  })
  classifyBlocks(List<OcrBlock> blocks, String targetLang) {
    final targetBase = targetLang == 'zh-TW' ? 'zh' : targetLang;
    var ready = <TranslatedRegion>[];
    var pending = <OcrBlock>[];
    var dropped = <BlockDrop>[];
    for (var i = 0; i < blocks.length; i++) {
      final block = blocks[i];
      if (block.language != targetBase) {
        pending.add(block);
        continue;
      }
      var reason = BlockDropReason.targetLanguage;
      if (targetLang == 'zh-TW' && block.language == 'zh') {
        final converted = OpenCC.simplifiedToTraditional(block.text);
        if (converted != block.text) {
          ready.add(_region(block, converted));
          continue;
        }
        reason = BlockDropReason.targetUnconverted;
      }
      dropped.add(_drop(i, reason, block));
    }
    return (ready: ready, pending: pending, dropped: dropped);
  }

  /// The one `BlockDrop` log line for a language-filter drop, in the same
  /// `key=value` shape as the model-drop site below so both are one grep apart.
  static void _logDrop(
    String page,
    int index,
    BlockDropReason reason,
    OcrBlock block,
  ) {
    Log.info(
      'Inpaint',
      'BlockDrop page=$page index=$index reason=${reason.name} '
      'lang=${block.language} text="${_preview(block.text)}"',
    );
  }

  /// OCR-only stage: decode, recognize, vote on language and apply the
  /// no-LLM zh→zh-TW conversion, returning the blocks still awaiting the model.
  /// Shared by [analyzePage] (reader, one page) and the batch pre-translation
  /// path (several pages, one request).
  Future<PageOcr> ocrPage(
    Uint8List imageBytes, {
    required String sourceLang,
    required String targetLang,
  }) async {
    final results = await ocrPages(
      [imageBytes],
      sourceLang: sourceLang,
      targetLang: targetLang,
    );
    if (results.isEmpty) {
      throw StateError('OCR produced no result');
    }
    if (results.first.hasError) {
      throw StateError(results.first.error!);
    }
    return results.first;
  }

  /// Turns [pending] blocks and their aligned [texts] into render-ready
  /// regions, dropping empties and no-ops. [texts] must align with [pending]
  /// (extra entries are ignored, missing ones treated as empty).
  ///
  /// Both drops are logged here and returned in the record's `dropped` list —
  /// see [BlockDropReason.modelEmpty] / [BlockDropReason.modelEchoed]. The
  /// behaviour is deliberately unchanged: an empty or echoed answer has
  /// nothing to draw, and re-asking the model would spend another request on
  /// a block it already declined. What changes is that the drop is a named,
  /// counted event instead of a `continue` nobody can see.
  ({List<TranslatedRegion> regions, List<BlockDrop> dropped})
  regionsFromTranslation(
    List<OcrBlock> pending,
    List<String> texts, {
    String page = '0',
  }) {
    var regions = <TranslatedRegion>[];
    var dropped = <BlockDrop>[];
    for (var i = 0; i < pending.length; i++) {
      var text = (i < texts.length ? texts[i] : '').trim();
      if (text.isEmpty || text == pending[i].text) {
        var reason = text.isEmpty
            ? BlockDropReason.modelEmpty
            : BlockDropReason.modelEchoed;
        dropped.add(_drop(i, reason, pending[i]));
        Log.info(
          'Inpaint',
          'BlockDrop page=$page index=$i reason=${reason.name} '
          'lang=${pending[i].language} '
          'text="${_preview(pending[i].text)}"',
        );
        continue;
      }
      regions.add(_region(pending[i], text));
    }
    return (regions: regions, dropped: dropped);
  }

  static BlockDrop _drop(int index, BlockDropReason reason, OcrBlock block) =>
      BlockDrop(
        index: index,
        reason: reason,
        language: block.language,
        text: _preview(block.text),
      );

  /// A block's text cut to [kBlockDropPreviewChars], whitespace collapsed so
  /// one drop is one log line whatever the recognizer returned.
  static String _preview(String text) {
    var flat = text.replaceAll(RegExp(r'\s+'), ' ').trim();
    return flat.length > kBlockDropPreviewChars
        ? '${flat.substring(0, kBlockDropPreviewChars)}…'
        : flat;
  }

  /// Renders [regions] over the page. Split from [analyzePage] so a page
  /// whose rendered image was evicted can be rebuilt from the cached text
  /// results alone. In [InpaintMode.smart] the original lettering is removed
  /// from the decoded pixels first with the pure-Dart eraser, so the renderer
  /// draws over a clean background.
  Future<Uint8List> renderPage(
    Uint8List imageBytes,
    List<TranslatedRegion> regions, {
    InpaintMode mode = InpaintMode.smart,
  }) async {
    var image = await _decode(imageBytes);
    final reason = ledgerReason(mode, regions);
    if (reason == kLedgerReasonPatch) {
      // Defect A, branch 1: `patch` never runs the eraser at all — the
      // original lettering is covered by opaque plates instead of erased. No
      // ledger was printed, so the most common mode on a slow device produced
      // a page whose "did the eraser run?" answer was, again, silence. It did
      // not run: `erased=0` is the honest count, and `reason=` says why.
      Log.info(
        'Inpaint',
        'erasure ledger: ${describeLedger(mode: mode, reason: reason)}',
      );
    } else if (reason == kLedgerReasonNoRegions) {
      // Defect A, branch 2: nothing to erase. This is the "no image to run
      // on" case that used to read identically to "the eraser never fired" —
      // and it is the one where a reader must not blame the eraser.
      Log.info(
        'Inpaint',
        'erasure ledger: ${describeLedger(mode: mode, reason: reason)}',
      );
    } else {
      // Defect A, branch 3 (the old one): the eraser keeps a per-rectangle
      // account. A rectangle whose reconstruction could not be completed — or
      // completed by turning bright artwork near-black — is put back exactly
      // as it was, so what is left on the page is the original lettering,
      // never a black block. That is a visible difference from "erased", so it
      // has to be a *logged* one too: without this line a rolled-back page
      // looks like an eraser that misfired, and the one person who can tell
      // the two apart is reading the log over the screenshot.
      final ledger = TextInpainter.eraseReport(
        image,
        eraseFootprintRects(regions, image.width, image.height),
      );
      // Phase 13-F13.3: the ledger is printed on **every** page, whatever it
      // says. It used to live inside the `rolledBack > 0` branch alone, and
      // silence is not a result — with no line to read, "the eraser never ran
      // on this page" (`erased=0 skipped=N`), "the eraser ran and the page is
      // clean" (`erased=N skipped=0`) and the one that the black-block reports
      // kept dying on, "the eraser shipped a black window and counted it a
      // success" (`erased=N`), were three names for the same nothing. The first
      // two are separable only by these counts; the third is separable from the
      // second only because the count of what it *declined* to do is on the
      // same line. The alarm keeps its own wording below so grepping an old
      // page still works. `mode=` and `reason=` are appended so this line and
      // the two branches above are one grep away from each other.
      final ledgerHead = describeLedger(
        mode: mode,
        reason: kLedgerReasonRan,
        erased: ledger.erased,
      );
      Log.info(
        'Inpaint',
        'erasure ledger: $ledgerHead ${ledger.describeLedger()}',
      );
      if (ledger.rolledBack > 0) {
        Log.warning(
          'Inpaint',
          'erasure rolled back to the original pixels on '
          '${ledger.rolledBack} of ${ledger.results.length} rectangle(s): '
          'source lettering stays visible there — ${ledger.describe()}',
        );
      }
    }
    return await renderTranslatedPage(imageBytes, image, regions, mode: mode);
  }

  /// The erasure-ledger line's leading fields: which render mode the page was
  /// drawn in and whether the eraser ran at all.
  ///
  /// [reason] is one of `ran` (the eraser ran, the counts follow),
  /// `patch` (the mode never calls the eraser), `no-regions` (nothing to
  /// erase) or `cache-hit` (the page was served from the rendered-image cache
  /// and never reached [renderPage] — logged by
  /// [ImageTranslationService.renderStoredPage]). Every one of them prints
  /// `erased=0` for the reasons where no pixel could have been written, so the
  /// three states a screenshot cannot tell apart — "never ran", "ran clean",
  /// "nothing to run on" — are three different lines instead of one absence.
  @visibleForTesting
  static String describeLedger({
    required InpaintMode mode,
    required String reason,
    int erased = 0,
  }) => 'mode=${mode.name} reason=$reason erased=$erased';

  /// `reason=` value for "the eraser ran and its own counts follow".
  static const String kLedgerReasonRan = 'ran';

  /// `reason=` value for [InpaintMode.patch]: the mode never calls the eraser.
  static const String kLedgerReasonPatch = 'patch';

  /// `reason=` value for "there was nothing to erase on this page".
  static const String kLedgerReasonNoRegions = 'no-regions';

  /// `reason=` value for "the rendered image was already cached, so this page
  /// was never re-rendered" — emitted by the service, not by [renderPage].
  static const String kLedgerReasonCacheHit = 'cache-hit';

  /// Which ledger line [renderPage] will print, as a pure function of the mode
  /// and the region list.
  ///
  /// Split out so the three branches — and the fact that the choice does not
  /// depend on anything else — can be asserted without decoding an image or
  /// running the eraser. [renderPage] uses exactly this, so a test over it is a
  /// test over the branch the page actually takes.
  @visibleForTesting
  static String ledgerReason(InpaintMode mode, List<TranslatedRegion> regions) {
    if (mode == InpaintMode.patch) return kLedgerReasonPatch;
    if (regions.isEmpty) return kLedgerReasonNoRegions;
    return kLedgerReasonRan;
  }

  /// Defect B: the per-line erase footprints, grown by a bounded margin.
  ///
  /// The detector's line boxes come from a binary-threshold flood fill
  /// (`_detPostprocessBatchSingle`): pixels fainter than the threshold —
  /// anti-aliased glyph edges — are not in the component, and the box is
  /// floored to integers, so a ring of still-readable original ink sits just
  /// *outside* the rectangle the eraser was handed. The eraser itself will
  /// not look further out than its own 1..3px guard (see TextInpainter's
  /// allowed window), so that ring is what shows through under the placed
  /// translation. Growing each erase rect by a small, source-scaled margin
  /// sweeps it.
  ///
  /// The margin is deliberately tiny and hard-capped at 4px: the eraser's
  /// contrast test cannot tell a wider window's bubble outlines and page
  /// artwork from lettering, and eating a line is far more visible than the
  /// 1px halo it would trade for. `2 + lineHeight/16` covers halos around
  /// small caption text (2px) and the bolder overhang of large lettering
  /// (capped 4px) without reaching the next line — line gaps are ≥ 0.4× the
  /// source glyph height, always above this margin.
  @visibleForTesting
  static List<IntRect> eraseFootprintRects(
    List<TranslatedRegion> regions,
    int width,
    int height,
  ) {
    final out = <IntRect>[];
    for (final region in regions) {
      final lineHeight = region.lineHeight > 0 ? region.lineHeight : 16;
      final margin = (2 + lineHeight ~/ 16).clamp(2, 4);
      for (final rect in region.eraseRects) {
        if (rect.width <= 0 || rect.height <= 0) continue;
        out.add(rect.inflated(margin, margin, width, height));
      }
    }
    return out;
  }

  static TranslatedRegion _region(OcrBlock block, String text) {
    return TranslatedRegion(
      rect: block.rect,
      eraseRect: block.eraseRect,
      eraseRects: block.eraseRects,
      text: text,
      backgroundColor: block.backgroundColor,
      textColor: block.textColor,
      lineHeight: block.lineHeight,
    );
  }

  bool _isTranslatable(String text) {
    if (text.length < 2) return false;
    // Pure digits/punctuation (page numbers, sfx dashes) are not worth a
    // translation pass.
    return text.runes.any((r) {
      return r > 0x2E80 || (r >= 0x41 && r <= 0x7A);
    });
  }

  Future<RgbaImage> _decode(Uint8List bytes) async {
    var buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
    var descriptor = await ui.ImageDescriptor.encoded(buffer);
    // Bound decoded size: huge pages (webtoon strips) are downscaled so the
    // pipeline's RGBA buffers stay within a sane memory budget, and no
    // dimension exceeds common GPU texture limits (the rendered result goes
    // through Picture.toImage).
    const maxPixels = 12 * 1024 * 1024;
    const maxDimension = 8000;
    var w = descriptor.width;
    var h = descriptor.height;
    var scale = 1.0;
    if (w * h > maxPixels) {
      scale = math.sqrt(maxPixels / (w * h));
    }
    if (math.max(w, h) * scale > maxDimension) {
      scale = maxDimension / math.max(w, h);
    }
    int? targetW;
    int? targetH;
    if (scale < 1.0) {
      // Both dimensions must be passed: instantiateCodec does not derive the
      // missing one from the aspect ratio.
      targetW = math.max(1, (w * scale).round());
      targetH = math.max(1, (h * scale).round());
    }
    var codec = await descriptor.instantiateCodec(
      targetWidth: targetW,
      targetHeight: targetH,
    );
    var frame = await codec.getNextFrame();
    var image = frame.image;
    try {
      var data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
      if (data == null) {
        throw Exception('Failed to read image pixels');
      }
      return RgbaImage(image.width, image.height, data.buffer.asUint8List());
    } finally {
      image.dispose();
      codec.dispose();
      descriptor.dispose();
      buffer.dispose();
    }
  }

  Future<void> release() async {
    TranslationWorker.instance.release();
  }
}

/// Kept for logging clarity when a page fails half-way; the worker reports
/// errors as exceptions already, so this is only used by the service layer.
void logTranslationFailure(Object error, StackTrace stack) {
  Log.error('Image Translation', error.toString(), stack);
}
