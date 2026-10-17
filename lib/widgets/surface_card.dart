import 'package:flutter/widgets.dart';

import '../orient_ui/card_box.dart';
import '../orient_ui/style.dart';
import '../orient_ui/tile.dart';

/// The color behind page content, one step away from the card color so cards
/// stand out from it.
///
/// Orient UI has no token for this: its page and card colors are both close
/// to white in light mode. Light mode uses the secondary button tone, dark
/// mode the darker surface tone. Returns the color. Does not throw.
Color pageBackground(BuildContext context) {
  final Style style = context.style;
  final ColorTokens colors = style.colors;
  return style.isDark ? colors.surfaceContainer : colors.button.secondary;
}

/// A [CardBox] that stays visible on [pageBackground]: it gets the page's
/// card color as a fill, behind the border, plus a soft shadow.
///
/// [CardBox]'s bordered variant has no fill, so on its own it blends into the
/// page. Margin is the caller's job, so it can match the surrounding list.
class SurfaceCard extends StatelessWidget {
  const SurfaceCard({
    required this.child,
    this.padding = const EdgeInsets.all(16),
    super.key,
  });

  final Widget child;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: context.style.colors.background,
        borderRadius: BorderRadius.circular(Style.radii.medium),
        boxShadow: <BoxShadow>[
          BoxShadow(
            color: const Color(0xFF000000).withValues(alpha: 0.06),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: CardBox(
        variant: CardBoxVariant.bordered,
        padding: padding,
        child: child,
      ),
    );
  }
}

/// A [Tile] in its own [SurfaceCard], for list rows. Takes the same
/// arguments as [Tile], plus the [margin] around the card.
class TileCard extends StatelessWidget {
  const TileCard({
    required this.title,
    this.leading,
    this.subtitle,
    this.trailing,
    this.onTap,
    this.variant = TileVariant.simple,
    this.margin = const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
    this.footer,
    super.key,
  });

  final String title;
  final Widget? leading;
  final String? subtitle;
  final Widget? trailing;
  final VoidCallback? onTap;
  final TileVariant variant;
  final EdgeInsetsGeometry margin;
  final Widget? footer;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: margin,
      child: SurfaceCard(
        padding: EdgeInsets.zero,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Tile(
              leading: leading,
              title: title,
              subtitle: subtitle,
              trailing: trailing,
              onTap: onTap,
              variant: variant,
            ),
            if (footer != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                child: footer,
              ),
          ],
        ),
      ),
    );
  }
}