import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart'
    show
        CameraFit,
        CircleLayer,
        CircleMarker,
        FlutterMap,
        InteractionOptions,
        InteractiveFlag,
        MapCamera,
        MapController,
        MapOptions,
        Marker,
        MarkerLayer,
        RichAttributionWidget,
        SourceAttribution,
        TapPosition,
        TextSourceAttribution,
        TileLayer;
import 'package:latlong2/latlong.dart' show LatLng;

import '../config/app_config.dart';

// Identifies the app to the tile server. Browsers set their own User-Agent,
// so on web this is only informational.
const String _userAgentPackageName = 'mx_pwa';

const LatLng _worldCenter = LatLng(20, 0);
const double _worldZoom = 2;
const double _pointZoom = 16;

/// A pin on a [GeoMap].
class GeoMapMarker {
  const GeoMapMarker({required this.point, required this.color});

  final LatLng point;
  final Color color;
}

/// A circle on a [GeoMap], sized in metres rather than pixels.
class GeoMapCircle {
  const GeoMapCircle({
    required this.center,
    required this.radiusM,
    required this.color,
  });

  final LatLng center;
  final double radiusM;
  final Color color;
}

/// An OpenStreetMap view with pins, an optional circle and optional tap
/// picking.
///
/// The tile server comes from `AppConfig.mapTileUrl`. The public OpenStreetMap
/// server is for light use only, so set a keyed provider for a real event.
/// The first marker is the one the map follows: when it moves out of view the
/// map pans to it, but a tap inside the view never recenters.
class GeoMap extends StatefulWidget {
  const GeoMap({
    this.markers = const <GeoMapMarker>[],
    this.circle,
    this.onTap,
    this.height = 260,
    super.key,
  });

  final List<GeoMapMarker> markers;
  final GeoMapCircle? circle;

  /// Called with the tapped point. Null makes the map view-only.
  final void Function(LatLng point)? onTap;
  final double height;

  @override
  State<GeoMap> createState() => _GeoMapState();
}

class _GeoMapState extends State<GeoMap> {
  final MapController _controller = MapController();
  LatLng? _focus;

  @override
  void initState() {
    super.initState();
    _focus = _firstPoint(widget);
  }

  @override
  void didUpdateWidget(GeoMap oldWidget) {
    super.didUpdateWidget(oldWidget);
    final LatLng? next = _firstPoint(widget);
    if (next == null || next == _focus) return;
    _focus = next;
    // The controller only works once the map has been laid out.
    WidgetsBinding.instance.addPostFrameCallback((Duration _) {
      if (!mounted) return;
      final MapCamera camera = _controller.camera;
      if (camera.visibleBounds.contains(next)) return;
      _controller.move(next, camera.zoom < 12 ? _pointZoom : camera.zoom);
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  static LatLng? _firstPoint(GeoMap widget) =>
      widget.markers.isEmpty ? null : widget.markers.first.point;

  @override
  Widget build(BuildContext context) {
    final List<LatLng> points = <LatLng>[
      for (final GeoMapMarker marker in widget.markers) marker.point,
    ];
    final GeoMapCircle? circle = widget.circle;
    final void Function(LatLng point)? onTap = widget.onTap;
    return SizedBox(
      height: widget.height,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: FlutterMap(
          mapController: _controller,
          options: MapOptions(
            initialCenter: points.isEmpty ? _worldCenter : points.first,
            initialZoom: points.isEmpty ? _worldZoom : _pointZoom,
            initialCameraFit: points.length > 1
                ? CameraFit.coordinates(
                    coordinates: points,
                    padding: const EdgeInsets.all(48),
                    maxZoom: 17,
                  )
                : null,
            // Rotation only gets in the way of picking a point.
            interactionOptions: const InteractionOptions(
              flags: InteractiveFlag.all & ~InteractiveFlag.rotate,
            ),
            onTap: onTap == null
                ? null
                : (TapPosition _, LatLng point) => onTap(point),
          ),
          children: <Widget>[
            TileLayer(
              urlTemplate: AppConfig.mapTileUrl,
              userAgentPackageName: _userAgentPackageName,
            ),
            if (circle != null)
              CircleLayer(
                circles: <CircleMarker>[
                  CircleMarker(
                    point: circle.center,
                    radius: circle.radiusM,
                    useRadiusInMeter: true,
                    color: circle.color.withValues(alpha: 0.15),
                    borderColor: circle.color,
                    borderStrokeWidth: 2,
                  ),
                ],
              ),
            MarkerLayer(
              markers: <Marker>[
                for (final GeoMapMarker marker in widget.markers)
                  Marker(
                    point: marker.point,
                    width: 40,
                    height: 40,
                    // The pin's tip, not its middle, sits on the point.
                    alignment: Alignment.topCenter,
                    child: Icon(
                      Icons.location_on,
                      color: marker.color,
                      size: 40,
                    ),
                  ),
              ],
            ),
            RichAttributionWidget(
              attributions: <SourceAttribution>[
                TextSourceAttribution(AppConfig.mapAttribution),
              ],
            ),
          ],
        ),
      ),
    );
  }
}