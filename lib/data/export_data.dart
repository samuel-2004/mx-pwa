import 'dart:convert';

import 'package:dart_quill_delta/dart_quill_delta.dart' show Delta;
import 'package:powersync/powersync.dart' show PowerSyncDatabase;

/// An activity as printed in an export.
class ExportActivityItem {
  const ExportActivityItem({
    required this.name,
    required this.description,
    required this.points,
  });

  final String name;

  /// Plain text. Empty when there is none.
  final String description;
  final int? points;
}

/// A subsection with its description and activities, in print order.
class ExportSubsection {
  const ExportSubsection({
    required this.id,
    required this.name,
    required this.description,
    required this.activities,
  });

  final String id;
  final String name;

  /// The rich-text description, or null when there is none.
  final Delta? description;
  final List<ExportActivityItem> activities;

  /// The description with all formatting removed. Empty when there is none.
  String get descriptionText {
    final Delta? delta = description;
    return delta == null ? '' : deltaPlainText(delta);
  }
}

/// Everything an export needs, read from the database in one go.
class ExportData {
  const ExportData({required this.gameName, required this.subsections});

  final String gameName;
  final List<ExportSubsection> subsections;
}

/// Turns the text stored in a rich-text column into a Quill [Delta].
///
/// [stored] is normally Delta JSON (a list of operations). Text that is not
/// JSON, or not a list, is treated as plain text, so descriptions written
/// before rich text still export. Returns null for blank or unreadable input.
/// A Quill document must end with a newline, so one is added if missing.
/// Does not throw.
Delta? deltaFromStored(String? stored) {
  final String text = (stored ?? '').trim();
  if (text.isEmpty) return null;

  dynamic decoded;

  try {
    decoded = jsonDecode(text);

    // Handle double-encoded JSON.
    //
    // Database:
    // "\"[{\\\"insert\\\":\\\"Hello\\n\\\"}]\""
    //
    // First jsonDecode -> String
    // Second jsonDecode -> List
    if (decoded is String) {
      decoded = jsonDecode(decoded);
    }
  } catch (_) {
    // Not JSON, so treat it as plain text.
    decoded = null;
  }

  final Delta delta;

  if (decoded is List) {
    try {
      delta = Delta.fromJson(
        decoded
            .whereType<Map>()
            .map((Map item) => Map<String, dynamic>.from(item))
            .toList(),
      );
    } catch (_) {
      return null;
    }
  } else if (decoded is Map && decoded['ops'] is List) {
    // Also support { "ops": [...] }.
    try {
      delta = Delta.fromJson(
        (decoded['ops'] as List)
            .whereType<Map>()
            .map((Map item) => Map<String, dynamic>.from(item))
            .toList(),
      );
    } catch (_) {
      return null;
    }
  } else {
    // Genuine plain text.
    delta = Delta()..insert(text);
  }

  if (delta.isEmpty) {
    return null;
  }

  // Quill documents should end with a newline.
  final List<dynamic> operations = delta.toList();

  if (operations.isEmpty) {
    return null;
  }

  final Object? last = operations.last.data;

  if (!(last is String && last.endsWith('\n'))) {
    delta.insert('\n');
  }

  return delta;
}

/// The text of [delta] with formatting and embeds (images, video) dropped.
///
/// Does not throw.
String deltaPlainText(Delta delta) {
  final StringBuffer out = StringBuffer();
  for (final dynamic operation in delta.toList()) {
    final Object? data = operation.data;
    if (data is String) out.write(data);
  }
  return out.toString().trim();
}

/// Reads the game, its subsections and their activities from the local
/// database.
///
/// [db] the PowerSync database. Returns null until the game has synced.
/// Activities without a subsection are left out, as the editor hides them
/// too. Order matches the activity editor. Throws if a query fails.
Future<ExportData?> loadExportData(PowerSyncDatabase db) async {
  final game = await db
      .getOptional('SELECT name FROM games WHERE deleted_at IS NULL LIMIT 1');
  if (game == null) return null;

  final subsections = await db.getAll(
    'SELECT id, name, "desc" AS description FROM subsections '
    'WHERE deleted_at IS NULL ORDER BY subsection_order, name',
  );
  final activities = await db.getAll(
    'SELECT subsection_id, name, "desc" AS description, points '
    'FROM activities WHERE deleted_at IS NULL AND subsection_id IS NOT NULL '
    'ORDER BY activity_order, name',
  );

  final Map<String, List<ExportActivityItem>> bySubsection =
      <String, List<ExportActivityItem>>{};
  for (final row in activities) {
    final String id = row['subsection_id'] as String;
    (bySubsection[id] ??= <ExportActivityItem>[]).add(
      ExportActivityItem(
        name: (row['name'] as String?) ?? '',
        description: ((row['description'] as String?) ?? '').trim(),
        points: row['points'] as int?,
      ),
    );
  }

  return ExportData(
    gameName: (game['name'] as String?) ?? '',
    subsections: <ExportSubsection>[
      for (final row in subsections)
        ExportSubsection(
          id: row['id'] as String,
          name: (row['name'] as String?) ?? '',
          description: deltaFromStored(row['description'] as String?),
          activities:
              bySubsection[row['id'] as String] ?? const <ExportActivityItem>[],
        ),
    ],
  );
}