import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/cache_manager.dart';
import 'package:venera/foundation/image_translation/llm_translator.dart';
import 'package:venera/foundation/image_translation/ocr_fingerprint.dart';
import 'package:venera/foundation/image_translation/ort_capabilities.dart';
import 'package:venera/foundation/image_translation/rate_limiter.dart';
import 'package:venera/foundation/image_translation/translation_config.dart';
import 'package:venera/foundation/image_translation/translation_models.dart';
import 'package:venera/foundation/image_translation/translation_performance_config.dart';
import 'package:venera/foundation/image_translation/translation_pipeline.dart';
import 'package:venera/foundation/image_translation/translation_store.dart';
import 'package:venera/foundation/image_translation/translation_types.dart';
import 'package:venera/foundation/image_translation/translation_worker.dart';
import 'package:venera/foundation/log.dart';
import 'package:venera/foundation/source_platform.dart';
import 'package:venera/utils/io.dart';

/// Per-page translation state exposed to the reader UI for status feedback.
enum PageTranslationStatus {
  /// Not queued, not done — nothing to show.
  idle,

  /// Queued or actively being translated.
  translating,

  /// A translated page is cached and shown.
  translated,

  /// The page has no translatable text (shown as-is).
  noContent,

  /// Translation failed; the reader offers a retry.
  failed,
}

/// Result of the shared translation core [_translateToCache].
enum _TranslateOutcome {
  /// A rendered translated page was already in the cache.
  alreadyCached,

  /// A translated page was produced and written to the cache this call.
  translated,

  /// The page has no translatable text; an empty text-result was cached.
  noContent,
}

/// Machine-readable split of one translation group's wall time: the structured
/// twin of the `GroupPerf ...` log line, and the only sanctioned source for the
/// card's translation / rendering `ms/page` figures (plan 12-B).
///
/// Why this exists: recognition already had a structured measurement source
/// (`OcrBatchPerf`, built at the worker's own timing site and sent back with
/// the batch response), so its `ms/page` was honest. Translation and rendering
/// had *only* a log string, so both rows stayed blank -- and the fix is not to
/// regex numbers out of that string. Parsing display text is what produced
/// Phase 2's "detMs is actually the batch size" incident: a scraped field
/// survives a rewording, its meaning does not. So the producer constructs this
/// object from the same locals it already logs and hands it to its caller
/// **with the response** (`onGroupPerf` on [ImageTranslationService
/// .translatePageGroup]). The log line is now formatted *from* the object
/// instead of the object being scraped *out of* the line, so the two cannot
/// drift, and no display code reads text.
///
/// Additivity holds by construction: `resolveMs + ocrMs + llmMs + renderMs ==
/// totalMs` ([resolveMs] is the additive remainder), so the split can be shown
/// without double-counting. Each timing is a **phase's elapsed group time**,
/// not a sum of per-page costs: chunks and renders run concurrently inside a
/// phase, so [llmMs] is the wall time of the one shared request and [renderMs]
/// the wall time of the concurrent draw loop. Dividing by the pages that phase
/// actually carried ([llmPages], [renderPages]) is what "ms per page at this
/// phase" means here -- the same convention as `OcrBatchPerf.totalMs / pages`.
class GroupPerf {
  const GroupPerf({
    required this.pages,
    required this.ocrCachedPages,
    required this.ocrRunPages,
    required this.llmPages,
    required this.renderPages,
    required this.resolveMs,
    required this.ocrMs,
    required this.llmMs,
    required this.renderMs,
    required this.totalMs,
    required this.bytesIn,
    required this.bytesOut,
    this.llmRequests = 0,
    this.llmBlocks = 0,
    this.llmWindowStartMs = 0,
    this.llmWindowEndMs = 0,
  });

  /// Pages the group was handed (input size, cache-resolved ones included).
  final int pages;

  /// Pages whose OCR row came from the intermediate store, and pages the group
  /// had to recognize: stage 1's split, so a slow group can be told apart from
  /// a cold one.
  final int ocrCachedPages;
  final int ocrRunPages;

  /// Pages whose bubbles went into the shared LLM request. Zero when every page
  /// was cache-resolved or had nothing pending: there is then no per-page
  /// translation cost to quote, and [translationMsPerPage] is null rather than
  /// 0 (unreadable is N/A, never a fake measurement).
  final int llmPages;

  /// Pages the stage-3 draw loop visited (already-settled ones excluded).
  final int renderPages;

  /// Wall time of the stage-1 cache lookups: the additive remainder of the
  /// group total (`totalMs - ocrMs - llmMs - renderMs`).
  final int resolveMs;
  final int ocrMs;
  final int llmMs;
  final int renderMs;

  /// Whole-group wall time, from the stopwatch the log line already printed.
  final int totalMs;

  /// Encoded input / written output bytes (the log shows both in kB).
  final int bytesIn;
  final int bytesOut;

  /// How many `LlmTranslator.translateBatch` calls this group issued: 0 when no
  /// page had pending bubbles, otherwise 1 — the group path concatenates every
  /// page's bubbles into one request by construction. Retries *inside* that
  /// call are the translator's own business and are not visible here, which is
  /// exactly why the window below exists.
  final int llmRequests;

  /// Bubbles carried by that request — the payload's `lines` count. This is the
  /// number that says whether requests are already as merged as they can be.
  final int llmBlocks;

  /// Epoch-millisecond window of the shared request. Two groups' windows tell
  /// serial from concurrent *from the log alone*: non-overlapping windows mean
  /// the chapter's requests were serialized and [llmMs] is pure request time;
  /// overlapping windows mean groups were in flight together, so [llmMs]
  /// includes waiting for a concurrency slot.
  final int llmWindowStartMs;
  final int llmWindowEndMs;

  /// Monotonic count of `translateBatch` calls issued by this process, printed
  /// on every group line as `llm_reqs_total` so a chapter's request count is a
  /// log subtraction rather than a claim.
  static int llmRequestsIssued = 0;

  /// Mean milliseconds the shared request spent per page it carried, or null
  /// when it carried none. Plain arithmetic on already-held fields: the data
  /// fold calls it once, the widget tree computes nothing.
  double? get translationMsPerPage =>
      llmPages > 0 && llmMs > 0 ? llmMs / llmPages : null;

  /// Mean milliseconds one page took to draw, or null when nothing was drawn.
  double? get renderMsPerPage =>
      renderPages > 0 && renderMs > 0 ? renderMs / renderPages : null;

  /// Whole-group wall time per input page, or null for an empty group. This is
  /// the group's *end-to-end* cost (resolve + recognize + ask + draw), which is
  /// what the committed stream's warm-up rate divides by.
  double? get totalMsPerPage =>
      pages > 0 && totalMs > 0 ? totalMs / pages : null;

  /// The `GroupPerf ...` telemetry line, formatted from this object. Field
  /// names and order are exactly what they were before the object existed, so
  /// existing log greps keep working; the new denominators are appended.
  ///
  /// `llm_reqs` / `llm_blocks` / `llm_window` (F13.7) are the request-shape
  /// fields: they answer "was this group one request or many, how big was it,
  /// and did it overlap another group's" without a second measurement path.
  String toLogLine() =>
      'GroupPerf pages=$pages in_kb=${(bytesIn / 1024).round()} '
      'ocr_cached=$ocrCachedPages ocr_run=$ocrRunPages '
      'parts={resolveMs:$resolveMs,ocrMs:$ocrMs,llmMs:$llmMs,renderMs:$renderMs} '
      'llm_ms=$llmMs render_ms=$renderMs render_pages=$renderPages '
      'out_kb=${(bytesOut / 1024).round()} total_ms=$totalMs '
      'llm_pages=$llmPages llm_reqs=$llmRequests llm_blocks=$llmBlocks '
      'llm_window=$llmWindowStartMs..$llmWindowEndMs '
      'llm_reqs_total=$llmRequestsIssued';
}

/// One page's block ledger, from recognized blocks to drawn regions (F13.7).
///
/// The worker's `OcrFunnel` closes on *clusters*; this closes on *blocks*, and
/// the two gaps it names are the ones no existing line could name:
///
///  * `skippedAsTarget` — blocks whose detected language equals the target and
///    which `PageTranslationPipeline.classifyBlocks` therefore drops without a
///    word. A kanji-only Japanese line read by the non-Japanese recognizer
///    lands here
///    (see `_detectLanguage` in the worker), which is one of the two ways a
///    fully recognized line can end up untranslated on a page whose funnel
///    looks healthy.
///  * `modelDropped` — blocks the model answered with an empty string or with
///    the source text unchanged, dropped by
///    `PageTranslationPipeline.regionsFromTranslation`
///    (`text.isEmpty || text == pending[i].text`) — the other way.
///
/// `null` means "not measurable on this path" and prints `?`, never 0: the
/// reader's per-page path cannot see the pending split without re-running the
/// pipeline's own composition, so it reports only `votes` and `regions`.
///
/// [skippedAsTarget] is optional: when a caller has the pipeline's own drop
/// list it can pass the real count instead of the `votes - pending - ready`
/// recovery, and when it has neither the field prints `?`.
String blockFunnelLine({
  required String page,
  required int? votes,
  required int? pending,
  required int? ready,
  required int? llmIn,
  required int? llmOut,
  required int regions,
  required int? modelDropped,
  int? skippedAsTarget,
}) {
  String show(int? value) => value == null ? '?' : '$value';
  int? skipped = skippedAsTarget;
  if (skipped == null && votes != null && pending != null && ready != null) {
    skipped = math.max(0, votes - pending - ready);
  }
  return 'BlockFunnel page=$page votes=${show(votes)} '
      'pending=${show(pending)} ready=${show(ready)} '
      'skippedAsTarget=${show(skipped)} llm_in=${show(llmIn)} '
      'llm_out=${show(llmOut)} regions=$regions '
      'modelDropped=${show(modelDropped)}';
}

/// Whether [reason] is the model declining a block (rather than the language
/// filter never sending it). Shared by the reader path's `BlockFunnel` split
/// so the two counts stay complementary.
bool _isModelDrop(BlockDropReason reason) =>
    reason == BlockDropReason.modelEmpty ||
    reason == BlockDropReason.modelEchoed;

class _TranslationTask {
  _TranslationTask(
    this.cacheKey,
    this.cid,
    this.sourceKey,
    this.imageBytes,
    this.config,
    this.chapter,
  );

  final String cacheKey;

  final String cid;
  final String? sourceKey;

  /// Identifies the comic for the per-comic language lock and glossary.
  String get comicKey => '$cid@$sourceKey';

  final Uint8List imageBytes;

  /// The comic's own language pair + render mode, captured when queued so a
  /// settings change mid-queue can't translate the page with another comic's
  /// languages.
  final TranslationConfig config;
  final TranslationChapterIdentity chapter;
  final listeners = <VoidCallback>[];
}

/// Schedules page translations, caches results and notifies the reader when
/// a page is ready so it can swap the displayed image.
///
/// Two cache levels keep repeat reads free:
/// - the rendered page image (30 days, large, may be LRU-evicted), and
/// - the text-level result (regions + translations, ~KB, 90 days): when only
///   the image was evicted the page is re-rendered locally without paying
///   for OCR or another translation request.
/// The page-identifying tail of a cache key, for logs.
///
/// `…@https://i3.nhentai.net/galleries/2089266/31.jpg#s` becomes `31.jpg`: the
/// last path segment, with the render-mode suffix removed. Full keys are
/// unreadable in a line and the batch-local index is ambiguous, so the segment
/// is the one part that is both short and unique per page.
String ocrBatchPageLabel(String cacheKey) {
  var base = cacheKey.split('#').first;
  var slash = base.lastIndexOf('/');
  var label = slash >= 0 ? base.substring(slash + 1) : base;
  return label.isEmpty ? base : label;
}

class ImageTranslationService with ChangeNotifier {
  ImageTranslationService._();

  static final instance = ImageTranslationService._();

  static const _imageCacheDuration = 30 * 24 * 60 * 60 * 1000;
  static const _maxQueueLength = 16;
  static const _failureRetryDelay = Duration(minutes: 5);
  /// How long the pipeline stays parked before handing model memory back.
  /// The retrospective writes about a 10-second idle eviction; the code has
  /// always used 90s. It is a setting now so the number can be checked rather
  /// than repeated (plan D-1). `0` disables the timer.
  static Duration get _idleReleaseDelay {
    final seconds = appdata.settings['imageTranslationIdleEvictionSeconds'];
    if (seconds is int && seconds >= 0) return Duration(seconds: seconds);
    return const Duration(seconds: 90);
  }

  final _queue = <_TranslationTask>[];
  final _active = <_TranslationTask>{};

  /// The done/failed markers describe a *rendered* image, so they key on the
  /// rendered key (page key + render-mode token) rather than the raw page key.
  /// Two comics reading with different text-removal modes therefore keep
  /// independent markers, and a mode change addresses different entries instead
  /// of needing the whole set cleared.
  final _failures = <String, DateTime>{};
  final _completed = <String>{};

  /// Last error message per failed page, for the reader's retry affordance.
  final _errors = <String, String>{};

  /// Pages known (via the text cache) to contain nothing translatable. Mode
  /// independent, so this one keys on the raw page key.
  final _noContent = <String>{};
  PageTranslationPipeline? _pipeline;
  Timer? _releaseTimer;

  /// Whether a translated page is known to exist for [cacheKey] under [mode].
  /// Feeds the provider identity so a finished background translation produces
  /// a new provider and the visible image swaps in place.
  bool isTranslated(String cacheKey, InpaintMode mode) {
    return _completed.contains(renderedKey(cacheKey, mode));
  }

  void markTranslated(String cacheKey, InpaintMode mode) =>
      _completed.add(renderedKey(cacheKey, mode));

  /// Current per-page translation state, for the reader status badge.
  PageTranslationStatus statusOf(String cacheKey, InpaintMode mode) {
    var renderKey = renderedKey(cacheKey, mode);
    if (_completed.contains(renderKey)) return PageTranslationStatus.translated;
    if (_noContent.contains(cacheKey)) return PageTranslationStatus.noContent;
    if (_active.any((t) => t.cacheKey == cacheKey)) {
      return PageTranslationStatus.translating;
    }
    if (_failures.containsKey(renderKey)) return PageTranslationStatus.failed;
    if (_queue.any((t) => t.cacheKey == cacheKey)) {
      return PageTranslationStatus.translating;
    }
    return PageTranslationStatus.idle;
  }

  /// Last failure message for [cacheKey], if the page failed to translate.
  String? errorOf(String cacheKey, InpaintMode mode) =>
      _errors[renderedKey(cacheKey, mode)];

  /// Clears the failure back-off for [cacheKey] so the reader can retry it
  /// immediately instead of waiting out [_failureRetryDelay].
  void clearFailure(String cacheKey, InpaintMode mode) {
    var renderKey = renderedKey(cacheKey, mode);
    _failures.remove(renderKey);
    _errors.remove(renderKey);
  }

  /// Trims an exception to a short, single-line message for display.
  static String _briefError(Object e) {
    var text = e.toString().replaceAll('\n', ' ').trim();
    const prefix = 'Exception: ';
    if (text.startsWith(prefix)) {
      text = text.substring(prefix.length);
    }
    return text.length > 160 ? '${text.substring(0, 160)}…' : text;
  }

  /// Rendered-image cache key: the page's durable text [cacheKey] plus the
  /// render-mode token. The rendered image depends on the mode, the stored text
  /// does not — so switching modes serves a different image re-derived from the
  /// same stored text, and switching back reuses the earlier render. The token
  /// is a suffix, so the comic/chapter scope prefixes still match it for
  /// deletion.
  static String renderedKey(String cacheKey, InpaintMode mode) =>
      '$cacheKey#${mode.token}';

  /// LLM translation is network-bound, so a second page's OCR can run in the
  /// worker while the first waits for its response.
  int get _maxConcurrent => 2;

  /// Whether detection/OCR models AND the user's LLM endpoint are usable for
  /// [sourceLang]. The source language is per-comic, so readiness is too: a
  /// comic set to Korean needs the Korean model even if another comic reads fine
  /// with Japanese.
  static bool isReadyForLang(String sourceLang) {
    if (!TranslationModels.isReadyFor(sourceLang)) {
      return false;
    }
    return LlmTranslator.isConfigured;
  }

  /// Whether translation can run for one comic, using that comic's own source
  /// language.
  static bool isReadyForComic(String cid, String? sourceKey) {
    return isReadyForLang(TranslationConfig.of(cid, sourceKey).sourceLang);
  }

  /// The implicitData keys holding per-comic translation preferences: the
  /// per-comic enable switch, the learned language locks, the glossary and the
  /// blocked terms. These are serialized into the backup explicitly (they live
  /// in implicitData, which is not part of appdata.json) and merged back on
  /// import — see the export/import paths in utils/data.dart.
  static const syncedPrefKeys = [
    _enabledComicsKey,
    _comicLangsKey,
    _comicGlossaryKey,
    _blockedTermsKey,
  ];

  /// Drops the lazy in-memory caches of the per-comic preference maps so the
  /// next access re-reads implicitData. Called after an import replaces those
  /// maps underneath us — without it the service would keep serving the
  /// pre-import glossary / language locks / blocked terms.
  void reloadSyncedPrefs() {
    _comicLangs = null;
    _glossaries = null;
    _blockedTerms = null;
    notifyListeners();
  }

  /// Comics the user explicitly turned translation on for. This is a dedicated
  /// per-comic store — NOT the reader-settings channel, which falls back to a
  /// single global value when a comic has no per-comic override. Translation
  /// spends tokens, so it must never be globally "on": enabling it for one
  /// comic must not translate every other comic the user opens.
  static const _enabledComicsKey = 'imageTranslationEnabledComics';

  /// Whether the user turned translation on for this specific comic.
  static bool isEnabledForComic(String cid, String sourceKey) {
    var stored = appdata.implicitData[_enabledComicsKey];
    if (stored is! Map) return false;
    return stored['$cid@$sourceKey'] == true;
  }

  /// Stable keys for comics whose per-comic translation switch is on.
  /// The list is intentionally exposed without titles: titles and covers are
  /// not part of the preference store and are resolved by the UI when known.
  static Set<String> get enabledComicKeys {
    var stored = appdata.implicitData[_enabledComicsKey];
    if (stored is! Map) return const {};
    return stored.entries
        .where((entry) => entry.value == true)
        .map((entry) => entry.key.toString())
        .toSet();
  }

  /// Turns translation on/off for one comic only.
  static void setEnabledForComic(String cid, String sourceKey, bool enabled) {
    var stored = appdata.implicitData[_enabledComicsKey];
    var map = stored is Map
        ? Map<String, dynamic>.from(stored)
        : <String, dynamic>{};
    var comicKey = '$cid@$sourceKey';
    if (enabled) {
      map[comicKey] = true;
    } else {
      map.remove(comicKey);
    }
    appdata.implicitData[_enabledComicsKey] = map;
    appdata.writeImplicitData();
    instance.notifyListeners();
  }

  /// Whether translation should run for a comic right now (per-comic switch +
  /// usable engine for that comic's language).
  static bool enabledFor(String cid, String sourceKey) {
    return isEnabledForComic(cid, sourceKey) && isReadyForComic(cid, sourceKey);
  }

  /// Prefix covering every cached page of one comic, for that comic's own
  /// language pair. The comic/chapter identity comes BEFORE the per-image part
  /// so a whole comic — or a single chapter — can be invalidated with one prefix
  /// delete (see [CacheManager.deleteByPrefix]).
  static String comicScopePrefix(String? sourceKey, String cid) {
    var prefix = TranslationConfig.of(cid, sourceKey).cachePrefix;
    return '$prefix$sourceKey@$cid@';
  }

  /// Prefix covering every cached page of one chapter.
  static String chapterScopePrefix(String? sourceKey, String cid, String eid) {
    return '${comicScopePrefix(sourceKey, cid)}$eid@';
  }

  static TranslationChapterIdentity chapterIdentity({
    required String cid,
    required String? sourceKey,
    required String eid,
    required TranslationConfig config,
    String comicTitle = '',
    String comicCover = '',
    String chapterTitle = '',
  }) {
    return TranslationChapterIdentity(
      scopePrefix: chapterScopePrefix(sourceKey, cid, eid),
      sourceKey: sourceKey ?? SourcePlatformResolver.localCanonicalKey,
      comicId: cid,
      chapterId: eid,
      sourceLang: config.sourceLang,
      targetLang: config.targetLang,
      comicTitle: comicTitle,
      comicCover: comicCover,
      chapterTitle: chapterTitle,
    );
  }

  /// Cache key of the translated variant of one page. It embeds the comic's
  /// language pair so changing that comic's languages re-translates instead of
  /// serving pages in the old language. Scope (source/comic/chapter) comes
  /// first, image key last, so a comic or chapter forms a deletable key prefix.
  static String cacheKeyFor(
    String imageKey,
    String? sourceKey,
    String cid,
    String eid,
  ) {
    return '${chapterScopePrefix(sourceKey, cid, eid)}$imageKey';
  }

  /// Fingerprint of the OCR pipeline and model set currently in effect.
  ///
  /// Every reader and writer of `translated_ocr_page` goes through here so a
  /// tier switch, a swapped model file or a CPU↔GPU change cannot keep serving
  /// stale recognition results (plan D-2). [effectiveLang] must be the
  /// *resolved* language — passing `auto` through would defeat the purpose.
  static String ocrFingerprintFor(String effectiveLang) {
    return ocrFingerprintOf(
      OcrInputs(
        schemaGen: kOcrSchemaGeneration,
        effectiveLang: effectiveLang,
        tier: TranslationModels.currentModelTier,
        epKind: TranslationWorker.instance.lastReport?.active ??
            OrtEpKind.cpu,
        componentStamps: componentStampsFor(TranslationModels.workerPaths()),
      ),
    );
  }

  /// Removes the rendered-image cache AND the durable stored text for every
  /// page under [scopePrefix], so the next view/pre-translate re-runs from
  /// scratch. Also clears the in-memory "done/empty/failed" markers for those
  /// keys. The store keys on the same prefix, so one call drops both levels.
  Future<int> invalidateScope(String scopePrefix) async {
    var removed = await CacheManager().deleteByPrefix(scopePrefix);
    TranslationStore().deleteByPrefix(scopePrefix);
    _completed.removeWhere((k) => k.startsWith(scopePrefix));
    _noContent.removeWhere((k) => k.startsWith(scopePrefix));
    _failures.removeWhere((k, _) => k.startsWith(scopePrefix));
    return removed;
  }

  /// Re-translates a whole comic: drops every stored page + rendered image for
  /// the current language pair AND the comic's learned glossary, so the next
  /// read / pre-translate starts clean. [eid] limits it to one chapter, in
  /// which case the glossary is kept (other chapters still rely on it).
  Future<void> retranslate(String cid, String sourceKey, {String? eid}) async {
    if (eid != null) {
      await invalidateScope(chapterScopePrefix(sourceKey, cid, eid));
    } else {
      await invalidateScope(comicScopePrefix(sourceKey, cid));
      _clearGlossary('$cid@$sourceKey');
    }
    // "重新翻译" means *ask again*, so the session's translation memory must not
    // hand back the wording this action exists to replace. The durable store and
    // the caches above are per page; the memory is per string, so it is dropped
    // wholesale — it repopulates from the next batch.
    LlmTranslator.forgetAllTranslations();
    notifyListeners();
  }

  /// Clears every translated page across all comics: the rendered-image cache
  /// and the durable stored text both go. The learned per-comic language locks
  /// and glossaries are left intact. Returns the rendered-image count removed.
  Future<int> clearAllTranslationCache() async {
    var removed = await CacheManager().deleteByPrefix('pageTranslation@');
    TranslationStore().clearAll();
    _completed.clear();
    _noContent.clear();
    _failures.clear();
    notifyListeners();
    return removed;
  }

  Future<File?> findTranslated(String cacheKey, InpaintMode mode) {
    return CacheManager().findCache(renderedKey(cacheKey, mode));
  }

  /// Whether a fully rendered translated page (not just the text result) is
  /// already cached. Used by the pre-translation task manager to skip pages
  /// that were done in an earlier run or read online.
  Future<bool> hasRenderedPage(String cacheKey, InpaintMode mode) async {
    return await CacheManager().findCache(renderedKey(cacheKey, mode)) != null;
  }

  /// How many pages of one chapter already have a stored text result — the
  /// durable, WebDAV-synced source of truth (empty-result "no text" pages count
  /// too). This is what lets a device show a chapter as already translated after
  /// receiving another device's translations, without needing that device's
  /// (non-synced) task records. Language-pair scoped, same as every cache key.
  static int storedPageCount(
    String cid,
    String sourceKey,
    String eid, {
    String comicTitle = '',
    String comicCover = '',
    String chapterTitle = '',
  }) {
    var config = TranslationConfig.of(cid, sourceKey);
    return TranslationStore().recordExistingChapter(
      chapterIdentity(
        cid: cid,
        sourceKey: sourceKey,
        eid: eid,
        config: config,
        comicTitle: comicTitle,
        comicCover: comicCover,
        chapterTitle: chapterTitle,
      ),
    );
  }

  /// Indexed translated comics whose language pair still matches the comic's
  /// current reader settings. Older language generations remain stored, but
  /// are not presented as directly usable results for the current config.
  static List<StoredTranslationComic> get translatedComics {
    return TranslationStore().comics.where((comic) {
      var config = TranslationConfig.of(comic.comicId, comic.sourceKey);
      return comic.sourceLang == config.sourceLang &&
          comic.targetLang == config.targetLang;
    }).toList();
  }

  /// Renders a page purely from an already-stored text result — no OCR, no LLM,
  /// no models. This is what lets a device that received another device's
  /// translations over WebDAV show them even without any translation models
  /// installed: the durable [TranslationStore] rows synced across, and the
  /// renderer only needs the page bytes + regions + the app font.
  ///
  /// Returns the rendered PNG bytes when a stored result produced a visible
  /// page (and caches it), or null when there is no stored result for this page
  /// or the stored result is empty (the page has no translatable text) — in
  /// both null cases the caller should show the original image. Never triggers
  /// a translation; a page missing from the store stays untranslated here.
  Future<Uint8List?> renderStoredPage(
    String cacheKey,
    Uint8List imageBytes,
    InpaintMode mode, {
    required TranslationChapterIdentity chapter,
  }) async {
    TranslationStore().recordExistingChapter(chapter);
    var renderKey = renderedKey(cacheKey, mode);
    var cached = await CacheManager().findCache(renderKey);
    if (cached != null) {
      // Defect A, branch 3 of the erasure ledger: this page never reached
      // `renderPage`, so the pipeline printed no ledger line at all — and on a
      // re-read of an already-translated chapter that is *every* page. Without
      // this line the most common page in the app is the one whose ledger is
      // missing, and "no ledger" again reads as "the eraser misfired". It did
      // not run: the pixels were served from cache, and `reason=cache-hit`
      // says so in the same shape the pipeline's three branches use. The
      // literal is kept in step with
      // `PageTranslationPipeline.kLedgerReasonCacheHit` by a test rather than
      // imported, because that member is `@visibleForTesting`.
      Log.info(
        'Inpaint',
        'erasure ledger: mode=${mode.name} reason=cache-hit erased=0',
      );
      _completed.add(renderKey);
      return await cached.readAsBytes();
    }
    var regions = TranslationStore().get(cacheKey);
    if (regions == null) {
      // Never translated on any device that synced here; show the original.
      return null;
    }
    if (regions.isEmpty) {
      // Stored "no translatable text" result; nothing to render.
      _noContent.add(cacheKey);
      return null;
    }
    var pipeline = _pipeline ??= PageTranslationPipeline();
    var rendered = await pipeline.renderPage(imageBytes, regions, mode: mode);
    await CacheManager().writeCache(renderKey, rendered, _imageCacheDuration);
    _completed.add(renderKey);
    return rendered;
  }

  /// Translates one page synchronously (awaitable), writing both cache levels,
  /// and returns whether a translated page was produced. Unlike [schedule]
  /// this does not go through the reader's bounded/LRU queue — the
  /// pre-translation task manager drives its own pacing and needs to await
  /// each page. Reuses the shared pipeline and language lock.
  ///
  /// Returns true when a translated page image is now cached (or already was),
  /// false when the page has no translatable text.
  Future<bool> translateOne(
    String cacheKey,
    String comicKey,
    Uint8List imageBytes,
    TranslationConfig config, {
    required TranslationChapterIdentity chapter,
    bool Function()? shouldCancel,
  }) async {
    var outcome = await _translateToCache(
      cacheKey,
      comicKey,
      imageBytes,
      config,
      chapter: chapter,
      shouldCancel: shouldCancel,
    );
    if (outcome == _TranslateOutcome.noContent) {
      return false;
    }
    _completed.add(renderedKey(cacheKey, config.mode));
    return true;
  }

  /// The shared OCR-intermediate cache read. Both consumer paths — the
  /// reader's [_translateToCache] and the batch [translatePageGroup] — go
  /// through here so the fingerprint they query with is always the one
  /// produced by [ocrFingerprintFor], exactly as the pre-translation sweep
  /// (`_runChapterOcrPass`) writes it. Readers computing the key
  /// "individually" is the drift plan §5.3 warns about (D-8).
  ///
  /// A miss — no row, a row under another fingerprint, a row that records an
  /// error, or a failed read — returns `fromCache: false` and null, and the
  /// caller runs OCR. Matching is never relaxed to force a hit: a fingerprint
  /// mismatch means the row was produced by different model inputs and must
  /// be re-recognised (D-2, red line R2-adjacent — [ocrFingerprintFor]'s
  /// semantics are not negotiable here).
  ({PageOcr? ocr, bool fromCache}) _ocrFromCache(
    String cacheKey,
    String fingerprint,
  ) {
    try {
      var ocr = TranslationStore().getOcr(cacheKey, fingerprint: fingerprint);
      if (ocr != null && !ocr.hasError) {
        return (ocr: ocr, fromCache: true);
      }
    } catch (e, s) {
      Log.warning('Image Translation', 'OCR cache read failed: $e\n$s');
    }
    return (ocr: null, fromCache: false);
  }

  /// The shared translation core used by both the awaitable [translateOne]
  /// (pre-translation manager) and the queued [_process] (reader). It performs
  /// the cache probe, OCR/translation analysis (with the text-level cache),
  /// language lock + glossary updates and the final render, writing both cache
  /// levels. Callers layer their own bookkeeping (queue management, listener
  /// notification, failure tracking) on top of the returned outcome.
  Future<_TranslateOutcome> _translateToCache(
    String cacheKey,
    String comicKey,
    Uint8List imageBytes,
    TranslationConfig config, {
    required TranslationChapterIdentity chapter,
    bool Function()? shouldCancel,
  }) async {
    TranslationStore().recordExistingChapter(chapter);
    var renderKey = renderedKey(cacheKey, config.mode);
    if (await CacheManager().findCache(renderKey) != null) {
      return _TranslateOutcome.alreadyCached;
    }
    var pipeline = _pipeline ??= PageTranslationPipeline();
    // The store is the durable source of truth: a hit (local, or merged from
    // another device via WebDAV) skips OCR and the paid LLM request entirely.
    var regions = TranslationStore().get(cacheKey);
    if (regions == null) {
      var effectiveSourceLang = _effectiveSourceFor(comicKey, config);
      // D-8: the reader shares the OCR intermediate with the pre-translation
      // sweep. A chapter whose sweep was cancelled or failed part-way used to
      // burn the GPU again here for pages already recognized; now the stored
      // PageOcr is handed to [analyzePage] and only the LLM is paid. The
      // fingerprint is computed the same way both writers compute it — from
      // the *resolved* source language, the value `effectiveSourceFor`
      // returns (never the raw `auto` of an unlocked comic's config), so the
      // reader queries exactly the key the sweep wrote (plan §5.3).
      var cached = _ocrFromCache(
        cacheKey,
        ocrFingerprintFor(effectiveSourceLang),
      );
      // Observability (plan V8-6): `ocr=cache` without a following
      // `det={…}` worker line is the evidence the page was not re-recognized.
      Log.info(
        'Image Translation',
        'Page analysis ocr=${cached.fromCache ? 'cache' : 'run'} '
        'lang=$effectiveSourceLang $cacheKey',
      );
      var analysis = await pipeline.analyzePage(
        imageBytes,
        sourceLang: effectiveSourceLang,
        targetLang: config.targetLang,
        glossary: _glossaryFor(comicKey),
        existingOcr: cached.ocr,
        page: cacheKey,
      );
      _updateLanguageLock(comicKey, analysis.languageVotes, config);
      _mergeGlossary(comicKey, analysis.newGlossary);
      regions = analysis.regions;
      // F13.7: the reader path can see the language votes, the regions and —
      // since the pipeline reports them — the blocks it dropped. The pending
      // split still lives inside `analyzePage`, so those two fields stay `?`
      // rather than a fake 0; `skippedAsTarget` and `modelDropped` are now
      // real counts of the two silent drops (an OCR row restored from the
      // durable cache reports neither, because it was not dropped on this
      // run). `votes - regions` remains the count of recognized blocks that
      // produced no drawn region.
      var votesTotal = analysis.languageVotes.values.fold<int>(
        0,
        (a, b) => a + b,
      );
      Log.info(
        'Image Translation',
        blockFunnelLine(
          page: cacheKey,
          votes: votesTotal,
          pending: null,
          ready: null,
          llmIn: null,
          llmOut: null,
          regions: regions.length,
          modelDropped: cached.fromCache
              ? null
              : analysis.dropped
                    .where((d) => _isModelDrop(d.reason))
                    .length,
          skippedAsTarget: cached.fromCache
              ? null
              : analysis.dropped
                    .where((d) => !_isModelDrop(d.reason))
                    .length,
        ),
      );
      TranslationStore().put(cacheKey, regions, chapter: chapter);
      // The durable text now exists (even if empty), so the OCR intermediate
      // is spent — drop it, matching translatePageGroup's stage-3 lifecycle,
      // including a stale-fingerprint row this page had to re-recognize past.
      TranslationStore().deleteOcr(cacheKey);
    }
    if (shouldCancel?.call() ?? false) {
      throw const PipelineCanceled();
    }
    if (regions.isEmpty) {
      // Nothing translatable; the cached empty result keeps this page from
      // being re-analyzed, even across restarts.
      _noContent.add(cacheKey);
      return _TranslateOutcome.noContent;
    }
    var rendered = await pipeline.renderPage(
      imageBytes,
      regions,
      mode: config.mode,
    );
    await CacheManager().writeCache(renderKey, rendered, _imageCacheDuration);
    return _TranslateOutcome.translated;
  }

  /// Translates a group of pages with ONE shared LLM request — used only by
  /// the background pre-translation manager (the reader keeps its per-page
  /// queue in [schedule]/[_process]). Pages already rendered, served from the
  /// text cache, or found to hold no translatable text need no request; the
  /// rest have their recognized bubbles concatenated into a single
  /// [LlmTranslator.translateBatch] call, so the model sees cross-page context
  /// and the comic spends one request per group instead of one per page.
  ///
  /// OCR, rendering and both cache levels stay per-page (only the translation
  /// request is grouped), so a partially finished group resumes cleanly. If the
  /// shared request fails, every page that needed it is reported failed for
  /// this run (to retry later) while pages resolved from cache still succeed.
  ///
  /// Returns a success flag per input page, aligned with [pages]; it only
  /// throws [PipelineCanceled] when [shouldCancel] fires between pages.
  ///
  /// [onGroupPerf] receives the group's [GroupPerf] -- the structured split of
  /// its wall time -- once every phase has settled, i.e. with the response and
  /// before this future completes. It is the display channel for the
  /// translation / rendering rates the progress card shows (plan 12-B): the
  /// caller never has to read the `GroupPerf` log line to get a number. Not
  /// called when the group was cancelled or threw, because there is then no
  /// complete measurement to hand back.
  Future<List<bool>> translatePageGroup(
    List<({String cacheKey, Uint8List imageBytes})> pages,
    String comicKey,
    TranslationConfig config, {
    required TranslationChapterIdentity chapter,
    bool Function()? shouldCancel,
    void Function(TranslationStage stage, double completedPages)? onStage,
    void Function(GroupPerf perf)? onGroupPerf,
  }) async {
    var success = List.filled(pages.length, false);
    if (pages.isEmpty) return success;
    // Stage-2 split timing (per group), measured by the four stopwatches below
    // and published as a [GroupPerf] value object plus its log line. The OCR
    // worker's perf log already splits a batch internally
    // (`parts={detMs,recGpuMs,decMsInRec,restMs}`), but a group's wall time was
    // not separable into "waiting on the LLM endpoint" vs "drawing the page" --
    // the two halves of stage 2 are billed to completely different resources
    // (network vs CPU raster) and only a split number says which one to attack.
    // The split is additive by construction: resolveMs + ocrMs + llmMs +
    // renderMs == totalMs, with resolveMs being the cache-lookup slack.
    final groupSw = Stopwatch()..start();
    final ocrRunSw = Stopwatch();
    final llmSw = Stopwatch();
    final renderSw = Stopwatch();
    var bytesIn = 0;
    for (var p in pages) {
      bytesIn += p.imageBytes.length;
    }
    var bytesOut = 0;
    TranslationStore().recordExistingChapter(chapter);
    var pipeline = _pipeline ??= PageTranslationPipeline();
    var sourceLang = _effectiveSourceFor(comicKey, config);

    // Final regions per page once known; null = a fresh-OCR page still awaiting
    // the LLM (composed in stage 2) or a page that failed and is skipped.
    var regionsOf = List<List<TranslatedRegion>?>.filled(pages.length, null);
    // Freshly OCR'd pages awaiting translation; null = resolved from cache,
    // already rendered, or failed during OCR.
    var pendingOcr = List<PageOcr?>.filled(pages.length, null);
    // Text cache is (re)written only for freshly OCR'd pages, matching
    // [_translateToCache]; cache-sourced regions are never rewritten.
    var freshOcr = List<bool>.filled(pages.length, false);
    // Pages needing no further work (rendered-cache hit or OCR failure).
    var settled = List<bool>.filled(pages.length, false);

    // How much of this group is done, in page units, weighted by the phase each
    // page has reached. Derived from the state above rather than counted up
    // separately so it cannot drift out of step with it. The caller's progress
    // bar needs this because a group's real counters commit all at once — with
    // 4-8 pages a group that is minutes from committing would otherwise read as
    // no progress at all.
    double completedPages() {
      var total = 0.0;
      for (var i = 0; i < pages.length; i++) {
        if (settled[i] || success[i]) {
          total += 1;
        } else if (regionsOf[i] != null) {
          total += 0.8; // translated, waiting to be drawn
        } else if (pendingOcr[i] != null) {
          total += 0.55; // recognized, waiting on the request
        } else {
          total += fetchedPageWeight; // downloaded, not recognized yet
        }
      }
      return total;
    }

    final perf = TranslationPerformanceConfig.effective;

    // Stage 1 — resolve each page as far as possible without the LLM.
    // Computed once per group: it stats the selected model files, and every
    // reader of the OCR cache must agree on the same value (plan §5.3).
    final ocrFp = ocrFingerprintFor(sourceLang);
    var ocrNeededIndices = <int>[];
    var reusedOcr = 0;
    for (var i = 0; i < pages.length; i++) {
      if (shouldCancel?.call() ?? false) throw const PipelineCanceled();
      var p = pages[i];
      try {
        var renderKey = renderedKey(p.cacheKey, config.mode);
        if (await CacheManager().findCache(renderKey) != null) {
          _completed.add(renderKey);
          success[i] = true;
          settled[i] = true;
          continue;
        }
        var stored = TranslationStore().get(p.cacheKey);
        if (stored != null) {
          regionsOf[i] = stored;
          continue;
        }
        var cached = _ocrFromCache(p.cacheKey, ocrFp);
        if (cached.ocr != null) {
          pendingOcr[i] = cached.ocr;
          freshOcr[i] = true;
          reusedOcr++;
          continue;
        }
        ocrNeededIndices.add(i);
      } catch (e, s) {
        Log.warning('Image Translation', 'Batch OCR failed: $e\n$s');
        settled[i] = true; // failed; success[i] stays false
      }
    }
    if (reusedOcr > 0 || ocrNeededIndices.isNotEmpty) {
      // The same ocr=cache / ocr=run field as the reader path, aggregated
      // per group so batch logs stay quiet (plan V8-6).
      Log.info(
        'Image Translation',
        'Group OCR resolve: ocr=cache x$reusedOcr '
        'ocr=run x${ocrNeededIndices.length} '
        '(fingerprint ${ocrFp.substring(0, 8)})',
      );
    }

    if (ocrNeededIndices.isNotEmpty) {
      ocrRunSw.start();
      final chunkSize = math.max<int>(1, perf.pagesPerOcrCall);
      final chunks = <List<int>>[];
      for (var i = 0; i < ocrNeededIndices.length; i += chunkSize) {
        chunks.add(ocrNeededIndices.sublist(
          i,
          math.min<int>(i + chunkSize, ocrNeededIndices.length),
        ));
      }

      final workerLimit = perf.ocrWorkers > 0 ? perf.ocrWorkers : 1;
      final ocrGate = ConcurrencyGate(
        (_) => math.max<int>(1, math.min<int>(workerLimit, chunks.length)),
      );

      await Future.wait(chunks.map((chunkIndices) async {
        await ocrGate.acquire('ocr');
        try {
          if (shouldCancel?.call() ?? false) throw const PipelineCanceled();
          onStage?.call(
            pipeline.ocrIsWarm
                ? TranslationStage.recognizing
                : TranslationStage.loadingModel,
            completedPages(),
          );
          final chunkBytes =
              chunkIndices.map((idx) => pages[idx].imageBytes).toList();
          // Name the pages this call covers.
          //
          // The worker's per-page lines (`OcrFunnel page=3 …`, and the detect
          // and reject ledger that goes with them) index pages *within the
          // batch*, so `page=3` means a different page in every group of a
          // thirty-seven page chapter. A user reporting a specific page and a
          // developer reading logs.txt therefore had no way to meet: the page
          // number in the report is the chapter's, and the one in the log is
          // the batch's. One line per call costs nothing and makes every later
          // line joinable.
          Log.info(
            'Image Translation',
            'OCR batch pages=${chunkIndices.map((i) => ocrBatchPageLabel(pages[i].cacheKey)).join(',')}',
          );
          final results = await pipeline.ocrPages(
            chunkBytes,
            sourceLang: sourceLang,
            targetLang: config.targetLang,
          );
          for (var c = 0; c < chunkIndices.length; c++) {
            final idx = chunkIndices[c];
            if (c < results.length && !results[c].hasError) {
              pendingOcr[idx] = results[c];
              freshOcr[idx] = true;
            } else {
              settled[idx] = true;
            }
          }
        } catch (e, s) {
          if (e is PipelineCanceled) rethrow;
          Log.warning('Image Translation', 'Batch OCR chunk failed: $e\n$s');
          for (var idx in chunkIndices) {
            settled[idx] = true;
          }
        } finally {
          ocrGate.release('ocr');
        }
      }));
      ocrRunSw.stop();
    }

    // Stage 2 — one request for the whole group's pending bubbles. Language
    // votes and glossary updates fold across the group, then results are
    // sliced back to each page.
    var votes = <String, int>{};
    for (var po in pendingOcr) {
      po?.languageVotes.forEach((k, v) => votes[k] = (votes[k] ?? 0) + v);
    }
    _updateLanguageLock(comicKey, votes, config);

    var texts = <String>[];
    var sliceAt = List<int>.filled(pages.length, 0);
    // Pages whose bubbles actually go into the shared request -- the
    // denominator of the translation phase's ms/page. Counted here, at the
    // same site that builds `texts`, so the divisor and the measured
    // `llmMs` can never describe different page sets.
    var llmPages = 0;
    for (var i = 0; i < pages.length; i++) {
      var po = pendingOcr[i];
      if (po == null) continue;
      sliceAt[i] = texts.length;
      if (po.pending.isNotEmpty) llmPages++;
      texts.addAll(po.pending.map((b) => b.text));
    }

    var batchOk = true;
    var translated = const <String>[];
    // F13.7 request-shape observability: the group path's LLM stage is exactly
    // one request (or none), and this records that as a number plus the epoch
    // window that lets the log prove whether another group's request was in
    // flight at the same time.
    var llmRequests = 0;
    var llmBlocks = 0;
    var llmWindowStartMs = 0;
    var llmWindowEndMs = 0;
    if (texts.isNotEmpty) {
      if (shouldCancel?.call() ?? false) throw const PipelineCanceled();
      onStage?.call(TranslationStage.translating, completedPages());
      llmRequests = 1;
      llmBlocks = texts.length;
      GroupPerf.llmRequestsIssued++;
      llmWindowStartMs = DateTime.now().millisecondsSinceEpoch;
      llmSw.start();
      try {
        var result = await LlmTranslator.translateBatch(
          texts,
          config.targetLang,
          glossary: _glossaryFor(comicKey),
        );
        _mergeGlossary(comicKey, result.glossary);
        translated = result.texts;
      } catch (e, s) {
        Log.warning('Image Translation', 'Batch translate failed: $e\n$s');
        batchOk = false;
      }
      llmSw.stop();
      llmWindowEndMs = DateTime.now().millisecondsSinceEpoch;
    }

    for (var i = 0; i < pages.length; i++) {
      var po = pendingOcr[i];
      if (po == null) continue;
      if (!batchOk && po.pending.isNotEmpty) {
        settled[i] = true; // request failed; retry this page on a later run
        continue;
      }
      var slice = po.pending.isEmpty || !batchOk
          ? const <String>[]
          : translated.sublist(
              sliceAt[i].clamp(0, translated.length),
              (sliceAt[i] + po.pending.length).clamp(0, translated.length),
            );
      var folded = pipeline.regionsFromTranslation(
        po.pending,
        slice,
        page: '$i',
      );
      var regions = [...po.ready, ...folded.regions];
      regionsOf[i] = regions;
      // F13.7: name the two silent drops of the pipeline stage from the data
      // the pipeline itself returned. `modelDropped` counts only the model's
      // own declines (`regionsFromTranslation`'s `text.isEmpty || text ==
      // pending[i].text`) — the same predicate the reader path uses, so the
      // two paths cannot disagree; the language-filter drops ride in
      // `po.dropped` and are counted as `skippedAsTarget`. Nothing here is
      // used for control flow.
      if (po.pending.isNotEmpty || po.ready.isNotEmpty) {
        var llmOut = folded.regions.length;
        var modelDropped = folded.dropped.where(
          (d) => _isModelDrop(d.reason),
        ).length;
        var skippedAsTarget = folded.dropped.length - modelDropped;
        var votesTotal = po.languageVotes.values.fold<int>(0, (a, b) => a + b);
        Log.info(
          'Image Translation',
          blockFunnelLine(
            page: '$i',
            votes: votesTotal,
            pending: po.pending.length,
            ready: po.ready.length,
            llmIn: po.pending.length,
            llmOut: llmOut,
            regions: regions.length,
            modelDropped: modelDropped,
            skippedAsTarget: skippedAsTarget,
          ),
        );
      }
    }

    // Stage 3 — render + cache each resolved page with bounded concurrency.
    renderSw.start();
    final renderGate =
        ConcurrencyGate((_) => math.max(1, perf.imageConcurrency));
    final renderFutures = <Future<void>>[];

    for (var i = 0; i < pages.length; i++) {
      if (settled[i]) continue;
      var regions = regionsOf[i];
      if (regions == null) continue;
      var p = pages[i];

      renderFutures.add(() async {
        await renderGate.acquire('render');
        try {
          if (shouldCancel?.call() ?? false) throw const PipelineCanceled();
          onStage?.call(TranslationStage.rendering, completedPages());
          if (freshOcr[i]) {
            TranslationStore().put(p.cacheKey, regions, chapter: chapter);
            TranslationStore().deleteOcr(p.cacheKey);
          }
          if (regions.isEmpty) {
            _noContent.add(p.cacheKey);
            TranslationStore().deleteOcr(p.cacheKey);
            success[i] = true; // no translatable text still counts as handled
            return;
          }
          var rendered = await pipeline.renderPage(
            p.imageBytes,
            regions,
            mode: config.mode,
          );
          var renderKey = renderedKey(p.cacheKey, config.mode);
          await CacheManager().writeCache(
            renderKey,
            rendered,
            _imageCacheDuration,
          );
          bytesOut += rendered.length;
          _completed.add(renderKey);
          success[i] = true;
        } catch (e, s) {
          if (e is PipelineCanceled) rethrow;
          Log.warning('Image Translation', 'Batch render failed: $e\n$s');
          settled[i] = true;
        } finally {
          renderGate.release('render');
        }
      }());
    }

    await Future.wait(renderFutures);
    renderSw.stop();
    groupSw.stop();
    // The structured twin of this group's timing, built from the very values
    // the log line prints below (plan 12-B: one producer, two renderings, so
    // the display can never disagree with the log and never has to parse it).
    final groupPerf = GroupPerf(
      pages: pages.length,
      ocrCachedPages: reusedOcr,
      ocrRunPages: ocrNeededIndices.length,
      llmPages: llmPages,
      renderPages: renderFutures.length,
      resolveMs:
          groupSw.elapsedMilliseconds -
          ocrRunSw.elapsedMilliseconds -
          llmSw.elapsedMilliseconds -
          renderSw.elapsedMilliseconds,
      ocrMs: ocrRunSw.elapsedMilliseconds,
      llmMs: llmSw.elapsedMilliseconds,
      renderMs: renderSw.elapsedMilliseconds,
      totalMs: groupSw.elapsedMilliseconds,
      bytesIn: bytesIn,
      bytesOut: bytesOut,
      llmRequests: llmRequests,
      llmBlocks: llmBlocks,
      llmWindowStartMs: llmWindowStartMs,
      llmWindowEndMs: llmWindowEndMs,
    );
    Log.info('Image Translation', groupPerf.toLogLine());
    // The terminal stage report goes first on purpose: the pre-translation
    // loop credits its translation sample at the moment the answer landed, and
    // that crossing is only observed through `onStage`. For a group whose draw
    // loop never ran (every page settled before stage 3) the terminal report
    // below is the *only* crossing there is, so reporting the timing first
    // would stamp the sample with the post-render clock instead.
    onStage?.call(TranslationStage.rendering, completedPages());
    onGroupPerf?.call(groupPerf);
    return success;
  }

  /// Releases pipeline/model memory when no reader is scheduling and the
  /// pre-translation manager has finished a batch. Safe to call any time.
  void releaseIfIdle() {
    if (_active.isEmpty && _queue.isEmpty) {
      _scheduleRelease();
    }
  }

  /// Queues a page for translation. [onTranslated] fires (once per caller)
  /// after the translated page is cached, right before listeners are
  /// notified — providers use it to evict their stale image cache entry.
  void schedule(
    String cacheKey,
    String cid,
    String? sourceKey,
    Uint8List imageBytes,
    TranslationConfig config,
    VoidCallback onTranslated, {
    required TranslationChapterIdentity chapter,
  }) {
    if (_noContent.contains(cacheKey)) {
      return;
    }
    var renderKey = renderedKey(cacheKey, config.mode);
    var failedAt = _failures[renderKey];
    if (failedAt != null) {
      if (DateTime.now().difference(failedAt) < _failureRetryDelay) {
        return;
      }
      _failures.remove(renderKey);
    }
    var existing = _queue.where((t) => t.cacheKey == cacheKey).firstOrNull;
    if (existing != null) {
      existing.listeners.add(onTranslated);
      return;
    }
    if (_queue.length >= _maxQueueLength) {
      // Prefer recent requests: the reader schedules pages in reading order,
      // so the oldest not-yet-started page is the one furthest behind.
      var oldest = _queue.where((t) => !_active.contains(t)).firstOrNull;
      if (oldest == null) {
        return;
      }
      _queue.remove(oldest);
    }
    _queue.add(
      _TranslationTask(cacheKey, cid, sourceKey, imageBytes, config, chapter)
        ..listeners.add(onTranslated),
    );
    _releaseTimer?.cancel();
    _pump();
  }

  void _pump() {
    while (_active.length < _maxConcurrent) {
      var next = _queue.where((t) => !_active.contains(t)).firstOrNull;
      if (next == null) break;
      _active.add(next);
      unawaited(_process(next));
    }
  }

  Future<void> _process(_TranslationTask task) async {
    var renderKey = renderedKey(task.cacheKey, task.config.mode);
    try {
      // The comic's translation settings may have changed while this page sat
      // in the queue; its key then belongs to a superseded language pair, so
      // drop it rather than paying for a translation nothing will read.
      var current = TranslationConfig.of(task.cid, task.sourceKey);
      if (!task.cacheKey.startsWith(current.cachePrefix) ||
          current.mode != task.config.mode) {
        return;
      }
      var outcome = await _translateToCache(
        task.cacheKey,
        task.comicKey,
        task.imageBytes,
        task.config,
        chapter: task.chapter,
      );
      _errors.remove(renderKey);
      if (outcome != _TranslateOutcome.noContent) {
        _notifyDone(task);
      }
    } on PipelineCanceled {
      // ignore
    } catch (e, s) {
      _failures[renderKey] = DateTime.now();
      _errors[renderKey] = _briefError(e);
      Log.error('Image Translation', 'Failed to translate page: $e', s);
      // Let the reader surface a failure badge instead of silently showing the
      // untranslated page forever.
      notifyListeners();
    } finally {
      _queue.remove(task);
      _active.remove(task);
      if (_queue.isEmpty && _active.isEmpty) {
        _scheduleRelease();
      } else {
        _pump();
      }
    }
  }

  // ---------------------------------------------------------------------
  // Per-comic language lock
  // ---------------------------------------------------------------------

  /// A comic is almost always written in a single language. Once enough
  /// blocks agree, the detected language is remembered for the comic so
  /// later pages skip the multi-engine fallback chain entirely.
  static const _comicLangsKey = 'imageTranslationComicLangs';
  Map<String, String>? _comicLangs;

  Map<String, String> get _langLocks {
    if (_comicLangs == null) {
      var stored = appdata.implicitData[_comicLangsKey];
      _comicLangs = stored is Map
          ? stored.map((k, v) => MapEntry(k.toString(), v.toString()))
          : <String, String>{};
    }
    return _comicLangs!;
  }

  PageTranslationPipeline get pipeline => _pipeline ??= PageTranslationPipeline();

  /// Test seam: replace the pipeline used by [_translateToCache] and
  /// [translatePageGroup] with a stub whose OCR/render are fake, so the
  /// cache-reuse decisions can be pinned without models, fonts or an LLM
  /// endpoint. Passing null restores lazy construction.
  @visibleForTesting
  void usePipelineForTest(PageTranslationPipeline? value) => _pipeline = value;

  String effectiveSourceFor(String comicKey, TranslationConfig config) =>
      _effectiveSourceFor(comicKey, config);

  String _effectiveSourceFor(String comicKey, TranslationConfig config) {
    if (config.sourceLang != 'auto') {
      return config.sourceLang;
    }
    return _langLocks[comicKey] ?? 'auto';
  }

  void _updateLanguageLock(
    String comicKey,
    Map<String, int> votes,
    TranslationConfig config,
  ) {
    if (config.sourceLang != 'auto' || _langLocks.containsKey(comicKey)) {
      return;
    }
    var total = votes.values.fold(0, (a, b) => a + b);
    if (total < 4) return;
    var dominant = votes.entries.reduce((a, b) => a.value >= b.value ? a : b);
    if (dominant.value / total < 0.75) return;
    var locks = _langLocks;
    locks[comicKey] = dominant.key;
    // Bound the persisted map; entries are tiny but unbounded growth in
    // implicitData is never OK.
    while (locks.length > 300) {
      locks.remove(locks.keys.first);
    }
    appdata.implicitData[_comicLangsKey] = locks;
    appdata.writeImplicitData();
    Log.info(
      'Image Translation',
      'Locked language "${dominant.key}" for $comicKey',
    );
  }

  // ---------------------------------------------------------------------
  // Per-comic glossary
  // ---------------------------------------------------------------------

  /// Agreed name/proper-noun translations per comic ('cid@sourceKey' ->
  /// {source term -> translation}). Sent to the LLM on every page so a
  /// character's name renders identically across pages and chapters, and
  /// grown with the terms the model reports back. Persisted so a later
  /// reading session — or the pre-translation of a different chapter —
  /// inherits the same names.
  static const _comicGlossaryKey = 'imageTranslationComicGlossary';

  /// Cap per comic. The glossary is sent verbatim with every page request, so
  /// an oversized one both wastes tokens and risks overflowing the model's
  /// context. It only holds short proper nouns, so a modest cap is plenty;
  /// once full, the oldest entries are dropped.
  static const _maxGlossaryEntries = 80;
  Map<String, Map<String, String>>? _glossaries;

  Map<String, Map<String, String>> get _allGlossaries {
    if (_glossaries == null) {
      var stored = appdata.implicitData[_comicGlossaryKey];
      _glossaries = <String, Map<String, String>>{};
      var cleaned = false;
      if (stored is Map) {
        stored.forEach((k, v) {
          if (v is! Map) return;
          var glossary = <String, String>{};
          v.forEach((ik, iv) {
            var source = ik.toString();
            var translation = iv.toString();
            // Drop entries an earlier version stored before the term filter
            // existed (whole sentences, URLs, numbers) so they stop being fed
            // back to the model and inflating the prompt.
            if (LlmTranslator.isValidGlossaryTerm(source, translation)) {
              glossary[source] = translation;
            } else {
              cleaned = true;
            }
          });
          if (glossary.length > _maxGlossaryEntries) {
            var keys = glossary.keys.toList();
            for (var key in keys.take(glossary.length - _maxGlossaryEntries)) {
              glossary.remove(key);
            }
            cleaned = true;
          }
          _glossaries![k.toString()] = glossary;
        });
      }
      // Persist the cleaned form once so the cost is paid a single time.
      if (cleaned) {
        appdata.implicitData[_comicGlossaryKey] = _glossaries;
        appdata.writeImplicitData();
      }
    }
    return _glossaries!;
  }

  Map<String, String> _glossaryFor(String comicKey) {
    return _allGlossaries[comicKey] ?? const {};
  }

  /// The learned glossary of a comic ('cid@sourceKey'), as an unmodifiable copy
  /// for the per-comic glossary editor.
  Map<String, String> glossaryOf(String cid, String sourceKey) {
    return Map.unmodifiable(_glossaryFor('$cid@$sourceKey'));
  }

  /// Adds or updates one glossary entry for a comic, correcting or seeding a
  /// name translation by hand. Takes effect on the next page/chapter without a
  /// re-translate. Returns false if the term is rejected (too long / URL /
  /// sentence) or the cap is reached for a new key.
  bool setGlossaryEntry(
    String cid,
    String sourceKey,
    String source,
    String translation,
  ) {
    source = source.trim();
    translation = translation.trim();
    if (!LlmTranslator.isValidGlossaryTerm(source, translation)) {
      return false;
    }
    var comicKey = '$cid@$sourceKey';
    var all = _allGlossaries;
    var glossary = all.putIfAbsent(comicKey, () => <String, String>{});
    if (!glossary.containsKey(source) &&
        glossary.length >= _maxGlossaryEntries) {
      return false;
    }
    glossary[source] = translation;
    // Adding a term by hand means the user wants it, so lift any prior block.
    _allBlockedTerms[comicKey]?.remove(source);
    _persistBlockedTerms();
    appdata.implicitData[_comicGlossaryKey] = all;
    appdata.writeImplicitData();
    notifyListeners();
    return true;
  }

  /// Removes one glossary entry for a comic. When [block] is true the source
  /// term is also added to the comic's block list so it will not be re-learned
  /// on later pages (a plain delete would just reappear next time the model
  /// reports it).
  void removeGlossaryEntry(
    String cid,
    String sourceKey,
    String source, {
    bool block = false,
  }) {
    var comicKey = '$cid@$sourceKey';
    var glossary = _allGlossaries[comicKey];
    var removed = glossary != null && glossary.remove(source) != null;
    if (removed) {
      appdata.implicitData[_comicGlossaryKey] = _allGlossaries;
    }
    if (block) {
      _addBlockedTerm(comicKey, source);
    }
    if (removed || block) {
      appdata.writeImplicitData();
      notifyListeners();
    }
  }

  // ---------------------------------------------------------------------
  // Per-comic blocked terms
  // ---------------------------------------------------------------------

  /// Source terms the user banned from a comic's glossary. Kept separate from
  /// the glossary so a deleted-and-blocked name is not silently re-learned the
  /// next time the model reports it.
  static const _blockedTermsKey = 'imageTranslationBlockedTerms';
  Map<String, Set<String>>? _blockedTerms;

  Map<String, Set<String>> get _allBlockedTerms {
    if (_blockedTerms == null) {
      var stored = appdata.implicitData[_blockedTermsKey];
      _blockedTerms = <String, Set<String>>{};
      if (stored is Map) {
        stored.forEach((k, v) {
          if (v is List) {
            _blockedTerms![k.toString()] = v.map((e) => e.toString()).toSet();
          }
        });
      }
    }
    return _blockedTerms!;
  }

  void _addBlockedTerm(String comicKey, String source) {
    if (source.isEmpty) return;
    var set = _allBlockedTerms.putIfAbsent(comicKey, () => <String>{});
    set.add(source);
    _persistBlockedTerms();
  }

  void _persistBlockedTerms() {
    appdata.implicitData[_blockedTermsKey] = _allBlockedTerms.map(
      (k, v) => MapEntry(k, v.toList()),
    );
  }

  /// The blocked source terms of a comic, for the glossary editor.
  List<String> blockedTermsOf(String cid, String sourceKey) {
    return _allBlockedTerms['$cid@$sourceKey']?.toList() ?? const [];
  }

  /// Lifts the block on a term so it can be learned/added again.
  void unblockTerm(String cid, String sourceKey, String source) {
    var comicKey = '$cid@$sourceKey';
    var set = _allBlockedTerms[comicKey];
    if (set == null || !set.remove(source)) return;
    _persistBlockedTerms();
    appdata.writeImplicitData();
    notifyListeners();
  }

  bool _isBlocked(String comicKey, String source) {
    return _allBlockedTerms[comicKey]?.contains(source) ?? false;
  }

  void _mergeGlossary(String comicKey, Map<String, String> discovered) {
    if (discovered.isEmpty) return;
    var all = _allGlossaries;
    var glossary = all.putIfAbsent(comicKey, () => <String, String>{});
    var changed = false;
    discovered.forEach((source, translation) {
      // First agreed translation wins: an established name is not overwritten
      // by a later page's rephrasing, which keeps it stable.
      // Validate here too: the parse-time filter is the primary guard, but a
      // future caller of _mergeGlossary must not be able to insert bloat.
      if (!LlmTranslator.isValidGlossaryTerm(source, translation)) return;
      // Blocked terms must never be re-learned, even if the model keeps
      // reporting them.
      if (_isBlocked(comicKey, source)) return;
      if (!glossary.containsKey(source)) {
        glossary[source] = translation;
        changed = true;
      }
    });
    if (!changed) return;
    while (glossary.length > _maxGlossaryEntries) {
      glossary.remove(glossary.keys.first);
    }
    appdata.implicitData[_comicGlossaryKey] = all;
    appdata.writeImplicitData();
  }

  /// Drops a comic's learned glossary. Called on re-translate so a wrong name
  /// established on an earlier run does not get re-fed to the model and
  /// perpetuated.
  void _clearGlossary(String comicKey) {
    var all = _allGlossaries;
    if (all.remove(comicKey) == null) return;
    appdata.implicitData[_comicGlossaryKey] = all;
    appdata.writeImplicitData();
  }

  /// How many completion callbacks have thrown. A listener is a UI refresh
  /// (the reader evicting an image provider); one broken listener must not
  /// stop the others, and it must not be silent either.
  int _listenerFailures = 0;

  /// Exposed for the reader's diagnostics; monotonic for the process.
  int get listenerFailures => _listenerFailures;

  /// Marks [task]'s page done and calls every completion callback it carries.
  ///
  /// One listener throwing is swallowed **for that listener only**: the loop
  /// keeps going, because a page that finished is finished, and the other
  /// listeners (other reader positions, other providers) still need their
  /// refresh. What used to be `catch (_) {}` — an invisible failure that made
  /// a reader stuck on the untranslated image look like a translation that
  /// never completed — is now a warning naming the page and the listener, plus
  /// a counter. The semantics are unchanged on purpose: nothing here rethrows,
  /// retries or stops the loop.
  ///
  /// `@visibleForTesting` so a test can drive the loop directly with throwing
  /// and recording callbacks, instead of standing up a whole translation just
  /// to reach it through [_process].
  @visibleForTesting
  void notifyDoneForTest(String cacheKey, List<VoidCallback> listeners) {
    _completed.add(cacheKey);
    for (var i = 0; i < listeners.length; i++) {
      try {
        listeners[i]();
      } catch (e) {
        _listenerFailures++;
        Log.warning(
          'Image Translation',
          'Translation listener #$i threw on $cacheKey: $e '
          '(other listeners still notified)',
        );
      }
    }
    notifyListeners();
  }

  void _notifyDone(_TranslationTask task) {
    notifyDoneForTest(task.cacheKey, task.listeners);
  }

  /// Frees model memory after the reader has been idle for a while.
  void _scheduleRelease() {
    _releaseTimer?.cancel();
    _releaseTimer = null;
    final delay = _idleReleaseDelay;
    if (delay == Duration.zero) return; // setting 0 = keep the pool warm
    _releaseTimer = Timer(delay, () {
      if (_active.isNotEmpty || _queue.isNotEmpty) return;
      var pipeline = _pipeline;
      _pipeline = null;
      unawaited(pipeline?.release());
    });
  }

  /// Drops queued-but-not-started work (e.g. when leaving the reader).
  void clearQueue() {
    _queue.removeWhere((task) => !_active.contains(task));
    if (_queue.isEmpty && _active.isEmpty) {
      _scheduleRelease();
    }
  }

  /// Evicts a provider's stale image-cache entry so the next resolve loads
  /// the translated page.
  static void evictImage(ImageProvider provider) {
    scheduleMicrotask(() {
      PaintingBinding.instance.imageCache.evict(provider);
    });
  }
}
