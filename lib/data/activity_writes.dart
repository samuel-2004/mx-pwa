import 'dart:convert';

import 'package:powersync/powersync.dart' show PowerSyncDatabase;

/// The kinds of answer an activity can ask for. Declared in the order they
/// appear on the answer form.
enum AnswerType {
  shortAnswer('short_answer', 'Short answer'),
  multipleChoice('multiple_choice', 'Multiple choice'),
  checkbox('checkbox', 'Checkbox'),
  image('image', 'Image'),
  geo('geo', 'Location');

  const AnswerType(this.wireName, this.label);

  /// Stored in `answer_schema`. Keep in sync with the database.
  final String wireName;
  final String label;

  /// Finds the type whose [wireName] equals [name], or null.
  static AnswerType? fromWireName(Object? name) {
    for (final AnswerType type in AnswerType.values) {
      if (type.wireName == name) return type;
    }
    return null;
  }
}

/// How a location answer is collected. Stored in `answer_schema.geo.source`.
enum GeoMode {
  auto('auto', 'Automatic', 'Read from the device when the player submits.'),
  photo('photo', 'From photo', 'Read from the metadata of the photo.'),
  manual('manual', 'Chosen by player', 'The player picks a point on the map.');

  const GeoMode(this.wireName, this.label, this.description);

  final String wireName;
  final String label;
  final String description;

  /// Finds the mode whose [wireName] equals [name]. Unknown values read as
  /// [manual], the one that needs no permission. Does not throw.
  static GeoMode fromWireName(Object? name) {
    for (final GeoMode mode in GeoMode.values) {
      if (mode.wireName == name) return mode;
    }
    return GeoMode.manual;
  }
}

/// How a location is collected and whether it can be asked for yet.
///
/// Holds no coordinates: the answer key is in `activities.solution`, which
/// players cannot read.
class GeoConfig {
  const GeoConfig({this.mode = GeoMode.manual, this.ready = false});

  final GeoMode mode;

  /// Whether a solution exists. The database derives this on every write, so
  /// a value written by the app is only a placeholder until it syncs back.
  final bool ready;
}

/// What an activity asks for, stored as JSON text in `answer_schema`.
///
/// An activity can ask for several things at once, for example a photo and a
/// short answer. Holds no answer key, because this reaches every player's
/// device.
class AnswerSchema {
  const AnswerSchema({
    required this.types,
    this.options = const <String>[],
    this.multiple = false,
    this.geo = const GeoConfig(),
  });

  static const AnswerSchema shortAnswer =
      AnswerSchema(types: <AnswerType>[AnswerType.shortAnswer]);

  /// Builds a schema from any [types], dropping duplicates and putting them
  /// in form order. An empty set becomes short answer. Does not throw.
  factory AnswerSchema.fromTypes(
    Iterable<AnswerType> types, {
    List<String> options = const <String>[],
    bool multiple = false,
    GeoConfig geo = const GeoConfig(),
  }) {
    final List<AnswerType> ordered = <AnswerType>[
      for (final AnswerType type in AnswerType.values)
        if (types.contains(type)) type,
    ];
    return AnswerSchema(
      types: ordered.isEmpty ? shortAnswer.types : ordered,
      options: options,
      multiple: multiple,
      geo: ordered.contains(AnswerType.geo) ? geo : const GeoConfig(),
    );
  }

  /// The things asked for, never empty, in form order.
  final List<AnswerType> types;

  /// The choices, used when [types] has multiple choice.
  final List<String> options;

  /// Whether more than one choice may be picked.
  final bool multiple;

  /// How the location is collected, used when [types] has location.
  final GeoConfig geo;

  /// Whether the activity asks for [type].
  bool has(AnswerType type) => types.contains(type);

  /// Whether players are asked for a location: it is requested and a
  /// solution exists.
  bool get asksLocation => has(AnswerType.geo) && geo.ready;

  /// The types players are asked for. A location is left out until its
  /// solution is set.
  List<AnswerType> get playerTypes => <AnswerType>[
        for (final AnswerType type in types)
          if (type != AnswerType.geo || geo.ready) type,
      ];

  /// Whether players have anything to answer. False for a location-only
  /// activity that has no solution yet.
  bool get isAnswerable => playerTypes.isNotEmpty;

  /// Reads a stored schema.
  ///
  /// Accepts the current `{"types": [...]}` shape and the older single
  /// `{"type": "..."}` shape. Returns short answer for empty, invalid or
  /// unknown schemas. Does not throw.
  factory AnswerSchema.parse(String? json) {
    if (json == null) return shortAnswer;
    try {
      Object? decoded = jsonDecode(json);
      // The server can hand back JSON that was encoded twice.
      if (decoded is String) decoded = jsonDecode(decoded);
      if (decoded is! Map<String, dynamic>) return shortAnswer;
      final Object? rawTypes = decoded['types'];
      final List<Object?> names =
          rawTypes is List<dynamic> ? rawTypes : <Object?>[decoded['type']];
      final List<AnswerType> types = <AnswerType>[];
      for (final Object? name in names) {
        final AnswerType? type = AnswerType.fromWireName(name);
        if (type != null) types.add(type);
      }
      final Object? rawOptions = decoded['options'];
      final Object? rawGeo = decoded['geo'];
      return AnswerSchema.fromTypes(
        types,
        options: rawOptions is List<dynamic>
            ? <String>[
                for (final Object? o in rawOptions)
                  if (o is String) o,
              ]
            : const <String>[],
        multiple: decoded['multiple'] == true,
        geo: rawGeo is Map<String, dynamic>
            ? GeoConfig(
                mode: GeoMode.fromWireName(rawGeo['source']),
                ready: rawGeo['ready'] == true,
              )
            : const GeoConfig(),
      );
    } on FormatException {
      return shortAnswer;
    }
  }

  /// The JSON text to store. Keep the shape in sync with the database check
  /// `valid_answer_schema` and the `answers_before_insert` trigger.
  String toJson() {
    final Map<String, Object> map = <String, Object>{
      'types': <String>[for (final AnswerType t in types) t.wireName],
    };
    if (has(AnswerType.multipleChoice)) {
      map['options'] = options;
      map['multiple'] = multiple;
    }
    if (has(AnswerType.geo)) {
      map['geo'] = <String, Object>{
        'source': geo.mode.wireName,
        'ready': geo.ready,
      };
    }
    return jsonEncode(map);
  }
}

/// The editable fields of one activity, used when creating them.
typedef ActivityDraft = ({
  String name,
  String description,
  AnswerSchema schema,
  int? points,
  int releaseOffsetMinutes,
  bool canResubmit,
});

/// Expands [base] into [count] drafts named "<name> 1", "<name> 2", and so on.
///
/// Returns an empty list when [count] is zero or less. Does not throw.
List<ActivityDraft> numberedDrafts(ActivityDraft base, int count) {
  return <ActivityDraft>[
    for (int i = 1; i <= count; i++)
      (
        name: '${base.name} $i',
        description: base.description,
        schema: base.schema,
        points: base.points,
        releaseOffsetMinutes: base.releaseOffsetMinutes,
        canResubmit: base.canResubmit,
      ),
  ];
}

String _now() => DateTime.now().toUtc().toIso8601String();

/// Reads the id of the signed-in user's game from the local database.
///
/// Returns null until the game has synced. Does not throw on an empty table.
Future<String?> loadGameId(PowerSyncDatabase db) async {
  final row = await db
      .getOptional('SELECT id FROM games WHERE deleted_at IS NULL LIMIT 1');
  return row?['id'] as String?;
}

/// Watches the id of the signed-in user's game in the local database.
///
/// Emits null until the game has synced, then the id. Screens that wait on it
/// update by themselves when the first sync finishes, instead of needing a
/// retry. Emits only when the value changes.
Stream<String?> watchGameId(PowerSyncDatabase db) {
  return db
      .watch('SELECT id FROM games WHERE deleted_at IS NULL LIMIT 1')
      .map((results) => results.isEmpty ? null : results.first['id'] as String?)
      .distinct();
}

/// Adds [drafts] to subsection [subsectionId], after its existing activities.
///
/// All writes are local and in one transaction; PowerSync uploads them later
/// and the server may still reject them (RLS or constraints), which the
/// connector logs. Throws if the local write fails.
Future<void> createActivities(
  PowerSyncDatabase db, {
  required String gameId,
  required String subsectionId,
  required List<ActivityDraft> drafts,
}) {
  return _insert(
    db,
    gameId: gameId,
    subsectionId: subsectionId,
    newSubsectionName: null,
    drafts: drafts,
  );
}

/// Creates a subsection after the existing ones, optionally with [drafts].
///
/// Same upload and error behavior as [createActivities].
Future<void> createSubsection(
  PowerSyncDatabase db, {
  required String gameId,
  required String name,
  List<ActivityDraft> drafts = const <ActivityDraft>[],
}) {
  return _insert(
    db,
    gameId: gameId,
    subsectionId: null,
    newSubsectionName: name,
    drafts: drafts,
  );
}

Future<void> _insert(
  PowerSyncDatabase db, {
  required String gameId,
  required String? subsectionId,
  required String? newSubsectionName,
  required List<ActivityDraft> drafts,
}) async {
  await db.writeTransaction((tx) async {
    String? target = subsectionId;
    if (newSubsectionName != null) {
      final next = await tx.get(
        'SELECT COALESCE(MAX(subsection_order), 0) + 1 AS next '
        'FROM subsections WHERE game_id = ? AND deleted_at IS NULL',
        <Object?>[gameId],
      );
      final created = await tx.get('SELECT uuid() AS id');
      target = created['id'] as String;
      await tx.execute(
        'INSERT INTO subsections (id, game_id, name, subsection_order) '
        'VALUES (?, ?, ?, ?)',
        <Object?>[target, gameId, newSubsectionName, next['next']],
      );
    }

    final first = await tx.get(
      'SELECT COALESCE(MAX(activity_order), 0) + 1 AS next FROM activities '
      'WHERE game_id = ? AND subsection_id IS ? AND deleted_at IS NULL',
      <Object?>[gameId, target],
    );
    int order = first['next'] as int;
    for (final ActivityDraft draft in drafts) {
      // "desc" is a reserved word, so it is always quoted.
      await tx.execute(
        'INSERT INTO activities (id, game_id, subsection_id, name, "desc", '
        'answer_schema, can_resubmit, release_time_offset_minutes, '
        'activity_order, points) VALUES (uuid(), ?, ?, ?, ?, ?, ?, ?, ?, ?)',
        <Object?>[
          gameId,
          target,
          draft.name,
          draft.description.isEmpty ? null : draft.description,
          draft.schema.toJson(),
          draft.canResubmit ? 1 : 0,
          draft.releaseOffsetMinutes,
          order,
          draft.points,
        ],
      );
      order++;
    }
  });
}

Future<void> updateSubsectionDescription(
  PowerSyncDatabase db, {
  required String id,
  required String description,
}) async {
  await db.execute(
    'UPDATE subsections SET "desc" = ? WHERE id = ?',
    [description, id],
  );
}

// [assignment] is fixed SQL from this file, never user input; every value
// goes through [values] as a bound parameter.
Future<void> _updateActivity(
  PowerSyncDatabase db,
  String id,
  String assignment,
  List<Object?> values,
) {
  return db.execute(
    'UPDATE activities SET $assignment, updated_at = ? WHERE id = ?',
    <Object?>[...values, _now(), id],
  );
}

/// Sets the name of activity [id]. Throws if the local write fails.
Future<void> setActivityName(PowerSyncDatabase db, String id, String name) =>
    _updateActivity(db, id, 'name = ?', <Object?>[name]);

/// Sets the description of activity [id]; blank clears it. Throws if the
/// local write fails.
Future<void> setActivityDescription(
  PowerSyncDatabase db,
  String id,
  String description,
) =>
    _updateActivity(
      db,
      id,
      '"desc" = ?',
      <Object?>[description.isEmpty ? null : description],
    );

/// Sets the points of activity [id]; null clears them. Throws if the local
/// write fails.
Future<void> setActivityPoints(PowerSyncDatabase db, String id, int? points) =>
    _updateActivity(db, id, 'points = ?', <Object?>[points]);

/// Sets the answer type, release offset and resubmission rule of activity
/// [id]. Throws if the local write fails.
Future<void> updateActivityDetails(
  PowerSyncDatabase db, {
  required String id,
  required AnswerSchema schema,
  required int releaseOffsetMinutes,
  required bool canResubmit,
}) =>
    _updateActivity(
      db,
      id,
      'answer_schema = ?, release_time_offset_minutes = ?, can_resubmit = ?',
      <Object?>[schema.toJson(), releaseOffsetMinutes, canResubmit ? 1 : 0],
    );

/// Soft-deletes activity [id], so existing answers keep their reference.
///
/// Throws if the local write fails.
Future<void> deleteActivity(PowerSyncDatabase db, String id) async {
  final String now = _now();
  await db.execute(
    'UPDATE activities SET deleted_at = ?, updated_at = ? WHERE id = ?',
    <Object?>[now, now, id],
  );
}

/// Renames subsection [id].
///
/// Throws if the local write fails.
Future<void> renameSubsection(
  PowerSyncDatabase db, {
  required String id,
  required String name,
}) async {
  await db.execute(
    'UPDATE subsections SET name = ?, updated_at = ? WHERE id = ?',
    <Object?>[name, _now(), id],
  );
}

/// Soft-deletes subsection [id] if it has no activities.
///
/// Returns false, changing nothing, when activities remain. Throws if the
/// local write fails.
Future<bool> deleteSubsection(PowerSyncDatabase db, String id) {
  return db.writeTransaction((tx) async {
    final count = await tx.get(
      'SELECT COUNT(*) AS n FROM activities '
      'WHERE subsection_id = ? AND deleted_at IS NULL',
      <Object?>[id],
    );
    if ((count['n'] as int) > 0) return false;
    final String now = _now();
    await tx.execute(
      'UPDATE subsections SET deleted_at = ?, updated_at = ? WHERE id = ?',
      <Object?>[now, now, id],
    );
    return true;
  });
}

Future<void> reorderActivities(
  PowerSyncDatabase db,
  List<String> activityIds,
) async {
  await db.writeTransaction((tx) async {
    final String now = _now();

    for (int i = 0; i < activityIds.length; i++) {
      await tx.execute(
        'UPDATE activities '
        'SET activity_order = ?, updated_at = ? '
        'WHERE id = ?',
        <Object?>[-(i + 1), now, activityIds[i]],
      );
    }

    for (int i = 0; i < activityIds.length; i++) {
      await tx.execute(
        'UPDATE activities '
        'SET activity_order = ?, updated_at = ? '
        'WHERE id = ?',
        <Object?>[i + 1, now, activityIds[i]],
      );
    }
  });
}