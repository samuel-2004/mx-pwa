import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:powersync/powersync.dart' show PowerSyncDatabase;
import 'package:flutter_localizations/flutter_localizations.dart';
// Narrowed so flutter_quill's own `Style` cannot clash with Orient UI's.
import 'package:flutter_quill/flutter_quill.dart' show FlutterQuillLocalizations;

import 'auth/auth_scope.dart';
import 'auth/auth_state.dart';
import 'auth/supabase_auth_state.dart';
import 'config/app_config.dart';
import 'orient_ui/style.dart';
import 'powersync/powersync.dart';
import 'router/app_router.dart';
import 'settings/app_settings.dart';

/// App entry point: initializes Supabase, auth state and PowerSync, then
/// runs the app. If startup fails, shows [StartupErrorApp] instead.
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  try {
    AppConfig.validate();
    // A quick local read; waiting for it avoids a theme flash.
    final AppSettings settings = await AppSettings.load();
    final SupabaseAuthState authState = SupabaseAuthState();
    final PowerSyncDatabase db = openPowerSync(
      authState: authState,
      endpoint: AppConfig.powersyncUrl,
    );
    runApp(
      MxApp(
        router: createRouter(authState, db),
        authState: authState,
        settings: settings,
      ),
    );
    // Only after the first frame is drawn, so nothing stands between the user
    // and the page.
    await WidgetsBinding.instance.endOfFrame;
    await authState.initialize(
      url: AppConfig.supabaseUrl,
      publishableKey: AppConfig.supabasePublishableKey,
    );
  } on Object catch (error) {
    runApp(StartupErrorApp(error: error));
  }
}

/// Root widget. Takes a prebuilt [router] so it is created once, not on
/// every rebuild, and shares [authState] with the tree through [AuthScope].
class MxApp extends StatelessWidget {
  const MxApp({
    required this.router,
    required this.authState,
    required this.settings,
    super.key,
  });

  final GoRouter router;
  final AuthState authState;
  final AppSettings settings;

  @override
  Widget build(BuildContext context) {
    return AuthScope(
      authState: authState,
      child: AppSettingsScope(
        settings: settings,
        child: ListenableBuilder(
          listenable: settings,
          builder: (BuildContext context, Widget? _) => MaterialApp.router(
            title: 'MX',
            routerConfig: router,
            // Style sits inside the builder so it is above the Navigator (and
            // so above every route and overlay) yet below MediaQuery, which
            // the "system" theme mode needs.
            builder: (BuildContext context, Widget? child) => Style(
              brightness: _brightnessFor(context, settings.themeMode),
              child: _MaterialBridge(
                child: MediaQuery(
                  data: MediaQuery.of(context).copyWith(
                    textScaler: TextScaler.linear(settings.textSize.scale),
                  ),
                  child: child ?? const SizedBox.shrink(),
                ),
              ),
            ),
            localizationsDelegates: const <LocalizationsDelegate<dynamic>>[
              GlobalMaterialLocalizations.delegate,
              GlobalWidgetsLocalizations.delegate,
              GlobalCupertinoLocalizations.delegate,
              FlutterQuillLocalizations.delegate,
            ],
            supportedLocales: FlutterQuillLocalizations.supportedLocales,
          ),
        ),
      ),
    );
  }
}

/// Resolves the saved [mode] to a concrete brightness. "System" follows the
/// platform setting.
Brightness _brightnessFor(BuildContext context, ThemeMode mode) {
  return switch (mode) {
    ThemeMode.light => Brightness.light,
    ThemeMode.dark => Brightness.dark,
    ThemeMode.system => MediaQuery.platformBrightnessOf(context),
  };
}

/// Themes the Material widgets that have no Orient UI replacement (text
/// fields, the Quill editor, date pickers, expansion tiles) from the Orient
/// UI tokens, because Orient UI does not read Material's theme and the two
/// would otherwise drift apart.
class _MaterialBridge extends StatelessWidget {
  const _MaterialBridge({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final Style style = context.style;
    final ColorTokens colors = style.colors;
    return Theme(
      data: ThemeData(
        colorScheme: ColorScheme(
          brightness: style.brightness,
          primary: colors.button.primary,
          onPrimary: colors.button.primaryForeground,
          secondary: colors.button.secondary,
          onSecondary: colors.button.secondaryForeground,
          error: colors.error,
          onError: colors.button.destructiveForeground,
          surface: colors.background,
          onSurface: colors.foreground,
          outline: colors.border,
          surfaceContainer: colors.surfaceContainer,
        ),
        scaffoldBackgroundColor: colors.background,
        dividerColor: colors.border,
        appBarTheme: AppBarTheme(
          backgroundColor: colors.background,
          foregroundColor: colors.foreground,
          surfaceTintColor: Colors.transparent,
          titleTextStyle: context.typography.title,
        ),
      ),
      child: child,
    );
  }
}

/// Shown when startup fails. Details appear only in debug builds.
class StartupErrorApp extends StatelessWidget {
  const StartupErrorApp({required this.error, super.key});

  final Object error;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: Scaffold(
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: SelectableText(
              kDebugMode
                  ? 'Startup failed:\n$error'
                  : 'Something went wrong. Reload the page and try again.',
            ),
          ),
        ),
      ),
    );
  }
}