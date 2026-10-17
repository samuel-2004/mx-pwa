/// Route path constants. Keep in sync with `createRouter`.
class Routes {
  const Routes._();

  static const String login = '/login';
  static const String createGame = '/create-game';
  static const String logout = '/logout';
  static const String activities = '/activities';
  static const String grading = '/grading';
  static const String users = '/users';
  static const String scoreboard = '/scoreboard';
  static const String gameSettings = '/game-settings';
  static const String settings = '/settings';
  static const String terms = '/terms';
  static const String diagnostics = '/diagnostics';
  static const String scoreGrid = '/grading/grid';

  /// Builds the path for an activity's submit page.
  ///
  /// [id] the activity id. Returns the encoded path. Does not throw.
  static String activity(String id) => '/activities/${Uri.encodeComponent(id)}';

  /// Builds the path for an admin submitting an answer on a user's behalf.
  ///
  /// [id] the activity id. Returns the encoded path. Does not throw.
  static String submitOnBehalf(String id) =>
      '/submit-on-behalf/${Uri.encodeComponent(id)}';
}