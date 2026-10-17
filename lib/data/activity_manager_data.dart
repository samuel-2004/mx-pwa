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

/// Watches the game's subsections in display order, from the local database.
Stream<List<ManagedSubsection>> watchSubsections(PowerSyncDatabase db) {
  return db
      .watch(
        'SELECT id, name, "desc" AS description FROM subsections WHERE deleted_at IS NULL '
        'ORDER BY subsection_order, name',
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

/// Watches every live activity in list order, from the local database.
///
/// Emits again whenever the table changes. Subscribe to it once per widget.
Stream<List<ManagedActivity>> watchManagedActivities(PowerSyncDatabase db) {
  return db
      .watch(
        'SELECT id, subsection_id, name, "desc" AS description, '
        'answer_schema, points, release_time_offset_minutes, can_resubmit '
        'FROM activities '
        'WHERE deleted_at IS NULL ORDER BY activity_order, name',
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