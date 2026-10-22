import 'package:powersync/powersync.dart' show PowerSyncDatabase;

import 'activity_writes.dart' show AnswerSchema;
import 'activity_notes.dart' show ActivityTag, parseTags;
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
  ) AS suburb
FROM activities a
LEFT JOIN subsections s ON s.id = a.subsection_id AND s.deleted_at IS NULL
LEFT JOIN games g ON g.id = a.game_id
WHERE a.deleted_at IS NULL
ORDER BY COALESCE(s.subsection_order, 2147483647), a.activity_order, a.name
''';

/// Watches the activity list from the local database.
///
/// [db] the PowerSync database. [userId] whose submissions to attach.
/// Returns a stream that emits again whenever the underlying tables change.
/// The userId is bound as a query parameter. An unparseable start time is
/// treated as no release gate. Activities with nothing to answer yet, such as
/// a location-only one whose solution is not set, are left out.
Stream<List<ActivityListItem>> watchActivities(
  PowerSyncDatabase db,
  String userId,
) {
  return db
      .watch(_activitiesSql, parameters: <Object?>[userId, userId, userId, userId])
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
          ),
    ];
  });
}

DateTime? releaseAt(String? startsAt, int offsetMinutes) {
  if (startsAt == null) return null;
  final DateTime? start = DateTime.tryParse(startsAt);
  return start?.add(Duration(minutes: offsetMinutes));
}
