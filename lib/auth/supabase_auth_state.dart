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

  SupabaseAuthState();

  final Completer<void> _initialized = Completer<void>();
  bool _sessionLoaded = false;
  bool _rolesLoaded = false;

  // Only read after [initialize] has finished.
  supabase.SupabaseClient get _client => supabase.Supabase.instance.client;

  @override
  bool get sessionLoaded => _sessionLoaded;

  @override
  bool get rolesLoaded => _rolesLoaded;

  /// Starts Supabase, reads the stored session and listens for auth changes.
  ///
  /// [url] and [publishableKey] are the public client values. Call it once,
  /// after the first frame. The session comes from local storage, so this
  /// does not wait for the network; roles then load in the background (see
  /// [rolesLoaded]). Throws whatever `Supabase.initialize` throws.
  Future<void> initialize({
    required String url,
    required String publishableKey,
  }) async {
    await supabase.Supabase.initialize(
      url: url,
      publishableKey: publishableKey,
    );
    _applySession(_client.auth.currentSession);
    _subscription = _client.auth.onAuthStateChange.listen(
      (supabase.AuthState data) {
        // Refreshes fire often and never change who the user is.
        if (data.event == supabase.AuthChangeEvent.tokenRefreshed) return;
        _applySession(data.session);
      },
    );
    _initialized.complete();
    // Optional diagnostic; auth startup must not depend on it.
    if (kDebugMode) unawaited(_logAuthContext());
  }

  void _applySession(supabase.Session? session) {
    final String? userId = session?.user.id;
    final bool changed = userId != _userId || !_sessionLoaded;
    _isSignedIn = session != null;
    _userId = userId;
    _sessionLoaded = true;
    if (changed) {
      _roles = _noRoles;
      _gameCode = null;
      _rolesLoaded = userId == null;
      notifyListeners();
    }
    if (changed && userId != null) {
      unawaited(_loadProfile(userId));
    }
  }

  Future<void> _logAuthContext() async {
    try {
      final Object? result = await _client.rpc('debug_auth_context');
      debugPrint('Auth context: $result');
    } on Exception catch (e) {
      debugPrint('Auth context diagnostic failed: $e');
    }
  }

  Future<void> _loadProfile(String userId) async {
    final _Roles roles = await _loadRoles(userId);

    if (_userId != userId) return;

    _roles = roles;
    _rolesLoaded = true;
    notifyListeners();

    final String? gameCode = await diagnoseCurrentUserGameId();

    if (_userId != userId) return;

    _gameCode = gameCode;
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
    await _initialized.future;
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
  Future<void> signOut() async {
    await _client.auth.signOut();
    _applySession(null);
  }

  @override
  void dispose() {
    unawaited(_subscription?.cancel());
    super.dispose();
  }

  Future<_Roles> _loadRoles(String userId) async {
    try {
      final Map<String, dynamic>? user = await _client
        .from('users')
        .select('is_admin, is_subsection_admin')
        .eq('id', userId)
        .isFilter('deleted_at', null)
        .maybeSingle();

      // postgresql sanity check
      bool isTrue(dynamic value) {
        return value == true || value == 1;
      }

      return (
        isAdmin: user != null && (isTrue(user['is_admin'])),
        isSubsectionAdmin: user != null && isTrue(user['is_subsection_admin']),
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
