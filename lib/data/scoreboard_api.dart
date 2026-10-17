import 'package:supabase_flutter/supabase_flutter.dart'
    show PostgrestException, Supabase, SupabaseClient;

/// One player's row on the scoreboard.
class ScoreboardEntry {
  const ScoreboardEntry({
    required this.place,
    required this.userId,
    required this.username,
    required this.totalPoints,
    required this.gradedCount,
  });

  /// 1 for the leader. Players with the same points share a place.
  final int place;
  final String userId;
  final String username;
  final int totalPoints;

  /// How many activities have a graded answer.
  final int gradedCount;
}

/// A failure from the scoreboard function, carrying the database error [code].
class ScoreboardException implements Exception {
  const ScoreboardException(this.code);

  final String code;

  /// A message that is safe to show to the user.
  String get message => switch (code) {
        '55000' => 'The scoreboard is turned off for this game.',
        '42501' => 'You cannot view the scoreboard.',
        _ => 'Something went wrong. Try again. Error code: $code',
      };
}

/// Calls the `scoreboard` database function, which works out the ranking from
/// every player's graded answers. It runs on the server because other
/// players' answers are not synced to this device.
class ScoreboardApi {
  ScoreboardApi([SupabaseClient? client])
      : _client = client ?? Supabase.instance.client;

  final SupabaseClient _client;

  /// Loads the ranking for the signed-in user's game, best first.
  ///
  /// Throws [ScoreboardException] when the server refuses (for example the
  /// scoreboard is turned off), and other exceptions on network failure.
  Future<List<ScoreboardEntry>> load() async {
    try {
      final Object? data = await _client.rpc('scoreboard');
      if (data is! List<dynamic>) throw const ScoreboardException('unknown');
      return <ScoreboardEntry>[
        for (final Object? row in data)
          if (row is Map<String, dynamic>)
            ScoreboardEntry(
              place: (row['place'] as num?)?.toInt() ?? 0,
              userId: row['user_id'] as String,
              username: (row['username'] as String?) ?? '',
              totalPoints: (row['total_points'] as num?)?.toInt() ?? 0,
              gradedCount: (row['graded_count'] as num?)?.toInt() ?? 0,
            ),
      ];
    } on PostgrestException catch (e) {
      throw ScoreboardException(e.code ?? 'unknown');
    }
  }
}