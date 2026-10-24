import 'package:powersync/powersync.dart' show PowerSyncDatabase;

import 'activity_writes.dart';

/// A subsection as shown in the activity manager.
/// A subsection as shown in the activity manager.
class ManagedSubsection {
  const ManagedSubsection({
    required this.id,
    required this.name,
    required this.description,
  });

  final String id;
  final String name;
  final String description;
}

/// Watches [gameId]'s subsections in display order from the local database.
///
/// [db] is the PowerSync database. Returns a stream of subsections. Database
/// errors are emitted by the stream.
Stream<List<ManagedSubsection>> watchSubsections(
  PowerSyncDatabase db,
  String gameId,
) {
  return db
      .watch(
        'SELECT id, name, "desc" AS description FROM subsections '
        'WHERE game_id = ? AND deleted_at IS NULL '
        'ORDER BY subsection_order, name',
        parameters: <Object?>[gameId],
      )
      .map((results) => <ManagedSubsection>[
            for (final row in results)
              ManagedSubsection(
                id: row['id'] as String,
                name: (row['name'] as String?) ?? '',
                description: (row['description'] as String?) ?? '',
              ),
          ]);
}

/// An activity as shown and edited in the activity manager.
class ManagedActivity {
  const ManagedActivity({
    required this.id,
    required this.subsectionId,
    required this.name,
    required this.description,
    required this.schema,
    required this.points,
    required this.releaseOffsetMinutes,
    required this.canResubmit,
  });

  final String id;
  final String? subsectionId;
  final String name;

  /// Empty when there is none.
  final String description;
  final AnswerSchema schema;
  final int? points;
  final int releaseOffsetMinutes;
  final bool canResubmit;
}

/// Watches [gameId]'s live activities in list order from the local database.
///
/// [db] is the PowerSync database. Returns a stream that emits again whenever
/// the table changes. Database errors are emitted by the stream.
Stream<List<ManagedActivity>> watchManagedActivities(
  PowerSyncDatabase db,
  String gameId,
) {
  return db
      .watch(
        'SELECT id, subsection_id, name, "desc" AS description, '
        'answer_schema, points, release_time_offset_minutes, can_resubmit '
        'FROM activities '
        'WHERE game_id = ? AND deleted_at IS NULL '
        'ORDER BY activity_order, name',
        parameters: <Object?>[gameId],
      )
      .map((results) => <ManagedActivity>[
            for (final row in results)
              ManagedActivity(
                id: row['id'] as String,
                subsectionId: row['subsection_id'] as String?,
                name: (row['name'] as String?) ?? '',
                description: (row['description'] as String?) ?? '',
                schema: AnswerSchema.parse(row['answer_schema'] as String?),
                points: row['points'] as int?,
                releaseOffsetMinutes:
                    (row['release_time_offset_minutes'] as int?) ?? 0,
                canResubmit: row['can_resubmit'] == 1,
              ),
          ]);
}
