import 'package:flutter/gestures.dart'
    show PointerExitEvent, PointerHoverEvent;
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart'
    show
        CameraFit,
        CircleLayer,
        CircleMarker,
        FlutterMap,
        InteractionOptions,
        InteractiveFlag,
        LayerHitNotifier,
        MapCamera,
        MapController,
        MapOptions,
        Marker,
        MarkerLayer,
        Polyline,
        PolylineLayer,
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
  const GeoMapMarker({
    required this.point,
    required this.color,
    this.icon = Icons.location_on,
    this.onTap,
  });

  final LatLng point;
  final Color color;
  final IconData icon;
  final VoidCallback? onTap;
}

/// A line drawn between points on a [GeoMap].
class GeoMapLine {
  const GeoMapLine({
    required this.points,
    required this.color,
    this.strokeWidth = 3,
    this.onTap,
  });

  final List<LatLng> points;
  final Color color;
  final double strokeWidth;
  final VoidCallback? onTap;
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
    this.lines = const <GeoMapLine>[],
    this.circle,
    this.onTap,
    this.height = 260,
    this.cameraFitPadding = const EdgeInsets.all(48),
    this.borderRadius = const BorderRadius.all(Radius.circular(8)),
    super.key,
  });

  final List<GeoMapMarker> markers;
  final List<GeoMapLine> lines;
  final GeoMapCircle? circle;

  /// Called with the tapped point. Null makes the map view-only.
  final void Function(LatLng point)? onTap;
  final double height;
  final EdgeInsets cameraFitPadding;
  final BorderRadius borderRadius;

  @override
  State<GeoMap> createState() => _GeoMapState();
}

class _GeoMapState extends State<GeoMap> {
  final MapController _controller = MapController();
  final LayerHitNotifier<GeoMapLine> _lineHitNotifier = ValueNotifier(null);
  LatLng? _focus;
  bool _hoveringInteractiveLine = false;

  @override
  void initState() {
    super.initState();
    _focus = _firstPoint(widget);
  }

  @override
  void didUpdateWidget(GeoMap oldWidget) {
    super.didUpdateWidget(oldWidget);
    final LatLng? next = _firstPoint(widget);
    final bool paddingChanged =
        oldWidget.cameraFitPadding != widget.cameraFitPadding;
    if (!paddingChanged && (next == null || next == _focus)) return;
    final bool firstFocus = _focus == null;
    if (next != null) _focus = next;
    // The controller only works once the map has been laid out.
    WidgetsBinding.instance.addPostFrameCallback((Duration _) {
      if (!mounted) return;
      if (paddingChanged) {
        final List<LatLng> points = _points(widget);
        if (points.length > 1) {
          _controller.fitCamera(
            CameraFit.coordinates(
              coordinates: points,
              padding: widget.cameraFitPadding,
              maxZoom: 17,
            ),
          );
        } else if (points.isNotEmpty) {
          _controller.move(points.first, _pointZoom);
        }
        return;
      }
      if (next == null) return;
      if (firstFocus) {
        final List<LatLng> points = _points(widget);
        if (points.length > 1) {
          _controller.fitCamera(
            CameraFit.coordinates(
              coordinates: points,
              padding: widget.cameraFitPadding,
              maxZoom: 17,
            ),
          );
        } else {
          _controller.move(next, _pointZoom);
        }
        return;
      }
      final MapCamera camera = _controller.camera;
      if (camera.visibleBounds.contains(next)) return;
      _controller.move(next, camera.zoom < 12 ? _pointZoom : camera.zoom);
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    _lineHitNotifier.dispose();
    super.dispose();
  }

  void _updateLineHover(PointerHoverEvent _) {
    final List<GeoMapLine> hits =
        _lineHitNotifier.value?.hitValues ?? const <GeoMapLine>[];
    final bool hovering =
        hits.any((GeoMapLine line) => line.onTap != null);
    if (hovering == _hoveringInteractiveLine) return;
    setState(() => _hoveringInteractiveLine = hovering);
  }

  void _clearLineHover(PointerExitEvent _) {
    if (!_hoveringInteractiveLine) return;
    setState(() => _hoveringInteractiveLine = false);
  }

  static List<LatLng> _points(GeoMap widget) => <LatLng>[
        for (final GeoMapMarker marker in widget.markers) marker.point,
        for (final GeoMapLine line in widget.lines) ...line.points,
      ];

  static LatLng? _firstPoint(GeoMap widget) =>
      widget.markers.isNotEmpty
          ? widget.markers.first.point
          : widget.lines.isEmpty || widget.lines.first.points.isEmpty
              ? null
              : widget.lines.first.points.first;

  @override
  Widget build(BuildContext context) {
    final List<LatLng> points = _points(widget);
    final GeoMapCircle? circle = widget.circle;
    final void Function(LatLng point)? onTap = widget.onTap;
    final bool hasInteractiveLine =
        widget.lines.any((GeoMapLine line) => line.onTap != null);
    return SizedBox(
      height: widget.height,
      child: ClipRRect(
        borderRadius: widget.borderRadius,
        child: MouseRegion(
          cursor: SystemMouseCursors.grab,
          child: FlutterMap(
            mapController: _controller,
            options: MapOptions(
              initialCenter: points.isEmpty ? _worldCenter : points.first,
              initialZoom: points.isEmpty ? _worldZoom : _pointZoom,
              initialCameraFit: points.length > 1
                  ? CameraFit.coordinates(
                      coordinates: points,
                      padding: widget.cameraFitPadding,
                      maxZoom: 17,
                    )
                  : null,
              // Rotation only gets in the way of picking a point.
              interactionOptions: const InteractionOptions(
                flags: InteractiveFlag.all & ~InteractiveFlag.rotate,
              ),
              onTap: onTap == null && !hasInteractiveLine
                  ? null
                  : (TapPosition _, LatLng point) {
                      final List<GeoMapLine> hits =
                          _lineHitNotifier.value?.hitValues ??
                          const <GeoMapLine>[];
                      for (final GeoMapLine line in hits) {
                        final VoidCallback? onLineTap = line.onTap;
                        if (onLineTap == null) continue;
                        onLineTap();
                        return;
                      }
                      onTap?.call(point);
                    },
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
              if (widget.lines.isNotEmpty)
                MouseRegion(
                  cursor: _hoveringInteractiveLine
                      ? SystemMouseCursors.click
                      : SystemMouseCursors.grab,
                  onHover: _updateLineHover,
                  onExit: _clearLineHover,
                  child: PolylineLayer<GeoMapLine>(
                    hitNotifier: _lineHitNotifier,
                    polylines: <Polyline<GeoMapLine>>[
                      for (final GeoMapLine line in widget.lines)
                        if (line.points.length > 1)
                          Polyline<GeoMapLine>(
                            points: line.points,
                            color: line.color,
                            strokeWidth: line.strokeWidth,
                            hitValue: line,
                          ),
                    ],
                  ),
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
                      child: MouseRegion(
                        cursor: marker.onTap == null
                            ? SystemMouseCursors.grab
                            : SystemMouseCursors.click,
                        child: GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onTap: marker.onTap,
                          child: Icon(
                            marker.icon,
                            color: marker.color,
                            size: 40,
                          ),
                        ),
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
      ),
    );
  }
}
