import 'package:supabase_flutter/supabase_flutter.dart'
    show PostgrestException, Supabase, SupabaseClient;

import 'geo.dart';

/// One answer waiting to be graded, or already graded.
class GradingItem {
  const GradingItem({
    required this.answerId,
    required this.activityName,
    required this.activityDescription,
    required this.maxPoints,
    required this.subsectionName,
    required this.username,
    required this.answerJson,
    required this.points,
    required this.createdAt,
    this.geoSolution,
    this.distanceM,
  });

  final String answerId;
  final String activityName;

  /// Empty when there is none.
  final String activityDescription;

  /// The score limit: positive for a reward, negative for a penalty.
  final int? maxPoints;
  final String? subsectionName;
  final String username;
  final String answerJson;

  /// Null means not graded yet.
  final int? points;
  final DateTime? createdAt;

  /// Where a location answer should be. Only sent for activities the grader
  /// can grade, and null when none is set.
  final GeoSolution? geoSolution;

  /// How far a location answer is from [geoSolution], in metres.
  final double? distanceM;

  /// A copy with [points] set.
  GradingItem withPoints(int points) => GradingItem(
        answerId: answerId,
        activityName: activityName,
        activityDescription: activityDescription,
        maxPoints: maxPoints,
        subsectionName: subsectionName,
        username: username,
        answerJson: answerJson,
        points: points,
        createdAt: createdAt,
        geoSolution: geoSolution,
        distanceM: distanceM,
      );
}

/// A failure from the grading functions, carrying the database error [code].
class GradingException implements Exception {
  const GradingException(this.code);

  final String code;

  /// A message that is safe to show to the user.
  String get message => switch (code) {
        '42501' => 'You cannot grade that answer.',
        '22023' => 'Points are outside the activity\'s point range.',
        '23514' => 'That answer was replaced by a newer one. Refresh the list.',
        'P0002' => 'That answer no longer exists.',
        _ => 'Something went wrong. Try again.',
      };
}

/// Calls the `grading_queue` and `grade_answer` database functions. They
/// decide which answers the signed-in grader may see and change.
class GradingApi {
  GradingApi([SupabaseClient? client])
      : _client = client ?? Supabase.instance.client;

  final SupabaseClient _client;

  /// Loads the latest answer per player per activity the caller can grade,
  /// oldest first, up to 100.
  ///
  /// [includeGraded] also returns answers that already have points. Throws
  /// [GradingException] when the server refuses, and other exceptions on
  /// network failure.
  Future<List<GradingItem>> loadQueue({required bool includeGraded}) async {
    try {
      final Object? data = await _client.rpc(
        'grading_queue',
        params: <String, dynamic>{'p_include_graded': includeGraded},
      );
      if (data is! List<dynamic>) throw const GradingException('unknown');
      return <GradingItem>[
        for (final Object? row in data)
          if (row is Map<String, dynamic>) _item(row),
      ];
    } on PostgrestException catch (e) {
      throw GradingException(e.code ?? 'unknown');
    }
  }

  /// Sets the points on answer [answerId].
  ///
  /// Throws [GradingException] when the server refuses (not allowed, out of
  /// range, or the answer was replaced), and other exceptions on network
  /// failure.
  Future<void> grade({required String answerId, required int points}) async {
    try {
      await _client.rpc(
        'grade_answer',
        params: <String, dynamic>{'p_answer_id': answerId, 'p_points': points},
      );
    } on PostgrestException catch (e) {
      throw GradingException(e.code ?? 'unknown');
    }
  }

  GradingItem _item(Map<String, dynamic> row) {
    final Object? created = row['created_at'];
    return GradingItem(
      answerId: row['answer_id'] as String,
      activityName: (row['activity_name'] as String?) ?? '',
      activityDescription: (row['activity_description'] as String?) ?? '',
      maxPoints: row['max_points'] as int?,
      subsectionName: row['subsection_name'] as String?,
      username: (row['username'] as String?) ?? '',
      answerJson: (row['answer'] as String?) ?? '',
      points: row['points'] as int?,
      createdAt: created is String ? DateTime.tryParse(created) : null,
      geoSolution: GeoSolution.fromSolutionJson(row['solution']),
      distanceM: (row['distance_m'] as num?)?.toDouble(),
    );
  }
}
