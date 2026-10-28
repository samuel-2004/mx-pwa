import 'package:flutter/material.dart';
import 'package:latlong2/latlong.dart' show LatLng;

import '../data/activity_notes.dart' show NotePin, normalisePin;
import '../data/device_location.dart';
import '../data/geo.dart' show GeoPoint;
import '../orient_ui/button.dart';
import '../orient_ui/info_banner.dart';
import '../orient_ui/style.dart';
import '../orient_ui/toggle_tile.dart';
import 'geo_map.dart';

/// Sets where an activity is. Players see this location on their map.
///
/// [value] is the current location, or null for none. [onChanged] receives
/// the new location, or null when it is cleared. Tapping the map or using the
/// device location sets it, with the longitude wrapped into -180 to 180.
/// The toggle shows or hides this editor, including its map, and never
/// changes [value].
class ActivityLocationEditor extends StatefulWidget {
  const ActivityLocationEditor({
    required this.value,
    required this.onChanged,
    super.key,
  });

  final NotePin? value;
  final ValueChanged<NotePin?> onChanged;

  @override
  State<ActivityLocationEditor> createState() => _ActivityLocationEditorState();
}

class _ActivityLocationEditorState extends State<ActivityLocationEditor> {
  // Starts on when a location is already saved, so it is never hidden.
  late bool _enabled = widget.value != null;
  bool _locating = false;
  String? _error;

  void _setEnabled(bool enabled) => setState(() => _enabled = enabled);

  void _pick(LatLng point) => widget.onChanged(
        normalisePin((lat: point.latitude, lng: point.longitude)),
      );

  Future<void> _useDevice() async {
    setState(() {
      _locating = true;
      _error = null;
    });
    try {
      final GeoPoint here = await getDeviceLocation();
      if (!mounted) return;
      _pick(LatLng(here.lat, here.lng));
    } on LocationUnavailableException catch (e) {
      if (!mounted) return;
      setState(() => _error = e.message);
    }
    if (!mounted) return;
    setState(() => _locating = false);
  }

  @override
  Widget build(BuildContext context) {
    final TypographyTokens typography = context.typography;
    final NotePin? point = widget.value;
    final Widget toggle = ToggleTile(
      title: 'Show an activity location to players',
      value: _enabled,
      onChanged: _setEnabled,
    );
    if (!_enabled) return toggle;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      spacing: 8,
      children: <Widget>[
        toggle,
        Text(
          point == null
              ? 'No location set. Players will not see this activity on '
                  'their map.'
              : '${point.lat.toStringAsFixed(5)}, '
                  '${point.lng.toStringAsFixed(5)}',
          style: typography.bodySmall.muted(context),
        ),
        if (_error != null)
          InfoBanner(title: _error!, variant: InfoBannerVariant.error),
                Wrap(
          spacing: 8,
          runSpacing: 8,
          children: <Widget>[
            Button.small(
              label: 'Use my location',
              icon: const Icon(Icons.my_location),
              variant: ButtonVariant.outline,
              loading: _locating,
              onPressed: _useDevice,
            ),
            if (point != null)
              Button.small(
                label: 'Clear location',
                icon: const Icon(Icons.delete_outline),
                variant: ButtonVariant.outline,
                onPressed: () => widget.onChanged(null),
              ),
          ],
        ),
        GeoMap(
          markers: <GeoMapMarker>[
            if (point != null)
              GeoMapMarker(
                point: LatLng(point.lat, point.lng),
                color: context.style.colors.warning,
                icon: Icons.flag_rounded,
              ),
          ],
          onTap: _pick,
        ),
        Text(
          'Tap the map to set the location.',
          style: typography.bodySmall.muted(context),
        ),
      ],
    );
  }
}