import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart'
    show SharedPreferencesAsync;

/// How large text appears on this device.
enum TextSize {
  small(0.9, 'Small'),
  normal(1.0, 'Normal'),
  large(1.2, 'Large');

  const TextSize(this.scale, this.label);

  final double scale;
  final String label;
}

/// Settings kept on this device only, such as the theme. They are not tied to
/// an account, are never synced, and survive signing out.
class AppSettings extends ChangeNotifier {
  AppSettings._(this._store, this._themeMode, this._textSize);

  static const String _themeKey = 'app.theme_mode';
  static const String _textKey = 'app.text_size';

  final SharedPreferencesAsync _store;
  ThemeMode _themeMode;
  TextSize _textSize;

  ThemeMode get themeMode => _themeMode;
  TextSize get textSize => _textSize;

  /// Reads the saved settings.
  ///
  /// Returns defaults (system theme, normal text) for anything missing or
  /// unreadable, such as when the browser blocks storage. Does not throw.
  static Future<AppSettings> load() async {
    final SharedPreferencesAsync store = SharedPreferencesAsync();
    String? theme;
    String? text;
    try {
      theme = await store.getString(_themeKey);
      text = await store.getString(_textKey);
    } on Exception {
      // Fall back to defaults.
    }
    return AppSettings._(
      store,
      ThemeMode.values.asNameMap()[theme] ?? ThemeMode.system,
      TextSize.values.asNameMap()[text] ?? TextSize.normal,
    );
  }

  /// Applies [mode] now and saves it. Does not throw.
  Future<void> setThemeMode(ThemeMode mode) async {
    if (mode == _themeMode) return;
    _themeMode = mode;
    notifyListeners();
    await _save(_themeKey, mode.name);
  }

  /// Applies [size] now and saves it. Does not throw.
  Future<void> setTextSize(TextSize size) async {
    if (size == _textSize) return;
    _textSize = size;
    notifyListeners();
    await _save(_textKey, size.name);
  }

  Future<void> _save(String key, String value) async {
    try {
      await _store.setString(key, value);
    } on Exception {
      // The choice still applies for this session; it just will not persist.
    }
  }
}

/// Exposes [AppSettings] to the widget tree and rebuilds dependents when it
/// notifies.
class AppSettingsScope extends InheritedNotifier<AppSettings> {
  const AppSettingsScope({
    required AppSettings settings,
    required super.child,
    super.key,
  }) : super(notifier: settings);

  /// Returns the nearest [AppSettings] and subscribes [context] to it.
  ///
  /// Throws [StateError] if no [AppSettingsScope] is above [context].
  static AppSettings of(BuildContext context) {
    final AppSettingsScope? scope =
        context.dependOnInheritedWidgetOfExactType<AppSettingsScope>();
    final AppSettings? settings = scope?.notifier;
    if (settings == null) {
      throw StateError('No AppSettingsScope found above this context.');
    }
    return settings;
  }
}