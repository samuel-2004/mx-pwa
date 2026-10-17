import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../auth/auth_scope.dart';
import '../auth/auth_state.dart';
import '../orient_ui/nav_bar.dart';
import '../orient_ui/tappable_icon.dart';
import '../router/routes.dart';
import '../widgets/surface_card.dart';

const double _minPageSide = 50;
const double _maxContentWidth = 900;
const double _floatingButtonInset = 16;

class _Destination {
  const _Destination(this.label, this.icon, this.path);

  final String label;
  final IconData icon;
  final String path;
}

/// Shared page template for signed-in routes: app bar, role-aware navigation
/// (bottom bar on narrow screens, side rail on wide ones, switched by
/// [NavBar] at the Orient UI desktop breakpoint) and a centered,
/// width-limited content area.
///
/// Screens use this instead of [Scaffold] and pass only their own content.
/// To add a destination, add it to `_destinationsFor`.
class AppScaffold extends StatelessWidget {
  const AppScaffold({
    required this.title,
    required this.body,
    this.actions = const <Widget>[],
    this.floatingActionButton,
    super.key,
  });

  /// Shown in the app bar.
  final String title;

  /// The page content.
  final Widget body;

  /// Extra app bar actions, shown before the shared ones.
  final List<Widget> actions;

  /// Optional button floating at the bottom right of the content area.
  final Widget? floatingActionButton;

  // Mirrors the route guards. The server must enforce the same rules.
  List<_Destination> _destinationsFor(AuthState auth) {
    final bool isStaff = auth.isAdmin || auth.isSubsectionAdmin;
    return <_Destination>[
      if (!auth.isSubsectionAdmin) const _Destination('Activities', Icons.list_alt, Routes.activities),
      const _Destination('Scoreboard', Icons.leaderboard, Routes.scoreboard),
      if (isStaff) const _Destination('Grading', Icons.grading, Routes.grading),
      if (auth.isAdmin) const _Destination('Users', Icons.group, Routes.users),
      if (auth.isAdmin)
        const _Destination('Game', Icons.tune, Routes.gameSettings),
      const _Destination('Settings', Icons.settings_outlined, Routes.settings),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final AuthState auth = AuthScope.of(context);
    final List<_Destination> destinations = _destinationsFor(auth);
    final String path = GoRouterState.of(context).uri.path;
    final int found = destinations.indexWhere(
      (_Destination d) => path == d.path || path.startsWith('${d.path}/'),
    );
    final int selected = found < 0 ? 0 : found;
    // NavBar asserts that it has at least two items.
    final bool showNav = destinations.length >= 2;

    final Widget? floatingButton = floatingActionButton;
    // NavBar owns the bottom bar, so Scaffold's own floating button slot
    // would sit on top of it. Placing the button inside the content area
    // keeps it clear of the bar.
    final Widget content = Stack(
      fit: StackFit.expand,
      children: <Widget>[
        Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: _maxContentWidth),
            child: body,
          ),
        ),
        if (floatingButton != null)
          Positioned(
            right: _floatingButtonInset,
            bottom: _floatingButtonInset,
            child: floatingButton,
          ),
      ],
    );

    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        // A resize can briefly hand the page a ~1x1 box.
        return Offstage(
          offstage: constraints.biggest.shortestSide < _minPageSide,
          child: Scaffold(
            backgroundColor: pageBackground(context),
            appBar: AppBar(
              title: Text(title),
              actions: <Widget>[
                ...actions,
                if (kDebugMode)
                  TappableIcon(
                    icon: const Icon(Icons.bug_report_outlined),
                    tooltip: 'Diagnostics',
                    onPressed: () => context.go(Routes.diagnostics),
                  ),
                if (kDebugMode)
                const SizedBox(width: 8),
              ],
            ),
            body: showNav
                ? NavBar(
                    currentIndex: selected,
                    onTap: (int index) => context.go(destinations[index].path),
                    items: <NavBarItem>[
                      for (final _Destination d in destinations)
                        NavBarItem(icon: Icon(d.icon), label: d.label),
                    ],
                    railFooterIndex: destinations.length - 1,
                    body: content,
                  )
                : content,
          ),
        );
      }
    );
  }
}
