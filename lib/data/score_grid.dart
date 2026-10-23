import 'package:powersync/powersync.dart' show PowerSyncDatabase;
import 'package:supabase_flutter/supabase_flutter.dart'
    show PostgrestException, Supabase, SupabaseClient;

/// One row of the grid: an activity.
class GridActivity {
  const GridActivity({
    required this.id,
    required this.name,
    required this.points,
    required this.subsectionName,
  });

  final String id;
  final String name;

  /// The score limit: positive for a reward, negative for a penalty.
  final int? points;
  final String? subsectionName;
}

/// One column of the grid: a team, which is a player account.
class GridTeam {
  const GridTeam({required this.id, required this.name});

  final String id;
  final String name;
}

/// A team's latest answer to an activity. A team that has not submitted has
/// no cell at all.
class GridCell {
  const GridCell({required this.points});

  /// Null means not graded yet. Zero is a real grade.
  final int? points;
}

/// Returns the key of the cell where [activityId] and [teamId] meet.
///
/// Does not throw.
String cellKey(String activityId, String teamId) => '$activityId|$teamId';

/// Everything the grid shows, read together so it is consistent.
class ScoreGridData {
  const ScoreGridData({
    required this.activities,
    required this.teams,
    required this.cells,
  });

  final List<GridActivity> activities;
  final List<GridTeam> teams;

  /// Latest answers by [cellKey].
  final Map<String, GridCell> cells;
}

// Same order as the player activity list.
const String _activitiesSql = '''
    SELECT a.id AS id, a.name AS name, a.points AS points,
        s.name AS subsection_name
    FROM activities a
    LEFT JOIN subsections s ON s.id = a.subsection_id AND s.deleted_at IS NULL
    WHERE a.deleted_at IS NULL
    ORDER BY COALESCE(s.subsection_order, 2147483647), a.activity_order, a.name
''';

// Graders are not teams: they have no answers of their own to score.
const String _teamsSql = '''
    SELECT id, uname FROM users
    WHERE deleted_at IS NULL
        AND COALESCE(is_admin, 0) = 0
        AND COALESCE(is_subsection_admin, 0) = 0
    ORDER BY LOWER(uname)
''';

// Oldest first, so a later answer replaces an earlier one in the map. The
// answer body is left out because the grid never shows it.
const String _answersSql = '''
    SELECT activity_id, user_id, points FROM answers
    WHERE deleted_at IS NULL
    ORDER BY created_at, id
''';

Future<ScoreGridData> _load(PowerSyncDatabase db) {
  return db.readTransaction((tx) async {
    final activityRows = await tx.getAll(_activitiesSql);
    final teamRows = await tx.getAll(_teamsSql);
    final answerRows = await tx.getAll(_answersSql);
    return ScoreGridData(
      activities: <GridActivity>[
        for (final row in activityRows)
          GridActivity(
            id: row['id'] as String,
            name: (row['name'] as String?) ?? '',
            points: row['points'] as int?,
            subsectionName: row['subsection_name'] as String?,
          ),
      ],
      teams: <GridTeam>[
        for (final row in teamRows)
          GridTeam(
            id: row['id'] as String,
            name: (row['uname'] as String?) ?? '',
          ),
      ],
      cells: <String, GridCell>{
        for (final row in answerRows)
          cellKey(row['activity_id'] as String, row['user_id'] as String):
              GridCell(points: row['points'] as int?),
      },
    );
  });
}

/// Watches the whole grid in the local database.
///
/// [db] the PowerSync database. Admins have every answer synced, so this
/// needs no server call. Emits at once, then again whenever any of the four
/// tables changes, including when a save comes back down. Listen to it once
/// per widget.
Stream<ScoreGridData> watchScoreGrid(PowerSyncDatabase db) {
  return db
      .onChange(<String>{'activities', 'subsections', 'users', 'answers'})
      .asyncMap((_) => _load(db));
}

/// One score to write.
typedef ScoreChange = ({String activityId, String teamId, int points});

/// A failure from the bulk score function, carrying the database error
/// [code].
class ScoreGridException implements Exception {
  const ScoreGridException(this.code);

  final String code;

  /// A message that is safe to show to the user.
  String get message => switch (code) {
        '42501' => 'Only game admins can enter scores in bulk.',
        '22023' => 'A score is outside its activity\'s point range.',
        'P0002' => 'An activity or team no longer exists. Reload the page.',
        _ => 'Something went wrong. Try again. Error code: $code',
      };
}

/// Calls the `bulk_set_scores` database function, which grades the latest
/// answer of each team, or creates one when the team has not submitted.
class ScoreGridApi {
  ScoreGridApi([SupabaseClient? client])
      : _client = client ?? Supabase.instance.client;

  final SupabaseClient _client;

  /// Writes all [changes] in one transaction, so either every score is saved
  /// or none is.
  ///
  /// Throws [ScoreGridException] when the server refuses, and other
  /// exceptions on network failure.
  Future<void> save(List<ScoreChange> changes) async {
    try {
      await _client.rpc(
        'bulk_set_scores',
        params: <String, dynamic>{
          'p_scores': <Map<String, Object>>[
            for (final ScoreChange change in changes)
              <String, Object>{
                'activity_id': change.activityId,
                'user_id': change.teamId,
                'points': change.points,
              },
          ],
        },
      );
    } on PostgrestException catch (e) {
      throw ScoreGridException(e.code ?? 'unknown');
    }
  }
}
