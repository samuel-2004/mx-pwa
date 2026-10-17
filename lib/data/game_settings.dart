import 'dart:convert';

import 'package:powersync/powersync.dart' show PowerSyncDatabase;
import 'package:supabase_flutter/supabase_flutter.dart'
    show PostgrestException, Supabase, SupabaseClient;
import 'package:flutter/foundation.dart' show debugPrint, kDebugMode;


/// The editable settings of the signed-in user's game.
class GameSettings {
  const GameSettings({
    required this.name,
    required this.gameCode,
    required this.options,
  });

  final String name;
  final String gameCode;

  final Map<String, dynamic> options;

  T? get<T>(String key) => options[key] as T?;
}

/// Watches the game's settings in the local database.
///
/// Emits null until the game has synced, then the settings, and again
/// whenever they change, including after a save comes back down. Subscribe to
/// it once per widget.
Stream<GameSettings?> watchGameSettings(PowerSyncDatabase db) {
  return db
      .watch(
        'SELECT game_code, name, game_options '
        'FROM games WHERE deleted_at IS NULL LIMIT 1',
      )
      .map((results) {
    if (results.isEmpty) return null;
    final row = results.first;
    final Object? rawOptions = row['game_options'];
    final Map<String, dynamic> options = rawOptions is String
        ? Map<String, dynamic>.from(jsonDecode(rawOptions) as Map)
        : rawOptions is Map
            ? Map<String, dynamic>.from(rawOptions)
            : <String, dynamic>{};

    return GameSettings(
      name: (row['name'] as String?) ?? '',
      gameCode: (row['game_code'] as String?) ?? '',
      options: options,
    );
  });
}

/// A failure from the settings function, carrying the database error [code].
class GameSettingsException implements Exception {
  const GameSettingsException(this.code);

  final String code;

  /// A message that is safe to show to the user.
  String get message => switch (code) {
        '42501' => 'Only game admins can change these settings.',
        '22023' => 'Check the name and dates. The end must be after the start.',
        _ => 'Something went wrong. Try again. Error code: $code',
      };
}

/// Saves game settings through the `update_game_settings` database function.
class GameSettingsApi {
  GameSettingsApi([SupabaseClient? client])
      : _client = client ?? Supabase.instance.client;

  final SupabaseClient _client;

  /// Saves all game settings together.
  Future<void> save({
    required String name,
    required Map<String, dynamic> options,
  }) async {
    try {
      String jsonifiedOptions = jsonEncode(options);
      if (kDebugMode) debugPrint(jsonifiedOptions);
      await _client.rpc(
        'update_game_settings',
        params: <String, dynamic>{
          'p_name': name,
          'p_game_options': options,
        },
      );
    } on PostgrestException catch (e) {
      throw GameSettingsException(e.code ?? 'unknown');
    }
  }
}