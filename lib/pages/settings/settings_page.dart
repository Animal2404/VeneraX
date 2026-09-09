import 'dart:convert';
import 'dart:async';
import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_reorderable_grid_view/widgets/reorderable_builder.dart';
import 'package:url_launcher/url_launcher_string.dart';
import 'package:uuid/uuid.dart';
import 'package:venera/components/components.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/battery_optimization.dart';
import 'package:venera/foundation/cache_manager.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/consts.dart';
import 'package:venera/foundation/download_network_guard.dart';
import 'package:venera/foundation/favorites.dart';
import 'package:venera/foundation/home_layout.dart';
import 'package:venera/foundation/image_enhance_shader.dart';
import 'package:venera/foundation/image_translation/llm_translator.dart';
import 'package:venera/foundation/image_translation/ort_capabilities.dart';
import 'package:venera/foundation/image_translation/pre_translation_tasks.dart';
import 'package:venera/foundation/image_translation/process_diagnostics.dart';
import 'package:venera/foundation/image_translation/translation_config.dart';
import 'package:venera/foundation/image_translation/translation_models.dart';
import 'package:venera/foundation/image_translation/translation_performance_config.dart';
import 'package:venera/foundation/image_translation/translation_service.dart';
import 'package:venera/foundation/image_translation/translation_worker.dart';
import 'package:venera/foundation/import_tasks.dart';
import 'package:venera/foundation/js_engine.dart';
import 'package:venera/foundation/launcher_icon.dart';
import 'package:venera/foundation/local.dart';
import 'package:venera/foundation/log.dart';
import 'package:venera/foundation/tray.dart';
import 'package:venera/network/app_dio.dart';
import 'package:venera/pages/app_lock_setup.dart';
import 'package:venera/pages/disclaimer.dart';
import 'package:venera/pages/guide_page.dart';
import 'package:venera/pages/settings/sync_config_qr.dart';
import 'package:venera/pages/webdav_libraries_page.dart';
import 'package:venera/utils/app_lock.dart';
import 'package:venera/utils/data.dart';
import 'package:venera/utils/data_sync.dart';
import 'package:venera/utils/io.dart';
import 'package:venera/utils/platform_abi.dart';
import 'package:venera/utils/sync_config_transfer.dart';
import 'package:venera/utils/translations.dart';

part 'reader.dart';
part 'translation_models_settings.dart';
part 'translation_diagnostics_page.dart';
part 'llm_providers_settings.dart';
part 'explore_settings.dart';
part 'setting_components.dart';
part 'launcher_icon_settings.dart';
part 'home_layout.dart';
part 'local_favorites.dart';
part 'app.dart';
part 'data_sync.dart';
part 'about.dart';
part 'network.dart';
part 'debug.dart';
part 'settings_search.dart';

/// Settings category display names, indexed by page id. Top-level so the
/// settings search index ([_settingsSearchIndex]) can map a result back to its
/// category page. Keep in sync with [_settingsCategoryIcons] and the page
/// switch in [_SettingsPageState._buildSettingsContent].
const _settingsCategories = <String>[
  "App",
  "Reading settings",
  "Local Favorites",
  "Data & Sync",
  "Explore",
  "Network",
  "Debug",
  "About",
];

const _settingsCategoryIcons = <IconData>[
  Icons.apps,
  Icons.book,
  Icons.collections_bookmark_rounded,
  Icons.cloud_sync_outlined,
  Icons.explore,
  Icons.public,
  Icons.bug_report,
  Icons.info,
];

class SettingsPage extends StatefulWidget {
  const SettingsPage({
    this.initialPage = -1,
    this.autoExpandGroupKey,
    super.key,
  });

  final int initialPage;

  /// Index of the "Reading settings" category in [_settingsCategories].
  /// Public so a deep link (the AI Translation sidebar entry) does not have
  /// to hard-code the position.
  static const readingSettingsIndex = 1;

  /// PageStorage id of a `_SettingsExpansionTile` inside the [initialPage]
  /// category. When set, that group is expanded and scrolled into view once,
  /// shortly after the page opens — the same "open at an anchor" behavior
  /// [GuidePage] gives its document sections, applied to a settings group.
  /// A null value (every other current caller) changes nothing.
  final String? autoExpandGroupKey;

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  int currentPage = -1;

  ColorScheme get colors => Theme.of(context).colorScheme;

  bool get enableTwoViews => context.width > 720;

  final _searchController = TextEditingController();

  String _searchQuery = "";

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  void initState() {
    currentPage = widget.initialPage;
    if (widget.autoExpandGroupKey != null && widget.initialPage >= 0) {
      // Single-view (narrow) layouts show the category list first; a deep
      // link opens its category exactly the way tapping the row would, and
      // the detail page then runs the group reveal. Two-view layouts already
      // show the category on the right, where buildRight reveals it.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && !enableTwoViews) {
          _openSettingsCategory(widget.initialPage);
        }
      });
    }
    super.initState();
  }

  @override
  Widget build(BuildContext context) {
    return Material(child: buildBody());
  }

  Widget buildBody() {
    if (enableTwoViews) {
      return Row(
        children: [
          SizedBox(width: 280, height: double.infinity, child: buildLeft()),
          Container(
            height: double.infinity,
            decoration: BoxDecoration(
              border: Border(
                left: BorderSide(
                  color: context.colorScheme.outlineVariant,
                  width: 0.6,
                ),
              ),
            ),
          ),
          Expanded(
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 200),
              transitionBuilder: (child, animation) {
                return LayoutBuilder(
                  builder: (context, constrains) {
                    return AnimatedBuilder(
                      animation: animation,
                      builder: (context, _) {
                        var width = constrains.maxWidth;
                        var value = animation.isForwardOrCompleted
                            ? 1 - animation.value
                            : 1;
                        var left = width * value;
                        return Stack(
                          children: [
                            Positioned(
                              top: 0,
                              bottom: 0,
                              left: left,
                              width: width,
                              child: child,
                            ),
                          ],
                        );
                      },
                    );
                  },
                );
              },
              child: buildRight(),
            ),
          ),
        ],
      );
    } else {
      return buildLeft();
    }
  }

  Widget buildLeft() {
    return Material(
      child: Column(
        children: [
          SizedBox(height: MediaQuery.of(context).padding.top),
          SizedBox(
            height: 56,
            child: Row(
              children: [
                const SizedBox(width: 8),
                Tooltip(
                  message: "Back",
                  child: IconButton(
                    icon: const Icon(Icons.arrow_back),
                    onPressed: context.pop,
                  ),
                ),
                const SizedBox(width: 24),
                Text("Settings".tl, style: ts.s20),
              ],
            ),
          ),
          const SizedBox(height: 4),
          buildSearchField(),
          Expanded(
            child: _searchQuery.trim().isEmpty
                ? buildCategories()
                : _buildSettingsSearchResults(
                    context,
                    _searchQuery,
                    _openSettingsCategory,
                  ),
          ),
        ],
      ),
    );
  }

  Widget buildSearchField() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
      child: AppSearchField(
        controller: _searchController,
        hintText: "Search settings".tl,
        onChanged: (v) => setState(() => _searchQuery = v),
      ),
    );
  }

  void _openSettingsCategory(int id) {
    if (enableTwoViews) {
      setState(() => currentPage = id);
    } else {
      context.to(
        () => _SettingsDetailPage(
          pageIndex: id,
          // Only the deep-linked category carries the reveal request; a row
          // the user tapped normally behaves exactly as before.
          revealGroupKey:
              id == widget.initialPage ? widget.autoExpandGroupKey : null,
        ),
      );
    }
  }

  Widget buildCategories() {
    Widget buildItem(String name, int id) {
      final bool selected = id == currentPage;

      Widget content = AnimatedContainer(
        key: ValueKey(id),
        duration: const Duration(milliseconds: 200),
        width: double.infinity,
        height: 46,
        padding: const EdgeInsets.fromLTRB(12, 0, 12, 0),
        decoration: BoxDecoration(
          color: selected ? colors.primaryContainer.toOpacity(0.36) : null,
          border: Border(
            left: BorderSide(
              color: selected ? colors.primary : Colors.transparent,
              width: 2,
            ),
          ),
        ),
        child: Row(
          children: [
            Icon(_settingsCategoryIcons[id]),
            const SizedBox(width: 16),
            Expanded(
              child: Text(name, style: ts.s16, overflow: TextOverflow.ellipsis),
            ),
            if (selected) const Icon(Icons.arrow_right),
          ],
        ),
      );

      return Padding(
        padding: enableTwoViews
            ? const EdgeInsets.fromLTRB(8, 0, 8, 0)
            : EdgeInsets.zero,
        child: InkWell(
          onTap: () => _openSettingsCategory(id),
          child: content,
        ).paddingVertical(4),
      );
    }

    return ListView.builder(
      padding: EdgeInsets.zero,
      itemCount: _settingsCategories.length,
      itemBuilder: (context, index) =>
          buildItem(_settingsCategories[index].tl, index),
    );
  }

  Widget buildRight() {
    if (currentPage == -1) {
      return const SizedBox();
    }
    return Navigator(
      onGenerateRoute: (settings) {
        return PageRouteBuilder(
          pageBuilder: (context, animation, secondaryAnimation) {
            Widget content = _buildSettingsContent(currentPage);
            final groupKey = widget.autoExpandGroupKey;
            // Only the deep-linked category can hold the group; reveal it on
            // landing. Any other category renders untouched.
            if (groupKey != null && currentPage == widget.initialPage) {
              content = _RevealExpansionGroup(groupKey: groupKey, child: content);
            }
            return content;
          },
          transitionDuration: Duration.zero,
        );
      },
    );
  }

  Widget _buildSettingsContent(int pageIndex) {
    return switch (pageIndex) {
      0 => const AppSettings(),
      1 => const ReaderSettings(),
      2 => const LocalFavoritesSettings(),
      3 => const DataSyncSettings(),
      4 => const ExploreSettings(),
      5 => const NetworkSettings(),
      6 => const DebugPage(),
      7 => const AboutSettings(),
      _ => throw UnimplementedError(),
    };
  }
}

class _SettingsDetailPage extends StatelessWidget {
  const _SettingsDetailPage({
    required this.pageIndex,
    this.revealGroupKey,
  });

  final int pageIndex;

  /// PageStorage id of a collapsible group to expand on open; see
  /// [SettingsPage.autoExpandGroupKey].
  final String? revealGroupKey;

  @override
  Widget build(BuildContext context) {
    Widget content = Material(child: _buildPage());
    final groupKey = revealGroupKey;
    if (groupKey != null) {
      content = _RevealExpansionGroup(groupKey: groupKey, child: content);
    }
    return content;
  }

  Widget _buildPage() {
    return switch (pageIndex) {
      0 => const AppSettings(),
      1 => const ReaderSettings(),
      2 => const LocalFavoritesSettings(),
      3 => const DataSyncSettings(),
      4 => const ExploreSettings(),
      5 => const NetworkSettings(),
      6 => const DebugPage(),
      7 => const AboutSettings(),
      _ => throw UnimplementedError(),
    };
  }
}

/// One-shot "open at an anchor" for a collapsible settings group, mirroring
/// the pattern [GuidePage] uses for document anchors: after this subtree has
/// produced a frame, the `_SettingsExpansionTile` whose `PageStorageKey`
/// matches [groupKey] is expanded through its public `ExpansibleController`
/// and scrolled into view.
///
/// It exists because the groups are declared inside `part 'reader.dart'` and
/// own their expansion state — the page hosting them can only reach them
/// through the widget tree. If nothing matches (a renamed group, a different
/// category) this widget gives up after a few frames and leaves the page
/// exactly as it was: a reveal request is a convenience, never a crash.
class _RevealExpansionGroup extends StatefulWidget {
  const _RevealExpansionGroup({required this.groupKey, required this.child});

  final String groupKey;

  final Widget child;

  @override
  State<_RevealExpansionGroup> createState() => _RevealExpansionGroupState();
}

class _RevealExpansionGroupState extends State<_RevealExpansionGroup> {
  /// Frames to keep searching before giving up. The deep-linked category may
  /// be mounted a frame or two after this widget itself (the narrow layout
  /// pushes its detail page from a post-frame callback).
  static const _maxFrames = 10;

  bool _revealed = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _reveal(_maxFrames));
  }

  void _reveal(int framesLeft) {
    if (!mounted || _revealed) return;
    // A State's context *is* its Element; the walk needs Element.visitChildren.
    final tile = _findByKey(
      context as Element,
      PageStorageKey<String>(widget.groupKey),
    );
    if (tile == null) {
      if (framesLeft > 0) {
        WidgetsBinding.instance.addPostFrameCallback(
          (_) => _reveal(framesLeft - 1),
        );
      }
      return;
    }
    _revealed = true;
    // Expanding first means ensureVisible aims at the header while the body
    // unfolds under it, so the header stays where it was placed.
    _controllerOfTile(tile)?.expand();
    Scrollable.ensureVisible(
      tile,
      alignment: 0.05,
      duration: const Duration(milliseconds: 300),
    );
  }

  static Element? _findByKey(Element root, Key key) {
    Element? found;
    void visit(Element element) {
      if (found != null) return;
      if (element.widget.key == key) {
        found = element;
        return;
      }
      element.visitChildren(visit);
    }

    root.visitChildren(visit);
    return found;
  }

  /// An `ExpansionTile` builds an `Expansible` below itself and hands it its
  /// controller; `ExpansibleController.maybeOf` only resolves from a context
  /// the Expansible encloses, so the search starts one step under the tile.
  static ExpansibleController? _controllerOfTile(Element tile) {
    ExpansibleController? controller;
    void visit(Element element) {
      if (controller != null) return;
      controller = ExpansibleController.maybeOf(element);
      if (controller == null) {
        element.visitChildren(visit);
      }
    }

    tile.visitChildren(visit);
    return controller;
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
