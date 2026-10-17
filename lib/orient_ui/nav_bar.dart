import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import 'style.dart';

class NavBarItem {
  final Widget icon;
  final String label;

  const NavBarItem({required this.icon, required this.label});
}

class NavBar extends StatefulWidget {
  final int currentIndex;
  final ValueChanged<int> onTap;
  final List<NavBarItem> items;
  final Widget body;
  final Widget? railHeader;
  final Widget? railFooter;
  final int? railFooterIndex;
  final double railWidth;

  const NavBar({
    super.key,
    required this.currentIndex,
    required this.onTap,
    required this.items,
    required this.body,
    this.railHeader,
    this.railFooter,
    this.railFooterIndex,
    this.railWidth = 240,
  }) : assert(items.length >= 2, 'At least 2 navigation items required');

  @override
  State<NavBar> createState() => _NavBarState();
}

class _NavigationRail extends StatelessWidget {
  final int currentIndex;
  final ValueChanged<int> onTap;
  final List<NavBarItem> items;
  final Widget? header;
  final Widget? footer;
  final int? footerIndex;
  final double width;

  const _NavigationRail({
    required this.currentIndex,
    required this.onTap,
    required this.items,
    this.header,
    this.footer,
    this.footerIndex,
    required this.width,
  });

  @override
  Widget build(BuildContext context) {
    final style = Style.of(context);
    final navColors = style.colors.navigation;

    return Container(
      width: width,
      color: navColors.railBackground,
      padding: const EdgeInsets.symmetric(horizontal: 24),
      child: Column(
        children: [
          if (header != null) ...[
            const SizedBox(height: 24),
            header!,
            const SizedBox(height: 32),
          ] else
            const SizedBox(height: 24),
          ...items.asMap().entries
              .where((entry) => entry.key != footerIndex)
              .map((entry) {
            final int index = entry.key;
            final NavBarItem item = entry.value;
            return Padding(
              padding: const EdgeInsets.only(bottom: 2),
              child: _RailItem(
                icon: item.icon,
                label: item.label,
                active: index == currentIndex,
                onTap: () => onTap(index),
              ),
            );
          }),
          if (footerIndex != null) ...[
            const Spacer(),
            Padding(
              padding: const EdgeInsets.only(bottom: 2),
              child: _RailItem(
                icon: items[footerIndex!].icon,
                label: items[footerIndex!].label,
                active: footerIndex == currentIndex,
                onTap: () => onTap(footerIndex!),
              ),
            ),
            const SizedBox(height: 24),
          ],
          if (footer != null) ...[
            const Spacer(),
            footer!,
            const SizedBox(height: 24),
          ],
        ],
      ),
    );
  }
}

class _RailItem extends StatefulWidget {
  final Widget icon;
  final String label;
  final bool active;
  final VoidCallback onTap;

  const _RailItem({
    required this.icon,
    required this.label,
    required this.active,
    required this.onTap,
  });

  @override
  State<_RailItem> createState() => _RailItemState();
}

class _RailItemState extends State<_RailItem> {
  bool _isHovered = false;

  @override
  Widget build(BuildContext context) {
    final Style style = Style.of(context);
    final NavigationColors navColors = style.colors.navigation;

    Color? backgroundColor;
    if (widget.active) {
      backgroundColor = navColors.railItemBackgroundActive;
    } else if (_isHovered) {
      backgroundColor = navColors.railItemBackgroundHover;
    }

    return Semantics(
      button: true,
      label: widget.label,
      selected: widget.active,
      child: MouseRegion(
        onEnter: (_) => setState(() => _isHovered = true),
        onExit: (_) => setState(() => _isHovered = false),
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          onTap: widget.onTap,
          behavior: HitTestBehavior.opaque,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 12),
            decoration: BoxDecoration(
              color: backgroundColor,
              borderRadius: BorderRadius.circular(Style.radii.medium),
            ),
            child: Row(
              children: [
                widget.icon,
                const SizedBox(width: 16),
                Text(
                  widget.label,
                  overflow: TextOverflow.ellipsis,
                  style: context.typography.subtitle.withColor(navColors.railItemText),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _BottomNavigationBar extends StatelessWidget {
  final int currentIndex;
  final ValueChanged<int> onTap;
  final List<NavBarItem> items;

  const _BottomNavigationBar({
    required this.currentIndex,
    required this.onTap,
    required this.items,
  });

  @override
  Widget build(BuildContext context) {
    final style = Style.of(context);
    final navColors = style.colors.navigation;
    final bottomPadding = MediaQuery.of(context).padding.bottom;

    return Container(
      decoration: BoxDecoration(
        color: navColors.bottomBarBackground,
        border: Border(top: BorderSide(color: style.colors.border, width: 1)),
      ),
      padding: EdgeInsets.only(bottom: bottomPadding),
      child: SizedBox(
        height: 72,
        child: Row(
          children: items.asMap().entries.map((entry) {
            final index = entry.key;
            final item = entry.value;
            return Expanded(
              child: _BottomBarItem(
                icon: item.icon,
                label: item.label,
                active: index == currentIndex,
                onTap: () => onTap(index),
              ),
            );
          }).toList(),
        ),
      ),
    );
  }
}

class _BottomBarItem extends StatelessWidget {
  final Widget icon;
  final String label;
  final bool active;
  final VoidCallback onTap;

  const _BottomBarItem({
    required this.icon,
    required this.label,
    required this.active,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final style = Style.of(context);
    final navColors = style.colors.navigation;

    final Color color = active
        ? navColors.bottomBarItemActive
        : navColors.bottomBarItemInactive;

    return Semantics(
      button: true,
      label: label,
      selected: active,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () {
          onTap.call();

          HapticFeedback.selectionClick();
        },
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            IconTheme(
              data: IconThemeData(color: color, size: 24),
              child: icon,
            ),
            const SizedBox(height: 2),
            Text(
              label,
              overflow: TextOverflow.ellipsis,
              style: context.typography.bodySmall.withColor(color),
            ),
          ],
        ),
      ),
    );
  }
}

class _NavBarState extends State<NavBar> {
  // Lets Flutter move the body between the Row and Column instead of
  // rebuilding it. A rebuild re-listens to single-subscription streams.
  final GlobalKey _bodyKey = GlobalKey();

  @override
  Widget build(BuildContext context) {
    final bool isDesktop =
        MediaQuery.of(context).size.width >= Style.breakpoints.desktop;
    final Widget body = KeyedSubtree(key: _bodyKey, child: widget.body);

    if (isDesktop) {
      return Row(
        children: [
          _NavigationRail(
            currentIndex: widget.currentIndex,
            onTap: widget.onTap,
            items: widget.items,
            header: widget.railHeader,
            footer: widget.railFooter,
            footerIndex: widget.railFooterIndex,
            width: widget.railWidth,
          ),
          Expanded(child: body),
        ],
      );
    }

    return Column(
      children: [
        Expanded(child: body),
        _BottomNavigationBar(
          currentIndex: widget.currentIndex,
          onTap: widget.onTap,
          items: widget.items,
        ),
      ],
    );
  }
}
