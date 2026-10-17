import 'package:flutter/material.dart';
import 'package:latlong2/latlong.dart' show LatLng;

import '../data/activity_writes.dart' show GeoMode;
import '../data/device_location.dart';
import '../data/geo.dart';
import '../orient_ui/button.dart';
import '../orient_ui/info_banner.dart';
import '../orient_ui/style.dart';
import '../widgets/geo_map.dart';

/// The location part of an answer form.
///
/// What it shows depends on [mode]: automatic and photo activities collect the
/// position elsewhere (on submit, from the chosen photo) and only show the
/// result, while [pickOnMap] adds a map to tap and a device location button.
/// The parent sets [pickOnMap] for manual activities and as a fallback when
/// the automatic route failed; it shows the reason in [message].
/// The chosen point is reported through [onChanged]. Hide the device location
/// button with [allowDeviceLocation] when the device is not where the answer
/// is, for example when an admin answers for a player.
class GeoAnswerField extends StatefulWidget {
  const GeoAnswerField({
    required this.mode,
    required this.value,
    required this.onChanged,
    required this.pickOnMap,
    this.allowDeviceLocation = true,
    this.message,
    super.key,
  });

  final GeoMode mode;
  final GeoPoint? value;
  final ValueChanged<GeoPoint?> onChanged;
  final bool pickOnMap;
  final bool allowDeviceLocation;
  final String? message;

  @override
  State<GeoAnswerField> createState() => _GeoAnswerFieldState();
}

class _GeoAnswerFieldState extends State<GeoAnswerField> {
  bool _locating = false;
  String? _error;

  String _help() => switch (widget.mode) {
        GeoMode.auto => 'Your location is read from your device when you submit.',
        GeoMode.photo => 'Your location is read from the photo you choose.',
        GeoMode.manual => 'Pick your location on the map.',
      };

  String _describe(GeoPoint point) {
    final double? accuracy = point.accuracyM;
    final String within = accuracy == null ? '' : ', within ${accuracy.round()} m';
    return '${point.lat.toStringAsFixed(5)}, ${point.lng.toStringAsFixed(5)}'
        ' (from ${point.origin.label}$within)';
  }

  Future<void> _useDevice() async {
    setState(() {
      _locating = true;
      _error = null;
    });
    try {
      final GeoPoint here = await getDeviceLocation();
      if (!mounted) return;
      widget.onChanged(here);
    } on LocationUnavailableException catch (e) {
      if (!mounted) return;
      setState(() => _error = e.message);
    }
    if (!mounted) return;
    setState(() => _locating = false);
  }

  void _tapped(LatLng point) {
    widget.onChanged(
      GeoPoint(
        lat: point.latitude,
        lng: point.longitude,
        origin: GeoOrigin.map,
        capturedAt: DateTime.now().toUtc(),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final TypographyTokens typography = context.typography;
    final GeoPoint? point = widget.value;
    final String? message = widget.message;
    final Color color = Theme.of(context).colorScheme.primary;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      spacing: 8,
      children: <Widget>[
        Text('Location', style: typography.body.w600),
        Text(_help(), style: typography.bodySmall.muted(context)),
        if (message != null)
          InfoBanner(title: message, variant: InfoBannerVariant.warning),
        if (_error != null)
          InfoBanner(title: _error!, variant: InfoBannerVariant.error),
        if (point != null) Text(_describe(point)),
        if (widget.pickOnMap) ...<Widget>[
          if (widget.allowDeviceLocation)
            Align(
              alignment: Alignment.centerLeft,
              child: Button.small(
                label: 'Use my location',
                icon: const Icon(Icons.my_location),
                variant: ButtonVariant.outline,
                loading: _locating,
                onPressed: _useDevice,
              ),
            ),
          GeoMap(
            markers: <GeoMapMarker>[
              if (point != null)
                GeoMapMarker(point: LatLng(point.lat, point.lng), color: color),
            ],
            onTap: _tapped,
          ),
        ],
      ],
    );
  }
}