import 'dart:async' show Timer, unawaited;
import 'dart:convert' show jsonDecode, utf8;
import 'dart:math' show asin, cos, min, pi, sin, sqrt;

import 'package:flutter/foundation.dart' show debugPrint, kDebugMode;
import 'package:http/http.dart' as http;
import 'package:powersync/powersync.dart' show PowerSyncDatabase;

import 'activity_notes.dart' show maxSuburbLength;

// How long a pin must stay as it is before its suburb is looked up. Every new
// pin restarts the wait.
const Duration _settleDelay = Duration(seconds: 5);

// A pin closer than this to the place the suburb was last looked up for keeps
// the suburb it has.
const double _relookupMeters = 500;

const Duration _requestTimeout = Duration(seconds: 10);

// The public OpenStreetMap server is for light use only (at most one request
// per second). Point this at a keyed or self-hosted instance for a real event.
const String _geocoderHost = 'nominatim.openstreetmap.org';

// Address parts that can name the area, best first. Nominatim leaves out the
// ones that do not apply, and which one is used varies by country.
const List<String> _areaKeys = <String>[
  'suburb',
  'city_district',
  'neighbourhood',
  'quarter',
  'village',
  'town',
  'city',
];

final RegExp _controlChars = RegExp(r'[\x00-\x1F\x7F]');

// One timer per player and activity, kept here rather than in a widget so a
// lookup still happens if the player leaves the page within the wait.
final Map<String, Timer> _pending = <String, Timer>{};

/// Schedules a suburb lookup for the player's pin on an activity.
///
/// Waits five seconds, and every further call for the same player and
/// activity restarts the wait, so a pin that is being moved is looked up
/// once, where it ends up. The lookup then runs only if the pin is more than
/// 500 m from the place the suburb was last looked up for, or has no suburb
/// yet. The result is saved to the note and shows through
/// `watchActivityNote`.
///
/// [db] the PowerSync database. [userId] the signed-in player. [activityId]
/// the activity. Returns at once. Does not throw; a failed lookup is logged
/// in debug builds and tried again the next time this is called.
void scheduleSuburbLookup(
  PowerSyncDatabase db, {
  required String userId,
  required String activityId,
}) {
  final String key = '$userId/$activityId';
  _pending[key]?.cancel();
  _pending[key] = Timer(_settleDelay, () {
    _pending.remove(key);
    unawaited(_refreshSuburb(db, userId: userId, activityId: activityId));
  });
}

/// Reads the area name from a Nominatim reverse geocoding response.
///
/// [body] the response text in `jsonv2` format. Returns the first of suburb,
/// city district, neighbourhood, quarter, village, town and city that is
/// present, with control characters removed and cut to the stored limit.
/// Returns null when the response has none of them or is not what was
/// expected. Does not throw.
String? parseSuburb(String body) {
  try {
    final Object? decoded = jsonDecode(body);
    if (decoded is! Map<String, dynamic>) return null;
    final Object? address = decoded['address'];
    if (address is! Map<String, dynamic>) return null;
    for (final String key in _areaKeys) {
      final Object? value = address[key];
      if (value is! String) continue;
      final String clean = value.replaceAll(_controlChars, '').trim();
      if (clean.isEmpty) continue;
      return clean.length > maxSuburbLength
          ? clean.substring(0, maxSuburbLength)
          : clean;
    }
    return null;
  } on FormatException {
    return null;
  }
}

Future<void> _refreshSuburb(
  PowerSyncDatabase db, {
  required String userId,
  required String activityId,
}) async {
  try {
    final row = await db.getOptional(
      'SELECT lat, lng, suburb_lat, suburb_lng FROM user_activity_notes '
      'WHERE user_id = ? AND activity_id = ?',
      <Object?>[userId, activityId],
    );
    final double? lat = (row?['lat'] as num?)?.toDouble();
    final double? lng = (row?['lng'] as num?)?.toDouble();
    // No pin: removing it already cleared the suburb.
    if (lat == null || lng == null) return;
    final double? lastLat = (row?['suburb_lat'] as num?)?.toDouble();
    final double? lastLng = (row?['suburb_lng'] as num?)?.toDouble();
    if (lastLat != null &&
        lastLng != null &&
        _distanceMeters(lat, lng, lastLat, lastLng) <= _relookupMeters) {
      return;
    }
    final String? suburb = await _reverseSuburb(lat, lng);
    await _storeSuburb(
      db,
      userId: userId,
      activityId: activityId,
      suburb: suburb,
      lat: lat,
      lng: lng,
    );
  } on Exception catch (e) {
    if (kDebugMode) debugPrint('Suburb lookup failed: $e');
  }
}

// Returns null when the geocoder has no area name for the point. Throws when
// the request fails, so a failure is not mistaken for "no suburb" and the
// point is looked up again later.
Future<String?> _reverseSuburb(double lat, double lng) async {
  // Browsers send their own User-Agent and Referer, which is what the usage
  // policy asks for, so no headers are set here.
  final Uri uri = Uri.https(_geocoderHost, '/reverse', <String, String>{
    'lat': lat.toStringAsFixed(6),
    'lon': lng.toStringAsFixed(6),
    'format': 'jsonv2',
  });
  final http.Response response = await http.get(uri).timeout(_requestTimeout);
  if (response.statusCode != 200) {
    throw http.ClientException('Geocoder replied ${response.statusCode}.', uri);
  }
  return parseSuburb(utf8.decode(response.bodyBytes));
}

// Records the suburb with the point it was looked up for, even when there is
// no suburb, so that point is not looked up again until the pin moves away
// from it. Skipped if the pin was removed while the request was running.
Future<void> _storeSuburb(
  PowerSyncDatabase db, {
  required String userId,
  required String activityId,
  required String? suburb,
  required double lat,
  required double lng,
}) {
  return db.execute(
    'UPDATE user_activity_notes '
    'SET suburb = ?, suburb_lat = ?, suburb_lng = ?, updated_at = ? '
    'WHERE user_id = ? AND activity_id = ? AND lat IS NOT NULL',
    <Object?>[
      suburb,
      lat,
      lng,
      DateTime.now().toUtc().toIso8601String(),
      userId,
      activityId,
    ],
  );
}

// Great-circle distance, which is accurate enough for a 500 m threshold.
double _distanceMeters(double lat1, double lng1, double lat2, double lng2) {
  const double earthRadiusM = 6371000;
  double radians(double degrees) => degrees * pi / 180;
  final double sinLat = sin(radians(lat2 - lat1) / 2);
  final double sinLng = sin(radians(lng2 - lng1) / 2);
  final double a = sinLat * sinLat +
      cos(radians(lat1)) * cos(radians(lat2)) * sinLng * sinLng;
  return 2 * earthRadiusM * asin(min(1.0, sqrt(a)));
}