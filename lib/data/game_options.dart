import 'dart:convert';

enum GameOptionType {
  text,
  boolean,
  dateTime,
  dropdown,
  number,
}

class GameOption {
  const GameOption({
    required this.key,
    required this.name,
    required this.description,
    required this.type,
    this.options,
    this.defaultValue,
    this.enabled = true,
  });

  /// Key used to store/retrieve the value from game_options.
  final String key;

  /// Display name shown in the settings UI.
  final String name;

  /// Explanation shown underneath the setting.
  final String description;

  /// Determines which input widget should be displayed.
  final GameOptionType type;

  /// Available values when [type] is [GameOptionType.dropdown].
  final List<GameOptionChoice>? options;

  /// Value shown when no value has been saved for this option.
  final Object? defaultValue;

  /// Whether the setting can currently be changed.
  final bool enabled;
}

class GameOptionChoice {
  const GameOptionChoice({
    required this.value,
    required this.label,
  });

  /// Actual value stored in the database.
  final String value;

  /// Human-readable value displayed to the user.
  final String label;
}

/// Key for the game-wide setting that permits activity resubmission rules.
const String allowResubmissionOptionKey = 'allow_resubmission';

/// Key for subsection IDs that only game admins can submit answers to.
const String adminOnlySubmissionsOptionKey = 'admin_only_submissions';

/// Key for the unavailable code-redemption setting.
const String codeRedemptionOptionKey = 'code_redemption_enabled';

/// Key controlling whether anyone with a game link can join.
const String allowUnregisteredUsersToJoinOptionKey =
    'allow_unregistered_users_to_join';

const List<GameOption> gameOptions = [
  GameOption(
    key: 'scoreboard_enabled',
    name: 'Scoreboard',
    description: 'Whether players can view the scoreboard.',
    type: GameOptionType.boolean,
  ),

  GameOption(
    key: 'starts_at',
    name: 'Game start time',
    description: 'The date and time the game starts.',
    type: GameOptionType.dateTime,
  ),

  GameOption(
    key: 'ends_at',
    name: 'Game end time',
    description: 'The date and time the game ends.',
    type: GameOptionType.dateTime,
  ),

  GameOption(
    key: 'game_mode',
    name: 'Game mode',
    description: 'Controls how the game operates.',
    type: GameOptionType.dropdown,
    options: [
      GameOptionChoice(
        value: 'standard',
        label: 'Standard',
      ),
      GameOptionChoice(
        value: 'competitive',
        label: 'Competitive',
      ),
      GameOptionChoice(
        value: 'practice',
        label: 'Practice',
      ),
    ],
  ),

  GameOption(
    key: allowResubmissionOptionKey,
    name: 'Allow resubmission',
    description:
        'When off, each activity allows one submission and its activity-level setting is hidden.',
    type: GameOptionType.boolean,
    defaultValue: true,
  ),

  GameOption(
    key: codeRedemptionOptionKey,
    name: 'Code redemption',
    description: 'Code redemption is not available yet.',
    type: GameOptionType.boolean,
    defaultValue: false,
    enabled: false,
  ),

  GameOption(
    key: allowUnregisteredUsersToJoinOptionKey,
    name: 'Anyone can join from link',
    description: 'When off, only people you add can join.',
    type: GameOptionType.boolean,
    defaultValue: true,
  ),
];

/// Reads a boolean from game options, returning [defaultValue] when absent or
/// malformed. [rawOptions] may be decoded options or their JSON text.
bool gameOptionBool(
  Object? rawOptions,
  String key, {
  required bool defaultValue,
}) {
  final Object? decoded = _decodeOptions(rawOptions);
  if (decoded is! Map) return defaultValue;
  final Object? value = decoded[key];
  return value is bool ? value : defaultValue;
}

/// Returns subsection IDs whose activities are view-only for players.
/// [rawOptions] may be decoded options or their JSON text. Invalid data gives
/// an empty set.
Set<String> adminOnlySubmissionSubsections(Object? rawOptions) {
  final Object? decoded = _decodeOptions(rawOptions);
  if (decoded is! Map) return <String>{};
  final Object? value = decoded[adminOnlySubmissionsOptionKey];
  if (value is! List) return <String>{};
  return <String>{for (final Object? id in value) if (id is String) id};
}

Object? _decodeOptions(Object? rawOptions) {
  if (rawOptions is String) {
    try {
      return jsonDecode(rawOptions);
    } on FormatException {
      return null;
    }
  }
  return rawOptions;
}
