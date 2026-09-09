import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/cache_manager.dart';
import 'package:venera/foundation/image_translation/translation_config.dart';
import 'package:venera/foundation/image_translation/translation_pipeline.dart';
import 'package:venera/foundation/image_translation/translation_service.dart';
import 'package:venera/foundation/image_translation/translation_store.dart';
import 'package:venera/foundation/image_translation/translation_types.dart';
import 'package:venera/foundation/log.dart';
import 'package:venera/foundation/sqlite_connection.dart';

/// Guards plan D-8 (§5.2.5): the reader's single-page path must reuse the
/// OCR intermediate the pre-translation sweep persisted, instead of burning
/// the GPU again on a page the app has already recognized.
///
/// The stub pipeline is the measurement instrument: [ocrRuns] counts real
/// GPU-OCR entries. A cache hit must leave it at zero; a miss (or a stale
/// fingerprint — red line: matching is never relaxed to force a hit) must
/// leave it at one. Everything below the pipeline (text store, OCR table,
/// rendered-image cache) is the real thing on a temp directory.
class _StubPipeline extends PageTranslationPipeline {
  _StubPipeline({required this.fresh});

  /// What the fake GPU returns when recognition actually runs.
  PageOcr fresh;

  int ocrRuns = 0;
  int renderRuns = 0;

  /// Observed hand-offs, so the test can assert what the *service* passed
  /// into the real `analyzePage` (which itself runs unstubbed — only its
  /// OCR/render edges are faked).
  PageOcr? lastExistingOcr;
  String? lastSourceLang;
  List<TranslatedRegion>? lastRenderedRegions;

  @override
  bool get ocrIsWarm => true;

  @override
  Future<List<PageOcr>> ocrPages(
    List<Uint8List> imageBytesList, {
    required String sourceLang,
    required String targetLang,
  }) async {
    ocrRuns++;
    // One result per input page, mirroring the worker's contract.
    return List.generate(imageBytesList.length, (_) => fresh);
  }

  @override
  Future<PageAnalysis> analyzePage(
    Uint8List imageBytes, {
    required String sourceLang,
    required String targetLang,
    Map<String, String> glossary = const {},
    PageOcr? existingOcr,
    String page = '0',
  }) async {
    lastExistingOcr = existingOcr;
    lastSourceLang = sourceLang;
    return super.analyzePage(
      imageBytes,
      sourceLang: sourceLang,
      targetLang: targetLang,
      glossary: glossary,
      existingOcr: existingOcr,
      page: page,
    );
  }

  @override
  Future<Uint8List> renderPage(
    Uint8List imageBytes,
    List<TranslatedRegion> regions, {
    InpaintMode mode = InpaintMode.smart,
  }) async {
    renderRuns++;
    lastRenderedRegions = regions;
    // Opaque bytes: CacheManager stores what it is given and the reader
    // decodes on display, not here.
    return Uint8List.fromList([137, 80, 78, 71]);
  }
}

TranslatedRegion _region(String text) => TranslatedRegion(
  rect: IntRect(0, 0, 10, 10),
  eraseRect: IntRect(0, 0, 10, 10),
  eraseRects: const [],
  text: text,
  backgroundColor: 0,
  textColor: 0,
  lineHeight: 12,
);

/// A recognition result that needs no LLM: everything is already in `ready`
/// (blocks the pipeline finalized without translation). `pending` stays empty
/// so no test ever reaches the network path.
PageOcr _readyOnly(String text) =>
    PageOcr([_region(text)], const [], const {'ja': 1});

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const comicKey = 'comic@src';
  const configJa = TranslationConfig(
    sourceLang: 'ja',
    targetLang: 'zh',
    mode: InpaintMode.patch,
  );
  const configAuto = TranslationConfig(
    sourceLang: 'auto',
    targetLang: 'zh',
    mode: InpaintMode.patch,
  );

  late Directory root;
  late ImageTranslationService service;
  late _StubPipeline stub;
  late TranslationChapterIdentity chapter;
  var pageSeq = 0;

  /// Unique page key per call — the service's in-memory `_completed` /
  /// `_noContent` markers are singleton state and survive between tests.
  String freshKey(String label) => ImageTranslationService.cacheKeyFor(
    '$label-${pageSeq++}',
    'src',
    'comic',
    'ch1',
  );

  Uint8List fakePageBytes() => Uint8List.fromList([0xFF, 0xD8, 0xFF, 0x00]);

  /// The `ocr=cache`/`ocr=run` field logged for this exact page (plan V8-6
  /// evidence), or null when the page never needed analysis.
  String? ocrFieldLoggedFor(String cacheKey) {
    for (final item in Log.logs.reversed) {
      if (item.title == 'Image Translation' &&
          item.content.endsWith(cacheKey)) {
        final m = RegExp(r'ocr=(\w+)').firstMatch(item.content);
        if (m != null) return m.group(1);
      }
    }
    return null;
  }

  setUp(() async {
    root = await Directory.systemTemp.createTemp('venera-ocr-cache-reuse');
    App.dataPath = root.path;
    App.cachePath = root.path;
    CacheManager.instance = null;
    await TranslationStore().init();
    // Clean language-lock / glossary state, and force the service to re-read
    // it from (empty) implicitData.
    appdata.implicitData['imageTranslationComicLangs'] = <String, String>{};
    service = ImageTranslationService.instance;
    service.reloadSyncedPrefs();
    chapter = ImageTranslationService.chapterIdentity(
      cid: 'comic',
      sourceKey: 'src',
      eid: 'ch1',
      config: configJa,
    );
    stub = _StubPipeline(fresh: _readyOnly('fresh-gpu-ocr'));
    service.usePipelineForTest(stub);
  });

  tearDown(() async {
    service.usePipelineForTest(null);
    // CacheManager._create fires a background directory scan (isolate + DB
    // work). Let it settle before the handles close and the temp root goes:
    // a rejected late scan would otherwise surface as an unhandled error on
    // whichever test happens to run next (races the whole suite's result).
    await pumpEventQueue();
    await Future<void>.delayed(const Duration(milliseconds: 400));
    TranslationStore().close();
    if (CacheManager.instance != null) {
      DatabaseGateway.instance.closeManaged('${App.dataPath}/cache.db');
      CacheManager.instance = null;
    }
    await root.delete(recursive: true);
  });

  group('reader single-page path reuses stored OCR (D-8)', () {
    test('cache hit: OCR is NOT run, stored PageOcr drives LLM+render', () async {
      final cacheKey = freshKey('hit');
      final fp = ImageTranslationService.ocrFingerprintFor('ja');
      TranslationStore().putOcr(
        cacheKey,
        _readyOnly('cached-ready'),
        fingerprint: fp,
      );

      final ok = await service.translateOne(
        cacheKey,
        comicKey,
        fakePageBytes(),
        configJa,
        chapter: chapter,
      );

      expect(ok, isTrue);
      expect(stub.ocrRuns, 0, reason: 'a stored OCR row must not re-run GPU OCR');
      expect(stub.lastExistingOcr, isNotNull,
          reason: 'the reader must hand the cached OCR to analyzePage');
      expect(stub.lastExistingOcr!.ready.single.text, 'cached-ready');
      expect(stub.renderRuns, 1);
      // The durable text now exists and the consumed OCR intermediate is
      // dropped (same lifecycle as the batch path).
      expect(TranslationStore().get(cacheKey)!.single.text, 'cached-ready');
      expect(
        TranslationStore().getOcr(cacheKey, fingerprint: fp),
        isNull,
        reason: 'the OCR row is spent once the text result was written',
      );
      // Observability (V8-6): the run is labelled as a cache reuse.
      expect(ocrFieldLoggedFor(cacheKey), 'cache');
    });

    test('cache miss: OCR runs exactly once, as before', () async {
      final cacheKey = freshKey('miss');

      final ok = await service.translateOne(
        cacheKey,
        comicKey,
        fakePageBytes(),
        configJa,
        chapter: chapter,
      );

      expect(ok, isTrue);
      expect(stub.ocrRuns, 1);
      expect(stub.lastExistingOcr, isNull);
      expect(TranslationStore().get(cacheKey)!.single.text, 'fresh-gpu-ocr');
      expect(ocrFieldLoggedFor(cacheKey), 'run');
    });

    test('fingerprint mismatch is NOT reused (red line: no fuzzy match)', () async {
      final cacheKey = freshKey('stale');
      // A row produced under a *different* model/language dimension: the
      // reader runs with resolved 'ja' and must query the 'ja' fingerprint.
      TranslationStore().putOcr(
        cacheKey,
        _readyOnly('stale-row'),
        fingerprint: ImageTranslationService.ocrFingerprintFor('en'),
      );

      final ok = await service.translateOne(
        cacheKey,
        comicKey,
        fakePageBytes(),
        configJa,
        chapter: chapter,
      );

      expect(ok, isTrue);
      expect(stub.ocrRuns, 1, reason: 'a stale fingerprint must re-recognise');
      expect(stub.lastExistingOcr, isNull);
      expect(
        TranslationStore().get(cacheKey)!.single.text,
        'fresh-gpu-ocr',
        reason: 'the fresh result, not the stale row, is what gets stored',
      );
      // The page now has a durable text result, so the mismatched row is
      // dropped too (deleteOcr keys on cache_key alone, matching the batch
      // path's cleanup).
      expect(
        TranslationStore().hasOcr(
          cacheKey,
          fingerprint: ImageTranslationService.ocrFingerprintFor('en'),
        ),
        isFalse,
        reason: 'garbage under the old fingerprint is discarded',
      );
    });

    test('resolved language, not `auto`, is what the fingerprint keys on', () async {
      // This is the writer-side contract from pre_translation_tasks.dart:
      // `ocrFingerprintFor(service.effectiveSourceFor(comicKey, config))`.
      // A comic whose config says `auto` but whose lock resolved to `ja`
      // must reuse the row written under the `ja` fingerprint, and must
      // *not* be served a row written under the literal `auto` one.
      final cacheKey = freshKey('lock');
      appdata.implicitData['imageTranslationComicLangs'] = <String, String>{
        comicKey: 'ja',
      };
      service.reloadSyncedPrefs();
      expect(
        service.effectiveSourceFor(comicKey, configAuto),
        'ja',
        reason: 'precondition: the lock resolves auto to ja',
      );
      TranslationStore().putOcr(
        cacheKey,
        _readyOnly('locked-ja-row'),
        fingerprint: ImageTranslationService.ocrFingerprintFor('ja'),
      );
      TranslationStore().putOcr(
        '$cacheKey.auto-bait',
        _readyOnly('auto-bait-row'),
        fingerprint: ImageTranslationService.ocrFingerprintFor('auto'),
      );

      final ok = await service.translateOne(
        cacheKey,
        comicKey,
        fakePageBytes(),
        configAuto,
        chapter: chapter,
      );

      expect(ok, isTrue);
      expect(stub.ocrRuns, 0, reason: 'the locked-language row is a hit');
      expect(stub.lastExistingOcr!.ready.single.text, 'locked-ja-row');
      expect(
        stub.lastSourceLang,
        'ja',
        reason: 'analyzePage is called with the resolved language too',
      );
      // The bait row sits under its own key; it must not have been consumed
      // by anything (nobody translates that key).
      expect(
        TranslationStore().hasOcr(
          '$cacheKey.auto-bait',
          fingerprint: ImageTranslationService.ocrFingerprintFor('auto'),
        ),
        isTrue,
      );
    });

    test('stored text result short-circuits before the OCR probe', () async {
      final cacheKey = freshKey('text-hit');
      TranslationStore().put(
        cacheKey,
        [_region('stored-text')],
        chapter: chapter,
      );

      final ok = await service.translateOne(
        cacheKey,
        comicKey,
        fakePageBytes(),
        configJa,
        chapter: chapter,
      );

      expect(ok, isTrue);
      expect(stub.ocrRuns, 0);
      expect(stub.lastRenderedRegions!.single.text, 'stored-text');
      expect(
        ocrFieldLoggedFor(cacheKey),
        isNull,
        reason: 'no analysis ran, so no ocr= line should be logged',
      );
    });
  });

  group('batch pre-translation path keeps the same semantics', () {
    test('cached OCR row is reused and spent (translatePageGroup)', () async {
      final cacheKey = freshKey('batch-hit');
      final fp = ImageTranslationService.ocrFingerprintFor('ja');
      TranslationStore().putOcr(
        cacheKey,
        _readyOnly('batch-cached'),
        fingerprint: fp,
      );

      final success = await service.translatePageGroup(
        [(cacheKey: cacheKey, imageBytes: fakePageBytes())],
        comicKey,
        configJa,
        chapter: chapter,
      );

      expect(success.single, isTrue);
      expect(stub.ocrRuns, 0, reason: 'stage 1 must not enqueue GPU work');
      expect(TranslationStore().get(cacheKey)!.single.text, 'batch-cached');
      expect(TranslationStore().getOcr(cacheKey, fingerprint: fp), isNull);
      final line = Log.logs
          .reversed
          .map((i) => i.content)
          .firstWhere((c) => c.startsWith('Group OCR resolve'));
      expect(line, contains('ocr=cache x1'));
      expect(line, contains('ocr=run x0'));
    });

    test('miss in batch still runs OCR through the chunked path', () async {
      final cacheKey = freshKey('batch-miss');

      final success = await service.translatePageGroup(
        [(cacheKey: cacheKey, imageBytes: fakePageBytes())],
        comicKey,
        configJa,
        chapter: chapter,
      );

      expect(success.single, isTrue);
      expect(stub.ocrRuns, greaterThanOrEqualTo(1));
      expect(TranslationStore().get(cacheKey)!.single.text, 'fresh-gpu-ocr');
    });
  });

  group('analyzePage existingOcr contract', () {
    test('default (no existingOcr) keeps running OCR — old callers', () async {
      final p = _StubPipeline(fresh: _readyOnly('fresh'));
      final analysis = await p.analyzePage(
        fakePageBytes(),
        sourceLang: 'ja',
        targetLang: 'zh',
      );
      expect(p.ocrRuns, 1);
      expect(analysis.regions.single.text, 'fresh');
      expect(p.lastExistingOcr, isNull);
    });

    test('existingOcr skips OCR and its ready regions are returned', () async {
      final p = _StubPipeline(fresh: _readyOnly('unused'));
      final analysis = await p.analyzePage(
        fakePageBytes(),
        sourceLang: 'ja',
        targetLang: 'zh',
        existingOcr: _readyOnly('provided'),
      );
      expect(p.ocrRuns, 0);
      expect(analysis.regions.single.text, 'provided');
      expect(analysis.languageVotes, {'ja': 1});
    });

    test('an existingOcr that carries an error is re-recognized', () async {
      final p = _StubPipeline(fresh: _readyOnly('recovered'));
      final analysis = await p.analyzePage(
        fakePageBytes(),
        sourceLang: 'ja',
        targetLang: 'zh',
        existingOcr: PageOcr(const [], const [], const {}, error: 'boom'),
      );
      expect(p.ocrRuns, 1);
      expect(analysis.regions.single.text, 'recovered');
    });
  });

  group('source guards (plan V8-7 / R6 / D-8 wiring)', () {
    final imgDir = Directory('lib/foundation/image_translation');
    final libDir = Directory('lib');

    List<File> dartFiles(Directory dir) => dir
        .listSync(recursive: true)
        .whereType<File>()
        .where((f) => f.path.endsWith('.dart'))
        .toList();

    test('every OCR-cache access carries a fingerprint: argument', () {
      // Red line (D-2/R2): `translated_ocr_page` reads/writes are exact-match
      // on the fingerprint; a call that drops it reopens the stale-model
      // dirty-read the fingerprint column exists to prevent. (The store's
      // definitions are excluded — they have no `.` receiver.)
      final callRe = RegExp(
        r'\.(getOcr|putOcr|hasOcr)\(((?:[^()]|\([^()]*\))*)\)',
      );
      for (final f in dartFiles(libDir)) {
        final text = f.readAsStringSync();
        for (final m in callRe.allMatches(text)) {
          expect(
            m.group(2),
            contains('fingerprint:'),
            reason: '${f.path}: OCR-cache call without fingerprint: '
                '${m.group(0)}',
          );
        }
      }
    });

    test(
      'fingerprint callers pass the RESOLVED language, never auto/config',
      () {
        // The D-8 fix only holds if every reader computes the fingerprint
        // from `effectiveSourceFor(...)` — the same value both writers use.
        // Passing the raw config (which may be `auto`) or a literal would
        // fork the reader/writer keys and silently disable reuse.
        final callRe = RegExp(
          r'ocrFingerprintFor\(((?:[^()]|\([^()]*\))*)\)',
        );
        final allowed = {
          'sourceLang',
          'effectiveSourceLang',
          'effectiveLang',
        };
        for (final f in dartFiles(imgDir)) {
          final text = f.readAsStringSync();
          for (final m in callRe.allMatches(text)) {
            // `line` is only the text BEFORE the match, and the match starts
            // at the name — so the definition reads as a line ending with
            // `static String`.
            final line = text.substring(0, m.start).split('\n').last;
            if (line.trimRight().endsWith('static String')) {
              continue; // the definition itself
            }
            // Collapse whitespace and a possible trailing comma so a
            // `dart format` reflow cannot false-fail the rule.
            final arg = m
                .group(1)!
                .replaceAll(RegExp(r'\s+'), '')
                .replaceAll(RegExp(r',+$'), '');
            expect(
              allowed,
              contains(arg),
              reason: '${f.path}: ocrFingerprintFor($arg) — pass the value '
                  'resolved by effectiveSourceFor(), never `auto` or '
                  'config.sourceLang (plan §5.3)',
            );
          }
        }
      },
    );

    test('_translateToCache actually consults the OCR cache (D-8 wiring)', () {
      // Regression guard: if the reader path is rewired back to a plain
      // analyzePage-with-OCR, reuse silently disappears.
      final text = File(
        'lib/foundation/image_translation/translation_service.dart',
      ).readAsStringSync();
      final start = text.indexOf('Future<_TranslateOutcome> _translateToCache');
      final end = text.indexOf('Future<List<bool>> translatePageGroup');
      expect(start, greaterThan(-1));
      expect(end, greaterThan(start));
      final body = text.substring(start, end);
      expect(body, contains('_ocrFromCache('));
      expect(body, contains('ocrFingerprintFor(effectiveSourceLang)'));
      expect(body, contains('existingOcr:'));
      expect(body, contains('deleteOcr('));
      // Both consumer paths share the single read helper.
      expect(
        RegExp(r'_ocrFromCache\(').allMatches(text).length,
        greaterThanOrEqualTo(3), // definition + reader + batch
      );
    });
  });
}
