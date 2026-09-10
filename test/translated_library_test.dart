import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/image_translation/translated_library.dart';
import 'package:venera/foundation/image_translation/translation_types.dart';
import 'package:venera/foundation/local.dart';

/// Phase 15 — the saved "AI translated manga" library.
///
/// The save path itself cannot be driven from a unit test: it needs a rendered
/// image in `CacheManager`, a `TranslationStore` row, a `LocalManager` database
/// and — for pages that were never translated — a real page fetch. What *can*
/// be pinned down is everything that decides whether what it writes is safe and
/// readable, and those are deliberately top-level pure functions:
///
///  * [safeSegment] / [chapterDirectoryName] decide the on-disk layout from
///    comic and chapter ids that come from the network. If one of them ever
///    produced `..`, a separator, or an empty segment, a save would write
///    outside its own library — or register a local comic whose chapter folder
///    cannot be found. Both are asserted here, including against the reader's
///    *own* sanitiser (`LocalManager.getChapterDirectoryName`), because the
///    reading side re-sanitises the chapter key and the two must agree.
///  * [pageFileName] is what makes the reader show the pages in order at all:
///    `LocalManager.getImagesForComic` sorts the folder's files by the integer
///    prefix of the name.
///  * [classifyPageForSave] decides whether a page is copied from the render
///    cache, re-rendered from durable text, or saved as the original. Collapsing
///    "never translated" into "has no text" is exactly how a save would report
///    success while shipping a half-translated chapter.
///  * the manifest round-trip (and its tolerance of a damaged file) is what
///    keeps the library listable after a half-finished write.
///
/// NOT VERIFIED LOCALLY (this workspace bans `flutter test`) — verified by the
/// cloud `Test` job, like every other suite in this repository.
void main() {
  /// The reader's own chapter-directory sanitiser, applied exactly the way
  /// `LocalManager.getImagesForComic` applies it to a chapter map key.
  String readerSanitiser(String name) =>
      LocalManager.getChapterDirectoryName(name);

  group('safeSegment keeps every id inside its own folder', () {
    final hostile = [
      '..',
      '.',
      '../..',
      '../../etc/passwd',
      'a/b',
      r'a\b',
      r'C:\Windows\System32',
      'CON',
      'con',
      'NUL',
      'LPT1',
      '   ',
      '',
      'x.',
      'x ',
      '.hidden',
      'a\u0000b',
      'a\u001fb',
      'name*with?wild|cards',
      'x' * 300,
      '第一话',
    ];

    test('never escapes: no separator, no . / .., no trailing dot or space',
        () {
      for (final raw in hostile) {
        final segment = safeSegment(raw);
        expect(segment, isNotEmpty, reason: 'empty segment for «$raw»');
        expect(segment, isNot('.'));
        expect(segment, isNot('..'));
        expect(
          segment.contains('/') || segment.contains(r'\'),
          isFalse,
          reason: '«$raw» produced a separator: $segment',
        );
        expect(
          segment.contains(':'),
          isFalse,
          reason: '«$raw» produced a drive/stream colon: $segment',
        );
        expect(
          segment.endsWith('.') || segment.endsWith(' '),
          isFalse,
          reason: '«$raw» produced a Windows-trimmed tail: $segment',
        );
        expect(
          RegExp(r'[<>"|?*\x00-\x1f]').hasMatch(segment),
          isFalse,
          reason: '«$raw» kept a reserved character: $segment',
        );
      }
    });

    test('is idempotent under the reader sanitiser (the reading contract)', () {
      for (final raw in hostile) {
        final segment = chapterDirectoryName(raw);
        expect(
          readerSanitiser(segment),
          segment,
          reason: 'the reader would look for a different folder than the one '
              'the save wrote for «$raw»',
        );
      }
    });

    test('is deterministic and collision-resistant', () {
      expect(safeSegment('第一话'), safeSegment('第一话'));
      // Two ids that sanitise to the same readable prefix must still land in
      // different folders, or one chapter would overwrite the other.
      expect(safeSegment('a/b'), isNot(safeSegment(r'a\b')));
      expect(safeSegment('a/b'), isNot(safeSegment('a:b')));
      expect(safeSegment('x' * 300), isNot(safeSegment('${'x' * 300}y')));
    });

    test('keeps a readable prefix for a CJK chapter title', () {
      expect(safeSegment('第一话'), startsWith('第一话'));
      expect(safeSegment('第 1 话'), startsWith('第_1_话'));
    });

    test('never emits a Windows device name', () {
      for (final name in const ['CON', 'con', 'AUX', 'nul', 'lpt9']) {
        expect(
          safeSegment(name).toUpperCase(),
          startsWith('X_'),
          reason: '$name is not a legal file name on Windows',
        );
      }
    });

    test('chapterDirectoryName maps the single-chapter sentinel to one folder',
        () {
      expect(chapterDirectoryName('0'), chapterDirectoryName(''));
      expect(chapterDirectoryName('  '), chapterDirectoryName('0'));
      expect(chapterDirectoryName('12'), startsWith('12'));
      expect(chapterDirectoryName('12'), isNot(chapterDirectoryName('0')));
    });
  });

  group('pageFileName sorts the way the reader reads', () {
    test('is a zero-padded PNG name', () {
      expect(pageFileName(1), '001.png');
      expect(pageFileName(42), '042.png');
      expect(pageFileName(999), '999.png');
    });

    test('lexicographic order equals page order for a whole chapter', () {
      final names = [for (var i = 1; i <= 120; i++) pageFileName(i)];
      final sorted = [...names]..sort();
      expect(sorted, names);
      // The reader's own comparator, so this cannot drift from
      // `LocalManager.getImagesForComic`.
      final readerSorted = [...names]..sort((a, b) {
        final ai = int.tryParse(a.split('.').first);
        final bi = int.tryParse(b.split('.').first);
        if (ai != null && bi != null) return ai.compareTo(bi);
        return a.compareTo(b);
      });
      expect(readerSorted, names);
    });
  });

  group('classifyPageForSave separates the four cases', () {
    test('a rendered page is copied', () {
      expect(
        classifyPageForSave(hasRenderedImage: true, hasStoredRegions: true),
        PageSaveKind.translatedCached,
      );
      expect(
        classifyPageForSave(hasRenderedImage: true, hasStoredRegions: null),
        PageSaveKind.translatedCached,
      );
    });

    test('an evicted render with durable text is rebuilt, not replaced', () {
      expect(
        classifyPageForSave(hasRenderedImage: false, hasStoredRegions: true),
        PageSaveKind.rerender,
      );
    });

    test('an empty stored result means the original is the right page', () {
      expect(
        classifyPageForSave(hasRenderedImage: false, hasStoredRegions: false),
        PageSaveKind.originalNoText,
      );
    });

    test('no stored row at all is an untranslated page, not a textless one',
        () {
      expect(
        classifyPageForSave(hasRenderedImage: false, hasStoredRegions: null),
        PageSaveKind.originalUntranslated,
      );
    });
  });

  group('staleness is decided by the settings a chapter was saved under', () {
    const base = (
      sourceLang: 'ja',
      targetLang: 'zh',
      mode: InpaintMode.smart,
      modelTier: 'balanced',
    );

    String fingerprintOf({
      String sourceLang = 'ja',
      String targetLang = 'zh',
      InpaintMode mode = InpaintMode.smart,
      String modelTier = 'balanced',
    }) => settingsFingerprint(
      sourceLang: sourceLang,
      targetLang: targetLang,
      mode: mode,
      modelTier: modelTier,
    );

    SavedChapter chapterWith(String fingerprint) => SavedChapter(
      chapterId: '1',
      directory: chapterDirectoryName('1'),
      title: 'Ch.1',
      pages: const [],
      savedAt: 1,
      sourceLang: base.sourceLang,
      targetLang: base.targetLang,
      mode: base.mode.name,
      modelTier: base.modelTier,
      settingsFingerprint: fingerprint,
    );

    test('a fingerprint is stable and depends on every input', () {
      expect(fingerprintOf(), fingerprintOf());
      expect(fingerprintOf(), isNot(fingerprintOf(modelTier: 'fast')));
      expect(fingerprintOf(), isNot(fingerprintOf(mode: InpaintMode.patch)));
      expect(fingerprintOf(), isNot(fingerprintOf(sourceLang: 'en')));
      expect(fingerprintOf(), isNot(fingerprintOf(targetLang: 'zh_TW')));
    });

    test('a chapter saved under the current settings is not stale', () {
      expect(
        isChapterStale(
          chapterWith(fingerprintOf()),
          sourceLang: base.sourceLang,
          targetLang: base.targetLang,
          mode: base.mode,
          modelTier: base.modelTier,
        ),
        isFalse,
      );
    });

    test('a tier or mode change marks the saved chapter stale', () {
      final saved = chapterWith(fingerprintOf());
      expect(
        isChapterStale(
          saved,
          sourceLang: base.sourceLang,
          targetLang: base.targetLang,
          mode: base.mode,
          modelTier: 'fast',
        ),
        isTrue,
        reason: 'a different model tier is a different renderer',
      );
      expect(
        isChapterStale(
          saved,
          sourceLang: base.sourceLang,
          targetLang: base.targetLang,
          mode: InpaintMode.patch,
          modelTier: base.modelTier,
        ),
        isTrue,
        reason: 'a different text-removal mode is a different page',
      );
      expect(
        isChapterStale(
          saved,
          sourceLang: 'en',
          targetLang: base.targetLang,
          mode: base.mode,
          modelTier: base.modelTier,
        ),
        isTrue,
      );
    });
  });

  group('manifest round-trip', () {
    SavedComicManifest sample() => SavedComicManifest(
      comicId: '12345',
      sourceKey: 'copymanga',
      title: 'サンプル',
      directory: 'copymanga@12345_ab12cd34',
      createdAt: 1000,
      updatedAt: 2000,
      chapters: [
        SavedChapter(
          chapterId: '第1话',
          directory: chapterDirectoryName('第1话'),
          title: '第1话 出会い',
          savedAt: 2000,
          sourceLang: 'ja',
          targetLang: 'zh',
          mode: InpaintMode.smart.name,
          modelTier: 'balanced',
          settingsFingerprint: 'abc123',
          failedPages: 1,
          pages: const [
            SavedPage(
              page: 1,
              file: '001.png',
              source: SavedPageSource.translated,
              imageKey: 'https://example.invalid/1.jpg',
            ),
            SavedPage(
              page: 2,
              file: '002.png',
              source: SavedPageSource.originalNoText,
            ),
          ],
        ),
      ],
    );

    test('survives a JSON round-trip byte for byte in its fields', () {
      final original = sample();
      final decoded = SavedComicManifest.fromJson(
        jsonDecode(jsonEncode(original.toJson())),
      );
      expect(decoded, isNotNull);
      final manifest = decoded!;
      expect(manifest.comicId, original.comicId);
      expect(manifest.sourceKey, original.sourceKey);
      expect(manifest.title, original.title);
      expect(manifest.directory, original.directory);
      expect(manifest.createdAt, original.createdAt);
      expect(manifest.updatedAt, original.updatedAt);
      expect(manifest.pageCount, 2);
      final chapter = manifest.chapters.single;
      expect(chapter.chapterId, '第1话');
      expect(chapter.directory, chapterDirectoryName('第1话'));
      expect(chapter.title, '第1话 出会い');
      expect(chapter.mode, InpaintMode.smart.name);
      expect(chapter.modelTier, 'balanced');
      expect(chapter.settingsFingerprint, 'abc123');
      expect(chapter.failedPages, 1);
      expect(chapter.translatedPages, 1);
      expect(chapter.originalPages, 1);
      expect(chapter.untranslatedPages, 0);
      expect(chapter.pages.first.source, SavedPageSource.translated);
      expect(chapter.pages.last.source, SavedPageSource.originalNoText);
      expect(chapter.pages.first.imageKey, 'https://example.invalid/1.jpg');
    });

    test('a missing manifest or a damaged one is skipped, not thrown', () {
      expect(SavedComicManifest.fromJson(null), isNull);
      expect(SavedComicManifest.fromJson(const <String, dynamic>{}), isNull);
      expect(
        SavedComicManifest.fromJson(const {'comicId': 5, 'sourceKey': 'x'}),
        isNull,
      );
      final partial = SavedComicManifest.fromJson(const {
        'comicId': '1',
        'sourceKey': 'local',
        'directory': 'local@1_deadbeef',
        'chapters': [
          {'chapterId': '9', 'directory': 'd', 'title': 't'},
          'not a chapter',
          {'nope': true},
        ],
      });
      expect(partial, isNotNull);
      final parsed = partial!;
      expect(parsed.chapters.length, 1);
      expect(parsed.chapters.single.chapterId, '9');
      expect(parsed.chapters.single.pages, isEmpty);
    });

    test('withChapter replaces in place and never erases a known title', () {
      final manifest = sample();
      final replacement = SavedChapter(
        chapterId: '第1话',
        directory: chapterDirectoryName('第1话'),
        title: '第1话',
        pages: const [
          SavedPage(page: 1, file: '001.png', source: SavedPageSource.translated),
        ],
        savedAt: 3000,
        sourceLang: 'ja',
        targetLang: 'zh',
        mode: InpaintMode.smart.name,
        modelTier: 'balanced',
        settingsFingerprint: 'abc123',
      );
      final updated = manifest.withChapter(
        replacement,
        title: '',
        updatedAt: 3000,
      );
      expect(updated.chapters.length, 1, reason: 'a re-save must not duplicate');
      expect(updated.chapters.single.savedAt, 3000);
      expect(
        updated.title,
        'サンプル',
        reason: 'an empty title from the caller must not blank a known one',
      );
      expect(updated.createdAt, 1000);
      expect(updated.updatedAt, 3000);

      final renamed = manifest.withChapter(
        replacement,
        title: '新しいタイトル',
        updatedAt: 4000,
      );
      expect(renamed.title, '新しいタイトル');
    });

    test('withChapters([]) is the empty library entry a deletion leaves', () {
      final emptied = sample().withChapters(const [], updatedAt: 5000);
      expect(emptied.chapters, isEmpty);
      expect(emptied.pageCount, 0);
      expect(emptied.sourceKey, 'copymanga');
    });

    test('chapterById finds the chapter a reader opened', () {
      final manifest = sample();
      expect(manifest.chapterById('第1话')?.title, contains('出会い'));
      expect(manifest.chapterById('missing'), isNull);
    });
  });

  group('the saved folder is the chapter the local comic registers', () {
    test('a chapter id maps to exactly one folder name, both ways', () {
      for (final eid in const ['0', '1', '12345', '第1话', 'a/b', '..']) {
        final folder = chapterDirectoryName(eid);
        // What the reader will list, given the chapter map key we register.
        expect(readerSanitiser(folder), folder);
        // And the key we register is the folder itself.
        final registered = {folder: 'title'};
        final looked = registered.keys.first;
        expect(readerSanitiser(looked), folder);
      }
    });

    test('page count and translated/original split add up', () {
      final chapter = SavedChapter(
        chapterId: '1',
        directory: chapterDirectoryName('1'),
        title: 't',
        pages: const [
          SavedPage(page: 1, file: '001.png', source: SavedPageSource.translated),
          SavedPage(page: 2, file: '002.png', source: SavedPageSource.translated),
          SavedPage(page: 3, file: '003.png', source: SavedPageSource.originalNoText),
          SavedPage(
            page: 4,
            file: '004.png',
            source: SavedPageSource.originalUntranslated,
          ),
        ],
        savedAt: 1,
        sourceLang: 'ja',
        targetLang: 'zh',
        mode: InpaintMode.smart.name,
        modelTier: 'balanced',
        settingsFingerprint: 'x',
      );
      expect(chapter.pages.length, 4);
      expect(chapter.translatedPages, 2);
      expect(chapter.originalPages, 2);
      expect(chapter.untranslatedPages, 1);
      expect(chapter.isComplete, isTrue);
    });
  });

  group('saved chapters are ordered for a reader, not for the saver', () {
    SavedChapter chapter(String id, {int pages = 1}) => SavedChapter(
      chapterId: id,
      directory: chapterDirectoryName(id),
      title: 'Ch $id',
      pages: [
        for (var i = 1; i <= pages; i++)
          SavedPage(
            page: i,
            file: pageFileName(i),
            source: SavedPageSource.translated,
          ),
      ],
      savedAt: 1,
      sourceLang: 'ja',
      targetLang: 'zh',
      mode: InpaintMode.smart.name,
      modelTier: 'balanced',
      settingsFingerprint: 'x',
    );

    test('numeric chapter ids come out in reading order', () {
      final ordered = orderSavedChapters([
        chapter('10'),
        chapter('2'),
        chapter('1'),
      ]);
      expect([for (final c in ordered) c.chapterId], ['1', '2', '10']);
    });

    test('non-numeric ids keep the order they were saved in', () {
      final saved = [chapter('番外'), chapter('第1话'), chapter('附录')];
      final ordered = orderSavedChapters(saved);
      expect(
        [for (final c in ordered) c.chapterId],
        ['番外', '第1话', '附录'],
      );
    });

    test('a mixed set is left alone rather than partly reordered', () {
      final saved = [chapter('5'), chapter('番外'), chapter('1')];
      expect(
        [for (final c in orderSavedChapters(saved)) c.chapterId],
        ['5', '番外', '1'],
      );
    });

    test('a chapter that saved no page is not registered as readable', () {
      final empty = chapter('7', pages: 0);
      expect(empty.pages, isEmpty);
      // The registration filter is expressed on the manifest side, so assert
      // the property it relies on rather than the filtered map itself.
      expect(empty.translatedPages, 0);
      expect(empty.isComplete, isTrue);
    });
  });

  group('local comic identity', () {    test('the registered id is prefixed so it can never collide with a '
        'user comic id', () {
      final id = TranslatedLibrary.localComicId('copymanga', '12345');
      expect(id, startsWith(kTranslatedLibraryIdPrefix));
      expect(id, contains('copymanga'));
      expect(id, contains('12345'));
      expect(TranslatedLibrary().isLocalComicId(id), isTrue);
      expect(TranslatedLibrary().isLocalComicId('12345'), isFalse);
    });

    test('the library root is a fixed folder under the app data directory',
        () {
      expect(kTranslatedLibraryDirName, 'translated_manga');
      expect(kTranslatedLibraryManifestName, 'manifest.json');
      expect(kTranslatedLibraryCoverName, 'cover.png');
    });

    test('a comic folder name is derived from the identity, not the title',
        () {
      final library = TranslatedLibrary();
      final a = library.comicDirectoryName('copymanga', '12345');
      final b = library.comicDirectoryName('copymanga', '12345');
      expect(a, b, reason: 'two saves of one comic must share a folder');
      expect(
        a,
        isNot(library.comicDirectoryName('copymanga', '12346')),
      );
      expect(readerSanitiser(a), a);
    });
  });
}
