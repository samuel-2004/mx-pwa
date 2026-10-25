import 'dart:async';

import 'package:flutter/foundation.dart' show debugPrint, kDebugMode;
import 'package:supabase_flutter/supabase_flutter.dart' as supabase;

import 'auth_state.dart';
import 'validators.dart';

typedef _Roles = ({bool isAdmin, bool isSubsectionAdmin});
const _Roles _noRoles = (isAdmin: false, isSubsectionAdmin: false);

/// Builds the synthetic email used as the Supabase Auth identity.
///
/// [username] and [gameCode] are trimmed and lowercased. Returns
/// `username@gamecode.com`, or null if either value would not form a valid
/// address. Use this for sign-up as well as sign-in so both agree. Does not
/// throw.
String? buildLoginEmail(String username, String gameCode) {
  final String user = username.trim().toLowerCase();
  final String code = gameCode.trim().toLowerCase();
  if (!usernamePattern.hasMatch(user)) return null;
  if (!gameCodePattern.hasMatch(code)) return null;
  return '$user@$code.com';
}

/// [AuthState] backed by Supabase Auth and the role tables.
///
/// Role flags are read from server rows and only drive UI guards. RLS must
/// enforce the same rules.
class SupabaseAuthState extends AuthState {
  SupabaseAuthState(this._client);

  final supabase.SupabaseClient _client;
  StreamSubscription<supabase.AuthState>? _subscription;
  bool _isSignedIn = false;
  String? _userId;
  String? _gameCode;
  _Roles _roles = _noRoles;

  @override
  bool get isSignedIn => _isSignedIn;

  @override
  String? get userId => _userId;

  @override
  bool get isAdmin => _roles.isAdmin;

  @override
  bool get isSubsectionAdmin => _roles.isSubsectionAdmin;
  
  @override
  String? get gameCode => _gameCode;

  bool _rolesLoaded = true;

  @override
  bool get rolesLoaded => _rolesLoaded;

  /// Reads the restored session and starts listening for auth changes.
  ///
  /// Call once before `runApp`. Returns at once: the session comes from local
  /// storage and roles load in the background, so check [rolesLoaded] before
  /// trusting [isAdmin] or [isSubsectionAdmin]. Does not throw.
  void initialize() {
    _applySession(_client.auth.currentSession);
    _subscription = _client.auth.onAuthStateChange.listen(
      (supabase.AuthState data) {
        // Refreshes fire often and never change who the user is.
        if (data.event == supabase.AuthChangeEvent.tokenRefreshed) return;
        _applySession(data.session);
      },
    );
    // Optional diagnostic; auth startup must not depend on it.
    if (kDebugMode) unawaited(_logAuthContext());
  }

  Future<void> _logAuthContext() async {
    try {
      final Object? result = await _client.rpc('debug_auth_context');
      debugPrint('Auth context: $result');
    } on Exception catch (e) {
      debugPrint('Auth context diagnostic failed: $e');
    }
  }

  @override
  Future<void> signOut() async {
    await _client.auth.signOut();
    _applySession(null);
  }

  // Publishes who is signed in at once, then loads roles in the background.
  // The same user firing again (for example a re-sent signedIn) keeps its
  // loaded roles, so the UI does not flash back to loading.
  void _applySession(supabase.Session? session) {
    final String? userId = session?.user.id;
    final bool changedUser = userId != _userId;
    _isSignedIn = session != null;
    _userId = userId;
    if (changedUser) {
      _roles = _noRoles;
      _gameCode = null;
      _rolesLoaded = userId == null;
      notifyListeners();
    }
    if (userId != null) unawaited(_loadProfile(userId));
  }

  Future<void> _loadProfile(String userId) async {
    final (_Roles roles, String? gameCode) =
        await (_loadRoles(userId), diagnoseCurrentUserGameId()).wait;
    // Signed out, or someone else signed in, while this was loading.
    if (_userId != userId) return;
    _roles = roles;
    _gameCode = gameCode;
    _rolesLoaded = true;
    notifyListeners();
  }

  @override
  Future<bool> signIn({
    required String username,
    required String password,
    required String gameCode,
  }) async {
    final String? email = buildLoginEmail(username, gameCode);
    if (email == null || password.isEmpty) return false;
    try {
      await _client.auth.signInWithPassword(email: email, password: password);
      return true;
    } on supabase.AuthException catch (e) {
      // Debug only: the UI deliberately hides which part was wrong.
      if (kDebugMode) {
        debugPrint('Sign-in rejected for $email: ${e.statusCode} ${e.message}');
      }
      return false;
    }
  }

  @override
  void dispose() {
    unawaited(_subscription?.cancel());
    super.dispose();
  }

  Future<_Roles> _loadRoles(String userId) async {
    try {
      final (
        Map<String, dynamic>? user,
        List<Map<String, dynamic>> grants,
      ) = await (
        _client
            .from('users')
            .select('is_admin, is_subsection_admin')
            .eq('id', userId)
            .isFilter('deleted_at', null)
            .maybeSingle(),
        _client
            .from('subsection_admins')
            .select('subsection_id')
            .eq('user_id', userId)
            .isFilter('deleted_at', null)
            .limit(1),
      ).wait;

      // postgresql sanity check
      bool isTrue(dynamic value) {
        return value == true || value == 1;
      }

      return (
        isAdmin: user != null && (isTrue(user['is_admin'])),
        isSubsectionAdmin: grants.isNotEmpty,
      );
    // wait() reports failures as a ParallelWaitError, not the original
    // exception, so catch Object to keep failing closed.
    } on Object catch (e) {
      // Fail closed: an unreadable role must never grant admin UI.
      debugPrint('Failed to load roles for $userId: $e');
      return _noRoles;
    }
  }


  /// Calls the PostgreSQL [is_game_admin] function for the current user.
  Future<bool> diagnoseIsGameAdmin() async {
    try {
      final dynamic result = await _client.rpc('is_game_admin');
      return result == true;
    } on Exception catch (e) {
      debugPrint('Diagnostics: is_game_admin failed: $e');
      return false;
    }
  }

  /// Calls the PostgreSQL [is_subsection_admin] function for the current user.
  Future<bool> diagnoseIsSubsectionAdmin() async {
    try {
      final dynamic result = await _client.rpc('is_subsection_admin');
      return result == true;
    } on Exception catch (e) {
      debugPrint('Diagnostics: is_subsection_admin failed: $e');
      return false;
    }
  }

  /// Calls the PostgreSQL [current_user_game_id] function for the current
  /// user.
  Future<String?> diagnoseCurrentUserGameId() async {
    try {
      final dynamic result = await _client.rpc('current_user_game_id');

      if (result == null) {
        return null;
      }

      return result.toString();
    } on Exception catch (e) {
      debugPrint('Diagnostics: current_user_game_id failed: $e');
      return null;
    }
  }
}
