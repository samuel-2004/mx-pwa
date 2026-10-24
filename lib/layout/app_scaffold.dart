import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollDirection;
import 'package:go_router/go_router.dart';

import '../auth/auth_scope.dart';
import '../auth/auth_state.dart';
import '../orient_ui/nav_bar.dart';
import '../orient_ui/style.dart';
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
/// width-limited content area by default.
///
/// Screens use this instead of [Scaffold] and pass only their own content.
/// To add a destination, add it to `_destinationsFor`.
class AppScaffold extends StatelessWidget {
  const AppScaffold({
    required this.title,
    required this.body,
    this.actions = const <Widget>[],
    this.floatingActionButton,
    this.smallScreenAction,
    this.fullWidthBody = false,
    super.key,
  });

  /// Shown in the app bar.
  final String title;

  /// The page content.
  final Widget body;

  /// Extra app bar actions, shown before the shared ones.
  final List<Widget> actions;

  /// Optional action shown in the app bar on small screens and floating at the
  /// bottom right otherwise.
  final Widget? floatingActionButton;

  /// Optional compact replacement for [floatingActionButton] in the app bar.
  final Widget? smallScreenAction;

  /// Whether [body] can use the full available width instead of the shared
  /// content width limit.
  final bool fullWidthBody;

  // Mirrors the route guards. The server must enforce the same rules.
  List<_Destination> _destinationsFor(
    AuthState auth, {
    required bool isSmallScreen,
  }) {
    final bool isStaff = auth.isAdmin || auth.isSubsectionAdmin;
    return <_Destination>[
      if (!auth.isSubsectionAdmin)
        const _Destination('Activities', Icons.list_alt, Routes.activities),
      if (auth.isAdmin)
        const _Destination('Map', Icons.map_outlined, Routes.geoMap),
      const _Destination('Scoreboard', Icons.leaderboard, Routes.scoreboard),
      if (isStaff) const _Destination('Grading', Icons.grading, Routes.grading),
      if (auth.isAdmin && !isSmallScreen)
        const _Destination('Users', Icons.group, Routes.users),
      if (auth.isAdmin)
        const _Destination('Game', Icons.tune, Routes.gameSettings),
      const _Destination('Settings', Icons.settings_outlined, Routes.settings),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final AuthState auth = AuthScope.of(context);
    final String path = GoRouterState.of(context).uri.path;

    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        // A resize can briefly hand the page a ~1x1 box.
        final bool isSmallScreen =
            constraints.maxWidth < Style.breakpoints.desktop;
        final List<_Destination> destinations = _destinationsFor(
          auth,
          isSmallScreen: isSmallScreen,
        );
        int selected = destinations.indexWhere(
          (_Destination d) => path == d.path || path.startsWith('${d.path}/'),
        );
        // Users is opened from the scoreboard on mobile, so keep Scores
        // selected while that contextual screen is visible.
        if (selected < 0 && isSmallScreen && path == Routes.users) {
          selected = destinations.indexWhere(
            (_Destination d) => d.path == Routes.scoreboard,
          );
        }
        if (selected < 0) selected = 0;
        // NavBar asserts that it has at least two items.
        final bool showNav = destinations.length >= 2;
        final Widget? floatingButton = floatingActionButton;
        final Widget? headerAction = smallScreenAction ?? floatingButton;
        // NavBar owns the bottom bar, so Scaffold's own floating button slot
        // would sit on top of it. Placing the button inside the content area
        // keeps it clear of the bar.
        final Widget content = Stack(
          fit: StackFit.expand,
          children: <Widget>[
            Align(
              alignment: Alignment.topCenter,
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  maxWidth: fullWidthBody ? double.infinity : _maxContentWidth,
                ),
                child: body,
              ),
            ),
            if (floatingButton != null && !isSmallScreen)
              Positioned(
                right: _floatingButtonInset,
                bottom: _floatingButtonInset,
                child: floatingButton,
              ),
          ],
        );
        final List<Widget> appBarActions = <Widget>[
          ...actions,
          if (isSmallScreen && headerAction != null) headerAction,
          if (kDebugMode)
            TappableIcon(
              icon: const Icon(Icons.bug_report_outlined),
              tooltip: 'Diagnostics',
              onPressed: () => context.go(Routes.diagnostics),
            ),
          if (kDebugMode) const SizedBox(width: 8),
        ];
        return Offstage(
          offstage: constraints.biggest.shortestSide < _minPageSide,
          child: ScrollAwareScaffold(
            isSmallScreen: isSmallScreen,
            resetKey: path,
            title: title,
            actions: appBarActions,
            backgroundColor: pageBackground(context),
            body: showNav
                ? NavBar(
                    currentIndex: selected,
                    onTap: (int index) => context.go(destinations[index].path),
                    items: <NavBarItem>[
                      for (final _Destination d in destinations)
                        NavBarItem(
                          icon: Icon(d.icon),
                          label: isSmallScreen && d.path == Routes.scoreboard
                              ? 'Scores'
                              : d.label,
                        ),
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

/// A page scaffold that hides its app bar on narrow screens while the user
/// scrolls down, then restores it when the user scrolls up.
class ScrollAwareScaffold extends StatefulWidget {
  /// Creates a responsive page scaffold.
  ///
  /// [title] is shown in the app bar, and [body] contains the page content.
  /// [actions] adds app bar controls. [backgroundColor] overrides the theme
  /// color. [isSmallScreen] overrides the shared width breakpoint, and
  /// [resetKey] restores the app bar when the displayed route changes.
  /// Returns a [ScrollAwareScaffold] instance and does not throw.
  const ScrollAwareScaffold({
    required this.title,
    required this.body,
    this.actions = const <Widget>[],
    this.backgroundColor,
    this.isSmallScreen,
    this.resetKey,
    super.key,
  });

  /// Title shown in the app bar.
  final String title;

  /// Page content, including any scrollable widgets.
  final Widget body;

  /// Additional app bar actions.
  final List<Widget> actions;

  /// Optional scaffold background color.
  final Color? backgroundColor;

  /// Whether to use the collapsing mobile layout, if already known.
  final bool? isSmallScreen;

  /// Value that changes when the displayed route changes.
  final Object? resetKey;

  @override
  State<ScrollAwareScaffold> createState() => _ScrollAwareScaffoldState();
}

class _ScrollAwareScaffoldState extends State<ScrollAwareScaffold> {
  bool _showHeader = true;
  bool? _lastSmallScreen;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final bool isSmallScreen = widget.isSmallScreen ??
        MediaQuery.sizeOf(context).width < Style.breakpoints.desktop;
    if (_lastSmallScreen != null && _lastSmallScreen != isSmallScreen) {
      _showHeader = true;
    }
    _lastSmallScreen = isSmallScreen;
  }

  @override
  void didUpdateWidget(ScrollAwareScaffold oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.isSmallScreen != widget.isSmallScreen ||
        oldWidget.resetKey != widget.resetKey) {
      _showHeader = true;
    }
  }

  bool _onScrollNotification(ScrollNotification notification) {
    if (notification.metrics.axis != Axis.vertical ||
        notification is! UserScrollNotification) {
      return false;
    }

    if (notification.direction == ScrollDirection.reverse && _showHeader) {
      setState(() => _showHeader = false);
    } else if (notification.direction == ScrollDirection.forward &&
        !_showHeader) {
      setState(() => _showHeader = true);
    }
    return false;
  }

  @override
  Widget build(BuildContext context) {
    final bool isSmallScreen = widget.isSmallScreen ??
        MediaQuery.sizeOf(context).width < Style.breakpoints.desktop;
    final AppBar appBar = AppBar(
      primary: !isSmallScreen,
      title: Text(widget.title),
      actions: widget.actions,
    );
    final Color backgroundColor =
        widget.backgroundColor ?? Theme.of(context).scaffoldBackgroundColor;

    final Color headerColor = appBar.backgroundColor ??
        Theme.of(context).appBarTheme.backgroundColor ??
        Theme.of(context).colorScheme.surface;

    return Scaffold(
      backgroundColor: backgroundColor,
      appBar: isSmallScreen ? null : appBar,
      body: Stack(
        fit: StackFit.expand,
        children: <Widget>[
          // Keep stream-backed page content mounted across the breakpoint.
          AnimatedPositioned(
            duration: const Duration(milliseconds: 180),
            curve: Curves.easeInOut,
            left: 0,
            top: isSmallScreen
                ? MediaQuery.of(context).padding.top +
                    (_showHeader ? kToolbarHeight : 0)
                : 0,
            right: 0,
            bottom: 0,
            child: NotificationListener<ScrollNotification>(
              onNotification:
                  isSmallScreen ? _onScrollNotification : (_) => false,
              child: widget.body,
            ),
          ),
          if (isSmallScreen)
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: SafeArea(
                top: true,
                bottom: false,
                left: false,
                right: false,
                child: ColoredBox(
                  color: headerColor,
                  child: ClipRect(
                    child: AnimatedSize(
                      alignment: Alignment.topCenter,
                      duration: const Duration(milliseconds: 180),
                      curve: Curves.easeInOut,
                      child: SizedBox(
                        width: double.infinity,
                        height: _showHeader ? kToolbarHeight : 0,
                        child: appBar,
                      ),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// Centers page content while allowing its parent scrollable to use full width.
class PageContent extends StatelessWidget {
  /// Creates a centred, width-limited page content region.
  const PageContent({
    required this.child,
    this.maxWidth = _maxContentWidth,
    super.key,
  });

  /// The page content to centre.
  final Widget child;

  /// Maximum width of the content region.
  final double maxWidth;

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: maxWidth),
        child: SizedBox(width: double.infinity, child: child),
      ),
    );
  }
}
