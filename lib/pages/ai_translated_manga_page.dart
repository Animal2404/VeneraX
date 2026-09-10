import 'dart:async';

import 'package:flutter/material.dart';
import 'package:venera/components/components.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/comic_type.dart';
import 'package:venera/foundation/history.dart';
import 'package:venera/foundation/image_translation/translated_library.dart';
import 'package:venera/foundation/image_translation/translation_config.dart';
import 'package:venera/foundation/image_translation/translation_models.dart';
import 'package:venera/foundation/image_translation/translation_types.dart';
import 'package:venera/foundation/local.dart';
import 'package:venera/foundation/source_platform.dart';
import 'package:venera/pages/comic_details_page/comic_page.dart';
import 'package:venera/pages/local_comics_page.dart' show openComicFolder;
import 'package:venera/pages/reader/reader.dart';
import 'package:venera/utils/translations.dart';

/// The sidebar's "AI Translated Manga" section (plan §15).
///
/// A view over [TranslatedLibrary]'s manifests — *not* over the whole local
/// library: the comics the user saved from the reader are registered as local
/// comics (that is how they are read back offline), but this section shows only
/// the ones this app saved translated pages for, and each row is the saved
/// chapter list rather than the source comic's chapter list.
class AiTranslatedMangaPage extends StatefulWidget {
  const AiTranslatedMangaPage({super.key});

  /// Stable [PaneItemEntry.id] for the sidebar entry; testable without
  /// depending on the entry's position in the list.
  static const sidebarEntryId = 'ai-translated-manga';

  @override
  State<AiTranslatedMangaPage> createState() => _AiTranslatedMangaPageState();
}

class _AiTranslatedMangaPageState extends State<AiTranslatedMangaPage> {
  final library = TranslatedLibrary();

  bool loading = true;

  @override
  void initState() {
    super.initState();
    library.addListener(_reload);
    unawaited(_load());
  }

  @override
  void dispose() {
    library.removeListener(_reload);
    super.dispose();
  }

  void _reload() {
    if (mounted) setState(() {});
  }

  Future<void> _load() async {
    await library.refresh();
    if (mounted) setState(() => loading = false);
  }

  /// The grid item for one saved comic.
  ///
  /// Its source key is the canonical local one, so the shared cover provider
  /// resolves `cover.png` through the registered [LocalComic] (see
  /// `buildComicImageProvider`) instead of trying to fetch anything.
  Comic _asComic(SavedComic saved) {
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

  LocalComic? _localComic(SavedComic saved) {
    final manager = LocalManager();
    if (!manager.isInitialized) return null;
    return manager.find(saved.id, ComicType.local);
  }

  void _openComic(SavedComic saved) {
    context.to(() => SavedMangaChaptersPage(comic: saved, library: library));
  }

  void _openDetails(SavedComic saved) {
    context.to(
      () => ComicPage(
        id: saved.id,
        sourceKey: SourcePlatformResolver.localCanonicalKey,
        title: saved.title,
      ),
    );
  }

  void _deleteComic(SavedComic saved) {
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
    final comics = library.comics;
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
          else if (comics.isEmpty)
            const SliverFillRemaining(
              hasScrollBody: false,
              child: _EmptyLibraryHint(),
            )
          else
            SliverGridComics(
              comics: [for (final saved in comics) _asComic(saved)],
              enableHero: false,
              badgeBuilder: (comic) {
                final saved = _savedFor(comic.id);
                if (saved == null) return null;
                return '@count chapters'.tlParams({
                  'count': saved.manifest.chapters.length,
                });
              },
              onTap: (comic, _) {
                final saved = _savedFor(comic.id);
                if (saved == null) return;
                _openComic(saved);
              },
              menuBuilder: (comic) {
                final saved = _savedFor(comic.id);
                if (saved == null) return const [];
                return [
                  MenuEntry(
                    icon: Icons.info_outline_rounded,
                    text: 'Open comic details'.tl,
                    onClick: () => _openDetails(saved),
                  ),
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
                  MenuEntry(
                    icon: Icons.delete_outline_rounded,
                    text: 'Delete saved manga'.tl,
                    color: context.colorScheme.error,
                    onClick: () => _deleteComic(saved),
                  ),
                ];
              },
            ),
        ],
      ),
    );
  }

  SavedComic? _savedFor(String comicId) {
    for (final saved in library.comics) {
      if (saved.id == comicId) return saved;
    }
    return null;
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
              'No saved manga yet'.tl,
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            Text(
              'Read a chapter with translation on, then tap the save button in the reader top bar. Only the pages you save are written to disk.'
                  .tl,
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}

/// The saved chapter list of one comic: what was saved, when, and which of them
/// came from a different model set.
class SavedMangaChaptersPage extends StatefulWidget {
  const SavedMangaChaptersPage({
    super.key,
    required this.comic,
    required this.library,
  });

  final SavedComic comic;

  final TranslatedLibrary library;

  @override
  State<SavedMangaChaptersPage> createState() => _SavedMangaChaptersPageState();
}

class _SavedMangaChaptersPageState extends State<SavedMangaChaptersPage> {
  @override
  void initState() {
    super.initState();
    widget.library.addListener(_reload);
  }

  @override
  void dispose() {
    widget.library.removeListener(_reload);
    super.dispose();
  }

  void _reload() {
    if (mounted) setState(() {});
  }

  /// The manifest is re-read from the library so a deleted chapter disappears
  /// without popping the page.
  SavedComic get comic {
    for (final saved in widget.library.comics) {
      if (saved.id == widget.comic.id) return saved;
    }
    return widget.comic;
  }

  Future<void> _openChapter(int index) async {
    final saved = comic;
    // A `final` local: the row is used inside the route builder below, and a
    // variable that gets reassigned anywhere in this function loses its
    // non-null promotion there.
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
        initialChapter: index,
        history: history ?? History.fromModel(model: local, ep: 0, page: 0),
        author: local.subtitle,
        tags: local.tags,
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

  void _deleteChapter(SavedChapter chapter) {
    showConfirmDialog(
      context: context,
      title: 'Delete saved chapter?'.tl,
      content:
          'This deletes the saved images of this chapter only. The original comic, the stored translation and the OCR cache are not touched.'
              .tl,
      btnColor: context.colorScheme.error,
      onConfirm: () async {
        await widget.library.deleteChapter(comic, chapter);
        if (mounted) setState(() {});
      },
    );
  }

  bool _isStale(SavedChapter chapter) {
    final config = TranslationConfigCompat.of(comic.manifest);
    return isChapterStale(
      chapter,
      sourceLang: config.sourceLang,
      targetLang: config.targetLang,
      mode: config.mode,
      modelTier: config.modelTier,
    );
  }

  @override
  Widget build(BuildContext context) {
    final chapters = orderSavedChapters(comic.manifest.chapters);
    return Scaffold(
      body: SmoothCustomScrollView(
        scrollbarTopPadding: context.padding.top + 56,
        slivers: [
          SliverAppbar(title: Text(comic.title)),
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Text(
                '@chapters chapters · @pages pages'.tlParams({
                  'chapters': chapters.length,
                  'pages': comic.pageCount,
                }),
                style: ts.s14,
              ),
            ),
          ),
          SliverList.builder(
            itemCount: chapters.length,
            itemBuilder: (context, index) {
              final chapter = chapters[index];
              final parts = <String>[
                '@count pages'.tlParams({'count': chapter.pages.length}),
                if (chapter.translatedPages > 0)
                  '@count translated'.tlParams({'count': chapter.translatedPages}),
                if (chapter.originalPages > 0)
                  '@count original'.tlParams({'count': chapter.originalPages}),
                if (chapter.failedPages > 0)
                  '@count failed'.tlParams({'count': chapter.failedPages}),
              ];
              return ListTile(
                title: Text(
                  chapter.title.isEmpty ? chapter.chapterId : chapter.title,
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
                    if (_isStale(chapter))
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
                onTap: () => unawaited(_openChapter(index + 1)),
                trailing: IconButton(
                  tooltip: 'Delete'.tl,
                  icon: const Icon(Icons.delete_outline),
                  onPressed: () => _deleteChapter(chapter),
                ),
              );
            },
          ),
        ],
      ),
    );
  }
}

/// Reads back the settings a saved chapter was produced under.
///
/// The manifest records the settings *as they were at save time*; comparing
/// them with the current ones needs the current values, which live on the comic
/// in the reader-settings channel. This indirection exists so the staleness
/// check stays a pure function over the two.
class TranslationConfigCompat {
  const TranslationConfigCompat({
    required this.sourceLang,
    required this.targetLang,
    required this.mode,
    required this.modelTier,
  });

  final String sourceLang;
  final String targetLang;
  final InpaintMode mode;
  final String modelTier;

  static TranslationConfigCompat of(SavedComicManifest manifest) {
    final config = TranslationConfig.of(manifest.comicId, manifest.sourceKey);
    return TranslationConfigCompat(
      sourceLang: config.sourceLang,
      targetLang: config.targetLang,
      mode: config.mode,
      modelTier: TranslationModels.currentModelTier.name,
    );
  }
}
