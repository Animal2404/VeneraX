import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/image_translation/translation_pipeline.dart';
import 'package:venera/foundation/image_translation/translation_service.dart';
import 'package:venera/foundation/image_translation/translation_store.dart';
import 'package:venera/foundation/image_translation/translation_types.dart';
import 'package:venera/foundation/log.dart';
import 'package:venera/foundation/sqlite_connection.dart';
import 'package:venera/utils/opencc.dart';

/// Pins the F13.7 "no silent drop" work: every place a recognized block used
/// to leave the pipeline without a drawn region, and every place the eraser
/// used to leave no line, now says so.
///
/// The three erasure-ledger branches are asserted through
/// [PageTranslationPipeline.ledgerReason] (the exact function `renderPage`
/// branches on) plus one real `renderPage` call per branch, so the log line and
/// the pixels come from the same run. The two block drops are asserted on the
/// returned record *and* on the log, because the whole point of the change is
/// that the drop is observable, not merely countable.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // The zh→zh-TW classification below runs the real OpenCC tables; without
  // this the `late final` dictionaries are read before they are loaded.
  setUpAll(OpenCC.init);

  setUp(() => Log.clear());
  tearDown(() => Log.clear());

  OcrBlock block(String text, {String lang = 'ja', int x = 0}) => OcrBlock(
    rect: IntRect(x, 0, x + 10, 10),
    text: text,
    language: lang,
    backgroundColor: 0xFFFFFFFF,
    textColor: 0xFF000000,
    lineHeight: 12,
  );

  Iterable<LogItem> linesFor(String title, String prefix) => Log.logs.where(
    (l) => l.title == title && l.content.startsWith(prefix),
  );

  group('erasure ledger names every branch (Defect A)', () {
    test('ledgerReason picks the branch from mode and regions alone', () {
      final regions = [
        TranslatedRegion(
          rect: IntRect(0, 0, 10, 10),
          text: 'x',
          backgroundColor: 0,
          textColor: 0,
        ),
      ];
      expect(
        PageTranslationPipeline.ledgerReason(InpaintMode.patch, const []),
        PageTranslationPipeline.kLedgerReasonPatch,
        reason: 'patch never reaches the eraser, regions or not',
      );
      expect(
        PageTranslationPipeline.ledgerReason(InpaintMode.patch, regions),
        PageTranslationPipeline.kLedgerReasonPatch,
      );
      expect(
        PageTranslationPipeline.ledgerReason(InpaintMode.smart, const []),
        PageTranslationPipeline.kLedgerReasonNoRegions,
      );
      expect(
        PageTranslationPipeline.ledgerReason(InpaintMode.smart, regions),
        PageTranslationPipeline.kLedgerReasonRan,
      );
    });

    test('describeLedger prints mode, reason and the erased count', () {
      expect(
        PageTranslationPipeline.describeLedger(
          mode: InpaintMode.smart,
          reason: PageTranslationPipeline.kLedgerReasonRan,
          erased: 7,
        ),
        'mode=smart reason=ran erased=7',
      );
      expect(
        PageTranslationPipeline.describeLedger(
          mode: InpaintMode.patch,
          reason: PageTranslationPipeline.kLedgerReasonPatch,
        ),
        'mode=patch reason=patch erased=0',
        reason: 'erased=0 is the honest count when the eraser never ran',
      );
    });

    test('the three pipeline branches print one ledger line each, and the '
        'regions still render', () async {
      final png = await _tinyPng();
      final regions = [
        TranslatedRegion(
          rect: IntRect(1, 1, 6, 6),
          text: '译',
          backgroundColor: 0xFFFFFFFF,
          textColor: 0xFF000000,
        ),
      ];

      // Branch 1: patch never erases.
      final patched = await PageTranslationPipeline().renderPage(
        png,
        regions,
        mode: InpaintMode.patch,
      );
      expect(patched, isNotEmpty, reason: 'the page is still rendered');
      expect(
        linesFor('Inpaint', 'erasure ledger:').single.content,
        'erasure ledger: mode=patch reason=patch erased=0',
      );

      Log.clear();

      // Branch 2: smart with nothing to erase.
      await PageTranslationPipeline().renderPage(
        png,
        const [],
        mode: InpaintMode.smart,
      );
      expect(
        linesFor('Inpaint', 'erasure ledger:').single.content,
        'erasure ledger: mode=smart reason=no-regions erased=0',
      );

      Log.clear();

      // Branch 3: the eraser runs and its own counts follow.
      await PageTranslationPipeline().renderPage(
        png,
        regions,
        mode: InpaintMode.smart,
      );
      final ran = linesFor('Inpaint', 'erasure ledger:').single.content;
      expect(ran, contains('mode=smart reason=ran erased='));
      expect(ran, contains('skipped='));
      expect(
        linesFor('Inpaint', 'erasure ledger:'),
        hasLength(1),
        reason: 'one page is one ledger line, never two',
      );
    });

    test('the cache-hit branch is logged where the page is served, not in '
        'the pipeline', () {
      // `renderPage` cannot print this branch: on a cache hit it is never
      // called. The service's stored-page path owns it.
      final service = File(
        'lib/foundation/image_translation/translation_service.dart',
      ).readAsStringSync();
      final start = service.indexOf('Future<Uint8List?> renderStoredPage(');
      expect(start, isNonNegative, reason: 'renderStoredPage must exist');
      final next = service.indexOf(
        '\n\n  /// ',
        start,
      ); // the next documented member
      final body = service.substring(
        start,
        next < 0 ? service.length : next,
      );
      expect(body, contains('reason=cache-hit'));
      expect(body, contains('erasure ledger:'));

      // The literal in the service must stay the same word the pipeline's
      // constant uses, or the four ledger lines stop being one grep.
      expect(
        PageTranslationPipeline.kLedgerReasonCacheHit,
        'cache-hit',
        reason: 'service hard-codes this literal (the constant is test-only)',
      );
      expect(
        PageTranslationPipeline.describeLedger(
          mode: InpaintMode.smart,
          reason: PageTranslationPipeline.kLedgerReasonCacheHit,
        ),
        'mode=smart reason=cache-hit erased=0',
      );
    });
  });

  group('model drop is named, not swallowed', () {
    test('an empty answer is modelEmpty, an echo is modelEchoed', () {
      final pending = [
        block('原文一', x: 0),
        block('原文二', x: 20),
        block('原文三', x: 40),
      ];
      final folded = PageTranslationPipeline().regionsFromTranslation(
        pending,
        ['译文一', '', '原文三'],
        page: 'ch1/p3',
      );

      expect(folded.regions.single.text, '译文一');
      expect(folded.dropped, hasLength(2));
      expect(folded.dropped[0].reason, BlockDropReason.modelEmpty);
      expect(folded.dropped[0].index, 1);
      expect(folded.dropped[1].reason, BlockDropReason.modelEchoed);
      expect(folded.dropped[1].index, 2);
      expect(folded.dropped[0].language, 'ja');
      expect(folded.dropped[1].language, 'ja');
    });

    test('a missing answer entry is an empty answer, not a crash', () {
      final folded = PageTranslationPipeline().regionsFromTranslation(
        [block('原文')],
        const [],
      );
      expect(folded.regions, isEmpty);
      expect(folded.dropped.single.reason, BlockDropReason.modelEmpty);
    });

    test('whitespace-only answers count as empty, and are trimmed before the '
        'echo test', () {
      final folded = PageTranslationPipeline().regionsFromTranslation(
        [block('原文一', x: 0), block('原文二', x: 20)],
        ['   ', ' 原文二 '],
      );
      expect(
        folded.dropped.map((d) => d.reason),
        [BlockDropReason.modelEmpty, BlockDropReason.modelEchoed],
        reason: 'the echo check is on the trimmed text, as before',
      );
    });

    test('each drop writes one line with index, reason, language and a '
        '24-character preview', () {
      final long = 'あ' * 40;
      PageTranslationPipeline().regionsFromTranslation(
        [block(long)],
        const [],
        page: 'ch1/p9',
      );
      final line = linesFor('Inpaint', 'BlockDrop ').single.content;
      expect(line, startsWith('BlockDrop page=ch1/p9 index=0 '));
      expect(line, contains('reason=modelEmpty'));
      expect(line, contains('lang=ja'));
      expect(
        line,
        contains('text="${'あ' * kBlockDropPreviewChars}…"'),
        reason: 'long text is cut so one drop stays one log line',
      );
    });

    test('newlines in the source text never break the one-line contract', () {
      PageTranslationPipeline().regionsFromTranslation(
        [block('一\n二\t三')],
        const [],
      );
      final line = linesFor('Inpaint', 'BlockDrop ').single.content;
      expect(line, contains('text="一 二 三"'));
      expect(line, isNot(contains('\n')));
    });

    test('the drop reason vocabulary round-trips through JSON', () {
      for (final reason in BlockDropReason.values) {
        final drop = BlockDrop(
          index: 3,
          reason: reason,
          language: 'ja',
          text: 'x',
        );
        expect(BlockDrop.fromJson(drop.toJson()).reason, reason);
        expect(BlockDrop.fromJson(drop.toJson()).index, 3);
      }
    });
  });

  group('language filter drops are named too (Defect B)', () {
    test('a target-language block is dropped, not translated', () {
      final classified = PageTranslationPipeline.classifyBlocks(
        [block('日本語', lang: 'ja'), block('中文', lang: 'zh')],
        'zh',
      );
      expect(classified.pending.single.text, '日本語');
      expect(classified.ready, isEmpty);
      expect(classified.dropped.single.reason, BlockDropReason.targetLanguage);
      expect(classified.dropped.single.index, 1);
      expect(classified.dropped.single.language, 'zh');
    });

    test('zh→zh-TW converts when it can and names the no-op when it cannot',
        () {
      final classified = PageTranslationPipeline.classifyBlocks(
        [block('汉字', lang: 'zh'), block('漢字', lang: 'zh')],
        'zh-TW',
      );
      expect(classified.ready.single.text, '漢字');
      expect(classified.pending, isEmpty);
      expect(
        classified.dropped.single.reason,
        BlockDropReason.targetUnconverted,
        reason: 'simplified == traditional: nothing to draw',
      );
      // The dropped block is the already-traditional one — the second block
      // in the list. Index 0 is the block that *did* convert, and it is in
      // `ready`, not in `dropped`.
      expect(classified.dropped.single.index, 1);
      expect(classified.dropped.single.text, '漢字');
    });

    test('indices are positions in the recognized list, so a drop can be '
        'matched to its block', () {
      final blocks = [
        block('a', lang: 'en', x: 0),
        block('中文', lang: 'zh', x: 20),
        block('b', lang: 'en', x: 40),
      ];
      final classified = PageTranslationPipeline.classifyBlocks(blocks, 'zh');
      expect(classified.dropped.single.index, 1);
      expect(blocks[classified.dropped.single.index].text, '中文');
    });
  });

  group('blockFunnelLine reports the two drops as separate counts', () {
    test('an explicit skippedAsTarget is used instead of the recovery', () {
      final line = blockFunnelLine(
        page: 'p1',
        votes: 9,
        pending: 4,
        ready: 1,
        llmIn: 4,
        llmOut: 3,
        regions: 4,
        modelDropped: 1,
        skippedAsTarget: 4,
      );
      expect(line, contains('skippedAsTarget=4'));
      expect(
        'skippedAsTarget='.allMatches(line),
        hasLength(1),
        reason: 'one field, not a duplicate',
      );
      expect(line, contains('modelDropped=1'));
    });

    test('without a drop list the count is still recovered, or unknown', () {
      final recovered = blockFunnelLine(
        page: 'p2',
        votes: 9,
        pending: 4,
        ready: 1,
        llmIn: 4,
        llmOut: 3,
        regions: 4,
        modelDropped: 1,
      );
      expect(recovered, contains('skippedAsTarget=4'));

      final unknown = blockFunnelLine(
        page: 'p3',
        votes: null,
        pending: null,
        ready: null,
        llmIn: null,
        llmOut: null,
        regions: 0,
        modelDropped: null,
      );
      expect(unknown, contains('skippedAsTarget=?'));
      expect(
        unknown,
        contains('modelDropped=?'),
        reason: 'not measurable must never print a fake 0',
      );
    });
  });

  group('_notifyDone keeps notifying, and says when it could not', () {
    test('one throwing listener does not stop the others', () {
      final service = ImageTranslationService.instance;
      final calls = <String>[];
      final before = service.listenerFailures;

      service.notifyDoneForTest('page@k1', [
        () => calls.add('first'),
        () => throw StateError('listener blew up'),
        () => calls.add('third'),
      ]);

      expect(
        calls,
        ['first', 'third'],
        reason: 'the loop must not abort on a broken listener',
      );
      expect(service.listenerFailures, before + 1);
      final line = linesFor('Image Translation', 'Translation listener')
          .single
          .content;
      expect(line, contains('listener #1'));
      expect(line, contains('page@k1'));
      expect(line, contains('listener blew up'));
      expect(line, contains('other listeners still notified'));
    });

    test('every listener runs when none throws, and nothing is logged', () {
      final calls = <String>[];
      ImageTranslationService.instance.notifyDoneForTest('page@k2', [
        () => calls.add('a'),
        () => calls.add('b'),
      ]);
      expect(calls, ['a', 'b']);
      expect(linesFor('Image Translation', 'Translation listener'), isEmpty);
    });

    test('_notifyDone itself has no swallowing catch left', () {
      final source = File(
        'lib/foundation/image_translation/translation_service.dart',
      ).readAsStringSync();
      final start = source.indexOf('void _notifyDone(_TranslationTask task)');
      expect(start, isNonNegative);
      final body = source.substring(start, start + 300);
      expect(body, contains('notifyDoneForTest(task.cacheKey'));
      expect(
        body,
        isNot(contains('catch')),
        reason: 'the catch (and its log) lives in the shared loop',
      );
    });
  });

  group('hasOcr tells a broken probe apart from an empty cache', () {
    late Directory root;

    setUp(() async {
      root = await Directory.systemTemp.createTemp('venera-hasocr');
      App.dataPath = root.path;
      await TranslationStore().init();
    });

    tearDown(() async {
      TranslationStore().close();
      await root.delete(recursive: true);
    });

    test('no row: false, quietly — that is not a failure', () {
      final before = TranslationStore().ocrProbeFailures;
      expect(
        TranslationStore().hasOcr('missing@page', fingerprint: 'fp'),
        isFalse,
      );
      expect(TranslationStore().ocrProbeFailures, before);
      expect(
        Log.logs.where((l) => l.content.contains('hasOcr failed')),
        isEmpty,
        reason: 'an empty cache must not log an error',
      );
    });

    test('a row: true', () {
      TranslationStore().putOcr(
        'page@k',
        PageOcr(
          [
            TranslatedRegion(
              rect: IntRect(0, 0, 10, 10),
              text: 't',
              backgroundColor: 0,
              textColor: 0,
            ),
          ],
          const [],
          const {'ja': 1},
        ),
        fingerprint: 'fp',
      );
      expect(TranslationStore().hasOcr('page@k', fingerprint: 'fp'), isTrue);
      expect(
        TranslationStore().hasOcr('page@k', fingerprint: 'other'),
        isFalse,
        reason: 'the fingerprint match is exact, never fuzzy',
      );
    });

    test('a throwing probe: false, but logged as a failure and counted', () async {
      final before = TranslationStore().ocrProbeFailures;
      // Break the table out of band: the store's handle stays open, the query
      // it will run now fails. This is the "database cannot answer" case that
      // used to be indistinguishable from "no cached row".
      await DatabaseGateway.instance.isolateOp(
        '${App.dataPath}/image_translation.db',
        (db) async => db.execute('drop table translated_ocr_page;'),
      );

      expect(
        TranslationStore().hasOcr('page@k', fingerprint: 'fp'),
        isFalse,
        reason: 'a failed probe is still a miss for the caller',
      );
      expect(TranslationStore().ocrProbeFailures, before + 1);
      final line = linesFor('TranslationStore', 'hasOcr failed').single;
      expect(line.level, LogLevel.error);
      expect(line.content, contains('probe #${before + 1}'));
      expect(line.content, contains('page@k'));
      expect(line.content, contains('fingerprint=fp'));
      expect(
        line.content,
        contains('not as an empty cache'),
        reason: 'the wording is what makes the two states separable',
      );
    });
  });
}

/// A 4x4 opaque PNG, built through the engine so `renderPage`'s real decoder
/// accepts it. Nothing about it is special: the tests only need a page that
/// decodes.
Future<Uint8List> _tinyPng() async {
  const width = 4;
  const height = 4;
  final pixels = Uint8List(width * height * 4);
  for (var i = 0; i < width * height; i++) {
    pixels[i * 4] = 0xFF;
    pixels[i * 4 + 1] = 0xFF;
    pixels[i * 4 + 2] = 0xFF;
    pixels[i * 4 + 3] = 0xFF;
  }
  final buffer = await ui.ImmutableBuffer.fromUint8List(pixels);
  final descriptor = ui.ImageDescriptor.raw(
    buffer,
    width: width,
    height: height,
    pixelFormat: ui.PixelFormat.rgba8888,
  );
  final codec = await descriptor.instantiateCodec();
  final frame = await codec.getNextFrame();
  try {
    final data = await frame.image.toByteData(format: ui.ImageByteFormat.png);
    return data!.buffer.asUint8List();
  } finally {
    frame.image.dispose();
    codec.dispose();
    descriptor.dispose();
    buffer.dispose();
  }
}
