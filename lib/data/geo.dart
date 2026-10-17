/// Where a submitted location came from.
enum GeoOrigin {
  device('device', 'the user\'s device'),
  photo('photo', 'the photo'),
  map('map', 'manual entry');

  const GeoOrigin(this.wireName, this.label);

  /// Stored in the answer as `source`. The `answers_before_insert` trigger
  /// only accepts these three values.
  final String wireName;

  /// Completes "from ..." in the UI.
  final String label;

  /// Finds the origin whose [wireName] equals [name], or null.
  static GeoOrigin? fromWireName(Object? name) {
    for (final GeoOrigin origin in GeoOrigin.values) {
      if (origin.wireName == name) return origin;
    }
    return null;
  }
}

/// Whether [lat] and [lng] are finite and inside the valid ranges.
///
/// Mirrors `valid_activity_solution` and the answers trigger. Does not throw.
bool isValidLatLng(double lat, double lng) {
  return lat.isFinite &&
      lng.isFinite &&
      lat >= -90 &&
      lat <= 90 &&
      lng >= -180 &&
      lng <= 180;
}

/// Formats a distance in metres, in kilometres from 1000 m up.
///
/// Does not throw.
String formatDistance(double meters) {
  if (meters >= 1000) return '${(meters / 1000).toStringAsFixed(2)} km';
  return '${meters.round()} m';
}

/// One captured position: the part of a location answer stored under
/// `parts.geo`.
///
/// Deliberately not tied to answers (position, accuracy, time, origin), so a
/// later feature that records positions at intervals can reuse it.
class GeoPoint {
  const GeoPoint({
    required this.lat,
    required this.lng,
    required this.origin,
    this.accuracyM,
    this.capturedAt,
  });

  final double lat;
  final double lng;
  final GeoOrigin origin;

  /// Horizontal accuracy in metres, when the source reports one.
  final double? accuracyM;
  final DateTime? capturedAt;

  /// Reads a stored `parts.geo` object.
  ///
  /// Returns null unless [json] is an object with numeric `lat` and `lng`.
  /// An unknown origin is read as the map. Does not throw.
  static GeoPoint? tryParse(Object? json) {
    if (json is! Map<String, dynamic>) return null;
    final Object? lat = json['lat'];
    final Object? lng = json['lng'];
    if (lat is! num || lng is! num) return null;
    final Object? accuracy = json['accuracy_m'];
    final Object? captured = json['captured_at'];
    return GeoPoint(
      lat: lat.toDouble(),
      lng: lng.toDouble(),
      origin: GeoOrigin.fromWireName(json['source']) ?? GeoOrigin.map,
      accuracyM: accuracy is num ? accuracy.toDouble() : null,
      capturedAt: captured is String ? DateTime.tryParse(captured) : null,
    );
  }

  /// The JSON stored under `parts.geo`. Keep the shape in sync with the
  /// `answers_before_insert` trigger. Does not throw.
  Map<String, Object> toAnswerPart() {
    final double? accuracy = accuracyM;
    final DateTime? captured = capturedAt;
    return <String, Object>{
      'lat': lat,
      'lng': lng,
      'source': origin.wireName,
      if (accuracy != null) 'accuracy_m': accuracy,
      if (captured != null) 'captured_at': captured.toUtc().toIso8601String(),
    };
  }
}

/// The answer key of a location activity: where the player should be, and
/// how close counts as correct.
///
/// Stored in `activities.solution` as `{"geo": {...}}`. Only admins can read
/// it; see the `activity_solutions` view.
class GeoSolution {
  const GeoSolution({required this.lat, required this.lng, this.maxDistanceM});

  final double lat;
  final double lng;

  /// Answers within this many metres are correct. Null means no limit is set,
  /// so nothing is graded automatically.
  final double? maxDistanceM;

  /// Reads a stored solution object.
  ///
  /// Returns null unless [solution] has a `geo` object with numeric `lat` and
  /// `lng`. Does not throw.
  static GeoSolution? fromSolutionJson(Object? solution) {
    if (solution is! Map<String, dynamic>) return null;
    final Object? geo = solution['geo'];
    if (geo is! Map<String, dynamic>) return null;
    final Object? lat = geo['lat'];
    final Object? lng = geo['lng'];
    if (lat is! num || lng is! num) return null;
    final Object? max = geo['max_distance_m'];
    return GeoSolution(
      lat: lat.toDouble(),
      lng: lng.toDouble(),
      maxDistanceM: max is num ? max.toDouble() : null,
    );
  }

  /// The JSON to store in `activities.solution`. Does not throw.
  Map<String, Object> toSolutionJson() {
    final double? max = maxDistanceM;
    return <String, Object>{
      'geo': <String, Object>{
        'lat': lat,
        'lng': lng,
        if (max != null) 'max_distance_m': max,
      },
    };
  }

  @override
  bool operator ==(Object other) =>
      other is GeoSolution &&
      other.lat == lat &&
      other.lng == lng &&
      other.maxDistanceM == maxDistanceM;

  @override
  int get hashCode => Object.hash(lat, lng, maxDistanceM);
}