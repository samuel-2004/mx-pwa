import 'package:supabase_flutter/supabase_flutter.dart'
    show FunctionException, FunctionResponse, Supabase, SupabaseClient;
import 'package:flutter/foundation.dart' show debugPrint, kDebugMode;

import 'grading_models.dart';

/// A member of the signed-in admin's game.
class GameUser {
  const GameUser({
    required this.id,
    required this.username,
    required this.isAdmin,
    this.subsectionIds = const <String>[],
  });

  final String id;
  final String username;
  final bool isAdmin;

  /// Subsections this user can grade. Empty for admins, who can grade all.
  final List<String> subsectionIds;
}

/// A subsection a user can be given admin rights over.
class SubsectionRef {
  const SubsectionRef({required this.id, required this.name});

  final String id;
  final String name;
}

/// The game's members and subsections, as loaded together.
class UserDirectory {
  const UserDirectory({required this.users, required this.subsections});

  final List<GameUser> users;
  final List<SubsectionRef> subsections;

  /// The name of subsection [id], or null if it is unknown.
  String? subsectionName(String id) {
    for (final SubsectionRef s in subsections) {
      if (s.id == id) return s.name;
    }
    return null;
  }
}

/// A failure reported by an Edge Function, carrying its error [code].
class AdminApiException implements Exception {
  const AdminApiException(this.code);

  final String code;

  /// A message that is safe to show to the user.
  String get message => switch (code) {
        'game_code_taken' => 'That game code is already taken.',
        'username_taken' => 'That username is already taken.',
        'invalid_input' => 'Some details are invalid. Check them and try again.',
        'forbidden' => 'You do not have permission to do that.',
        'not_found' => 'That item no longer exists.',
        'superseded' =>
          'The player submitted again. Refresh to see the newer answer.',
        'points_too_high' => 'That score is outside the activity\'s point range.',
        'return_type_invalid' => 'The server returned an unexpected type.',
        'game_not_found' => 'No game exists with that game code.',
        _ => 'Something went wrong. Try again. Error: $code',
      };
}

/// Calls the `create-game`, `manage-users` and `grading` Edge Functions.
///
/// Account creation and role assignment happen server-side only. The client
/// never writes role columns or creates other people's accounts.
class AdminApi {
  AdminApi([this._injected]);

  final SupabaseClient? _injected;

  SupabaseClient get _client => _injected ?? Supabase.instance.client;

  /// Creates a game and its first admin account.
  ///
  /// Returns when the game exists. Throws [AdminApiException] when the server
  /// rejects the request, and other exceptions on network failure.
  Future<void> createGame({
    required String gameName,
    required String gameCode,
    required String username,
    required String password,
  }) async {
    await _invoke('create-game', <String, dynamic>{
      'game_name': gameName,
      'game_code': gameCode,
      'username': username,
      'password': password,
    });
  }

  /// Loads the members of the caller's game with the subsections each one
  /// administers, plus the game's subsections.
  ///
  /// Throws [AdminApiException] on rejection, and other exceptions on
  /// network failure.
  Future<UserDirectory> loadDirectory() async {
    final Object? data = await _invoke('manage-users', <String, dynamic>{
      'action': 'list',
    });
    if (data is! Map<String, dynamic>) throw const AdminApiException('unknown');
    final Object? users = data['users'];
    final Object? subsections = data['subsections'];
    if (users is! List<dynamic> || subsections is! List<dynamic>) {
      throw const AdminApiException('return_type_invalid');
    }
    return UserDirectory(
      users: users
          .whereType<Map<String, dynamic>>()
          .map(
            (Map<String, dynamic> row) => GameUser(
              id: row['id'] as String,
              username: row['uname'] as String,
              isAdmin: row['is_admin'] == true,
              subsectionIds: <String>[
                for (final Object? id
                    in (row['subsection_ids'] as List<dynamic>? ?? <dynamic>[]))
                  if (id is String) id,
              ],
            ),
          )
          .toList(),
      subsections: subsections
          .whereType<Map<String, dynamic>>()
          .map(
            (Map<String, dynamic> row) => SubsectionRef(
              id: row['id'] as String,
              name: (row['name'] as String?) ?? '',
            ),
          )
          .toList(),
    );
  }

  /// Lists the members of the caller's game.
  ///
  /// Throws [AdminApiException] on rejection, and other exceptions on
  /// network failure.
  Future<List<GameUser>> listUsers() async => (await loadDirectory()).users;

  /// Creates a participant account in the caller's game.
  ///
  /// Throws [AdminApiException] on rejection, and other exceptions on
  /// network failure.
  Future<void> createUser({
    required String username,
    required String password,
  }) async {
    await _invoke('manage-users', <String, dynamic>{
      'action': 'create',
      'username': username,
      'password': password,
    });
  }

  /// Sets a new password for a participant.
  ///
  /// Throws [AdminApiException] on rejection, and other exceptions on
  /// network failure.
  Future<void> resetPassword({
    required String userId,
    required String password,
  }) async {
    await _invoke('manage-users', <String, dynamic>{
      'action': 'reset_password',
      'user_id': userId,
      'password': password,
    });
  }

  /// Replaces the subsections participant [userId] can administer.
  ///
  /// [subsectionIds] is the complete new set; an empty list removes all.
  /// Throws [AdminApiException] on rejection (admins cannot be assigned), and
  /// other exceptions on network failure.
  Future<void> setSubsections({
    required String userId,
    required List<String> subsectionIds,
  }) async {
    await _invoke('manage-users', <String, dynamic>{
      'action': 'set_subsections',
      'user_id': userId,
      'subsection_ids': subsectionIds,
    });
  }

  /// Removes a participant: blocks sign-in and soft-deletes the row.
  ///
  /// Throws [AdminApiException] on rejection, and other exceptions on
  /// network failure.
  Future<void> removeUser(String userId) async {
    await _invoke('manage-users', <String, dynamic>{
      'action': 'remove',
      'user_id': userId,
    });
  }

  /// Lists the latest answers the caller may grade.
  ///
  /// [status] which answers to show. [activityId] limits it to one activity.
  /// At most 100 come back; check [GradingPage.truncated]. Throws
  /// [AdminApiException] on rejection, and other exceptions on network
  /// failure.
  Future<GradingPage> listAnswers({
    required GradingStatus status,
    String? activityId,
  }) async {
    final Object? data = await _invoke('grading', <String, dynamic>{
      'action': 'list',
      'status': status.wireName,
      if (activityId != null) 'activity_id': activityId,
    });
    if (data is! Map<String, dynamic>) throw const AdminApiException('unknown');
    return GradingPage.fromJson(data);
  }

  /// Sets the points on an answer; null [points] clears the grade.
  ///
  /// Throws [AdminApiException] on rejection (for example `superseded` if
  /// the player submitted again), and other exceptions on network failure.
  Future<void> gradeAnswer({
    required String answerId,
    required int? points,
  }) async {
    await _invoke('grading', <String, dynamic>{
      'action': 'grade',
      'answer_id': answerId,
      'points': points,
    });
  }

  Future<Object?> _invoke(
    String function,
    Map<String, dynamic> body,
  ) async {
    try {
      final FunctionResponse response =
          await _client.functions.invoke(function, body: body);

      if (kDebugMode) {
        debugPrint('[AdminApi] $function success');
        debugPrint('[AdminApi] response: ${response.data}');
      }

      return response.data;
    } on FunctionException catch (e, stack) {
      if (kDebugMode) {
        debugPrint('[AdminApi] $function failed');
        debugPrint('[AdminApi] status: ${e.status}');
        debugPrint('[AdminApi] details: ${e.details}');
        debugPrint('[AdminApi] reason: ${e.reasonPhrase}');
        debugPrint('[AdminApi] stack: $stack');
      }

      final Object? details = e.details;

      String? code;

      if (details is Map) {
        final Object? error = details['error'];
        if (error is String) {
          code = error;
        }
      }

      throw AdminApiException(code ?? 'unknown');
    }
  }

  Future<void> joinGame({
    required String gameCode,
    required String username,
    required String password,
  }) async {
    await _invoke('join-game', <String, dynamic>{
      'game_code': gameCode,
      'username': username,
      'password': password,
    });
  }
}
