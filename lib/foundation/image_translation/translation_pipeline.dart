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

/// Result of the analysis stage: render-ready regions plus the language
/// distribution of ALL translatable blocks (including ones skipped for
/// already being in the target language) — the service uses the votes to
/// lock a comic's dominant language.
class PageAnalysis {
  PageAnalysis(this.regions, this.languageVotes, [this.newGlossary = const {}]);

  final List<TranslatedRegion> regions;
  final Map<String, int> languageVotes;

  /// Name/proper-noun translations the model reported for this page, to be
  /// merged into the comic's running glossary for later pages.
  final Map<String, String> newGlossary;
}

/// Result of the OCR-only stage ([PageTranslationPipeline.ocrPage]): everything
/// known about a page before the LLM is called. Split out so a batch caller can
/// OCR several pages, send their [pending] blocks in ONE translation request,
/// then fold the results back per page. [ready] holds regions that need no LLM
/// (an already-target-language block converted zh→zh-TW).
class PageOcr {
  PageOcr(this.ready, this.pending, this.languageVotes, {this.error});

  /// Regions already finalized without translation (e.g. zh→zh-TW conversion).
  final List<TranslatedRegion> ready;

  /// Blocks awaiting LLM translation, in order. Empty means the page needs no
  /// request; combined with an empty [ready] it means nothing translatable.
  final List<OcrBlock> pending;

  final Map<String, int> languageVotes;

  final String? error;

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
  }) async {
    var ocr = (existingOcr != null && !existingOcr.hasError)
        ? existingOcr
        : await ocrPage(
            imageBytes,
            sourceLang: sourceLang,
            targetLang: targetLang,
          );
    if (ocr.pending.isEmpty) {
      return PageAnalysis(ocr.ready, ocr.languageVotes, const {});
    }
    var result = await LlmTranslator.translateBatch(
      ocr.pending.map((b) => b.text).toList(),
      targetLang,
      glossary: glossary,
    );
    var regions = [
      ...ocr.ready,
      ...regionsFromTranslation(ocr.pending, result.texts),
    ];
    return PageAnalysis(regions, ocr.languageVotes, result.glossary);
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
    final targetBase = targetLang == 'zh-TW' ? 'zh' : targetLang;

    for (var res in pageResults) {
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

      var ready = <TranslatedRegion>[];
      var pending = <OcrBlock>[];
      for (var block in blocks) {
        if (block.language == targetBase) {
          if (targetLang == 'zh-TW' && block.language == 'zh') {
            var converted = OpenCC.simplifiedToTraditional(block.text);
            if (converted != block.text) {
              ready.add(_region(block, converted));
            }
          }
          continue;
        }
        pending.add(block);
      }
      output.add(PageOcr(ready, pending, votes));
    }
    return output;
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
  List<TranslatedRegion> regionsFromTranslation(
    List<OcrBlock> pending,
    List<String> texts,
  ) {
    var regions = <TranslatedRegion>[];
    for (var i = 0; i < pending.length; i++) {
      var text = (i < texts.length ? texts[i] : '').trim();
      if (text.isEmpty || text == pending[i].text) continue;
      regions.add(_region(pending[i], text));
    }
    return regions;
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
    if (mode != InpaintMode.patch && regions.isNotEmpty) {
      // Defect A: the eraser keeps a per-rectangle account. A rectangle whose
      // reconstruction could not be completed — or completed by turning bright
      // artwork near-black — is put back exactly as it was, so what is left on
      // the page is the original lettering, never a black block. That is a
      // visible difference from "erased", so it has to be a *logged* one too:
      // without this line a rolled-back page looks like an eraser that
      // misfired, and the one person who can tell the two apart is reading the
      // log over the screenshot.
      final ledger = TextInpainter.eraseReport(
        image,
        eraseFootprintRects(regions, image.width, image.height),
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

  TranslatedRegion _region(OcrBlock block, String text) {
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
