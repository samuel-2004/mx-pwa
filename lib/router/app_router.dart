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
  // The session loads right after the first frame. Until it is known, and
  // until a signed-in user's roles are known, every route is let through so
  // the page frame shows at once; the guards run again when each arrives.
  // These guards are UI only. RLS enforces access either way.
  GoRouterRedirect roleOnly(bool Function() allowed) {
    return (BuildContext context, GoRouterState state) {
      if (!authState.sessionLoaded) return null;
      if (!authState.isSignedIn) return Routes.login;
      if (!authState.rolesLoaded) return null;
      return allowed() ? null : Routes.activities;
    };
  }

  String? signedOutOnly(BuildContext context, GoRouterState state) {
    return authState.sessionLoaded && authState.isSignedIn
        ? Routes.activities
        : null;
  }

  final GoRouterRedirect signedInOnly = roleOnly(() => true);
  final GoRouterRedirect adminOnly = roleOnly(() => authState.isAdmin);
  final GoRouterRedirect subsectionAdminOnly =
      roleOnly(() => authState.isSubsectionAdmin);
  final GoRouterRedirect playerOnly = roleOnly(() => !authState.isAdmin);
  final GoRouterRedirect staffOnly =
      roleOnly(() => authState.isAdmin || authState.isSubsectionAdmin);

  // Builds [screen] only once the roles are known. Until then it shows the
  // normal page frame with [loading] in place of the content, so no screen
  // starts loading data before it is known who is looking at it.
  Widget gated(String title, String loading, Widget Function() screen) {
    return ListenableBuilder(
      listenable: authState,
      builder: (BuildContext context, Widget? _) => screen(),
    );
  }

  return GoRouter(
    initialLocation: Routes.login,
    refreshListenable: authState,
    routes: <RouteBase>[
      GoRoute(
        path: '/',
        redirect: (BuildContext context, GoRouterState state) =>
            (!authState.sessionLoaded || authState.isSignedIn)
                ? Routes.activities
                : Routes.login,
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
        builder: (BuildContext context, GoRouterState state) => gated(
          'Activities',
          'Loading activities...',
          // Admins manage activities here; players see their own progress.
          () => authState.isAdmin
              ? ActivityManagerScreen(db: db, userId: authState.userId!)
              : ActivitiesScreen(db: db),
        ),
        routes: <RouteBase>[
          GoRoute(
            path: ':id',
            redirect: playerOnly,
            builder: (BuildContext context, GoRouterState state) => gated(
              'Submit',
              'Loading activity...',
              () => SubmitAnswerScreen(
                db: db,
                activityId: state.pathParameters['id']!,
                onBehalf: false,
              ),
            ),
          ),
        ],
      ),
      GoRoute(
        // Keep in sync with Routes.submitOnBehalf.
        path: '/submit-on-behalf/:id',
        redirect: adminOnly,
        builder: (BuildContext context, GoRouterState state) => gated(
          'Submit for a user',
          'Loading activity...',
          () => SubmitAnswerScreen(
            db: db,
            activityId: state.pathParameters['id']!,
            onBehalf: true,
          ),
        ),
      ),
      GoRoute(
        path: Routes.grading,
        redirect: staffOnly,
        builder: (BuildContext context, GoRouterState state) => gated(
          'Grading',
          'Loading answers...',
          () => const GradingScreen(),
        ),
        routes: <RouteBase>[
          GoRoute(
            path: 'grid',
            redirect: adminOnly,
            builder: (BuildContext context, GoRouterState state) => gated(
              'Bulk scores',
              'Loading scores...',
              () => ScoreGridScreen(db: db),
            ),
          ),
        ],
      ),
      GoRoute(
        path: Routes.users,
        redirect: adminOnly,
        builder: (BuildContext context, GoRouterState state) => gated(
          'Users',
          'Loading users...',
          () => const UsersScreen(),
        ),
      ),
      GoRoute(
        path: Routes.geoMap,
        redirect: adminOnly,
        builder: (BuildContext context, GoRouterState state) => gated(
          'Game map',
          'Loading map...',
          () => GeoActivityMapScreen(db: db),
        ),
      ),
      GoRoute(
        path: Routes.scoreboard,
        redirect: signedInOnly,
        builder: (BuildContext context, GoRouterState state) => gated(
          'Scoreboard',
          'Loading scoreboard...',
          () => const ScoreboardScreen(),
        ),
      ),
      GoRoute(
        path: Routes.gameSettings,
        redirect: adminOnly,
        builder: (BuildContext context, GoRouterState state) => gated(
          'Game settings',
          'Loading settings...',
          () => GameSettingsScreen(db: db),
        ),
      ),
      GoRoute(
        // Local settings only, so it needs no gate.
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
