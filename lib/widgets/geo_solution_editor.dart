import 'package:flutter/material.dart';
import 'package:flutter/services.dart'
    show FilteringTextInputFormatter, TextInputFormatter;
import 'package:latlong2/latlong.dart' show LatLng;

import '../data/device_location.dart';
import '../data/geo.dart';
import '../orient_ui/button.dart';
import '../orient_ui/info_banner.dart';
import '../orient_ui/style.dart';
import 'geo_map.dart';

// Digits, a decimal point and a minus sign. Ranges are checked on parse.
final List<TextInputFormatter> _numberFormatters = <TextInputFormatter>[
  FilteringTextInputFormatter.allow(RegExp(r'[0-9.\-]')),
];

/// Edits the solution of a location activity: coordinates typed in or picked
/// on a map, plus an optional maximum distance that turns on auto-grading.
///
/// Starts from [initial] and reports every edit through [onChanged] with the
/// parsed solution. The solution is null when the fields are empty (no
/// solution, error null) or invalid (error set). Never calls [onChanged] on
/// its own at start. To load a different [initial], give the widget a new key.
class GeoSolutionEditor extends StatefulWidget {
  const GeoSolutionEditor({
    required this.initial,
    required this.onChanged,
    super.key,
  });

  final GeoSolution? initial;
  final void Function(GeoSolution? solution, String? error) onChanged;

  @override
  State<GeoSolutionEditor> createState() => _GeoSolutionEditorState();
}

class _GeoSolutionEditorState extends State<GeoSolutionEditor> {
  late final TextEditingController _lat =
      TextEditingController(text: _text(widget.initial?.lat));
  late final TextEditingController _lng =
      TextEditingController(text: _text(widget.initial?.lng));
  late final TextEditingController _max =
      TextEditingController(text: _text(widget.initial?.maxDistanceM));
  late GeoSolution? _solution = widget.initial;
  String? _error;
  bool _locating = false;

  static String _text(double? value) {
    if (value == null) return '';
    return value == value.roundToDouble()
        ? value.round().toString()
        : value.toString();
  }

  @override
  void dispose() {
    _lat.dispose();
    _lng.dispose();
    _max.dispose();
    super.dispose();
  }

  void _changed() {
    final String latText = _lat.text.trim();
    final String lngText = _lng.text.trim();
    final String maxText = _max.text.trim();
    final double? lat = double.tryParse(latText);
    final double? lng = double.tryParse(lngText);
    final double? max = double.tryParse(maxText);
    String? error;
    GeoSolution? solution;
    if (latText.isEmpty && lngText.isEmpty && maxText.isEmpty) {
      // Everything cleared: no solution, and no error.
    } else if (lat == null || lng == null || !isValidLatLng(lat, lng)) {
      error = 'Enter a latitude from -90 to 90 and a longitude from -180 to 180.';
    } else if (maxText.isNotEmpty && (max == null || !max.isFinite || max <= 0)) {
      error = 'The maximum distance must be above 0 metres, or empty.';
    } else {
      solution = GeoSolution(
        lat: lat,
        lng: lng,
        maxDistanceM: maxText.isEmpty ? null : max,
      );
    }
    setState(() {
      _solution = solution;
      _error = error;
    });
    widget.onChanged(solution, error);
  }

  void _pick(LatLng point) {
    // Six decimals is about 0.1 m, far finer than any maximum distance.
    _lat.text = point.latitude.toStringAsFixed(6);
    _lng.text = point.longitude.toStringAsFixed(6);
    _changed();
  }

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
    final GeoSolution? solution = _solution;
    final double? limit = solution?.maxDistanceM;
    final Color color = Theme.of(context).colorScheme.primary;
    const TextInputType numberKeyboard =
        TextInputType.numberWithOptions(decimal: true, signed: true);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      spacing: 8,
      children: <Widget>[
        Row(
          spacing: 8,
          children: <Widget>[
            Expanded(
              child: TextField(
                controller: _lat,
                decoration: const InputDecoration(
                  labelText: 'Latitude',
                  isDense: true,
                  border: OutlineInputBorder(),
                ),
                keyboardType: numberKeyboard,
                inputFormatters: _numberFormatters,
                onChanged: (String _) => _changed(),
              ),
            ),
            Expanded(
              child: TextField(
                controller: _lng,
                decoration: const InputDecoration(
                  labelText: 'Longitude',
                  isDense: true,
                  border: OutlineInputBorder(),
                ),
                keyboardType: numberKeyboard,
                inputFormatters: _numberFormatters,
                onChanged: (String _) => _changed(),
              ),
            ),
          ],
        ),
        TextField(
          controller: _max,
          decoration: const InputDecoration(
            labelText: 'Maximum distance (metres)',
            helperText: 'Optional. A location-only activity with points set is '
                'graded automatically: full points within this distance, '
                'otherwise 0.',
            helperMaxLines: 3,
            isDense: true,
            border: OutlineInputBorder(),
          ),
          keyboardType: numberKeyboard,
          inputFormatters: _numberFormatters,
          onChanged: (String _) => _changed(),
        ),
        if (_error != null)
          InfoBanner(title: _error!, variant: InfoBannerVariant.error),
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
            if (solution != null)
              GeoMapMarker(
                point: LatLng(solution.lat, solution.lng),
                color: color,
              ),
          ],
          circle: solution != null && limit != null
              ? GeoMapCircle(
                  center: LatLng(solution.lat, solution.lng),
                  radiusM: limit,
                  color: color,
                )
              : null,
          onTap: _pick,
        ),
        Text(
          'Tap the map to set the solution, or type the coordinates.',
          style: context.typography.bodySmall.muted(context),
        ),
      ],
    );
  }
}