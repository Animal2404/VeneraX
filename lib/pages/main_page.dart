import 'package:flutter/material.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/pages/categories_page.dart';
import 'package:venera/pages/comic_details_page/comic_page.dart';
import 'package:venera/pages/random_comic_draw_dialog.dart';
import 'package:venera/pages/search_page.dart';
import 'package:venera/pages/settings/settings_page.dart';
import 'package:venera/pages/tasks_page.dart';
import 'package:venera/utils/translations.dart';

import '../components/components.dart';
import '../foundation/app.dart';
import 'explore_page.dart';
import 'favorites/favorites_page.dart';
import 'home_page.dart';

class MainPage extends StatefulWidget {
  const MainPage({super.key});

  @override
  State<MainPage> createState() => _MainPageState();
}

class _MainPageState extends State<MainPage> {
  late final NaviObserver _observer;

  GlobalKey<NavigatorState>? _navigatorKey;

  void to(Widget Function() widget, {bool preventDuplicate = false}) async {
    if (preventDuplicate) {
      var page = widget();
      if ("/${page.runtimeType}" == _observer.routes.last.toString()) return;
    }
    _navigatorKey!.currentContext!.to(widget);
  }

  void back() {
    _navigatorKey!.currentContext!.pop();
  }

  @override
  void initState() {
    _observer = NaviObserver();
    _navigatorKey = GlobalKey();
    App.mainNavigatorKey = _navigatorKey;
    index = int.tryParse(appdata.settings['initialPage'].toString()) ?? 0;
    super.initState();
  }

  /// [PaneItemEntry.id] of the AI Translation entry below; tests and callers
  /// use it instead of positions, which shift when entries are inserted.
  static const aiTranslationEntryId = 'ai-translation';

  /// PageStorage id of the "AI Translation (experimental)" expansion group
  /// inside the Reading settings category (`part 'reader.dart'` declares it
  /// as a `_SettingsExpansionTile`). The sidebar entry asks [SettingsPage] to
  /// scroll to and expand exactly this group.
  static const _aiTranslationGroupKey = 'readerTranslationGroup';

  /// Opens the AI translation *parameters* — performance mode, pipeline mode,
  /// batch sizes, concurrency, inference backend — which live in the
  /// "AI Translation (experimental)" group of the Reading settings category.
  ///
  /// Landing directly on [TranslationModelsPage] (what this entry did first)
  /// only showed model download/validation, which is why the report read
  /// "nothing can be configured here": the model manager stays reachable as
  /// the group's own secondary entry ("Translation models" → "Manage").
  ///
  /// No page slot is taken; the routing dedup (a re-tap returns to the layer
  /// already open instead of pushing another copy) and the highlight
  /// lifecycle live in [NaviPaneState.handleItemTap].
  void _openTranslationSettings() {
    _navigatorKey!.currentContext!.to(
      () => SettingsPage(
        initialPage: SettingsPage.readingSettingsIndex,
        autoExpandGroupKey: _aiTranslationGroupKey,
      ),
    );
  }

  final _pages = [
    const HomePage(),
    const FavoritesPage(key: PageStorageKey('favorites')),
    const ExplorePage(key: PageStorageKey('explore')),
    const CategoriesPage(key: PageStorageKey('categories')),
  ];

  /// Built once (a `late` field initializer may tear off the instance
  /// methods) rather than per build: the AI Translation highlight is tracked
  /// by entry identity, and a per-build list handed every MainPage rebuild a
  /// fresh `PaneItemEntry` would silently orphan that selection.
  late final List<PaneItemEntry> _paneItems = [
    PaneItemEntry(
      label: 'Home'.tl,
      icon: Icons.home_outlined,
      activeIcon: Icons.home,
    ),
    PaneItemEntry(
      label: 'Favorites'.tl,
      icon: Icons.local_activity_outlined,
      activeIcon: Icons.local_activity,
    ),
    PaneItemEntry(
      label: 'Explore'.tl,
      icon: Icons.explore_outlined,
      activeIcon: Icons.explore,
    ),
    PaneItemEntry(
      label: 'Categories'.tl,
      icon: Icons.category_outlined,
      activeIcon: Icons.category,
    ),
    PaneItemEntry(
      id: aiTranslationEntryId,
      label: 'AI Translation (experimental)'.tl,
      icon: Icons.translate,
      activeIcon: Icons.translate,
      onTap: _openTranslationSettings,
    ),
  ];

  var index = 0;

  @override
  Widget build(BuildContext context) {
    return NaviPane(
      initialPage: index,
      observer: _observer,
      navigatorKey: _navigatorKey!,
      paneItems: _paneItems,
      onPageChanged: (i) {
        setState(() {
          index = i;
        });
      },
      paneActions: [
        if (index != 0)
          PaneActionEntry(
            icon: Icons.search,
            label: "Search".tl,
            onTap: () {
              to(() => const SearchPage(), preventDuplicate: true);
            },
          ),
        PaneActionEntry(
          icon: Icons.style_outlined,
          label: 'Draw a comic'.tl,
          onTap: () async {
            final comic = await showRandomComicDrawDialog(context);
            if (!mounted || comic == null) return;
            to(
              () => ComicPage(
                id: comic.id,
                sourceKey: comic.sourceKey,
                cover: comic.cover,
                title: comic.title,
              ),
            );
          },
        ),
        PaneActionEntry(
          icon: Icons.assignment_outlined,
          label: "Tasks".tl,
          onTap: () {
            to(() => const TasksPage(), preventDuplicate: true);
          },
        ),
        PaneActionEntry(
          icon: Icons.settings,
          label: "Settings".tl,
          onTap: () {
            to(() => const SettingsPage(), preventDuplicate: true);
          },
        ),
      ],
      pageBuilder: (index) {
        return _pages[index];
      },
    );
  }
}
