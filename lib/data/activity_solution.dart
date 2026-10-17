import 'package:supabase_flutter/supabase_flutter.dart'
    show PostgrestException, Supabase, SupabaseClient;

import 'geo.dart';

/// A failure reading or saving a solution, carrying a short [code].
class SolutionException implements Exception {
  const SolutionException(this.code);

  /// A Postgres error code, or `not_found` when no row was updated.
  final String code;

  /// A message that is safe to show to the user.
  String get message => switch (code) {
        '42501' => 'Only game admins can change a solution.',
        '23514' => 'That location is not valid.',
        'not_found' =>
          'The activity was not found. If you just created it, wait for it '
              'to upload and try again.',
        _ => 'Something went wrong. Try again. Error code: $code',
      };
}

/// Reads and writes `activities.solution`.
///
/// Solutions are not synced to the app database, so this talks to the server
/// directly: it reads through the `activity_solutions` view, which only game
/// admins can see, and writes with a plain update that the database limits to
/// game admins and validates.
class ActivitySolutionApi {
  ActivitySolutionApi([SupabaseClient? client])
      : _client = client ?? Supabase.instance.client;

  final SupabaseClient _client;

  /// Loads the location solution of activity [activityId].
  ///
  /// Returns null when none is set, and for everyone who is not a game admin.
  /// Throws other exceptions on network failure.
  Future<GeoSolution?> loadGeo(String activityId) async {
    final List<Map<String, dynamic>> rows = await _client
        .from('activity_solutions')
        .select('solution')
        .eq('activity_id', activityId)
        .limit(1);
    if (rows.isEmpty) return null;
    return GeoSolution.fromSolutionJson(rows.first['solution']);
  }

  /// Saves [solution] for activity [activityId]; null clears it.
  ///
  /// Throws [SolutionException] when the database refuses (not a game admin,
  /// invalid shape) or when no row was updated, which also happens while a new
  /// activity has not uploaded yet. Throws other exceptions on network
  /// failure.
  Future<void> saveGeo(String activityId, GeoSolution? solution) async {
    try {
      // select('id') makes an empty result visible: an update that matches no
      // row is otherwise reported as success.
      final List<Map<String, dynamic>> rows = await _client
          .from('activities')
          .update(<String, dynamic>{
            'solution': solution?.toSolutionJson(),
            'updated_at': DateTime.now().toUtc().toIso8601String(),
          })
          .eq('id', activityId)
          .select('id');
      if (rows.isEmpty) throw const SolutionException('not_found');
    } on PostgrestException catch (e) {
      throw SolutionException(e.code ?? 'unknown');
    }
  }
}