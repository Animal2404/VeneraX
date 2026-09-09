// NOTE: 本文件按任务约束在本地**未运行**（禁止本地 flutter test / 构建）。
// 只经过 `flutter analyze --no-pub`。列入待云端 `Test` job 验证清单。
//
// Plan 12-B, end to end: the translation service must report one group's wall
// time as a **structured value object handed back with the response**, so the
// progress card can show `ms/页` for the translation and rendering phases
// without reading a line of log text.
//
// The red line this guards: Phase 2 scraped a perf string and printed a number
// whose name did not match its meaning ("detMs" was really the batch size).
// Here the measurement and the log line are produced from one object, so the
// two cannot drift — and the test proves the *drift* direction too, by
// comparing the logged text against the object's own formatting (a test may
// read a log; production may not).
//
// The stub pipeline is the same instrument `ocr_cache_reuse_test.dart` uses:
// OCR and render edges are faked, everything under them (text store, OCR
// intermediate, rendered-image cache) is the real thing on a temp directory.
// The fake returns a PageOcr whose bubbles are all `ready`, so the shared LLM
// request is never reached and no test can touch the network.

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/cache_manager.dart';
import 'package:venera/foundation/image_translation/pre_translation_tasks.dart';
import 'package:venera/foundation/image_translation/translation_config.dart';
import 'package:venera/foundation/image_translation/translation_pipeline.dart';
import 'package:venera/foundation/image_translation/translation_service.dart';
import 'package:venera/foundation/image_translation/translation_store.dart';
import 'package:venera/foundation/image_translation/translation_types.dart';
import 'package:venera/foundation/log.dart';
import 'package:venera/foundation/sqlite_connection.dart';

class _StubPipeline extends PageTranslationPipeline {
  _StubPipeline({this.ocrDelay = Duration.zero, this.renderDelay = Duration.zero});

  /// How long a fake recognition / draw takes. Non-zero where a test asserts a
  /// measured cost, so "0 ms" can only ever mean "this phase did not run".
  final Duration ocrDelay;
  final Duration renderDelay;

  int ocrRuns = 0;
  int renderRuns = 0;

  @override
  bool get ocrIsWarm => true;

  @override
  Future<List<PageOcr>> ocrPages(
    List<Uint8List> imageBytesList, {
    required String sourceLang,
    required String targetLang,
  }) async {
    ocrRuns++;
    if (ocrDelay > Duration.zero) {
      await Future<void>.delayed(ocrDelay);
    }
    return List.generate(
      imageBytesList.length,
      (_) => _readyOnly('fresh-gpu-ocr'),
    );
  }

  @override
  Future<Uint8List> renderPage(
    Uint8List imageBytes,
    List<TranslatedRegion> regions, {
    InpaintMode mode = InpaintMode.smart,
  }) async {
    renderRuns++;
    if (renderDelay > Duration.zero) {
      await Future<void>.delayed(renderDelay);
    }
    // Opaque bytes: CacheManager stores what it is given.
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

/// Recognition result with nothing left to translate: `pending` empty means
/// stage 2 skips the LLM call entirely (and the request's ms stay 0).
PageOcr _readyOnly(String text) =>
    PageOcr([_region(text)], const [], const {'ja': 1});

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const comicKey = 'perf-comic@src';
  const configJa = TranslationConfig(
    sourceLang: 'ja',
    targetLang: 'zh',
    mode: InpaintMode.patch,
  );

  late Directory root;
  late ImageTranslationService service;
  late TranslationChapterIdentity chapter;
  var pageSeq = 0;

  String freshKey(String label) => ImageTranslationService.cacheKeyFor(
    '$label-${pageSeq++}',
    'src',
    'perf-comic',
    'ch1',
  );

  Uint8List fakePageBytes() => Uint8List.fromList([0xFF, 0xD8, 0xFF, 0x00]);

  /// The `GroupPerf ...` line the service logged most recently, or null.
  String? lastGroupPerfLine() {
    for (final item in Log.logs.reversed) {
      if (item.title == 'Image Translation' &&
          item.content.startsWith('GroupPerf ')) {
        return item.content;
      }
    }
    return null;
  }

  setUp(() async {
    root = await Directory.systemTemp.createTemp('venera-group-perf');
    App.dataPath = root.path;
    App.cachePath = root.path;
    CacheManager.instance = null;
    await TranslationStore().init();
    appdata.implicitData['imageTranslationComicLangs'] = <String, String>{};
    service = ImageTranslationService.instance;
    service.reloadSyncedPrefs();
    chapter = ImageTranslationService.chapterIdentity(
      cid: 'perf-comic',
      sourceKey: 'src',
      eid: 'ch1',
      config: configJa,
    );
  });

  tearDown(() async {
    service.usePipelineForTest(null);
    // CacheManager's constructor fires a background directory scan; let it
    // settle before the handles close and the temp root goes away.
    await pumpEventQueue();
    await Future<void>.delayed(const Duration(milliseconds: 400));
    TranslationStore().close();
    if (CacheManager.instance != null) {
      DatabaseGateway.instance.closeManaged('${App.dataPath}/cache.db');
      CacheManager.instance = null;
    }
    await root.delete(recursive: true);
  });

  group('the service reports a group timing with the response', () {
    test('one GroupPerf per group, built from its own measured phases', () async {
      service.usePipelineForTest(
        _StubPipeline(
          ocrDelay: const Duration(milliseconds: 20),
          renderDelay: const Duration(milliseconds: 20),
        ),
      );
      final keys = [freshKey('a'), freshKey('b')];
      final reported = <GroupPerf>[];

      final success = await service.translatePageGroup(
        [
          (cacheKey: keys[0], imageBytes: fakePageBytes()),
          (cacheKey: keys[1], imageBytes: fakePageBytes()),
        ],
        comicKey,
        configJa,
        chapter: chapter,
        onGroupPerf: reported.add,
      );

      expect(success, [isTrue, isTrue]);
      expect(reported.length, 1, reason: 'one group, one report');
      final perf = reported.single;
      expect(perf.pages, 2);
      expect(perf.ocrRunPages, 2, reason: 'neither page had a cached OCR row');
      expect(perf.ocrCachedPages, 0);
      expect(perf.renderPages, 2);
      // The split closes: the four parts are exactly the group total.
      expect(perf.resolveMs + perf.ocrMs + perf.llmMs + perf.renderMs, perf.totalMs);
      // …and the remainder is not negative, which is what a double-counted
      // (overlapping) phase would produce: the four are disjoint by
      // construction, and this is the assertion that catches it if they stop
      // being so.
      expect(perf.resolveMs, greaterThanOrEqualTo(0));
      expect(perf.ocrMs, greaterThan(0), reason: 'the fake OCR ran');
      expect(perf.renderMs, greaterThan(0));
      // No request was made, so the translation phase has no per-page cost —
      // and the card must print —, not 0.
      expect(perf.llmPages, 0);
      expect(perf.llmMs, 0);
      expect(perf.translationMsPerPage, isNull);
      expect(perf.renderMsPerPage, perf.renderMs / perf.renderPages);
    });

    test('the logged line is the object rendered, not a second hand-written copy', () async {
      service.usePipelineForTest(
        _StubPipeline(renderDelay: const Duration(milliseconds: 10)),
      );
      final reported = <GroupPerf>[];

      await service.translatePageGroup(
        [(cacheKey: freshKey('log'), imageBytes: fakePageBytes())],
        comicKey,
        configJa,
        chapter: chapter,
        onGroupPerf: reported.add,
      );

      final line = lastGroupPerfLine();
      expect(line, isNotNull);
      // Byte-equal to what the object prints: one producer, so the display can
      // never disagree with the telemetry the user reads in the log.
      expect(line, reported.single.toLogLine());
    });

    test('a fully cached group claims no per-page cost', () async {
      service.usePipelineForTest(_StubPipeline());
      final key = freshKey('cached');
      // Warm the rendered-image cache first, then ask again: stage 1 settles
      // the page and nothing downstream runs.
      await service.translatePageGroup(
        [(cacheKey: key, imageBytes: fakePageBytes())],
        comicKey,
        configJa,
        chapter: chapter,
      );
      final reported = <GroupPerf>[];

      final success = await service.translatePageGroup(
        [(cacheKey: key, imageBytes: fakePageBytes())],
        comicKey,
        configJa,
        chapter: chapter,
        onGroupPerf: reported.add,
      );

      expect(success.single, isTrue);
      final perf = reported.single;
      expect(perf.pages, 1);
      expect(perf.renderPages, 0, reason: 'nothing was drawn');
      expect(perf.ocrRunPages, 0);
      expect(perf.renderMsPerPage, isNull);
      expect(perf.translationMsPerPage, isNull);
      expect(perf.totalMs, greaterThanOrEqualTo(0));
    });

    test('the reported numbers reach the card through the activity, unparsed', () async {
      service.usePipelineForTest(
        _StubPipeline(
          ocrDelay: const Duration(milliseconds: 10),
          renderDelay: const Duration(milliseconds: 20),
        ),
      );
      final activity = PreTranslationActivity()
        ..chapterIndex = 1
        ..chapterEid = 'ch1';
      GroupPerf? measured;

      await service.translatePageGroup(
        [(cacheKey: freshKey('card'), imageBytes: fakePageBytes())],
        comicKey,
        configJa,
        chapter: chapter,
        onGroupPerf: (perf) {
          measured = perf;
          // Exactly the branching the pre-translation loop applies.
          if (perf.llmPages > 0) {
            activity.recordTranslatedGroup(perf);
          } else {
            activity.recordTranslatedPages(perf.pages);
          }
          activity.recordRenderWork(perf);
        },
      );

      expect(measured, isNotNull);
      expect(
        measured!.renderMsPerPage,
        greaterThan(0),
        reason: 'the draw loop took measurable time (20 ms stub)',
      );
      // The card's number, recomputed here from the object's *raw* fields: the
      // row reads the structured report, and nothing between the two is a
      // string. (An identity against the same getter would prove nothing.)
      expect(
        activity.renderWorkRates.msPerPage,
        measured!.renderMs / measured!.renderPages,
      );
      // The fake returns nothing pending, so no request was made: the arrival
      // is credited (a resumed chapter must still show a rate) but no
      // millisecond is billed to it, and a single duration-less sample is not
      // yet a rate — `—`, not 0.
      expect(activity.translateRates.samples, 1);
      expect(activity.translateRates.msPerPage, isNull);
      expect(activity.translateRates.pagesPerMinute, isNull);
      expect(activity.sweepRates.samples, 0);
    });
  });
}
