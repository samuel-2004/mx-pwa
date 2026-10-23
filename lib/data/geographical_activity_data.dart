import 'package:flutter/foundation.dart' show debugPrint, kDebugMode;
import 'package:powersync/powersync.dart' show PowerSyncDatabase;
import 'package:supabase_flutter/supabase_flutter.dart' show Supabase;

import 'activity_writes.dart' show AnswerSchema, AnswerType;
import 'answer_view.dart' show parseAnswerParts;
import 'geo.dart' show GeoPoint, GeoSolution, isValidLatLng;

/// A location activity and its optional answer-key location.
class GeoActivity {
  const GeoActivity({
    required this.id,
    required this.name,
    this.solution,
  });

  final String id;
  final String name;
  final GeoSolution? solution;
}

/// A non-admin participant with at least one location submission.
class GeoParticipant {
  const GeoParticipant({required this.id, required this.name});

  final String id;
  final String name;
}

/// One location answer with the participant, activity and submission time.
class GeoSubmission {
  const GeoSubmission({
    required this.answerId,
    required this.activityId,
    required this.activityName,
    required this.participantId,
    required this.participantName,
    required this.point,
    required this.createdAt,
  });

  final String answerId;
  final String activityId;
  final String activityName;
  final String participantId;
  final String participantName;
  final GeoPoint point;
  final DateTime? createdAt;
}

/// The activities, participants and location answers shown on the admin map.
class GeoActivityData {
  const GeoActivityData({
    required this.activities,
    required this.participants,
    required this.submissions,
    required this.solutionsUnavailable,
  });

  final List<GeoActivity> activities;
  final List<GeoParticipant> participants;
  final List<GeoSubmission> submissions;
  final bool solutionsUnavailable;
}

/// Watches location answers and the protected activity-solution view.
///
/// [db] supplies the admin's synced game data. Solution coordinates are read
/// from the server because they are deliberately excluded from synced
/// activity rows. Emits when any source table changes. Throws when the local
/// database query fails.
Stream<GeoActivityData> watchGeoActivityData(PowerSyncDatabase db) {
  return db
      .onChange(<String>{'activities', 'answers', 'users'})
      .asyncMap((_) => _loadGeoActivityData(db));
}

Future<GeoActivityData> _loadGeoActivityData(PowerSyncDatabase db) async {
  final local = await db.readTransaction((tx) async {
    final activityRows = await tx.getAll(
      'SELECT id, name, answer_schema FROM activities '
      'WHERE deleted_at IS NULL ORDER BY activity_order, name',
    );
    final answerRows = await tx.getAll(
      'SELECT answers.id AS answer_id, answers.activity_id, answers.user_id, '
      'answers.answer, answers.created_at, activities.name AS activity_name, '
      'users.uname AS participant_name '
      'FROM answers '
      'JOIN activities ON activities.id = answers.activity_id '
      'JOIN users ON users.id = answers.user_id '
      'WHERE answers.deleted_at IS NULL '
      'AND activities.deleted_at IS NULL AND users.deleted_at IS NULL '
      'AND COALESCE(users.is_admin, 0) = 0 '
      'AND COALESCE(users.is_subsection_admin, 0) = 0 '
      'ORDER BY answers.created_at, answers.id',
    );

    final Map<String, GeoActivity> activities = <String, GeoActivity>{};
    for (final row in activityRows) {
      final AnswerSchema schema =
          AnswerSchema.parse(row['answer_schema'] as String?);
      if (!schema.has(AnswerType.geo)) continue;
      final String id = row['id'] as String;
      activities[id] = GeoActivity(
        id: id,
        name: (row['name'] as String?) ?? '',
      );
    }

    final List<GeoSubmission> submissions = <GeoSubmission>[];
    final Map<String, GeoParticipant> participants =
        <String, GeoParticipant>{};
    for (final row in answerRows) {
      final String activityId = row['activity_id'] as String;
      final GeoActivity? activity = activities[activityId];
      if (activity == null) continue;
      final String answerJson = row['answer'] as String? ?? '';
      GeoPoint? point;
      for (final part in parseAnswerParts(answerJson)) {
        if (part.type == AnswerType.geo) {
          point = part.geo;
          break;
        }
      }
      if (point == null || !isValidLatLng(point.lat, point.lng)) continue;

      final String participantId = row['user_id'] as String;
      final String participantName =
          (row['participant_name'] as String?) ?? 'Unknown';
      participants.putIfAbsent(
        participantId,
        () => GeoParticipant(id: participantId, name: participantName),
      );
      submissions.add(
        GeoSubmission(
          answerId: row['answer_id'] as String,
          activityId: activityId,
          activityName: activity.name,
          participantId: participantId,
          participantName: participantName,
          point: point,
          createdAt: DateTime.tryParse((row['created_at'] as String?) ?? ''),
        ),
      );
    }

    return (
      activities: activities,
      participants: participants,
      submissions: submissions,
    );
  });

  bool solutionsUnavailable = false;
  final Map<String, GeoSolution> solutions = <String, GeoSolution>{};
  try {
    final rows = await Supabase.instance.client
        .from('activity_solutions')
        .select('activity_id, solution');
    for (final Object? item in rows) {
      if (item is! Map<String, dynamic>) continue;
      final String? activityId = item['activity_id'] as String?;
      final GeoSolution? solution =
          GeoSolution.fromSolutionJson(item['solution']);
      if (activityId != null &&
          solution != null &&
          isValidLatLng(solution.lat, solution.lng)) {
        solutions[activityId] = solution;
      }
    }
  } on Exception catch (error) {
    solutionsUnavailable = true;
    if (kDebugMode) debugPrint('Could not load activity locations: $error');
  }

  return GeoActivityData(
    activities: <GeoActivity>[
      for (final GeoActivity activity in local.activities.values)
        GeoActivity(
          id: activity.id,
          name: activity.name,
          solution: solutions[activity.id],
        ),
    ],
    participants: local.participants.values.toList(),
    submissions: local.submissions,
    solutionsUnavailable: solutionsUnavailable,
  );
}
