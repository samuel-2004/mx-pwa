import 'package:flutter/foundation.dart';

/// Session state consumed by the router.
///
/// Implement against Supabase Auth. Derive role flags from server-side rows,
/// never from a client-editable claim.
abstract class AuthState extends ChangeNotifier {
  /// Whether a valid session exists.
  bool get isSignedIn;

  /// The signed-in user's id, or null when signed out.
  String? get userId;

  /// Whether the signed-in user is a game admin.
  bool get isAdmin;

  /// Whether the signed-in user administers at least one subsection.
  bool get isSubsectionAdmin;

  /// Whether the stored session has been read. False only until startup
  /// finishes, right after the first frame; until then [isSignedIn] only
  /// means "not known yet".
  bool get sessionLoaded;

  /// Whether [isAdmin] and [isSubsectionAdmin] are final for the current
  /// user. False until [sessionLoaded], then while a signed-in user's roles
  /// load; true when signed out, since there is nothing to load.
  bool get rolesLoaded;

  /// The users game code.
  String? get gameCode;

  /// Signs in with username, password and game code.
  ///
  /// Returns true on success, false if the credentials are rejected. The
  /// failure is deliberately generic so callers cannot tell which of the
  /// three values was wrong. Throws on network failure.
  Future<bool> signIn({
    required String username,
    required String password,
    required String gameCode,
  });

  /// Ends the session and calls [notifyListeners].
  ///
  /// Throws if the sign-out request fails.
  Future<void> signOut();




  /// Calls the PostgreSQL [is_game_admin] function for the current user.
  ///
  /// Returns false if the function call fails.
  Future<bool> diagnoseIsGameAdmin();

  /// Calls the PostgreSQL [is_subsection_admin] function for the current user.
  ///
  /// Returns false if the function call fails.
  Future<bool> diagnoseIsSubsectionAdmin();

  /// Calls the PostgreSQL [current_user_game_id] function for the current
  /// user.
  ///
  /// Returns null if the function call fails or the user has no game.
  Future<String?> diagnoseCurrentUserGameId();
}