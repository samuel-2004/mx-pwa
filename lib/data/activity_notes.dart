import 'dart:convert';

import 'package:powersync/powersync.dart' show PowerSyncDatabase;

import 'geo.dart' show isValidLatLng;

/// The most tags one player can put on one activity. Keep in sync with
/// `valid_activity_tags` in the database.
const int maxTagsPerActivity = 5;

/// The longest tag name, in characters. Keep in sync with
/// `valid_activity_tags` in the database.
const int maxTagNameLength = 30;

/// The longest suburb name kept, in characters. Keep in sync with the
/// `suburb` check in the database.
const int maxSuburbLength = 100;

/// The colours offered for a tag, as `#RRGGBB`. The database accepts any
/// colour in that form, so this only limits what the app offers.
const List<String> tagPalette = <String>[
  '#DC2626',
  '#EA580C',
  '#CA8A04',
  '#16A34A',
  '#0D9488',
  '#2563EB',
  '#7C3AED',
  '#DB2777',
];

final RegExp _colorPattern = RegExp(r'^#[0-9A-Fa-f]{6}$');
final RegExp _controlChars = RegExp(r'[\x00-\x1F\x7F]');

/// One tag: a name and its colour as `#RRGGBB`.
class ActivityTag {
  const ActivityTag({required this.name, required this.color});

  final String name;
  final String color;
}

/// A point the player dropped on the map, in degrees.
typedef NotePin = ({double lat, double lng});

/// A player's private notes on one activity.
///
/// Stored in `user_activity_notes`, which only its owner can read. Admins
/// and other players never receive it.
class ActivityNote {
  const ActivityNote({
    this.tags = const <ActivityTag>[],
    this.pin,
    this.suburb,
  });

  /// What a player with no notes yet has.
  static const ActivityNote empty = ActivityNote();

  /// Sorted by name, at most [maxTagsPerActivity].
  final List<ActivityTag> tags;

  /// Where the player thinks the activity should be done, or null.
  final NotePin? pin;

  /// The suburb of [pin], looked up from the map, or null while there is no
  /// pin or no result yet.
  final String? suburb;
}

/// Reads stored tags JSON, sorted by name.
///
/// Accepts the object `{"name": "#RRGGBB"}`, including JSON that was encoded
/// twice. Entries with an empty name or an invalid colour are dropped.
/// Returns an empty list for missing or invalid input. Does not throw.
List<ActivityTag> parseTags(String? json) {
  if (json == null) return const <ActivityTag>[];
  try {
    Object? decoded = jsonDecode(json);
    // The server can hand back JSON that was encoded twice.
    if (decoded is String) decoded = jsonDecode(decoded);
    if (decoded is! Map<String, dynamic>) return const <ActivityTag>[];
    final List<ActivityTag> tags = <ActivityTag>[
      for (final MapEntry<String, dynamic> entry in decoded.entries)
        if (entry.key.isNotEmpty &&
            entry.value is String &&
            _colorPattern.hasMatch(entry.value as String))
          ActivityTag(name: entry.key, color: entry.value as String),
    ];
    _sortByName(tags);
    return tags;
  } on FormatException {
    return const <ActivityTag>[];
  }
}

void _sortByName(List<ActivityTag> tags) => tags.sort(
      (ActivityTag a, ActivityTag b) =>
          a.name.toLowerCase().compareTo(b.name.toLowerCase()),
    );

// Names are the JSON keys, so the colours cannot be stored more than once
// per name.
String _encodeTags(List<ActivityTag> tags) => jsonEncode(
      <String, String>{for (final ActivityTag tag in tags) tag.name: tag.color},
    );

/// Checks the name of a tag the player is making.
///
/// [value] the raw field text. [known] every tag the player already has, on
/// any activity, so one name is never made twice. Returns an error message,
/// or null when the name is fine. Names are compared without regard to case.
/// The per-activity limit is the caller's to check. Does not throw.
String? validateNewTagName(String? value, List<ActivityTag> known) {
  final String name = (value ?? '').trim();
  if (name.isEmpty) return 'Enter a name.';
  if (name.length > maxTagNameLength) {
    return 'Use at most $maxTagNameLength characters.';
  }
  if (_controlChars.hasMatch(name)) return 'Use plain text only.';
  final String lower = name.toLowerCase();
  if (known.any((ActivityTag tag) => tag.name.toLowerCase() == lower)) {
    return 'You already have a tag with that name.';
  }
  return null;
}

/// Watches the player's notes on one activity in the local database.
///
/// [db] the PowerSync database. [userId] the signed-in player. [activityId]
/// the activity. Returns a stream that emits [ActivityNote.empty] while there
/// are no notes, and again whenever they change. Subscribe to it once per
/// widget. Does not throw.
Stream<ActivityNote> watchActivityNote(
  PowerSyncDatabase db, {
  required String userId,
  required String activityId,
}) {
  return db
      .watch(
        'SELECT tags, lat, lng, suburb FROM user_activity_notes '
        'WHERE user_id = ? AND activity_id = ? LIMIT 1',
        parameters: <Object?>[userId, activityId],
      )
      .map((results) {
    if (results.isEmpty) return ActivityNote.empty;
    final row = results.first;
    final double? lat = (row['lat'] as num?)?.toDouble();
    final double? lng = (row['lng'] as num?)?.toDouble();
    final bool hasPin = lat != null && lng != null && isValidLatLng(lat, lng);
    return ActivityNote(
      tags: parseTags(row['tags'] as String?),
      pin: hasPin ? (lat: lat, lng: lng) : null,
      suburb: hasPin ? row['suburb'] as String? : null,
    );
  });
}

/// Watches every tag the player has made, on any activity, in the local
/// database.
///
/// [db] the PowerSync database. [userId] the signed-in player. Returns a
/// stream of the distinct tags sorted by name, which emits again whenever
/// the notes change. A name is listed once, without regard to case, with the
/// colour from the most recently saved note. Subscribe to it once per
/// widget. Does not throw.
Stream<List<ActivityTag>> watchTagLibrary(
  PowerSyncDatabase db, {
  required String userId,
}) {
  return db
      .watch(
        'SELECT tags FROM user_activity_notes WHERE user_id = ? '
        'ORDER BY updated_at DESC',
        parameters: <Object?>[userId],
      )
      .map((results) {
    final Map<String, ActivityTag> byName = <String, ActivityTag>{};
    for (final row in results) {
      for (final ActivityTag tag in parseTags(row['tags'] as String?)) {
        byName.putIfAbsent(tag.name.toLowerCase(), () => tag);
      }
    }
    final List<ActivityTag> library = byName.values.toList();
    _sortByName(library);
    return library;
  });
}

// [values] keys are fixed column names from this file, never user input;
// every value goes through a bound parameter.
Future<void> _saveNote(
  PowerSyncDatabase db, {
  required String userId,
  required String activityId,
  required Map<String, Object?> values,
}) {
  return db.writeTransaction((tx) async {
    final Map<String, Object?> changed = <String, Object?>{
      ...values,
      'updated_at': _now(),
    };
    final existing = await tx.getOptional(
      'SELECT id FROM user_activity_notes WHERE user_id = ? AND activity_id = ?',
      <Object?>[userId, activityId],
    );
    if (existing != null) {
      await tx.execute(
        'UPDATE user_activity_notes SET '
        '${changed.keys.map((String name) => '$name = ?').join(', ')} '
        'WHERE id = ?',
        <Object?>[...changed.values, existing['id']],
      );
      return;
    }
    // The server requires tags, so a new row that only sets a pin still
    // starts with an empty tag object.
    final Map<String, Object?> row = <String, Object?>{
      'tags': '{}',
      ...changed,
    };
    await tx.execute(
      'INSERT INTO user_activity_notes (id, user_id, activity_id, '
      '${row.keys.join(', ')}) VALUES (uuid(), ?, ?, '
      '${List<String>.filled(row.length, '?').join(', ')})',
      <Object?>[userId, activityId, ...row.values],
    );
  });
}

String _now() => DateTime.now().toUtc().toIso8601String();

/// Replaces the player's tags on an activity.
///
/// [tags] the complete new set; an empty list removes all. Written locally in
/// one transaction and uploaded later, so the server can still reject it
/// (RLS or constraints), which the connector logs. Returns when the local
/// write is done. Throws [ArgumentError] if there are more than
/// [maxTagsPerActivity] tags, and other exceptions if the local write fails.
Future<void> setActivityTags(
  PowerSyncDatabase db, {
  required String userId,
  required String activityId,
  required List<ActivityTag> tags,
}) async {
  if (tags.length > maxTagsPerActivity) {
    throw ArgumentError('At most $maxTagsPerActivity tags.');
  }
  await _saveNote(
    db,
    userId: userId,
    activityId: activityId,
    values: <String, Object?>{'tags': _encodeTags(tags)},
  );
}

/// Sets or clears the player's map pin on an activity.
///
/// [pin] the point to keep; null removes the pin and its suburb. Longitudes from a map
/// that was panned past the date line are wrapped into -180 to 180. Same
/// upload behavior as [setActivityTags]. Throws [ArgumentError] if the
/// point is not a valid position, and other exceptions if the local write
/// fails.
Future<void> setActivityPin(
  PowerSyncDatabase db, {
  required String userId,
  required String activityId,
  required NotePin? pin,
}) async {
  final NotePin? wrapped =
      pin == null ? null : (lat: pin.lat, lng: (pin.lng + 180) % 360 - 180);
  if (wrapped != null && !isValidLatLng(wrapped.lat, wrapped.lng)) {
    throw ArgumentError('Not a valid position.');
  }
  await _saveNote(
    db,
    userId: userId,
    activityId: activityId,
    values: <String, Object?>{
      'lat': wrapped?.lat,
      'lng': wrapped?.lng,
      // A suburb belongs to its pin, so removing the pin removes it too.
      if (wrapped == null) ...<String, Object?>{
        'suburb': null,
        'suburb_lat': null,
        'suburb_lng': null,
      },
    },
  );
}