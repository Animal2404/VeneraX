// UNVERIFIED — written under a local `flutter test` ban; only
// `flutter analyze --no-pub` has run against this file. Cloud to-do:
//   flutter test test/navigation_bar_ai_entry_test.dart
// plus the regression pair:
//   flutter test test/navigation_bar_labels_test.dart
//   flutter test test/home_edit_back_gesture_test.dart
//
// Locks the two selection/routing defects of the sidebar AI-Translation
// entry (introduced in 1fc07be, fixed on top of it):
//   * Defect 1: while a custom-tap entry owns the highlight, the current
//     page slot stayed highlighted too — two purple rows at once.
//   * Defect 2: every re-tap re-ran the entry's action, which pushes —
//     screens stacked layer over layer.
// The wiring mirrors lib/pages/main_page.dart: a custom-tap entry whose
// action pushes a screen onto the observed navigator without taking a page
// slot; regular items keep the original index-based slot behaviour.
//
// Width notes: 400 px renders the compact surfaces (off-screen folded side
// bar + bottom bar) that navigation_bar_labels_test.dart also uses; 1400 px
// renders the expanded side bar, which stays visible *next to* the pushed
// screen — so re-taps happen there, the way the user re-taps the real
// sidebar while the AI screen is open.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera/components/components.dart';

void main() {
  const aiScreenLabel = 'Translation screen';
  const deeperScreenLabel = 'Deeper screen';

  Future<NaviObserver> pumpBar(
    WidgetTester tester, {
    required List<PaneItemEntry> items,
    required GlobalKey<NavigatorState> nav,
    GlobalKey<NaviPaneState>? stateKey,
    double width = 400,
  }) async {
    tester.view.physicalSize = Size(width, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final observer = NaviObserver();
    await tester.pumpWidget(
      MaterialApp(
        home: NaviPane(
          key: stateKey,
          paneItems: items,
          paneActions: const [],
          pageBuilder: (index) => Center(child: Text('Page $index')),
          observer: observer,
          navigatorKey: nav,
        ),
      ),
    );
    await tester.pumpAndSettle();
    return observer;
  }

  /// A custom entry that behaves like main_page's AI Translation one: its
  /// action pushes its own screen onto the navigator NaviPane owns, instead
  /// of taking a page slot.
  PaneItemEntry aiEntry(GlobalKey<NavigatorState> nav) => PaneItemEntry(
    id: 'ai-translation',
    label: 'AI',
    icon: Icons.translate,
    activeIcon: Icons.translate,
    onTap: () {
      nav.currentState!.push(
        MaterialPageRoute(
          builder: (_) =>
              const Scaffold(body: Center(child: Text(aiScreenLabel))),
        ),
      );
    },
  );

  PaneItemEntry regular(String label, IconData icon, IconData active) =>
      PaneItemEntry(label: label, icon: icon, activeIcon: active);

  /// Number of *rendered* pane rows currently showing the selected state.
  /// `_SideNaviWidget` is private to navigation_bar.dart, but `enabled` is a
  /// public member, so the dynamic read observes what is painted — not just
  /// the state's own opinion. The side bar is built at every width (only its
  /// position animates), so this counts on both surfaces' shared selection.
  int renderedSelectedCount(WidgetTester tester) {
    var count = 0;
    for (final widget in tester.widgetList(
      find.byWidgetPredicate(
        (widget) => widget.runtimeType.toString() == '_SideNaviWidget',
      ),
    )) {
      if ((widget as dynamic).enabled == true) count++;
    }
    return count;
  }

  Future<void> tapAiCompact(WidgetTester tester) async {
    // `.last` hits the bottom-bar instance at compact width (same convention
    // as navigation_bar_labels_test.dart); the folded side-bar copy sits
    // off-screen underneath.
    await tester.tap(find.byIcon(Icons.translate).last);
    await tester.pumpAndSettle();
  }

  Future<void> tapAiSidebar(WidgetTester tester) async {
    // Expanded side bar (1400 px): the AI row keeps its label visible next to
    // the pushed screen, exactly where the user re-taps it in production.
    await tester.tap(find.text('AI'));
    await tester.pumpAndSettle();
  }

  testWidgets('defect 1: the AI entry highlights alone, not on top of the '
      'page slot', (tester) async {
    final nav = GlobalKey<NavigatorState>();
    final home = regular('Home', Icons.home_outlined, Icons.home);
    final ai = aiEntry(nav);
    final stateKey = GlobalKey<NaviPaneState>();
    await pumpBar(
      tester,
      items: [home, ai],
      nav: nav,
      stateKey: stateKey,
    );

    // Before the tap the page slot owns the single highlight.
    expect(renderedSelectedCount(tester), 1);
    expect(stateKey.currentState!.isEntrySelected(home, 0), isTrue);
    expect(stateKey.currentState!.isEntrySelected(ai, 1), isFalse);

    await tapAiCompact(tester);

    // The pushed screen is up, and it is highlighted *alone*: the old code
    // kept 'Home' lit underneath (the two purple rows in the screenshot).
    expect(find.text(aiScreenLabel), findsOneWidget);
    expect(renderedSelectedCount(tester), 1);
    expect(stateKey.currentState!.isEntrySelected(ai, 1), isTrue);
    expect(stateKey.currentState!.isEntrySelected(home, 0), isFalse);

    // Same rule on the bottom-bar surface: its Semantics nodes carry
    // `selected`, so count them there too.
    final selectedButtons = tester
        .widgetList<Semantics>(
          find.byWidgetPredicate(
            (widget) =>
                widget is Semantics &&
                widget.properties.button == true &&
                widget.properties.selected == true,
          ),
        )
        .length;
    expect(selectedButtons, 1);
  });

  testWidgets('defect 2: repeated and rapid taps keep exactly one layer; '
      'a re-tap never pushes a copy', (tester) async {
    final nav = GlobalKey<NavigatorState>();
    final home = regular('Home', Icons.home_outlined, Icons.home);
    final ai = aiEntry(nav);
    final observer = await pumpBar(
      tester,
      items: [home, ai],
      nav: nav,
      width: 1400,
    );

    // Only the initial main-view route is on the observed stack.
    expect(observer.routes.length, 1);

    await tapAiSidebar(tester);
    expect(observer.routes.length, 2);

    // A deliberate second tap must NOT push a copy.
    await tapAiSidebar(tester);
    expect(observer.routes.length, 2);
    expect(find.text(aiScreenLabel), findsOneWidget);

    // Rapid double tap with only a pump between — no settle, no extra layer
    // (the first tap's push is synchronous, so the second already sees it).
    await tester.tap(find.text('AI'));
    await tester.pump();
    await tester.tap(find.text('AI'));
    await tester.pumpAndSettle();
    expect(observer.routes.length, 2);
    expect(find.text(aiScreenLabel), findsOneWidget);
  });

  testWidgets('defect 2 follow-up: with deeper pages above it, a re-tap '
      'pops back to the entry layer and the highlight stays unique', (
    tester,
  ) async {
    final nav = GlobalKey<NavigatorState>();
    final home = regular('Home', Icons.home_outlined, Icons.home);
    final ai = aiEntry(nav);
    final observer = await pumpBar(
      tester,
      items: [home, ai],
      nav: nav,
      width: 1400,
    );

    await tapAiSidebar(tester);
    // Simulate the opened screen pushing its own secondary entry (the model
    // manager inside the AI translation group is exactly such a sub-page).
    nav.currentState!.push(
      MaterialPageRoute(
        builder: (_) =>
            const Scaffold(body: Center(child: Text(deeperScreenLabel))),
      ),
    );
    await tester.pumpAndSettle();
    expect(observer.routes.length, 3);
    // Even buried one level down, the entry owns exactly one highlight.
    expect(renderedSelectedCount(tester), 1);

    await tapAiSidebar(tester);
    // Back on the entry's own layer: the deeper page is gone and no new copy
    // was pushed.
    expect(observer.routes.length, 2);
    expect(find.text(deeperScreenLabel), findsNothing);
    expect(find.text(aiScreenLabel), findsOneWidget);
    expect(renderedSelectedCount(tester), 1);
  });

  testWidgets('popping the opened screen hands the highlight back to the '
      'page slot without caller cooperation', (tester) async {
    final nav = GlobalKey<NavigatorState>();
    final home = regular('Home', Icons.home_outlined, Icons.home);
    final ai = aiEntry(nav);
    final stateKey = GlobalKey<NaviPaneState>();
    await pumpBar(
      tester,
      items: [home, ai],
      nav: nav,
      stateKey: stateKey,
      width: 1400,
    );

    await tapAiSidebar(tester);
    expect(stateKey.currentState!.isEntrySelected(ai, 1), isTrue);

    nav.currentState!.pop();
    await tester.pumpAndSettle();

    expect(stateKey.currentState!.isEntrySelected(ai, 1), isFalse);
    expect(stateKey.currentState!.isEntrySelected(home, 0), isTrue);
    expect(renderedSelectedCount(tester), 1);
  });

  testWidgets('regular items are untouched: tapping a slot switches pages, '
      'pops the pushed screen and reclaims the single highlight', (
    tester,
  ) async {
    final nav = GlobalKey<NavigatorState>();
    final home = regular('Home', Icons.home_outlined, Icons.home);
    final favs = regular('Favorites', Icons.star_outline, Icons.star);
    final ai = aiEntry(nav);
    final observer = await pumpBar(
      tester,
      items: [home, favs, ai],
      nav: nav,
      width: 1400,
    );

    await tapAiSidebar(tester);
    expect(observer.routes.length, 2);

    await tester.tap(find.text('Favorites'));
    await tester.pumpAndSettle();
    expect(find.text('Page 1'), findsOneWidget);
    expect(find.text(aiScreenLabel), findsNothing);
    expect(observer.routes.length, 1);
    expect(renderedSelectedCount(tester), 1);
  });
}
