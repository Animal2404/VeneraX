part of 'components.dart';

class PaneItemEntry {
  String label;

  IconData icon;

  IconData activeIcon;

  /// Optional fixed id so tests and callers can identify an entry without
  /// depending on its position in the list.
  final Object? id;

  /// Optional custom activation. A selection-based entry switches the page
  /// slot at its own index; an entry given an [onTap] manages its content
  /// itself (the AI Translation entry pushes a sub-page over the current
  /// slot), and the bar only moves the selection highlight to it.
  final VoidCallback? onTap;

  PaneItemEntry({
    required this.label,
    required this.icon,
    required this.activeIcon,
    this.id,
    this.onTap,
  });
}

class PaneActionEntry {
  String label;

  IconData icon;

  VoidCallback onTap;

  PaneActionEntry({
    required this.label,
    required this.icon,
    required this.onTap,
  });
}

class NaviPane extends StatefulWidget {
  const NaviPane({
    required this.paneItems,
    required this.paneActions,
    required this.pageBuilder,
    this.initialPage = 0,
    this.onPageChanged,
    required this.observer,
    required this.navigatorKey,
    super.key,
  });

  final List<PaneItemEntry> paneItems;

  final List<PaneActionEntry> paneActions;

  final Widget Function(int page) pageBuilder;

  final void Function(int index)? onPageChanged;

  final int initialPage;

  final NaviObserver observer;

  final GlobalKey<NavigatorState> navigatorKey;

  @override
  State<NaviPane> createState() => NaviPaneState();

  static NaviPaneState of(BuildContext context) {
    return context.findAncestorStateOfType<NaviPaneState>()!;
  }
}

typedef NaviItemTapListener = void Function(int);

class NaviPaneState extends State<NaviPane>
    with SingleTickerProviderStateMixin {
  bool _canPop = true;

  late int _currentPage = widget.initialPage;

  /// The pane item currently shown as selected. Normally `null` (the current
  /// page slot owns the highlight); an entry with a custom
  /// [PaneItemEntry.onTap] (the AI Translation entry) owns it while the
  /// screen it pushed is on top, with the page slot staying put underneath.
  PaneItemEntry? _selectedEntry;

  /// The route the selected custom-tap entry pushed. It serves two purposes:
  /// a re-tap returns to this layer instead of pushing a second copy (the
  /// page-stacking defect), and the highlight falls back to the page slot as
  /// soon as the route leaves the observed stack, whoever popped it.
  Route<dynamic>? _selectedEntryRoute;

  /// Whether [entry] (rendered at [renderedIndex] on the calling surface) is
  /// highlighted. At most one item ever matches: while a custom-tap entry
  /// owns the highlight it owns it *exclusively* — the page slot underneath
  /// must not light up too (the double-highlight defect). Otherwise the
  /// regular entry whose rendered position owns the current slot is
  /// selected, which is the original index-based rule.
  bool isEntrySelected(PaneItemEntry entry, int renderedIndex) {
    final selected = _selectedEntry;
    if (selected != null) {
      return identical(selected, entry);
    }
    return renderedIndex == _currentPage;
  }

  /// Item tap from any navigation surface (compact sidebar, bottom bar,
  /// expanded side bar). Entries with a custom [PaneItemEntry.onTap] take
  /// over routing: the highlight moves to them and they push their own
  /// screen onto the observed navigator; everything else switches the page
  /// slot at [index].
  ///
  /// Re-tapping an already-selected custom entry never runs its action a
  /// second time — that unconditional re-push was the page-stacking defect.
  /// Instead the stack pops back to the route the entry first pushed, so the
  /// user returns to the layer that is already open, and rapid taps cannot
  /// stack copies (the first tap's push is synchronous, so the second tap
  /// already sees the route in place).
  void handleItemTap(int index, PaneItemEntry entry) {
    final action = entry.onTap;
    if (action == null) {
      updatePage(index);
      return;
    }
    final opened = _selectedEntryRoute;
    if (identical(_selectedEntry, entry) &&
        opened != null &&
        widget.observer.routes.contains(opened)) {
      widget.navigatorKey.currentState?.popUntil((route) => route == opened);
      return;
    }
    if (!identical(_selectedEntry, entry)) {
      setState(() => _selectedEntry = entry);
    }
    _selectedEntryRoute = null;
    action();
    // The action pushes its screen synchronously (Navigator.push notifies
    // didPush from within the same call), so the top of the observed stack
    // is the route this entry just opened. An action that pushes nothing
    // leaves the highlight on the entry with no route to return to; the
    // custom entries this bar ships with always push exactly one screen.
    final routes = widget.observer.routes;
    _selectedEntryRoute = routes.isEmpty ? null : routes.last;
  }

  /// Hands the selection highlight back to the current page slot after a
  /// custom-tap entry's pushed screen was popped (or replaced).
  void restoreSelection() {
    if (_selectedEntry == null && _selectedEntryRoute == null) return;
    _selectedEntryRoute = null;
    if (!mounted) return;
    setState(() => _selectedEntry = null);
    // The compact surfaces (bottom bar) live in the main view subtree, which
    // NaviPane's own setState does not rebuild.
    mainViewUpdateHandler?.call();
  }

  /// Schedules the highlight fallback when the observed stack changes: once
  /// the custom entry's route is gone (back button, gesture, popUntil), the
  /// page slot owns the highlight again without the entry's owner having to
  /// remember to call [restoreSelection]. Deferred to after the frame
  /// because observer notifications can arrive mid-history-flush, when a
  /// setState would be illegal.
  void _maybeRestoreSelectionAfterRouteChange() {
    final opened = _selectedEntryRoute;
    if (_selectedEntry == null ||
        opened == null ||
        widget.observer.routes.contains(opened)) {
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final route = _selectedEntryRoute;
      if (_selectedEntry != null &&
          route != null &&
          !widget.observer.routes.contains(route)) {
        restoreSelection();
      }
    });
  }

  int get currentPage => _currentPage;

  set currentPage(int value) {
    if (value == _currentPage) return;
    _currentPage = value;
    widget.onPageChanged?.call(value);
  }

  void Function()? mainViewUpdateHandler;

  late AnimationController controller;

  final _naviItemTapListeners = <NaviItemTapListener>[];

  void addNaviItemTapListener(NaviItemTapListener listener) {
    _naviItemTapListeners.add(listener);
  }

  void removeNaviItemTapListener(NaviItemTapListener listener) {
    _naviItemTapListeners.remove(listener);
  }

  // Leave enough room for the icon and its short navigation label.
  static const _kBottomBarHeight = 64.0;

  static const _kFoldedSideBarWidth = 72.0;

  static const _kSideBarWidth = 224.0;

  static const _kTopBarHeight = 48.0;

  double get bottomBarHeight =>
      _kBottomBarHeight + MediaQuery.paddingOf(context).bottom;

  void onNavigatorStateChange() {
    _maybeRestoreSelectionAfterRouteChange();
    onRebuild(context);
  }

  void updatePage(int index) {
    for (var listener in _naviItemTapListeners) {
      listener(index);
    }
    if (widget.observer.routes.length > 1) {
      widget.navigatorKey.currentState!.popUntil((route) => route.isFirst);
    }
    // Any custom-tap highlight (AI Translation) ends as soon as a page slot
    // switches; its pushed screen was just popped by popUntil above.
    final wasCustom = _selectedEntry != null;
    if (currentPage == index && !wasCustom) {
      return;
    }
    setState(() {
      currentPage = index;
      if (wasCustom) {
        _selectedEntry = null;
        _selectedEntryRoute = null;
      }
    });
    mainViewUpdateHandler?.call();
  }

  @override
  void initState() {
    controller = AnimationController(
      duration: const Duration(milliseconds: 250),
      lowerBound: 0,
      upperBound: 3,
      vsync: this,
    );
    widget.observer.addListener(onNavigatorStateChange);
    super.initState();
  }

  @override
  void dispose() {
    controller.dispose();
    widget.observer.removeListener(onNavigatorStateChange);
    super.dispose();
  }

  double targetFormContext(BuildContext context) {
    var width = MediaQuery.sizeOf(context).width;
    double target = 0;
    if (width > changePoint) {
      target = 2;
    }
    if (width > changePoint2) {
      target = 3;
    }
    return target;
  }

  double? animationTarget;

  void onRebuild(BuildContext context) {
    double target = targetFormContext(context);
    if (controller.value != target || animationTarget != target) {
      if (controller.isAnimating) {
        if (animationTarget == target) {
          return;
        } else {
          controller.stop();
        }
      }
      controller.animateTo(target);
      animationTarget = target;
    }
  }

  @override
  Widget build(BuildContext context) {
    onRebuild(context);
    // Aspect-scoped reads: the shell must not rebuild on every keyboard
    // inset frame (#107), so avoid a full MediaQuery.of subscription here.
    final sideInsets =
        (App.isMobile &&
            MediaQuery.orientationOf(context) == Orientation.landscape)
        ? EdgeInsets.only(
            left: math.max(
              MediaQuery.viewPaddingOf(context).left,
              MediaQuery.systemGestureInsetsOf(context).left,
            ),
            right: math.max(
              MediaQuery.viewPaddingOf(context).right,
              MediaQuery.systemGestureInsetsOf(context).right,
            ),
          )
        : EdgeInsets.zero;
    return _NaviPopScope(
      action: () {
        if (App.mainNavigatorKey!.currentState!.canPop()) {
          App.mainNavigatorKey!.currentState!.maybePop();
        } else {
          SystemNavigator.pop();
        }
      },
      popGesture: App.isIOS && context.width >= changePoint,
      child: AnimatedBuilder(
        animation: controller,
        builder: (context, child) {
          final value = controller.value;
          Widget content = Stack(
            children: [
              Positioned(
                left: _kFoldedSideBarWidth * ((value - 2.0).clamp(-1.0, 0.0)),
                top: 0,
                bottom: 0,
                child: buildLeft(),
              ),
              Positioned.fill(
                left:
                    _kFoldedSideBarWidth * ((value - 1).clamp(0, 1)) +
                    (_kSideBarWidth - _kFoldedSideBarWidth) *
                        ((value - 2).clamp(0, 1)),
                child: buildMainView(),
              ),
            ],
          );
          if (sideInsets != EdgeInsets.zero) {
            content = Padding(padding: sideInsets, child: content);
          }
          return content;
        },
      ),
    );
  }

  Widget buildMainView() {
    return HeroControllerScope(
      controller: MaterialApp.createMaterialHeroController(),
      child: PopScope(
        canPop: _canPop,
        onPopInvokedWithResult: (didPop, result) {
          if (didPop) {
            return;
          }
          widget.navigatorKey.currentState?.maybePop(result);
        },
        child: NotificationListener<NavigationNotification>(
          onNotification: (NavigationNotification notification) {
            final bool nextCanPop = !notification.canHandlePop;
            if (nextCanPop != _canPop) {
              setState(() {
                _canPop = nextCanPop;
              });
            }
            return false;
          },
          child: Navigator(
            observers: [widget.observer],
            key: widget.navigatorKey,
            onGenerateRoute: (settings) => AppPageRoute(
              preventRebuild: false,
              builder: (context) {
                return _NaviMainView(state: this);
              },
            ),
          ),
        ),
      ),
    );
  }

  Widget buildMainViewContent() {
    return widget.pageBuilder(currentPage);
  }

  Widget buildTop() {
    return Material(
      child: Container(
        padding: const EdgeInsets.only(left: 16, right: 16),
        height: _kTopBarHeight,
        width: double.infinity,
        child: Row(
          children: [
            Text(
              widget.paneItems[currentPage].label,
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
            const Spacer(),
            for (var action in widget.paneActions)
              Tooltip(
                message: action.label,
                child: IconButton(
                  icon: Icon(action.icon),
                  onPressed: action.onTap,
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget buildBottom() {
    return Material(
      textStyle: Theme.of(context).textTheme.labelSmall,
      elevation: 0,
      child: Container(
        height: _kBottomBarHeight,
        decoration: BoxDecoration(
          border: Border(
            top: BorderSide(
              color: Theme.of(context).colorScheme.outlineVariant,
              width: 1,
            ),
          ),
        ),
        child: Row(
          children: List<Widget>.generate(widget.paneItems.length, (index) {
            return Expanded(
              child: _SingleBottomNaviWidget(
                enabled: isEntrySelected(widget.paneItems[index], index),
                entry: widget.paneItems[index],
                onTap: () {
                  handleItemTap(index, widget.paneItems[index]);
                },
                key: ValueKey(index),
              ),
            );
          }),
        ),
      ),
    );
  }

  Widget buildAppLogo({double size = 32}) {
    return ClipOval(
      child: Image.asset(
        LauncherIconService.current.inAppLogoAsset,
        width: size,
        height: size,
        fit: BoxFit.cover,
      ),
    );
  }

  Widget buildLeft() {
    final value = controller.value;
    const paddingHorizontal = 12.0;
    return Material(
      child: Container(
        width:
            _kFoldedSideBarWidth +
            (_kSideBarWidth - _kFoldedSideBarWidth) * ((value - 2).clamp(0, 1)),
        height: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: paddingHorizontal),
        decoration: BoxDecoration(
          border: Border(
            right: BorderSide(
              color: Theme.of(context).colorScheme.outlineVariant,
              width: 1.0,
            ),
          ),
        ),
        child: Column(
          children: [
            // Align the logo block with the main view's search bar: mirror the
            // search bar's top margin (8) and height (mobile 52 / desktop 46)
            // so the logo's vertical center lines up with the search box across
            // the divider. Keep these in sync with `_SearchBar` in home_page.dart.
            const SizedBox(height: 8),
            SizedBox(height: MediaQuery.paddingOf(context).top),
            SizedBox(
              height: App.isMobile ? 52 : 46,
              child: Material(
                color: Colors.transparent,
                borderRadius: BorderRadius.circular(8),
                child: InkWell(
                  borderRadius: BorderRadius.circular(8),
                  onTap: () => updatePage(0),
                  child: value == 3
                      ? Row(
                          children: [
                            const SizedBox(width: 8),
                            buildAppLogo(),
                            const SizedBox(width: 10),
                            // Flexible + ellipsis: the wordmark is the only
                            // elastic child of a row that lives inside a fixed
                            // 224 px side bar. With a wider glyph set (the
                            // test font, a large textScaler, or a translated
                            // label) the intrinsic width exceeded the bar and
                            // the row painted "RenderFlex overflowed by 6.8
                            // pixels" instead of a readable label.
                            const Flexible(
                              child: Text(
                                'VeneraX',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: 22,
                                  fontWeight: FontWeight.w800,
                                ),
                              ),
                            ),
                          ],
                        )
                      : Center(child: buildAppLogo()),
                ),
              ),
            ),
            const SizedBox(height: 8),
            Expanded(child: buildLeftScrollable(value)),
          ],
        ),
      ),
    );
  }

  /// Builds the scrollable body of the side bar (nav items + actions).
  ///
  /// Uses the "scroll only when overflowing" pattern: the content fills the
  /// available height (keeping the actions pinned to the bottom via [Spacer])
  /// when there is room, but becomes scrollable in constrained heights such as
  /// landscape on phones, where it would otherwise overflow and be unreachable.
  Widget buildLeftScrollable(double value) {
    return LayoutBuilder(
      builder: (context, constraints) {
        return SingleChildScrollView(
          child: ConstrainedBox(
            constraints: BoxConstraints(minHeight: constraints.maxHeight),
            child: IntrinsicHeight(
              child: Column(
                children: [
                  ...List<Widget>.generate(
                    widget.paneItems.length,
                    (index) => _SideNaviWidget(
                      enabled: isEntrySelected(widget.paneItems[index], index),
                      entry: widget.paneItems[index],
                      showTitle: value == 3,
                      onTap: () {
                        handleItemTap(index, widget.paneItems[index]);
                      },
                      key: ValueKey(index),
                    ),
                  ),
                  const Spacer(),
                  ...List<Widget>.generate(
                    widget.paneActions.length,
                    (index) => _PaneActionWidget(
                      entry: widget.paneActions[index],
                      showTitle: value == 3,
                      key: ValueKey(index + widget.paneItems.length),
                    ),
                  ),
                  const SizedBox(height: 16),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

class _SideNaviWidget extends StatelessWidget {
  const _SideNaviWidget({
    required this.enabled,
    required this.entry,
    required this.onTap,
    required this.showTitle,
    super.key,
  });

  final bool enabled;

  final PaneItemEntry entry;

  final VoidCallback onTap;

  final bool showTitle;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final icon = Icon(enabled ? entry.activeIcon : entry.icon);
    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: onTap,
      // The side bar is the navigation surface that stays visible next to a
      // screen a custom-tap entry pushed, so it has to carry the same
      // selection semantics the bottom-bar row already does
      // (`_SingleBottomNaviWidget`). Without `selected`, "which row is the
      // current one" is a colour only — and the compact surface that would
      // have answered it is offstage underneath the pushed opaque route.
      // No `label` here: the visible Text is the label whenever the bar is
      // expanded, and a second copy would be announced twice.
      child: Semantics(
        button: true,
        selected: enabled,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          padding: const EdgeInsets.symmetric(horizontal: 12),
          height: 38,
          decoration: BoxDecoration(
            color: enabled ? colorScheme.primaryContainer : null,
            borderRadius: BorderRadius.circular(12),
          ),
          child: showTitle
              ? Row(
                  children: [
                    icon,
                    const SizedBox(width: 12),
                    // Same reason as the wordmark above: a long localized
                    // label ("AI Translation (experimental)") must ellipsize
                    // inside the 224 px bar instead of overflowing it.
                    Flexible(
                      child: Text(
                        entry.label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                )
              : Align(alignment: Alignment.centerLeft, child: icon),
        ),
      ),
    ).paddingVertical(4);
  }
}

class _PaneActionWidget extends StatelessWidget {
  const _PaneActionWidget({
    required this.entry,
    required this.showTitle,
    super.key,
  });

  final PaneActionEntry entry;

  final bool showTitle;

  @override
  Widget build(BuildContext context) {
    final icon = Icon(entry.icon);
    return InkWell(
      onTap: entry.onTap,
      borderRadius: BorderRadius.circular(12),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        padding: const EdgeInsets.symmetric(horizontal: 12),
        height: 38,
        child: showTitle
            ? Row(
                children: [
                  icon,
                  const SizedBox(width: 12),
                  // Elastic like the nav rows: a long action label must not
                  // overflow the fixed-width side bar.
                  Flexible(
                    child: Text(
                      entry.label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              )
            : Align(alignment: Alignment.centerLeft, child: icon),
      ),
    ).paddingVertical(4);
  }
}

class _SingleBottomNaviWidget extends StatefulWidget {
  const _SingleBottomNaviWidget({
    required this.enabled,
    required this.entry,
    required this.onTap,
    super.key,
  });

  final bool enabled;

  final PaneItemEntry entry;

  final VoidCallback onTap;

  @override
  State<_SingleBottomNaviWidget> createState() =>
      _SingleBottomNaviWidgetState();
}

class _SingleBottomNaviWidgetState extends State<_SingleBottomNaviWidget>
    with SingleTickerProviderStateMixin {
  late AnimationController controller;

  bool isHovering = false;

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant _SingleBottomNaviWidget oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.enabled != widget.enabled) {
      if (widget.enabled) {
        controller.forward(from: 0);
      } else {
        controller.reverse(from: 1);
      }
    }
  }

  @override
  void initState() {
    super.initState();
    controller = AnimationController(
      value: widget.enabled ? 1 : 0,
      vsync: this,
      duration: _fastAnimationDuration,
    );
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: CurvedAnimation(parent: controller, curve: Curves.ease),
      builder: (context, child) {
        return MouseRegion(
          cursor: SystemMouseCursors.click,
          onEnter: (details) => setState(() => isHovering = true),
          onExit: (details) => setState(() => isHovering = false),
          child: GestureDetector(
            behavior: HitTestBehavior.translucent,
            onTap: widget.onTap,
            child: buildContent(),
          ),
        );
      },
    );
  }

  Widget buildContent() {
    final value = controller.value;
    final colorScheme = Theme.of(context).colorScheme;
    final icon = Icon(
      widget.enabled ? widget.entry.activeIcon : widget.entry.icon,
    );
    final iconSlot = SizedBox(
      height: 30,
      child: Container(
        width: 64,
        decoration: BoxDecoration(
          borderRadius: const BorderRadius.all(Radius.circular(12)),
          color: isHovering ? colorScheme.surfaceContainer : Colors.transparent,
        ),
        child: Center(
          child: Container(
            width: 32 + value * 32,
            height: 28,
            decoration: BoxDecoration(
              borderRadius: const BorderRadius.all(Radius.circular(12)),
              color: value != 0
                  ? colorScheme.secondaryContainer
                  : Colors.transparent,
            ),
            child: Center(child: icon),
          ),
        ),
      ),
    );
    final content = Center(child: iconSlot);
    return Semantics(
      button: true,
      label: widget.entry.label,
      selected: widget.enabled,
      child: Tooltip(
        message: widget.entry.label,
        child: SizedBox(width: double.infinity, height: 52, child: content),
      ),
    );
  }
}

class NaviObserver extends NavigatorObserver implements Listenable {
  var routes = Queue<Route>();

  int get pageCount {
    int count = 0;
    for (var route in routes) {
      if (route is AppPageRoute) {
        count++;
      }
    }
    return count;
  }

  @override
  void didPop(Route route, Route? previousRoute) {
    routes.removeLast();
    notifyListeners();
  }

  @override
  void didPush(Route route, Route? previousRoute) {
    routes.addLast(route);
    notifyListeners();
  }

  @override
  void didRemove(Route route, Route? previousRoute) {
    routes.remove(route);
    notifyListeners();
  }

  @override
  void didReplace({Route? newRoute, Route? oldRoute}) {
    routes.remove(oldRoute);
    if (newRoute != null) {
      routes.add(newRoute);
    }
    notifyListeners();
  }

  List<VoidCallback> listeners = [];

  @override
  void addListener(VoidCallback listener) {
    listeners.add(listener);
  }

  @override
  void removeListener(VoidCallback listener) {
    listeners.remove(listener);
  }

  void notifyListeners() {
    for (var listener in listeners) {
      listener();
    }
  }
}

class _NaviPopScope extends StatelessWidget {
  const _NaviPopScope({
    required this.child,
    this.popGesture = false,
    required this.action,
  });

  final Widget child;
  final bool popGesture;
  final VoidCallback action;

  static bool panStartAtEdge = false;

  @override
  Widget build(BuildContext context) {
    Widget res = child;
    if (popGesture) {
      res = GestureDetector(
        onPanStart: (details) {
          if (details.globalPosition.dx < 64) {
            panStartAtEdge = true;
          }
        },
        onPanEnd: (details) {
          if (details.velocity.pixelsPerSecond.dx < 0 ||
              details.velocity.pixelsPerSecond.dx > 0) {
            if (panStartAtEdge) {
              action();
            }
          }
          panStartAtEdge = false;
        },
        child: res,
      );
    }
    return res;
  }
}

class _NaviMainView extends StatefulWidget {
  const _NaviMainView({required this.state});

  final NaviPaneState state;

  @override
  State<_NaviMainView> createState() => _NaviMainViewState();
}

class _NaviMainViewState extends State<_NaviMainView> {
  NaviPaneState get state => widget.state;

  @override
  void initState() {
    state.mainViewUpdateHandler = () {
      setState(() {});
    };
    super.initState();
  }

  @override
  Widget build(BuildContext context) {
    var shouldShowAppBar = state.controller.value < 2;
    return Column(
      children: [
        if (shouldShowAppBar) state.buildTop().paddingTop(context.padding.top),
        Expanded(
          child: MediaQuery.removePadding(
            context: context,
            removeTop: shouldShowAppBar,
            // Keep the page slot tight to the main pane width.  The default
            // AnimatedSwitcher layout is intentionally intrinsic/centered;
            // without an explicit width constraint a page whose content has a
            // natural max width can leave a large unused area on wide desktop
            // windows (the home feed is the most visible example).
            child: SizedBox.expand(
              child: AnimatedSwitcher(
                duration: _fastAnimationDuration,
                child: state.buildMainViewContent(),
              ),
            ),
          ),
        ),
        if (shouldShowAppBar)
          state.buildBottom().paddingBottom(context.padding.bottom),
      ],
    );
  }
}
