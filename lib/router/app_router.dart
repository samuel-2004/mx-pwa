import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter/widgets.dart';
import 'package:go_router/go_router.dart';
import 'package:powersync/powersync.dart' show PowerSyncDatabase;

import '../auth/auth_state.dart';
import '../screens/activities_screen.dart';
import '../screens/activity_manager_screen.dart';
import '../screens/create_game_screen.dart';
import '../screens/diagnostics_screen.dart';
import '../screens/game_settings_screen.dart';
import '../screens/geo_activity_map_screen.dart';
import '../screens/grading_screen.dart';
import '../screens/login_screen.dart';
import '../screens/logout_screen.dart';
import '../screens/scoreboard_screen.dart';
import '../screens/settings_screen.dart';
import '../screens/submit_answer_screen.dart';
import '../screens/users_screen.dart';
import '../screens/terms_screen.dart';
import '../screens/score_grid_screen.dart';
import 'routes.dart';

/// Builds the app router.
///
/// [authState] drives redirects and re-evaluates guards when it notifies.
/// [db] is only used by the debug-only diagnostics route.
/// Returns the configured [GoRouter]. Does not throw.
///
/// These guards are UI only. Every restriction must also be enforced by
/// Supabase RLS.
GoRouter createRouter(AuthState authState, PowerSyncDatabase db) {
  String? signedOutOnly(BuildContext context, GoRouterState state) {
    return authState.isSignedIn ? Routes.activities : null;
  }

  String? signedInOnly(BuildContext context, GoRouterState state) {
    return authState.isSignedIn ? null : Routes.login;
  }

  String? adminOnly(BuildContext context, GoRouterState state) {
    if (!authState.isSignedIn) return Routes.login;
    return authState.isAdmin ? null : Routes.activities;
  }

  String? subsectionAdminOnly(BuildContext context, GoRouterState state) {
    if (!authState.isSignedIn) return Routes.login;
    return authState.isSubsectionAdmin ? null : Routes.activities;
  }

  String? playerOnly(BuildContext context, GoRouterState state) {
    if (!authState.isSignedIn) return Routes.login;
    return authState.isAdmin ? Routes.activities : null;
  }

  String? staffOnly(BuildContext context, GoRouterState state) {
    if (!authState.isSignedIn) return Routes.login;
    return authState.isAdmin || authState.isSubsectionAdmin
        ? null
        : Routes.activities;
  }

  return GoRouter(
    initialLocation: Routes.login,
    refreshListenable: authState,
    routes: <RouteBase>[
      GoRoute(
        path: '/',
        redirect: (BuildContext context, GoRouterState state) =>
            authState.isSignedIn ? Routes.activities : Routes.login,
      ),
      GoRoute(
        path: Routes.login,
        redirect: signedOutOnly,
        builder: (BuildContext context, GoRouterState state) =>
            LoginScreen(
              authState: authState,
              gameCode: state.uri.queryParameters['gameCode'],
            ),
      ),
      GoRoute(
        path: Routes.createGame,
        redirect: signedOutOnly,
        builder: (BuildContext context, GoRouterState state) =>
            CreateGameScreen(authState: authState),
      ),
      GoRoute(
        path: Routes.logout,
        redirect: signedInOnly,
        builder: (BuildContext context, GoRouterState state) =>
            LogoutScreen(authState: authState),
      ),
      GoRoute(
        path: Routes.activities,
        redirect: signedInOnly,
        builder: (BuildContext context, GoRouterState state) =>
            // Admins manage activities here; players see their own progress.
            authState.isAdmin
                ? ActivityManagerScreen(db: db)
                : ActivitiesScreen(db: db),
        routes: <RouteBase>[
          GoRoute(
            path: ':id',
            redirect: playerOnly,
            builder: (BuildContext context, GoRouterState state) =>
                SubmitAnswerScreen(
                  db: db,
                  activityId: state.pathParameters['id']!,
                  onBehalf: false,
                ),
          ),
        ],
      ),
      GoRoute(
        // Keep in sync with Routes.submitOnBehalf.
        path: '/submit-on-behalf/:id',
        redirect: adminOnly,
        builder: (BuildContext context, GoRouterState state) =>
            SubmitAnswerScreen(
              db: db,
              activityId: state.pathParameters['id']!,
              onBehalf: true,
            ),
      ),
      GoRoute(
        path: Routes.grading,
        redirect: staffOnly,
        builder: (BuildContext context, GoRouterState state) =>
            const GradingScreen(),
        routes: <RouteBase>[
          GoRoute(
            path: 'grid',
            redirect: adminOnly,
            builder: (BuildContext context, GoRouterState state) =>
                ScoreGridScreen(db: db),
          ),
        ],
      ),
      GoRoute(
        path: Routes.users,
        redirect: adminOnly,
        builder: (BuildContext context, GoRouterState state) =>
            const UsersScreen(),
      ),
      GoRoute(
        path: Routes.geoMap,
        redirect: adminOnly,
        builder: (BuildContext context, GoRouterState state) =>
            GeoActivityMapScreen(db: db),
      ),
      GoRoute(
        path: Routes.scoreboard,
        redirect: signedInOnly,
        builder: (BuildContext context, GoRouterState state) =>
            const ScoreboardScreen(),
      ),
      GoRoute(
        path: Routes.gameSettings,
        redirect: adminOnly,
        builder: (BuildContext context, GoRouterState state) =>
            GameSettingsScreen(db: db),
      ),
      GoRoute(
        path: Routes.settings,
        redirect: signedInOnly,
        builder: (BuildContext context, GoRouterState state) =>
            const SettingsScreen(),
      ),
      GoRoute(
        path: Routes.terms,
        builder: (BuildContext context, GoRouterState state) =>
            const TermsScreen(),
      ),
      // Reachable signed out too, so connectivity can be checked before login.
      if (kDebugMode)
        GoRoute(
          path: Routes.diagnostics,
          builder: (BuildContext context, GoRouterState state) =>
              DiagnosticsScreen(db: db, authState: authState),
        ),
    ],
  );
}
