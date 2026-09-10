/// The durable home of "AI translated manga" (plan §15).
///
/// Until this module existed the merged page — the original art with the
/// translated text drawn into it — only ever lived in [CacheManager], under the
/// page's rendered key. That cache is a *cache*: it expires after 30 days and
/// is evicted under pressure, so "the chapter I translated last month" could
/// silently become untranslated again. This module promotes what the user
/// explicitly saves into a directory of its own, laid out so the app's existing
/// local-comic layer reads it back with no new reading path:
///
/// ```
/// <App.dataPath>/translated_manga/
///   <comicDir>/                    safeSegment('sourceKey@comicId')
///     manifest.json                SavedComicManifest
///     cover.png                    first saved page of the first chapter
///     <chapterDir>/                safeSegment(chapterId)
///       001.png 002.png …          NNN = order inside the chapter
/// ```
///
/// Reading it back is deliberately *not* reimplemented here: [saveChapter]
/// registers a [LocalComic] row (id `xlated:<sourceKey>:<comicId>`, an absolute
/// directory, one chapter per saved segment) and the reader's own local-comic
/// path does the rest — `LocalManager.getImagesForComic` lists the chapter
/// folder sorted by the numeric file prefix, which is exactly why the files are
/// named `NNN.png`.
///
/// What this module does **not** do: render, OCR, or talk to an LLM. Every byte
/// it writes comes from a page that is already translated (the rendered cache,
/// or a re-render of durable stored regions); pages the user has not translated
/// are copied as the original image and labelled as such in the manifest.
library;

import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/comic_state_repository.dart';
import 'package:venera/foundation/comic_type.dart';
import 'package:venera/foundation/image_translation/translation_config.dart';
import 'package:venera/foundation/image_translation/translation_models.dart';
import 'package:venera/foundation/image_translation/translation_service.dart';
import 'package:venera/foundation/image_translation/translation_store.dart';
import 'package:venera/foundation/image_translation/translation_types.dart';
import 'package:venera/foundation/local.dart';
import 'package:venera/foundation/log.dart';
import 'package:venera/foundation/source_platform.dart';
import 'package:venera/network/images.dart';
import 'package:venera/utils/io.dart';
import 'package:venera/utils/translations.dart';

/// Root folder name under the app data directory. Kept out of
/// `LocalManager.path` on purpose: that path is user-relocatable (SD card, SAF)
/// and this library must always be writable by plain `dart:io`.
const String kTranslatedLibraryDirName = 'translated_manga';

const String kTranslatedLibraryManifestName = 'manifest.json';

const String kTranslatedLibraryCoverName = 'cover.png';

/// Prefix of the [LocalComic] id this module registers. Also the only way the
/// AI-translated entries can be told apart from ordinary local comics in the
/// shared `comics` table.
const String kTranslatedLibraryIdPrefix = 'xlated:';

/// `001.png`, `002.png`, … — three digits sorts correctly up to 999 pages, and
/// `LocalManager.getImagesForComic` parses the leading integer.
const int kSavedPageDigits = 3;

/// The longest a directory segment may be before truncation. The reader does
/// not care, but Windows paths are capped at 260 characters and the root,
/// comic and chapter segments all contribute.
const int kSafeSegmentMaxLength = 40;

const Set<String> _windowsReservedNames = {
  'CON',
  'PRN',
  'AUX',
  'NUL',
  'COM1',
  'COM2',
  'COM3',
  'COM4',
  'COM5',
  'COM6',
  'COM7',
  'COM8',
  'COM9',
  'LPT1',
  'LPT2',
  'LPT3',
  'LPT4',
  'LPT5',
  'LPT6',
  'LPT7',
  'LPT8',
  'LPT9',
};

/// Characters no platform we ship on accepts in a file name, plus the ASCII
/// control range. `/` and `\` are here because a segment containing either
/// would escape the directory it was meant to name.
final RegExp _forbiddenSegmentChars = RegExp(r'[\x00-\x1f<>:"/\\|?*]');

/// Whitespace, including the ideographic space a CJK chapter title can carry.
/// Collapsed to `_` so the folder name stays one shell word.
final RegExp _whitespaceRun = RegExp(r'\s+');

/// Sanitises one path segment this module builds (`..`-safe, separator-free,
/// platform-legal) while keeping it recognisable to a human.
///
/// Two properties matter and are asserted by tests:
///  * **containment** — the result never contains a separator, is never `.` or
///    `..`, and never *ends* in a dot or a space, so joining it onto the root
///    cannot land outside the root whatever the comic or chapter id holds;
///  * **collision resistance** — a short hash of the raw value is appended, so
///    two ids that sanitise to the same prefix (`a/b` and `a\b`, a title that
///    differs only in stripped punctuation, a truncated long id) still get
///    different folders.
String safeSegment(String raw, {int maxLength = kSafeSegmentMaxLength}) {
  var text = raw
      .replaceAll(_forbiddenSegmentChars, '_')
      .replaceAll(_whitespaceRun, '_');
  // A trailing dot or space is silently dropped by Windows, which would make
  // two different segments collide; strip both ends instead of trimming.
  text = text.replaceAll(RegExp(r'^[.\s]+'), '').replaceAll(RegExp(r'[.\s]+$'), '');
  if (text.runes.length > maxLength) {
    text = String.fromCharCodes(text.runes.take(maxLength));
  }
  var upper = text.toUpperCase();
  if (text.isEmpty || text == '.' || text == '..' || _windowsReservedNames.contains(upper)) {
    text = '';
  }
  final digest = sha1.convert(utf8.encode(raw)).toString().substring(0, 8);
  return text.isEmpty ? 'x_$digest' : '${text}_$digest';
}

/// Folder name for one chapter inside a comic folder. `'0'` is the app's
/// sentinel for "this comic has a single unnamed chapter".
String chapterDirectoryName(String chapterId) {
  final trimmed = chapterId.trim();
  return safeSegment(trimmed.isEmpty || trimmed == '0' ? 'chapter' : trimmed);
}

/// File name of the [sequence]-th page written into a chapter folder.
String pageFileName(int sequence) =>
    '${sequence.toString().padLeft(kSavedPageDigits, '0')}.png';

/// Where a saved page's pixels came from.
enum SavedPageSource {
  /// The rendered page: original art with the translation drawn in.
  translated,

  /// The original page, saved as-is because the durable store says it holds no
  /// translatable text (a splash page, a cover, an empty bubble).
  originalNoText,

  /// The original page, saved as-is because this page was never translated.
  originalUntranslated;

  bool get isTranslated => this == SavedPageSource.translated;

  static SavedPageSource? fromName(String? name) {
    for (final value in SavedPageSource.values) {
      if (value.name == name) return value;
    }
    return null;
  }
}

/// One page on disk.
class SavedPage {
  const SavedPage({
    required this.page,
    required this.file,
    required this.source,
    this.imageKey = '',
  });

  /// 1-based position of this page in the chapter's *source* page list. Kept
  /// even though [file] is a contiguous sequence, so a page that failed to save
  /// leaves a visible hole in the record instead of shifting its neighbours.
  final int page;

  /// Name inside the chapter folder.
  final String file;

  final SavedPageSource source;

  /// The page key this came from (a URL, or a `file://` path for local comics).
  /// Recorded so a future re-save can map a page back to its source without
  /// guessing from the file name.
  final String imageKey;

  Map<String, dynamic> toJson() => {
    'page': page,
    'file': file,
    'source': source.name,
    if (imageKey.isNotEmpty) 'imageKey': imageKey,
  };

  static SavedPage? fromJson(Object? json) {
    if (json is! Map) return null;
    final page = json['page'];
    final file = json['file'];
    if (page is! int || file is! String || file.isEmpty) return null;
    return SavedPage(
      page: page,
      file: file,
      source:
          SavedPageSource.fromName(json['source'] as String?) ??
          SavedPageSource.translated,
      imageKey: json['imageKey'] is String ? json['imageKey'] as String : '',
    );
  }
}

/// One saved chapter: its folder, its ordered pages and the settings that
/// produced them.
class SavedChapter {
  const SavedChapter({
    required this.chapterId,
    required this.directory,
    required this.title,
    required this.pages,
    required this.savedAt,
    required this.sourceLang,
    required this.targetLang,
    required this.mode,
    required this.modelTier,
    required this.settingsFingerprint,
    this.failedPages = 0,
  });

  /// The chapter id exactly as the translation cache keys use it.
  final String chapterId;

  /// Folder name — always the output of [chapterDirectoryName], which is also
  /// the key this chapter is registered under in the local comic's chapter map.
  final String directory;

  final String title;

  /// Ordered by [SavedPage.page].
  final List<SavedPage> pages;

  final int savedAt;

  final String sourceLang;

  final String targetLang;

  final String mode;

  final String modelTier;

  /// See [settingsFingerprint]: what the translation settings were at save
  /// time, so the UI can say "this chapter came from a different model set"
  /// instead of silently replacing it.
  final String settingsFingerprint;

  /// Pages that could not be written at all (fetch failed, decode failed).
  final int failedPages;

  int get translatedPages =>
      pages.where((p) => p.source.isTranslated).length;

  int get originalPages => pages.length - translatedPages;

  int get untranslatedPages =>
      pages.where((p) => p.source == SavedPageSource.originalUntranslated).length;

  bool get isComplete => failedPages == 0;

  Map<String, dynamic> toJson() => {
    'chapterId': chapterId,
    'directory': directory,
    'title': title,
    'savedAt': savedAt,
    'sourceLang': sourceLang,
    'targetLang': targetLang,
    'mode': mode,
    'modelTier': modelTier,
    'settingsFingerprint': settingsFingerprint,
    if (failedPages > 0) 'failedPages': failedPages,
    'pages': [for (final page in pages) page.toJson()],
  };

  static SavedChapter? fromJson(Object? json) {
    if (json is! Map) return null;
    final chapterId = json['chapterId'];
    final directory = json['directory'];
    if (chapterId is! String || directory is! String || directory.isEmpty) {
      return null;
    }
    final pages = <SavedPage>[];
    final rawPages = json['pages'];
    if (rawPages is List) {
      for (final raw in rawPages) {
        final page = SavedPage.fromJson(raw);
        if (page != null) pages.add(page);
      }
    }
    pages.sort((a, b) => a.page.compareTo(b.page));
    return SavedChapter(
      chapterId: chapterId,
      directory: directory,
      title: json['title'] is String ? json['title'] as String : '',
      pages: pages,
      savedAt: json['savedAt'] is int ? json['savedAt'] as int : 0,
      sourceLang: json['sourceLang'] is String ? json['sourceLang'] as String : '',
      targetLang: json['targetLang'] is String ? json['targetLang'] as String : '',
      mode: json['mode'] is String ? json['mode'] as String : '',
      modelTier: json['modelTier'] is String ? json['modelTier'] as String : '',
      settingsFingerprint: json['settingsFingerprint'] is String
          ? json['settingsFingerprint'] as String
          : '',
      failedPages: json['failedPages'] is int ? json['failedPages'] as int : 0,
    );
  }
}

/// The on-disk index of one saved comic. Its own folder name is stored so a
/// manifest found by scanning the root is self-describing.
class SavedComicManifest {
  const SavedComicManifest({
    required this.comicId,
    required this.sourceKey,
    required this.title,
    required this.directory,
    required this.chapters,
    required this.createdAt,
    required this.updatedAt,
    this.version = currentVersion,
  });

  static const int currentVersion = 1;

  final int version;

  final String comicId;

  /// Canonical source key ('local' for a local comic).
  final String sourceKey;

  final String title;

  /// Folder name under the library root.
  final String directory;

  final List<SavedChapter> chapters;

  final int createdAt;

  final int updatedAt;

  int get pageCount =>
      chapters.fold(0, (total, chapter) => total + chapter.pages.length);

  SavedChapter? chapterById(String chapterId) {
    for (final chapter in chapters) {
      if (chapter.chapterId == chapterId) return chapter;
    }
    return null;
  }

  /// Replaces (or adds) one chapter, keeping the previous title when the caller
  /// has none — a save triggered from a screen that never loaded the metadata
  /// must not erase what an earlier save recorded.
  SavedComicManifest withChapter(
    SavedChapter chapter, {
    required String title,
    required int updatedAt,
  }) {
    final merged = <SavedChapter>[
      for (final existing in chapters)
        if (existing.directory != chapter.directory) existing,
      chapter,
    ];
    return SavedComicManifest(
      version: version,
      comicId: comicId,
      sourceKey: sourceKey,
      title: title.isEmpty ? this.title : title,
      directory: directory,
      chapters: merged,
      createdAt: createdAt,
      updatedAt: updatedAt,
    );
  }

  SavedComicManifest withChapters(List<SavedChapter> chapters, {required int updatedAt}) {
    return SavedComicManifest(
      version: version,
      comicId: comicId,
      sourceKey: sourceKey,
      title: title,
      directory: directory,
      chapters: chapters,
      createdAt: createdAt,
      updatedAt: updatedAt,
    );
  }

  Map<String, dynamic> toJson() => {
    'version': version,
    'comicId': comicId,
    'sourceKey': sourceKey,
    'title': title,
    'directory': directory,
    'createdAt': createdAt,
    'updatedAt': updatedAt,
    'chapters': [for (final chapter in chapters) chapter.toJson()],
  };

  /// Tolerant parse: a manifest written by a newer build, or damaged by a
  /// half-finished write, yields null (caller skips that folder) rather than
  /// throwing inside a directory scan.
  static SavedComicManifest? fromJson(Object? json) {
    if (json is! Map) return null;
    final comicId = json['comicId'];
    final sourceKey = json['sourceKey'];
    final directory = json['directory'];
    if (comicId is! String || sourceKey is! String || directory is! String) {
      return null;
    }
    if (comicId.isEmpty || directory.isEmpty) return null;
    final chapters = <SavedChapter>[];
    final rawChapters = json['chapters'];
    if (rawChapters is List) {
      for (final raw in rawChapters) {
        final chapter = SavedChapter.fromJson(raw);
        if (chapter != null) chapters.add(chapter);
      }
    }
    return SavedComicManifest(
      version: json['version'] is int ? json['version'] as int : currentVersion,
      comicId: comicId,
      sourceKey: sourceKey,
      title: json['title'] is String ? json['title'] as String : '',
      directory: directory,
      chapters: chapters,
      createdAt: json['createdAt'] is int ? json['createdAt'] as int : 0,
      updatedAt: json['updatedAt'] is int ? json['updatedAt'] as int : 0,
    );
  }
}

/// A saved comic as the UI sees it: the manifest plus where it lives.
class SavedComic {
  const SavedComic({required this.manifest, required this.directory});

  final SavedComicManifest manifest;

  /// Absolute path of the comic folder.
  final String directory;

  String get id => TranslatedLibrary.localComicId(
    manifest.sourceKey,
    manifest.comicId,
  );

  String get title =>
      manifest.title.isEmpty ? manifest.comicId : manifest.title;

  String get coverPath =>
      FilePath.join(directory, kTranslatedLibraryCoverName);

  int get pageCount => manifest.pageCount;
}

/// What [TranslatedLibrary.saveChapter] did, in counts the UI can report
/// honestly: pages that came from the translated cache, pages saved as the
/// original because there was nothing to translate, pages saved as the original
/// because they were never translated, and pages that failed outright.
class SaveChapterOutcome {
  const SaveChapterOutcome({
    required this.comicDirectory,
    required this.chapterDirectory,
    required this.translated,
    required this.originalNoText,
    required this.originalUntranslated,
    required this.failures,
  });

  final String comicDirectory;

  final String chapterDirectory;

  final int translated;

  final int originalNoText;

  final int originalUntranslated;

  /// One human-readable line per page that could not be written.
  final List<String> failures;

  int get saved => translated + originalNoText + originalUntranslated;

  int get failed => failures.length;

  bool get ok => saved > 0;

  String describe() =>
      'saved=$saved translated=$translated originalNoText=$originalNoText '
      'originalUntranslated=$originalUntranslated failed=$failed';
}

/// Fingerprint of the settings that decide *which* model set renders a page.
///
/// Not the OCR content hash of the model files (`ocrFingerprintFor`, which
/// reads model bytes and is too expensive to run on every save): this records
/// the choice the user made — language pair, text-removal mode, model tier —
/// which is what "this chapter came from an older set" is being asked about.
/// Documented limitation: swapping a model *file* at the same tier does not
/// move this fingerprint.
String settingsFingerprint({
  required String sourceLang,
  required String targetLang,
  required InpaintMode mode,
  required String modelTier,
}) {
  final raw = '$sourceLang>$targetLang@${mode.name}@$modelTier';
  return sha1.convert(utf8.encode(raw)).toString().substring(0, 12);
}

/// Whether a saved chapter was produced under settings other than [current].
bool isChapterStale(
  SavedChapter chapter, {
  required String sourceLang,
  required String targetLang,
  required InpaintMode mode,
  required String modelTier,
}) {
  return chapter.settingsFingerprint !=
      settingsFingerprint(
        sourceLang: sourceLang,
        targetLang: targetLang,
        mode: mode,
        modelTier: modelTier,
      );
}

/// What a save has to do with one page, decided from two facts about the cache.
///
/// Pure so the four branches can be asserted without a filesystem, a model or a
/// network: the two null/false cases are the ones that silently produce a
/// half-translated chapter if they are collapsed into each other.
enum PageSaveKind {
  /// A rendered page exists in the cache: copy it.
  translatedCached,

  /// The rendered cache was evicted but durable stored regions exist: rebuild
  /// the page from them (no OCR, no LLM) instead of saving the original.
  rerender,

  /// The store says this page holds nothing translatable: the original *is* the
  /// correct page.
  originalNoText,

  /// Never translated: save the original and label it as untranslated.
  originalUntranslated,
}

/// [hasStoredRegions] is null when the store has no row for the page at all.
PageSaveKind classifyPageForSave({
  required bool hasRenderedImage,
  required bool? hasStoredRegions,
}) {
  if (hasRenderedImage) return PageSaveKind.translatedCached;
  if (hasStoredRegions == null) return PageSaveKind.originalUntranslated;
  if (hasStoredRegions) return PageSaveKind.rerender;
  return PageSaveKind.originalNoText;
}

/// Orders saved chapters the way a reader expects to see them.
///
/// The manifest stores them in save order, which is the reading order only if
/// the user saved them while reading forward. When every chapter id is numeric
/// — which is what every source in this app publishes — sort by that number;
/// otherwise keep insertion order rather than inventing an order for ids that
/// are titles or slugs.
List<SavedChapter> orderSavedChapters(List<SavedChapter> chapters) {
  final numbers = <int>[];
  for (final chapter in chapters) {
    final number = int.tryParse(chapter.chapterId.trim());
    if (number == null) return chapters;
    numbers.add(number);
  }
  final indexed = <({int number, int index, SavedChapter chapter})>[
    for (var i = 0; i < chapters.length; i++)
      (number: numbers[i], index: i, chapter: chapters[i]),
  ];
  indexed.sort((a, b) {
    final byNumber = a.number.compareTo(b.number);
    return byNumber != 0 ? byNumber : a.index.compareTo(b.index);
  });
  return [for (final entry in indexed) entry.chapter];
}

/// Staging area for "save the chapter I am reading / I translated" (plan §15).
///
/// The library is a plain directory of manifests — there is no database, so
/// "nothing saved yet" and "the index is corrupt" are both just an empty list.
class TranslatedLibrary with ChangeNotifier {
  TranslatedLibrary.create();

  static TranslatedLibrary? _instance;

  factory TranslatedLibrary() => _instance ??= TranslatedLibrary.create();

  static String localComicId(String sourceKey, String comicId) =>
      '$kTranslatedLibraryIdPrefix$sourceKey:$comicId';

  bool isLocalComicId(String id) =>
      id.startsWith(kTranslatedLibraryIdPrefix);

  /// Absolute root of the library.
  String get rootPath => FilePath.join(App.dataPath, kTranslatedLibraryDirName);

  Directory get rootDirectory => Directory(rootPath);

  /// Folder name for one comic; deterministic, so saving two chapters of the
  /// same comic writes into one folder instead of two.
  String comicDirectoryName(String sourceKey, String comicId) =>
      safeSegment('$sourceKey@$comicId');

  List<SavedComic> _comics = const [];

  List<SavedComic> get comics => _comics;

  bool _loaded = false;

  bool get isLoaded => _loaded;

  /// Reads every manifest under the root. Cheap enough to call on page open
  /// (one directory listing plus one small JSON file per comic).
  Future<List<SavedComic>> refresh() async {
    final found = <SavedComic>[];
    try {
      final root = rootDirectory;
      if (await root.exists()) {
        await for (final entity in root.list()) {
          if (entity is! Directory) continue;
          final manifest = await readManifest(entity.path);
          if (manifest == null || manifest.chapters.isEmpty) continue;
          found.add(SavedComic(manifest: manifest, directory: entity.path));
        }
      }
    } catch (e, s) {
      Log.error('TranslatedLibrary', 'failed to scan $rootPath: $e', s);
    }
    found.sort((a, b) => b.manifest.updatedAt.compareTo(a.manifest.updatedAt));
    _comics = found;
    _loaded = true;
    notifyListeners();
    return found;
  }

  /// The manifest inside [comicDirectory], or null when there is none or it is
  /// unreadable.
  Future<SavedComicManifest?> readManifest(String comicDirectory) async {
    final file = File(
      FilePath.join(comicDirectory, kTranslatedLibraryManifestName),
    );
    try {
      if (!await file.exists()) return null;
      return SavedComicManifest.fromJson(jsonDecode(await file.readAsString()));
    } catch (e) {
      Log.warning('TranslatedLibrary', 'unreadable manifest ${file.path}: $e');
      return null;
    }
  }

  SavedComic? findComic(String sourceKey, String comicId) {
    for (final comic in _comics) {
      if (comic.manifest.sourceKey == sourceKey &&
          comic.manifest.comicId == comicId) {
        return comic;
      }
    }
    return null;
  }

  SavedChapter? findChapter(String sourceKey, String comicId, String chapterId) {
    return findComic(
      sourceKey,
      comicId,
    )?.manifest.chapterById(chapterId);
  }

  /// Saves every page of one chapter.
  ///
  /// [pageKeys] must be the chapter's pages in reading order — the same keys the
  /// reader holds, so the cache keys computed here are the ones the pipeline
  /// already wrote. Pages with a rendered image are copied; pages that were
  /// never translated are fetched from the source (or read from disk for a local
  /// comic) and saved as the original, so the saved chapter has no holes.
  ///
  /// A page that cannot be materialised is skipped and reported in
  /// [SaveChapterOutcome.failures]; the rest are still saved.
  Future<SaveChapterOutcome> saveChapter({
    required String comicId,
    required String? sourceKey,
    required String chapterId,
    required String comicTitle,
    required String chapterTitle,
    required List<String> pageKeys,
    required TranslationConfig config,
    void Function(int done, int total)? onProgress,
  }) async {
    final canonicalSourceKey =
        sourceKey ?? SourcePlatformResolver.localCanonicalKey;
    final comicDirName = comicDirectoryName(canonicalSourceKey, comicId);
    final comicDir = Directory(FilePath.join(rootPath, comicDirName));
    await comicDir.create(recursive: true);
    final chapterDirName = chapterDirectoryName(chapterId);
    final chapterDir = Directory(FilePath.join(comicDir.path, chapterDirName));
    await chapterDir.create(recursive: true);

    final pages = <SavedPage>[];
    final failures = <String>[];
    var translated = 0;
    var originalNoText = 0;
    var originalUntranslated = 0;

    final total = pageKeys.length;
    for (var i = 0; i < total; i++) {
      final imageKey = pageKeys[i];
      final pageNumber = i + 1;
      Uint8List? bytes;
      var source = SavedPageSource.translated;
      try {
        final cacheKey = ImageTranslationService.cacheKeyFor(
          imageKey,
          sourceKey,
          comicId,
          chapterId,
        );
        final cached = await ImageTranslationService.instance.findTranslated(
          cacheKey,
          config.mode,
        );
        if (cached != null) {
          bytes = await cached.readAsBytes();
        } else {
          final stored = TranslationStore().get(cacheKey);
          final kind = classifyPageForSave(
            hasRenderedImage: false,
            hasStoredRegions: stored?.isNotEmpty,
          );
          final original = await _loadOriginalBytes(
            imageKey,
            sourceKey,
            comicId,
            chapterId,
          );
          if (original == null) {
            failures.add('page $pageNumber: original image unavailable');
            onProgress?.call(pageNumber, total);
            continue;
          }
          if (kind == PageSaveKind.rerender) {
            // Rebuild from durable regions: no OCR, no LLM, same pixels the
            // reader would show if the rendered cache were still warm.
            bytes = await ImageTranslationService.instance.renderStoredPage(
              cacheKey,
              original,
              config.mode,
              chapter: ImageTranslationService.chapterIdentity(
                cid: comicId,
                sourceKey: sourceKey,
                eid: chapterId,
                config: config,
                comicTitle: comicTitle,
                chapterTitle: chapterTitle,
              ),
            );
          }
          if (bytes == null) {
            bytes = original;
            source = kind == PageSaveKind.originalNoText
                ? SavedPageSource.originalNoText
                : SavedPageSource.originalUntranslated;
          }
        }
      } catch (e) {
        Log.warning(
          'TranslatedLibrary',
          'page $pageNumber of $chapterId failed to save: $e',
        );
        failures.add('page $pageNumber: $e');
        onProgress?.call(pageNumber, total);
        continue;
      }
      if (bytes.isEmpty) {
        failures.add('page $pageNumber: empty image data');
        onProgress?.call(pageNumber, total);
        continue;
      }
      final fileName = pageFileName(pages.length + 1);
      try {
        await File(
          FilePath.join(chapterDir.path, fileName),
        ).writeAsBytes(bytes, flush: true);
      } catch (e, s) {
        Log.error('TranslatedLibrary', 'failed to write $fileName: $e', s);
        failures.add('page $pageNumber: write failed');
        onProgress?.call(pageNumber, total);
        continue;
      }
      pages.add(
        SavedPage(
          page: pageNumber,
          file: fileName,
          source: source,
          imageKey: imageKey,
        ),
      );
      switch (source) {
        case SavedPageSource.translated:
          translated++;
        case SavedPageSource.originalNoText:
          originalNoText++;
        case SavedPageSource.originalUntranslated:
          originalUntranslated++;
      }
      onProgress?.call(pageNumber, total);
    }

    final now = DateTime.now().millisecondsSinceEpoch;
    final previous = await readManifest(comicDir.path);
    final chapter = SavedChapter(
      chapterId: chapterId,
      directory: chapterDirName,
      title: chapterTitle,
      pages: pages,
      savedAt: now,
      sourceLang: config.sourceLang,
      targetLang: config.targetLang,
      mode: config.mode.name,
      modelTier: TranslationModels.currentModelTier.name,
      settingsFingerprint: settingsFingerprint(
        sourceLang: config.sourceLang,
        targetLang: config.targetLang,
        mode: config.mode,
        modelTier: TranslationModels.currentModelTier.name,
      ),
      failedPages: failures.length,
    );
    final manifest = (previous ??
            SavedComicManifest(
              comicId: comicId,
              sourceKey: canonicalSourceKey,
              title: comicTitle,
              directory: comicDirName,
              chapters: const [],
              createdAt: now,
              updatedAt: now,
            ))
        .withChapter(chapter, title: comicTitle, updatedAt: now);
    await _writeManifest(comicDir.path, manifest);
    await _ensureCover(comicDir.path, manifest);
    await registerAsLocalComic(manifest, comicDir.path);
    await refresh();

    final outcome = SaveChapterOutcome(
      comicDirectory: comicDir.path,
      chapterDirectory: chapterDir.path,
      translated: translated,
      originalNoText: originalNoText,
      originalUntranslated: originalUntranslated,
      failures: failures,
    );
    Log.info('TranslatedLibrary', 'chapter $chapterId ${outcome.describe()}');
    return outcome;
  }

  /// Deletes one chapter folder and its manifest entry. The translated pages
  /// are removed; the OCR cache, the stored text and the source comic are not.
  Future<void> deleteChapter(SavedComic comic, SavedChapter chapter) async {
    await _deleteDirectory(
      Directory(FilePath.join(comic.directory, chapter.directory)),
    );
    final remaining = [
      for (final existing in comic.manifest.chapters)
        if (existing.directory != chapter.directory) existing,
    ];
    final manifest = comic.manifest.withChapters(
      remaining,
      updatedAt: DateTime.now().millisecondsSinceEpoch,
    );
    if (remaining.isEmpty) {
      // Nothing left to read: the folder itself goes, and the registered local
      // comic row with it.
      await _deleteDirectory(Directory(comic.directory));
    } else {
      await _writeManifest(comic.directory, manifest);
      await _ensureCover(comic.directory, manifest);
    }
    await registerAsLocalComic(manifest, comic.directory);
    await refresh();
  }

  /// Deletes a whole saved comic: folder, manifest and the registered local
  /// comic row.
  Future<void> deleteComic(SavedComic comic) async {
    final manifest = comic.manifest.withChapters(
      const [],
      updatedAt: DateTime.now().millisecondsSinceEpoch,
    );
    await _deleteDirectory(Directory(comic.directory));
    await registerAsLocalComic(manifest, comic.directory);
    await refresh();
  }

  /// Registers (or re-registers) the saved comic as a [LocalComic] so the
  /// existing reader can open it offline.
  ///
  /// The row is removed first: [LocalManager.add] unions `downloadedChapters`
  /// with the previous row's, which would resurrect a chapter this call is
  /// meant to drop.
  Future<bool> registerAsLocalComic(
    SavedComicManifest manifest,
    String comicDirectory,
  ) async {
    final manager = LocalManager();
    if (!manager.isInitialized) return false;
    final id = localComicId(manifest.sourceKey, manifest.comicId);
    try {
      manager.remove(id, ComicType.local);
      if (manifest.chapters.isEmpty) {
        try {
          const ComicStateRepository().removeLocalComicMirror(id);
        } catch (_) {}
        return true;
      }
      final chapters = <String, String>{
        for (final chapter in orderSavedChapters(manifest.chapters))
          // A chapter that saved no page at all is not readable and must not
          // appear in the reader's chapter list as an empty chapter.
          if (chapter.pages.isNotEmpty)
            chapter.directory: chapter.title.isEmpty
                ? chapter.chapterId
                : chapter.title,
      };
      await manager.add(
        LocalComic(
          id: id,
          title: manifest.title.isEmpty ? manifest.comicId : manifest.title,
          subtitle: ComicSource.find(manifest.sourceKey)?.name ?? '',
          tags: const [],
          // Absolute path: the library lives in the app data directory, not
          // under the user-relocatable local-comic root.
          directory: comicDirectory,
          chapters: ComicChapters(chapters),
          cover: kTranslatedLibraryCoverName,
          comicType: ComicType.local,
          downloadedChapters: chapters.keys.toList(),
          createdAt: DateTime.fromMillisecondsSinceEpoch(
            manifest.createdAt == 0 ? manifest.updatedAt : manifest.createdAt,
          ),
          description: 'AI translated pages saved from the reader'.tl,
        ),
      );
      return true;
    } catch (e, s) {
      Log.error('TranslatedLibrary', 'failed to register $id: $e', s);
      return false;
    }
  }

  Future<void> _writeManifest(
    String comicDirectory,
    SavedComicManifest manifest,
  ) async {
    final file = File(
      FilePath.join(comicDirectory, kTranslatedLibraryManifestName),
    );
    await file.writeAsString(jsonEncode(manifest.toJson()), flush: true);
  }

  /// The comic's cover is the first page of its first chapter, unless the user's
  /// original cover was already saved there.
  Future<void> _ensureCover(
    String comicDirectory,
    SavedComicManifest manifest,
  ) async {
    final cover = File(
      FilePath.join(comicDirectory, kTranslatedLibraryCoverName),
    );
    if (await cover.exists()) return;
    for (final chapter in manifest.chapters) {
      for (final page in chapter.pages) {
        final source = File(
          FilePath.join(comicDirectory, chapter.directory, page.file),
        );
        if (await source.exists()) {
          try {
            await source.copy(cover.path);
          } catch (e) {
            Log.warning('TranslatedLibrary', 'cover copy failed: $e');
          }
          return;
        }
      }
    }
  }

  Future<void> _deleteDirectory(Directory directory) async {
    try {
      if (await directory.exists()) {
        await directory.delete(recursive: true);
      }
    } catch (e, s) {
      Log.error(
        'TranslatedLibrary',
        'failed to delete ${directory.path}: $e',
        s,
      );
    }
  }

  /// Original bytes of one page: read from disk for a local comic, fetched (and
  /// usually served from the image cache) otherwise.
  Future<Uint8List?> _loadOriginalBytes(
    String imageKey,
    String? sourceKey,
    String comicId,
    String chapterId,
  ) async {
    if (imageKey.startsWith('file://')) {
      try {
        return await File(imageKey.substring(7)).readAsBytes();
      } catch (e) {
        Log.warning('TranslatedLibrary', 'unreadable local page $imageKey: $e');
        return null;
      }
    }
    try {
      Uint8List? bytes;
      final stream = ImageDownloader.loadComicImage(
        imageKey,
        sourceKey,
        comicId,
        chapterId,
      );
      await for (final event in stream.timeout(const Duration(minutes: 2))) {
        if (event.imageBytes != null) {
          bytes = event.imageBytes;
          break;
        }
      }
      return bytes;
    } catch (e) {
      Log.warning('TranslatedLibrary', 'page fetch failed for $imageKey: $e');
      return null;
    }
  }
}
