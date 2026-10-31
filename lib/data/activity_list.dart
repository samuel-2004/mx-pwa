import 'package:powersync/powersync.dart' show PowerSyncDatabase;

import 'activity_writes.dart' show AnswerSchema;
import 'activity_notes.dart' show ActivityTag, NotePin, parseTags;
import 'geo.dart' show isValidLatLng;
import 'game_options.dart'
    show
        adminOnlySubmissionSubsections,
        allowResubmissionOptionKey,
        gameOptionDateTime,
        isGameWindowOpenAt,
        gameOptionBool;

/// One row of the activity list, with the caller's own submission state.
class ActivityListItem {
  const ActivityListItem({
    required this.id,
    required this.name,
    required this.points,
    required this.subsectionName,
    required this.releaseAt,
    required this.gameStartsAt,
    required this.gameEndsAt,
    required this.canResubmit,
    required this.adminOnlySubmission,
    required this.answerCount,
    required this.latestPoints,
    required this.tags,
    required this.suburb,
    required this.pin,
    required this.location,
  });

  final String id;
  final String name;
  final int? points;
  final String? subsectionName;

  /// Game start plus the activity's offset, or null when it has no gate.
  final DateTime? releaseAt;
  final DateTime? gameStartsAt;
  final DateTime? gameEndsAt;
  final bool canResubmit;
  final bool adminOnlySubmission;
  final int answerCount;

  /// Points on the caller's latest answer. Null means not graded yet.
  final int? latestPoints;

  /// List of tags used by this user on their other activities.
  final List<ActivityTag> tags;
  /// The suburb of the caller's pin on this activity, or null.
  final String? suburb;

  /// Where the caller dropped a pin on this activity, or null.
  final NotePin? pin;

  /// The activities location, or null.
  final NotePin? location;

  /// Returns the release time if it is still in the future at [now], else
  /// null (already open or never gated).
  DateTime? opensAfter(DateTime now) {
    final DateTime? at = releaseAt;
    if (at == null || !at.isAfter(now)) return null;
    return at;
  }

  /// Checks whether this activity is inside its game's schedule window.
  ///
  /// [now] is the current time. Returns false outside the window; does not
  /// throw.
  bool gameWindowIsOpenAt(DateTime now) => isGameWindowOpenAt(
        now: now,
        startsAt: gameStartsAt,
        endsAt: gameEndsAt,
      );
}

// Ordered by subsection, then activity. Activities without a subsection
// sort last. Reads the local database only.
const String _activitiesSql = '''
SELECT
  a.id AS id,
  a.name AS name,
  a.points AS points,
  a.answer_schema AS answer_schema,
  a.can_resubmit AS can_resubmit,
  a.subsection_id AS subsection_id,
  a.release_time_offset_minutes AS offset_minutes,
  s.name AS subsection_name,
  g.starts_at AS starts_at,
  g.game_options AS game_options,
  (SELECT COUNT(*) FROM answers x
    WHERE x.activity_id = a.id AND x.user_id = ? AND x.deleted_at IS NULL
  ) AS answer_count,
  (SELECT x.points FROM answers x
    WHERE x.activity_id = a.id AND x.user_id = ? AND x.deleted_at IS NULL
    ORDER BY x.created_at DESC LIMIT 1
  ) AS latest_points,
  (SELECT n.tags FROM user_activity_notes n
    WHERE n.activity_id = a.id AND n.user_id = ?
  ) AS tags,
  (SELECT n.suburb FROM user_activity_notes n
    WHERE n.activity_id = a.id AND n.user_id = ?
  ) AS suburb,
  (SELECT n.lat FROM user_activity_notes n
    WHERE n.activity_id = a.id AND n.user_id = ?
  ) AS pin_lat,
  (SELECT n.lng FROM user_activity_notes n
    WHERE n.activity_id = a.id AND n.user_id = ?
  ) AS pin_lng,
  a.location_lat AS loc_lat,
  a.location_lng AS loc_lng
FROM activities a
LEFT JOIN subsections s ON s.id = a.subsection_id AND s.deleted_at IS NULL
LEFT JOIN games g ON g.id = a.game_id
WHERE a.game_id = (
    SELECT game_id FROM users WHERE id = ? AND deleted_at IS NULL LIMIT 1
  )
  AND a.deleted_at IS NULL
ORDER BY COALESCE(s.subsection_order, 2147483647), a.activity_order, a.name
''';

/// Watches the activity list from the local database.
///
/// [db] is the PowerSync database; [userId] identifies the signed-in user and
/// whose submissions to attach. Returns a stream of answerable activities in
/// that user's game, re-emitting when the underlying tables change. The userId
/// is bound as a query parameter. An unparseable start time is treated as no
/// release gate. Activities with no answer types are left out. Query errors
/// are emitted by the stream.
Stream<List<ActivityListItem>> watchActivities(
  PowerSyncDatabase db,
  String userId,
) {
  return db
      .watch(
        _activitiesSql,
        // One userId per placeholder in the query.
        parameters: List<Object?>.filled(7, userId),
      )
      .map((results) {
    return <ActivityListItem>[
      for (final row in results)
        if (AnswerSchema.parse(row['answer_schema'] as String?).isAnswerable)
          ActivityListItem(
            id: row['id'] as String,
            name: (row['name'] as String?) ?? '',
            points: row['points'] as int?,
            subsectionName: row['subsection_name'] as String?,
            releaseAt: releaseAt(
              row['starts_at'] as String?,
              (row['offset_minutes'] as int?) ?? 0,
            ),
            gameStartsAt: gameOptionDateTime(row['game_options'], 'starts_at'),
            gameEndsAt: gameOptionDateTime(row['game_options'], 'ends_at'),
            canResubmit: row['can_resubmit'] == 1 &&
                gameOptionBool(
                  row['game_options'],
                  allowResubmissionOptionKey,
                  defaultValue: true,
                ),
            adminOnlySubmission: row['subsection_id'] is String &&
                adminOnlySubmissionSubsections(row['game_options'])
                    .contains(row['subsection_id']),
            answerCount: (row['answer_count'] as int?) ?? 0,
            latestPoints: row['latest_points'] as int?,
            tags: parseTags(row['tags'] as String?),
            suburb: row['suburb'] as String?,
            pin: _latLngFrom(row['pin_lat'], row['pin_lng']),
            location: _latLngFrom(row['loc_lat'], row['loc_lng']),
          ),
    ];
  });
}

DateTime? releaseAt(String? startsAt, int offsetMinutes) {
  if (startsAt == null) return null;
  final DateTime? start = DateTime.tryParse(startsAt);
  return start?.add(Duration(minutes: offsetMinutes));
}

/// Builds a pin from the two stored coordinates.
///
/// [lat] and [lng] are raw column values. Returns null unless both are
/// numbers forming a valid position. Does not throw.
NotePin? _latLngFrom(Object? lat, Object? lng) {
  if (lat is! num || lng is! num) return null;
  if (!isValidLatLng(lat.toDouble(), lng.toDouble())) return null;
  return (lat: lat.toDouble(), lng: lng.toDouble());
}

/// Drops the activities outside their game's schedule window.
///
/// [items] the activities to check. [now] the current time.
/// [canViewOutsideGameWindow] is true for staff, who see everything. Returns
/// the remaining activities in their order. Does not throw.
List<ActivityListItem> availableActivities(
  List<ActivityListItem> items, {
  required DateTime now,
  required bool canViewOutsideGameWindow,
}) {
  if (canViewOutsideGameWindow) return items;
  return <ActivityListItem>[
    for (final ActivityListItem item in items)
      if (item.gameWindowIsOpenAt(now)) item,
  ];
}

/// Lists the distinct tag names on [items], sorted without regard to case.
///
/// [items] the activities to read tags from. Returns the names. Does not
/// throw.
List<String> tagNames(List<ActivityListItem> items) {
  final Set<String> names = <String>{
    for (final ActivityListItem item in items)
      for (final ActivityTag tag in item.tags) tag.name,
  };
  return names.toList()
    ..sort((String a, String b) => a.toLowerCase().compareTo(b.toLowerCase()));
}

/// Keeps the activities that have at least one tag named in [active].
///
/// [items] the activities to filter. [active] the chosen tag names; empty
/// keeps everything. Returns the matching activities in their order. Does not
/// throw.
List<ActivityListItem> filterByTags(
  List<ActivityListItem> items,
  Set<String> active,
) {
  if (active.isEmpty) return items;
  return <ActivityListItem>[
    for (final ActivityListItem item in items)
      if (item.tags.any((ActivityTag tag) => active.contains(tag.name))) item,
  ];
}