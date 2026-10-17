import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../layout/app_scaffold.dart';
import '../orient_ui/segment_bar.dart';
import '../orient_ui/style.dart';
import '../orient_ui/tile.dart';
import '../router/routes.dart';
import '../settings/app_settings.dart';
import '../widgets/surface_card.dart';

String _themeLabel(ThemeMode mode) => switch (mode) {
      ThemeMode.system => 'System',
      ThemeMode.light => 'Light',
      ThemeMode.dark => 'Dark',
    };

/// Settings for this device only: theme and text size. Also where to sign out.
class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final AppSettings settings = AppSettingsScope.of(context);
    final TypographyTokens typography = context.typography;
    return AppScaffold(
      title: 'Settings',
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: <Widget>[
          // The segment bars sit on a card because their selected segment
          // uses the same color as the dark page and would disappear there.
          SurfaceCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text('Theme', style: typography.subtitle),
                const SizedBox(height: 8),
                // SegmentBar works by position, so the enum order is the tab
                // order.
                SegmentBar(
                  index: settings.themeMode.index,
                  onChanged: (int index) =>
                      settings.setThemeMode(ThemeMode.values[index]),
                  items: <SegmentItem>[
                    for (final ThemeMode mode in ThemeMode.values)
                      SegmentItem(label: _themeLabel(mode)),
                  ],
                ),
                const SizedBox(height: 24),
                Text('Text size', style: typography.subtitle),
                const SizedBox(height: 8),
                SegmentBar(
                  index: settings.textSize.index,
                  onChanged: (int index) =>
                      settings.setTextSize(TextSize.values[index]),
                  items: <SegmentItem>[
                    for (final TextSize size in TextSize.values)
                      SegmentItem(label: size.label),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          SurfaceCard(
            padding: EdgeInsets.zero,
            child: Column(
              children: <Widget>[
                Tile(
                  leading: const Icon(Icons.description_outlined),
                  title: 'Terms & Conditions / Licence',
                  onTap: () => context.go(Routes.terms),
                ),
                const Divider(height: 1),
                Tile(
                  leading: const Icon(Icons.logout),
                  title: 'Sign out',
                  onTap: () => context.go(Routes.logout),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}