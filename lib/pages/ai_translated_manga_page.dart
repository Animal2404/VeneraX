import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:venera/components/components.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/comic_type.dart';
import 'package:venera/foundation/history.dart';
import 'package:venera/foundation/image_translation/translated_library.dart';
import 'package:venera/foundation/image_translation/translation_config.dart';
import 'package:venera/foundation/image_translation/translation_models.dart';
import 'package:venera/foundation/image_translation/translation_service.dart';
import 'package:venera/foundation/image_translation/translation_store.dart';
import 'package:venera/foundation/local.dart';
import 'package:venera/foundation/log.dart';
import 'package:venera/foundation/source_platform.dart';
import 'package:venera/pages/comic_details_page/comic_page.dart';
import 'package:venera/pages/local_comics_page.dart' show openComicFolder;
import 'package:venera/pages/reader/reader.dart';
import 'package:venera/pages/translated_comics_page.dart'
    show hydrateTranslatedComicMetadata;
import 'package:venera/utils/translations.dart';

/// The sidebar's "AI Translated Manga" section (plan §15).
///
/// It lists a comic when **either** half of the feature knows about it:
///
///  * it has stored translations (the durable per-page text index) — the user
///    translated it, and that is what they expect to find here. The section
///    used to show *only* comics whose pages had been explicitly saved to disk,
///    which read as a bug: "我已经翻译完了，这里为什么没有显示" while the task
///    list said 100%;
///  * its pages were saved (`translated_manga/<comic>/…` + manifest), which is
///    what makes a chapter readable offline.
///
/// A row says which of the two it is, and the chapter list offers "保存本章"
/// for a translated chapter that has not been saved yet — there the page keys
/// are resolved from the local library or the comic source, exactly as the
/// pre-translation sweep resolves them.
class AiTranslatedMangaPage extends StatefulWidget {
  const AiTranslatedMangaPage({super.key});

  /// Stable [PaneItemEntry.id] for the sidebar entry; testable without
  /// depending on the entry's position in the list.
  static const sidebarEntryId = 'ai-translated-manga';

  @override
  State<AiTranslatedMangaPage> createState() => _AiTranslatedMangaPageState();
}

/// One comic in the section: translations, saved pages, or both.
class TranslatedMangaEntry {
  const TranslatedMangaEntry({
    required this.sourceKey,
    required this.comicId,
    required this.title,
    required this.cover,
    this.translated,
    this.saved,
  });

  final String sourceKey;
  final String comicId;
  final String title;
  final String cover;

  /// Present when the durable translation index has chapters for this comic.
  final StoredTranslationComic? translated;

  /// Present when saved pages exist on disk.
  final SavedComic? saved;

  bool get isSaved => saved != null;

  String get titleOrId => title.isEmpty ? comicId : title;

  int get updatedAt => math.max(
    translated?.updatedAt.millisecondsSinceEpoch ?? 0,
    saved?.manifest.updatedAt ?? 0,
  );

  static String keyOf(String sourceKey, String comicId) =>
      '$sourceKey\u0000$comicId';
}

class _AiTranslatedMangaPageState extends State<AiTranslatedMangaPage> {
  final library = TranslatedLibrary();

  bool loading = true;

  /// The merged list, computed outside `build`.
  ///
  /// [ImageTranslationService.translatedComics] runs a synchronous SQLite
  /// SELECT, so reading it per grid item (what a naive `entryFor(comic)` does)
  /// would both break the project's "no IO in build" rule and go quadratic in
  /// the number of comics. Rebuilt on library changes and, throttled, on
  /// translation-service changes.
  List<TranslatedMangaEntry> _entries = const [];

  DateTime _entriesBuiltAt = DateTime.fromMillisecondsSinceEpoch(0);

  static const _entriesThrottle = Duration(seconds: 2);

  @override
  void initState() {
    super.initState();
    library.addListener(_onLibraryChanged);
    ImageTranslationService.instance.addListener(_onTranslationsChanged);
    unawaited(_load());
  }

  @override
  void dispose() {
    library.removeListener(_onLibraryChanged);
    ImageTranslationService.instance.removeListener(_onTranslationsChanged);
    super.dispose();
  }

  void _onLibraryChanged() {
    if (!mounted) return;
    setState(() => _refreshEntries(force: true));
  }

  /// The service notifies per translated page, which is far more often than the
  /// set of comics can change — hence the throttle.
  void _onTranslationsChanged() {
    if (!mounted) return;
    final now = DateTime.now();
    if (now.difference(_entriesBuiltAt) < _entriesThrottle) return;
    setState(() => _refreshEntries());
  }

  Future<void> _load() async {
    await library.refresh();
    if (mounted) setState(() => loading = false);
    _refreshEntries(force: true);
    // Titles and covers for comics the index only knows by id: the index is
    // filled from page keys, so a comic translated elsewhere can arrive here
    // without a name. Best-effort, and it persists what it finds.
    try {
      await hydrateTranslatedComicMetadata();
    } catch (e) {
      Log.warning('TranslatedLibrary', 'metadata hydration failed: $e');
    }
    if (mounted) setState(() => _refreshEntries(force: true));
  }

  void _refreshEntries({bool force = false}) {
    final now = DateTime.now();
    if (!force && now.difference(_entriesBuiltAt) < _entriesThrottle) return;
    final byKey = <String, TranslatedMangaEntry>{};
    for (final saved in library.comics) {
      final key = TranslatedMangaEntry.keyOf(
        saved.manifest.sourceKey,
        saved.manifest.comicId,
      );
      byKey[key] = TranslatedMangaEntry(
        sourceKey: saved.manifest.sourceKey,
        comicId: saved.manifest.comicId,
        title: saved.title,
        cover: saved.manifest.comicId,
        saved: saved,
      );
    }
    for (final stored in ImageTranslationService.translatedComics) {
      final key = TranslatedMangaEntry.keyOf(stored.sourceKey, stored.comicId);
      final existing = byKey[key];
      byKey[key] = TranslatedMangaEntry(
        sourceKey: stored.sourceKey,
        comicId: stored.comicId,
        title: (existing?.title.isNotEmpty ?? false)
            ? existing!.title
            : stored.title,
        cover: stored.cover.isNotEmpty ? stored.cover : (existing?.cover ?? ''),
        translated: stored,
        saved: existing?.saved,
      );
    }
    final list = byKey.values.toList()
      ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    _entries = list;
    _entriesBuiltAt = now;
  }

  LocalComic? _localComic(SavedComic saved) {
    final manager = LocalManager();
    if (!manager.isInitialized) return null;
    return manager.find(saved.id, ComicType.local);
  }

  /// The grid item for one entry.
  ///
  /// A saved comic is a [LocalComic] (`sourceKey` = local) so the shared cover
  /// provider reads `cover.png` from disk; one that only has translations keeps
  /// its real source and cover, so the normal cover path applies.
  Comic _asComic(TranslatedMangaEntry entry) {
    final saved = entry.saved;
    if (saved != null) {
      final local = _localComic(saved);
      return Comic(
        saved.title,
        local?.cover ?? kTranslatedLibraryCoverName,
        saved.id,
        local?.subtitle ?? '',
        const [],
        'AI translated pages saved from the reader'.tl,
        SourcePlatformResolver.localCanonicalKey,
        null,
        null,
      );
    }
    final source = ComicSource.find(entry.sourceKey);
    return Comic(
      entry.titleOrId,
      entry.cover,
      entry.comicId,
      source?.name,
      const [],
      '',
      entry.sourceKey,
      null,
      null,
    );
  }

  void _openEntry(TranslatedMangaEntry entry) {
    context.to(
      () => TranslatedMangaChaptersPage(entry: entry, library: library),
    );
  }

  void _openDetails(TranslatedMangaEntry entry) {
    final saved = entry.saved;
    context.to(
      () => ComicPage(
        id: saved?.id ?? entry.comicId,
        sourceKey: saved != null
            ? SourcePlatformResolver.localCanonicalKey
            : entry.sourceKey,
        title: entry.titleOrId,
      ),
    );
  }

  void _deleteComic(TranslatedMangaEntry entry) {
    final saved = entry.saved;
    if (saved == null) return;
    showConfirmDialog(
      context: context,
      title: 'Delete saved manga?'.tl,
      content:
          'This deletes the saved images of this comic. The original comic, the stored translations and the OCR cache are not touched.'
              .tl,
      btnColor: context.colorScheme.error,
      onConfirm: () async {
        await library.deleteComic(saved);
        if (mounted) setState(() {});
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final items = _entries;
    final byComicId = <String, TranslatedMangaEntry>{
      for (final entry in items)
        if (entry.saved != null) entry.saved!.id: entry,
      for (final entry in items)
        if (entry.saved == null) entry.comicId: entry,
    };
    return Scaffold(
      body: SmoothCustomScrollView(
        scrollbarTopPadding: context.padding.top + 56,
        slivers: [
          SliverAppbar(title: Text('AI Translated Manga'.tl)),
          if (loading)
            const SliverFillRemaining(
              hasScrollBody: false,
              child: Center(child: CircularProgressIndicator()),
            )
          else if (items.isEmpty)
            const SliverFillRemaining(
              hasScrollBody: false,
              child: _EmptyLibraryHint(),
            )
          else
            SliverGridComics(
              comics: [for (final entry in items) _asComic(entry)],
              enableHero: false,
              badgeBuilder: (comic) {
                final entry = byComicId[comic.id];
                if (entry == null) return null;
                if (entry.isSaved) {
                  return 'Saved @count chapters'.tlParams({
                    'count': entry.saved!.manifest.chapters.length,
                  });
                }
                return 'Translated @count chapters'.tlParams({
                  'count': entry.translated?.chapterCount ?? 0,
                });
              },
              onTap: (comic, _) {
                final entry = byComicId[comic.id];
                if (entry == null) return;
                _openEntry(entry);
              },
              menuBuilder: (comic) {
                final entry = byComicId[comic.id];
                if (entry == null) return const [];
                final saved = entry.saved;
                return [
                  MenuEntry(
                    icon: Icons.info_outline_rounded,
                    text: 'Open comic details'.tl,
                    onClick: () => _openDetails(entry),
                  ),
                  if (saved != null)
                    MenuEntry(
                      icon: Icons.folder_open,
                      text: 'Open Folder'.tl,
                      onClick: () {
                        final local = _localComic(saved);
                        if (local != null) {
                          unawaited(openComicFolder(local));
                        }
                      },
                    ),
                  if (saved != null)
                    MenuEntry(
                      icon: Icons.delete_outline_rounded,
                      text: 'Delete saved manga'.tl,
                      color: context.colorScheme.error,
                      onClick: () => _deleteComic(entry),
                    ),
                ];
              },
            ),
        ],
      ),
    );
  }

}

class _EmptyLibraryHint extends StatelessWidget {
  const _EmptyLibraryHint();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.translate, size: 48),
            const SizedBox(height: 12),
            Text(
              'No translated comics yet'.tl,
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            Text(
              'Translated comics show up here automatically. Tap the save button in the reader top bar to keep a chapter on disk.'
                  .tl,
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}

/// One chapter of an entry, as the list shows it.
class TranslatedMangaChapterRow {
  const TranslatedMangaChapterRow({
    required this.chapterId,
    required this.title,
    required this.translatedPages,
    this.saved,
  });

  final String chapterId;
  final String title;

  /// Pages the durable store holds for this chapter (0 when unknown).
  final int translatedPages;

  /// The manifest chapter when those pages are saved to disk.
  final SavedChapter? saved;

  bool get isSaved => saved != null;
}

/// The chapter list of one comic: translated, saved, or both.
class TranslatedMangaChaptersPage extends StatefulWidget {
  const TranslatedMangaChaptersPage({
    super.key,
    required this.entry,
    required this.library,
  });

  final TranslatedMangaEntry entry;

  final TranslatedLibrary library;

  @override
  State<TranslatedMangaChaptersPage> createState() =>
      _TranslatedMangaChaptersPageState();
}

class _TranslatedMangaChaptersPageState
    extends State<TranslatedMangaChaptersPage> {
  /// Chapter currently being saved, so its row can show progress and a second
  /// tap cannot start a second copy.
  String? savingChapterId;

  /// The merged chapter list, computed outside `build`: its translated half
  /// comes from a synchronous SQLite index, which the project's "no IO in
  /// build" rule keeps out of the widget path.
  List<TranslatedMangaChapterRow> _rows = const [];

  @override
  void initState() {
    super.initState();
    widget.library.addListener(_reload);
    _refreshRows();
  }

  @override
  void dispose() {
    widget.library.removeListener(_reload);
    super.dispose();
  }

  void _reload() {
    if (!mounted) return;
    setState(_refreshRows);
  }

  /// The entry as the library knows it *now* — a save or a delete performed
  /// from this page must show up without popping it.
  TranslatedMangaEntry get entry {
    for (final saved in widget.library.comics) {
      if (saved.manifest.comicId == widget.entry.comicId &&
          saved.manifest.sourceKey == widget.entry.sourceKey) {
        return TranslatedMangaEntry(
          sourceKey: widget.entry.sourceKey,
          comicId: widget.entry.comicId,
          title: widget.entry.title,
          cover: widget.entry.cover,
          translated: widget.entry.translated,
          saved: saved,
        );
      }
    }
    return TranslatedMangaEntry(
      sourceKey: widget.entry.sourceKey,
      comicId: widget.entry.comicId,
      title: widget.entry.title,
      cover: widget.entry.cover,
      translated: widget.entry.translated,
    );
  }

  /// Translated chapters ∪ saved chapters, in reading order.
  void _refreshRows() {
    final current = entry;
    final rows = <String, TranslatedMangaChapterRow>{};
    final stored = current.translated;
    if (stored != null) {
      final translated = TranslationStore().chaptersFor(
        stored.sourceKey,
        stored.comicId,
        sourceLang: stored.sourceLang,
        targetLang: stored.targetLang,
      );
      for (final chapter in translated) {
        rows[chapter.identity.chapterId] = TranslatedMangaChapterRow(
          chapterId: chapter.identity.chapterId,
          title: chapter.identity.chapterTitle,
          translatedPages: chapter.pageCount,
        );
      }
    }
    for (final chapter in orderSavedChapters(
      current.saved?.manifest.chapters ?? const [],
    )) {
      final existing = rows[chapter.chapterId];
      rows[chapter.chapterId] = TranslatedMangaChapterRow(
        chapterId: chapter.chapterId,
        title: existing != null && existing.title.isNotEmpty
            ? existing.title
            : chapter.title,
        translatedPages: math.max(
          existing?.translatedPages ?? 0,
          chapter.translatedPages,
        ),
        saved: chapter,
      );
    }
    _rows = rows.values.toList();
  }

  bool _isStale(SavedChapter chapter) {
    final config = TranslationConfig.of(entry.comicId, entry.sourceKey);
    return isChapterStale(
      chapter,
      sourceLang: config.sourceLang,
      targetLang: config.targetLang,
      mode: config.mode,
      modelTier: TranslationModels.currentModelTier.name,
    );
  }

  Future<void> _openChapter(TranslatedMangaChapterRow row) async {
    final current = entry;
    final saved = current.saved;
    final savedChapter = row.saved;
    if (saved != null && savedChapter != null) {
      final index = saved.manifest.chapters.indexOf(savedChapter) + 1;
      final local = await _resolveLocalComic(saved);
      if (!mounted) return;
      if (local == null) {
        context.showMessage(message: 'Cannot open saved manga'.tl);
        return;
      }
      final history = HistoryManager().isInitialized
          ? HistoryManager().find(local.id, ComicType.local)
          : null;
      context.to(
        () => Reader(
          type: ComicType.local,
          cid: local.id,
          name: local.title,
          chapters: local.chapters,
          initialChapter: index < 1 ? 1 : index,
          history: history ?? History.fromModel(model: local, ep: 0, page: 0),
          author: local.subtitle,
          tags: local.tags,
        ),
      );
      return;
    }
    // Not saved: the ordinary comic path reads it (translating on demand), so
    // this section never becomes a second reader with its own rules.
    context.to(
      () => ComicPage(
        id: current.comicId,
        sourceKey: current.sourceKey,
        cover: current.cover,
        title: current.titleOrId,
      ),
    );
  }

  /// The registered local comic for [saved], re-registering it first when the
  /// row is missing. The manifest is the source of truth; the row is derived
  /// from it and can be lost with the local library.
  Future<LocalComic?> _resolveLocalComic(SavedComic saved) async {
    final manager = LocalManager();
    if (!manager.isInitialized) return null;
    final existing = manager.find(saved.id, ComicType.local);
    if (existing != null) return existing;
    await widget.library.registerAsLocalComic(saved.manifest, saved.directory);
    return manager.find(saved.id, ComicType.local);
  }

  Future<void> _saveChapter(TranslatedMangaChapterRow row) async {
    if (savingChapterId != null) return;
    final current = entry;
    final config = TranslationConfig.of(current.comicId, current.sourceKey);
    setState(() => savingChapterId = row.chapterId);
    try {
      final outcome = await widget.library.saveChapterFromSource(
        comicId: current.comicId,
        sourceKey: current.sourceKey,
        chapterId: row.chapterId,
        comicTitle: current.titleOrId,
        chapterTitle: row.title,
        config: config,
        comicType: ComicType.fromKey(current.sourceKey),
      );
      if (!mounted) return;
      context.showMessage(message: describeSaveOutcome(outcome));
    } catch (e, s) {
      Log.error('TranslatedLibrary', 'saving from the library failed: $e', s);
      if (mounted) {
        context.showMessage(message: 'Saving failed'.tl);
      }
    } finally {
      if (mounted) setState(() => savingChapterId = null);
    }
  }

  void _deleteChapter(SavedChapter chapter) {
    final saved = entry.saved;
    if (saved == null) return;
    showConfirmDialog(
      context: context,
      title: 'Delete saved chapter?'.tl,
      content:
          'This deletes the saved images of this chapter only. The original comic, the stored translation and the OCR cache are not touched.'
              .tl,
      btnColor: context.colorScheme.error,
      onConfirm: () async {
        await widget.library.deleteChapter(saved, chapter);
        if (mounted) setState(_refreshRows);
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final current = entry;
    final rows = _rows;
    final savedChapters = current.saved?.manifest.chapters.length ?? 0;
    return Scaffold(
      body: SmoothCustomScrollView(
        scrollbarTopPadding: context.padding.top + 56,
        slivers: [
          SliverAppbar(title: Text(current.titleOrId)),
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Text(
                savedChapters > 0
                    ? '@chapters chapters · @saved saved'.tlParams({
                        'chapters': rows.length,
                        'saved': savedChapters,
                      })
                    : '@chapters chapters'.tlParams({'chapters': rows.length}),
                style: ts.s14,
              ),
            ),
          ),
          SliverList.builder(
            itemCount: rows.length,
            itemBuilder: (context, index) {
              final row = rows[index];
              final parts = <String>[
                if (row.translatedPages > 0)
                  '@count pages translated'.tlParams({
                    'count': row.translatedPages,
                  }),
                if (row.saved != null)
                  '@count pages saved'.tlParams({
                    'count': row.saved!.pages.length,
                  })
                else
                  'Not saved'.tl,
                if (row.saved != null && row.saved!.failedPages > 0)
                  '@count failed'.tlParams({'count': row.saved!.failedPages}),
              ];
              final saving = savingChapterId == row.chapterId;
              return ListTile(
                title: Text(
                  row.title.isEmpty ? row.chapterId : row.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                subtitle: Row(
                  children: [
                    Flexible(
                      child: Text(
                        parts.join(' · '),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    if (row.saved != null && _isStale(row.saved!))
                      Padding(
                        padding: const EdgeInsets.only(left: 8),
                        child: Text(
                          'Saved with an older model'.tl,
                          style: TextStyle(
                            color: context.colorScheme.error,
                            fontSize: 12,
                          ),
                        ),
                      ),
                  ],
                ),
                onTap: () => unawaited(_openChapter(row)),
                trailing: saving
                    ? const Padding(
                        padding: EdgeInsets.symmetric(horizontal: 12),
                        child: SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                      )
                    : row.isSaved
                    ? IconButton(
                        tooltip: 'Delete'.tl,
                        icon: const Icon(Icons.delete_outline),
                        onPressed: () => _deleteChapter(row.saved!),
                      )
                    : IconButton(
                        tooltip: 'Save this chapter'.tl,
                        icon: const Icon(Icons.save_alt),
                        onPressed: () => unawaited(_saveChapter(row)),
                      ),
              );
            },
          ),
        ],
      ),
    );
  }
}
