import 'dart:convert';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart' show PlatformFile;
import 'package:flutter/foundation.dart' show debugPrint, kDebugMode;

import '../auth/validators.dart';
import 'activity_writes.dart';

const int _maxFileBytes = 1024 * 1024;
const int _maxSubsections = 100;
const int _maxActivities = 1000;
const int _maxNameLength = 200;
// Mirrors the limit in the activity manager screen.
const int _maxPoints = 1000000;
const List<String> _csvHeader = <String>[
  'subsection',
  'activity',
  'description',
  'points',
];
// The prefix characters ExportActivity escapes in CSV cells.
const String _csvFormulaChars = '=+-@\t\r';
final RegExp _controlChars = RegExp(r'[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]');

/// Thrown when an import file is unreadable or breaks a rule.
/// [message] is safe to show to the user.
class ImportFormatException implements Exception {
  const ImportFormatException(this.message);

  final String message;

  @override
  String toString() => 'ImportFormatException: $message';
}

/// A subsection read from an import file, ready for `createSubsection`.
class ImportSubsection {
  const ImportSubsection({
    required this.name,
    required this.description,
    required this.drafts,
  });

  final String name;

  /// Quill Delta JSON, or empty when the file had no description.
  final String description;
  final List<ActivityDraft> drafts;
}

/// Reads subsections and activities from exported CSV, JSON or Markdown files.
///
/// [files] picked files. Subsections that share a name, within a file or
/// across files, are merged.
/// Returns the subsections in file order.
/// Throws [ImportFormatException] if a file is unreadable, too large,
/// malformed or fails validation.
Future<List<ImportSubsection>> parseImportFiles(
  List<PlatformFile> files,
) async {
  final _Collector collector = _Collector();
    for (final PlatformFile file in files) {
    try {
      final int? length = await file.length();
      if (kDebugMode) debugPrint('[import] ${file.name}: reported length $length');

      if (length != null && length > _maxFileBytes) {
        throw const ImportFormatException('File is larger than 1 MB.');
      }
      final Uint8List bytes = await file.readAsBytes();
      if (kDebugMode) debugPrint('[import] ${file.name}: read ${bytes.length} bytes');
      _parseFile(file.name, bytes, collector);
    } on ImportFormatException catch (e) {
      if (kDebugMode) debugPrint('[import] ${file.name}: rejected: ${e.message}');
      throw ImportFormatException('${file.name}: ${e.message}');
    } on Exception catch (e) {
      if (kDebugMode) debugPrint('[import] ${file.name}: read failed: $e');
      throw ImportFormatException('${file.name}: could not read the file.');
    }
  }
  return collector.build();
}

class _Pending {
  _Pending(this.description);

  String description;
  final List<ActivityDraft> drafts = <ActivityDraft>[];
}

class _Collector {
  final Map<String, _Pending> _byName = <String, _Pending>{};
  int _activityCount = 0;

  _Pending subsection(String rawName, {String description = ''}) {
    final String name = _clean(rawName);
    final String? error = validateSubsectionName(name);
    if (error != null) {
      throw ImportFormatException('Subsection "$name": $error');
    }
    final _Pending? existing = _byName[name];
    if (existing != null) {
      if (existing.description.isEmpty) {
        existing.description = _descriptionJson(description);
      }
      return existing;
    }
    if (_byName.length >= _maxSubsections) {
      throw const ImportFormatException('Too many subsections (max 100).');
    }
    return _byName[name] = _Pending(_descriptionJson(description));
  }

  void addActivity(
    String subsectionName, {
    required String name,
    required String description,
    required String points,
  }) {
    final _Pending pending = subsection(subsectionName);
    final String activityName = _clean(name);
    final String? nameError =
        validateActivityName(activityName, maxLength: _maxNameLength);
    if (nameError != null) {
      throw ImportFormatException('Activity "$activityName": $nameError');
    }
    final String pointsText = _clean(points);
    final int? parsedPoints = int.tryParse(pointsText);
    final String? pointsError =
        validateOptionalCount(pointsText, max: _maxPoints);
    if (pointsError != null ||
        (pointsText.isNotEmpty && parsedPoints == null)) {
      throw ImportFormatException(
        'Activity "$activityName": points must be a whole number '
        'up to $_maxPoints.',
      );
    }
    _activityCount++;
    if (_activityCount > _maxActivities) {
      throw const ImportFormatException('Too many activities (max 1000).');
    }
    // The exports carry no schema, offset or resubmit flag, so these match
    // the defaults of "Add activity".
    pending.drafts.add((
      name: activityName,
      description: _clean(description),
      schema: AnswerSchema.shortAnswer,
      points: parsedPoints,
      releaseOffsetMinutes: 0,
      canResubmit: true,
    ));
  }

  List<ImportSubsection> build() {
    if (_byName.isEmpty) {
      throw const ImportFormatException('No subsections found.');
    }
    return <ImportSubsection>[
      for (final MapEntry<String, _Pending> e in _byName.entries)
        ImportSubsection(
          name: e.key,
          description: e.value.description,
          drafts: e.value.drafts,
        ),
    ];
  }
}

void _parseFile(String fileName, Uint8List bytes, _Collector collector) {
  if (bytes.length > _maxFileBytes) {
    throw const ImportFormatException('File is larger than 1 MB.');
  }
  final String text = _decode(bytes);
  switch (fileName.split('.').last.toLowerCase()) {
    case 'csv':
      _readCsv(text, collector);
    case 'json':
      _readJson(text, collector);
    case 'md':
      _readMarkdown(text, collector);
    default:
      throw const ImportFormatException('Only CSV, JSON and MD are supported.');
  }
}

String _decode(Uint8List bytes) {
  try {
    final String text = utf8.decode(bytes);
    return text.startsWith('\uFEFF') ? text.substring(1) : text;
  } on FormatException {
    throw const ImportFormatException('File is not valid UTF-8 text.');
  }
}

// Strips control characters so they never reach the database or the UI.
String _clean(String value) =>
    value.replaceAll('\r\n', '\n').replaceAll(_controlChars, '').trim();

String _descriptionJson(String text) {
  final String clean = _clean(text);
  if (clean.isEmpty) return '';
  return jsonEncode(<Map<String, String>>[
    <String, String>{'insert': '$clean\n'},
  ]);
}

void _readCsv(String text, _Collector collector) {
  final List<List<String>> rows = _parseCsv(text);
  if (rows.isEmpty || !_isCsvHeader(rows.first)) {
    throw const ImportFormatException(
      'Expected the header Subsection,Activity,Description,Points.',
    );
  }
  for (final List<String> row in rows.skip(1)) {
    if (row.every((String c) => c.trim().isEmpty)) continue;
    if (row.length != 4) {
      throw const ImportFormatException('Every CSV row needs four columns.');
    }
    final String subsection = _unguard(row[0]);
    final String activity = _unguard(row[1]);
    if (_clean(activity).isEmpty) {
      collector.subsection(subsection);
      continue;
    }
    collector.addActivity(
      subsection,
      name: activity,
      description: _unguard(row[2]),
      points: row[3],
    );
  }
}

bool _isCsvHeader(List<String> row) {
  if (row.length != _csvHeader.length) return false;
  for (int i = 0; i < row.length; i++) {
    if (row[i].trim().toLowerCase() != _csvHeader[i]) return false;
  }
  return true;
}

// Reverses the formula-injection guard ExportActivity adds to cells.
String _unguard(String value) {
  if (value.length < 2 || value[0] != '\'') return value;
  return _csvFormulaChars.contains(value[1]) ? value.substring(1) : value;
}

List<List<String>> _parseCsv(String text) {
  final List<List<String>> rows = <List<String>>[];
  List<String> row = <String>[];
  final StringBuffer cell = StringBuffer();
  bool quoted = false;

  void endCell() {
    row.add(cell.toString());
    cell.clear();
  }

  void endRow() {
    endCell();
    rows.add(row);
    row = <String>[];
  }

  for (int i = 0; i < text.length; i++) {
    final String char = text[i];
    if (quoted) {
      if (char != '"') {
        cell.write(char);
      } else if (i + 1 < text.length && text[i + 1] == '"') {
        cell.write('"');
        i++;
      } else {
        quoted = false;
      }
      continue;
    }
    switch (char) {
      case '"':
        quoted = true;
      case ',':
        endCell();
      case '\n':
        endRow();
      case '\r':
        break;
      default:
        cell.write(char);
    }
  }
  if (quoted) {
    throw const ImportFormatException('A quoted CSV cell is never closed.');
  }
  if (cell.isNotEmpty || row.isNotEmpty) endRow();
  return rows;
}

void _readJson(String text, _Collector collector) {
  final Object? decoded;
  try {
    decoded = jsonDecode(text);
  } on FormatException catch (e) {
    if (kDebugMode) debugPrint('[import] JSON decode failed: ${e.message}');
    throw const ImportFormatException('Invalid JSON.');
  }
  if (kDebugMode) debugPrint('[import] JSON top level: ${decoded.runtimeType}');
  if (decoded is! List) {
    throw const ImportFormatException('Expected a JSON list of activities.');
  }
  if (kDebugMode) debugPrint('[import] JSON entries: ${decoded.length}');
  final Object? first = decoded.isEmpty ? null : decoded.first;
  if (first is Map) if (kDebugMode) debugPrint('[import] JSON first entry keys: ${first.keys.toList()}');

  int activities = 0;
  int subsectionOnly = 0;
  for (final Object? item in decoded) {
    if (item is! Map) {
      throw const ImportFormatException('Every JSON entry must be an object.');
    }
    final String subsection = _jsonText(item['subsection'], 'subsection');
    final String activity = _jsonText(item['activity'], 'activity');
    if (_clean(activity).isEmpty) {
      subsectionOnly++;
      collector.subsection(subsection);
      continue;
    }
    activities++;
    collector.addActivity(
      subsection,
      name: activity,
      description: _jsonText(item['description'], 'description'),
      points: _jsonText(item['points'], 'points'),
    );
  }
  if (kDebugMode) debugPrint('[import] JSON read: $activities activities, $subsectionOnly subsection-only');
}

String _jsonText(Object? value, String field) {
  if (value == null) return '';
  if (value is String) return value;
  if (value is int) return value.toString();
  throw ImportFormatException('"$field" must be text.');
}

void _readMarkdown(String text, _Collector collector) {
  String? name;
  List<String> description = <String>[];
  List<List<String>> rows = <List<String>>[];
  int tableRows = 0;

  void flush() {
    final String? current = name;
    if (current == null) return;
    collector.subsection(current, description: description.join('\n'));
    for (final List<String> cells in rows) {
      collector.addActivity(
        current,
        name: cells[0],
        description: cells[1],
        points: cells[2],
      );
    }
    description = <String>[];
    rows = <List<String>>[];
    tableRows = 0;
  }

  for (final String raw in text.split('\n')) {
    final String line = raw.trim();
    if (line.startsWith('# ')) {
      flush();
      name = line.substring(2);
      continue;
    }
    if (name == null) {
      if (line.isEmpty) continue;
      throw const ImportFormatException('Expected a "# Subsection" heading.');
    }
    if (!line.startsWith('|')) {
      if (tableRows == 0) description.add(raw.trimRight());
      continue;
    }
    tableRows++;
    // The first two table rows are the header and the divider.
    if (tableRows <= 2) continue;
    final List<String> cells = _splitRow(line);
    if (cells.length < 3) {
      throw const ImportFormatException('Every table row needs three columns.');
    }
    rows.add(<String>[
      for (final String c in cells.take(3)) c.replaceAll('<br>', '\n'),
    ]);
  }
  flush();
}

List<String> _splitRow(String line) {
  final List<String> cells = <String>[];
  final StringBuffer cell = StringBuffer();
  for (int i = 0; i < line.length; i++) {
    final String char = line[i];
    if (char == r'\' && i + 1 < line.length && line[i + 1] == '|') {
      cell.write('|');
      i++;
      continue;
    }
    if (char == '|') {
      cells.add(cell.toString());
      cell.clear();
      continue;
    }
    cell.write(char);
  }
  cells.add(cell.toString());
  // Drop the empty pieces outside the leading and trailing pipes.
  cells.removeAt(0);
  if (cells.isNotEmpty && cells.last.trim().isEmpty) cells.removeLast();
  return <String>[for (final String c in cells) c.trim()];
}