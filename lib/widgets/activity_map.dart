import 'dart:async' show unawaited;

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:latlong2/latlong.dart' show LatLng;

import '../data/activity_list.dart';
import '../data/activity_notes.dart' show NotePin;
import '../orient_ui/button.dart';
import '../orient_ui/empty_state.dart';
import '../orient_ui/popup.dart';
import '../orient_ui/style.dart';
import '../router/routes.dart';
import 'geo_map.dart';

/// A map of where the player's activities are and where they dropped pins.
///
/// [items] are the player's activities. Activities that have not opened yet
/// are left off, so their locations stay hidden until release.
/// [canViewOutsideGameWindow] lets staff see activities outside the game's
/// schedule window. Tapping a marker shows its details and a link to the
/// activity. Rebuild it as time passes so newly opened activities appear.
class ActivityMap extends StatelessWidget {
  const ActivityMap({
    required this.items,
    required this.canViewOutsideGameWindow,
    super.key,
  });

  final List<ActivityListItem> items;
  final bool canViewOutsideGameWindow;

  void _showDetails(
    BuildContext context,
    ActivityListItem item, {
    required bool isPin,
  }) {
    final String? suburb = item.suburb;
    final String kind = !isPin
        ? 'Activity location'
        : (suburb == null ? 'Your pin' : 'Your pin in $suburb');
    unawaited(
      Popup.show(
        context: context,
        title: item.name,
        // The builder gives the button the popup's own context to pop.
        child: Builder(
          builder: (BuildContext popupContext) => Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            spacing: 12,
            children: <Widget>[
              Text(kind),
              Button.small(
                label: 'Open activity',
                variant: ButtonVariant.outline,
                onPressed: () {
                  Navigator.of(popupContext).pop();
                  unawaited(context.push(Routes.activity(item.id)));
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final DateTime now = DateTime.now().toUtc();
    final ColorTokens colors = context.style.colors;
    final List<GeoMapMarker> markers = <GeoMapMarker>[];
    for (final ActivityListItem item in items) {
      if (item.opensAfter(now) != null) continue;
      if (!canViewOutsideGameWindow && !item.gameWindowIsOpenAt(now)) continue;
      final NotePin? pin = item.pin;
      final NotePin? location = item.location;
      if (pin != null) {
        markers.add(
          GeoMapMarker(
            point: LatLng(pin.lat, pin.lng),
            color: colors.button.link,
            onTap: () => _showDetails(context, item, isPin: true),
          ),
        );
      }
      if (location != null) {
        markers.add(
          GeoMapMarker(
            point: LatLng(location.lat, location.lng),
            color: colors.warning,
            icon: Icons.flag_rounded,
            onTap: () => _showDetails(context, item, isPin: false),
          ),
        );
      }
    }
    if (markers.isEmpty) {
      return const EmptyState(
        title: 'Nothing on the map yet.',
        description: 'Activity locations and your pins will appear here.',
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.all(12),
          child: Wrap(
            spacing: 16,
            runSpacing: 4,
            children: <Widget>[
              _LegendItem(
                icon: Icons.flag_rounded,
                color: colors.warning,
                label: 'Activity location',
              ),
              _LegendItem(
                icon: Icons.location_on,
                color: colors.button.link,
                label: 'Your pin',
              ),
            ],
          ),
        ),
        Expanded(
          child: LayoutBuilder(
            builder: (BuildContext context, BoxConstraints constraints) =>
                GeoMap(
              markers: markers,
              height: constraints.maxHeight,
              borderRadius: BorderRadius.zero,
            ),
          ),
        ),
      ],
    );
  }
}

class _LegendItem extends StatelessWidget {
  const _LegendItem({
    required this.icon,
    required this.color,
    required this.label,
  });

  final IconData icon;
  final Color color;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      spacing: 4,
      children: <Widget>[
        Icon(icon, color: color, size: 20),
        Text(label, style: context.typography.bodySmall),
      ],
    );
  }
}