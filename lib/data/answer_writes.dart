import 'dart:convert';
import 'dart:typed_data';

import 'package:powersync/powersync.dart' show PowerSyncDatabase;
import 'package:supabase_flutter/supabase_flutter.dart'
    show FileOptions, Supabase;
import 'package:flutter/foundation.dart' show debugPrint, kDebugMode;
import 'package:flutter_image_compress/flutter_image_compress.dart'
    show CompressFormat, FlutterImageCompress;
import 'package:flutter/services.dart' show PlatformException;

import 'activity_list.dart' show releaseAt;
import 'activity_writes.dart';
import 'game_options.dart'
    show
        adminOnlySubmissionSubsections,
        allowResubmissionOptionKey,
        gameOptionBool;

const String _bucket = 'submissions';
/// Quality used when re-encoding uploads to WebP.
const int _webpQuality = 80;

/// Largest image the bucket accepts. Keep in sync with the bucket's limit.
const int maxImageBytes = 5 * 1024 * 1024;

/// Accepted image types and the file extension used for each.
const Map<String, String> allowedImageTypes = <String, String>{
  'image/jpeg': 'jpg',
  'image/png': 'png',
  'image/webp': 'webp',
};

/// The activity being answered, read from the local database.
class SubmitActivity {
  const SubmitActivity({
    required this.id,
    required this.gameId,
    required this.name,
    required this.description,
    required this.schema,
    required this.canResubmit,
    required this.adminOnlySubmission,
    required this.points,
    required this.releaseAt,
  });

  final String id;
  final String gameId;
  final String name;

  /// Empty when there is none.
  final String description;
  final AnswerSchema schema;
  final bool canResubmit;
  final bool adminOnlySubmission;
  final int? points;
  final DateTime? releaseAt;

  /// Returns the release time if it is still in the future at [now], else
  /// null.
  DateTime? opensAfter(DateTime now) {
    final DateTime? at = releaseAt;
    if (at == null || !at.isAfter(now)) return null;
    return at;
  }
}

/// A user's most recent submission for one activity.
class LatestAnswer {
  const LatestAnswer({
    required this.summary,
    required this.points,
    required this.createdAt,
  });

  final String summary;

  /// Null means not graded yet.
  final int? points;
  final DateTime? createdAt;
}

/// JSON text for an answer made of [parts], keyed by answer type.
///
/// Each value is that part's payload: `{'text': ...}` for short answer,
/// `{'selected': [...]}` for multiple choice, `{'checked': true}` for a
/// checkbox and `{'path': ...}` for an image. Keep the shape in sync with the
/// database trigger `answers_before_insert`. Does not throw.
String buildAnswerJson(Map<AnswerType, Map<String, Object>> parts) {
  return jsonEncode(<String, Object>{
    'parts': <String, Object>{
      for (final MapEntry<AnswerType, Map<String, Object>> e in parts.entries)
        e.key.wireName: e.value,
    },
  });
}

/// A short, human-readable description of stored answer JSON.
///
/// Returns an empty string for missing or invalid input. Does not throw.
String describeAnswer(String? answerJson) {
  if (answerJson == null) return '';
  try {
    Object? decoded = jsonDecode(answerJson);
    // The server can hand back JSON that was encoded twice.
    if (decoded is String) decoded = jsonDecode(decoded);
    if (decoded is! Map<String, dynamic>) return '';
    final Object? parts = decoded['parts'];
    // Answers saved before multiple answer types hold one part at the top.
    final Object? legacyType = decoded['type'];
    final Map<String, dynamic> byType = parts is Map<String, dynamic>
        ? parts
        : <String, dynamic>{if (legacyType is String) legacyType: decoded};
    final List<String> described = <String>[];
    for (final MapEntry<String, dynamic> entry in byType.entries) {
      final Object? part = entry.value;
      if (part is! Map<String, dynamic>) continue;
      switch (entry.key) {
        case 'short_answer':
          final String text = (part['text'] as String?) ?? '';
          described.add(text.length > 80 ? '${text.substring(0, 80)}...' : text);
        case 'multiple_choice':
          final Object? selected = part['selected'];
          if (selected is List<dynamic>) described.add(selected.join(', '));
        case 'checkbox':
          described.add('Checked');
        case 'image':
          described.add('Photo');
        case 'geo':
          described.add('Location');
      }
    }
    return described.where((String d) => d.isNotEmpty).join(' · ');
  } on FormatException {
    return '';
  }
}

DateTime? _parse(Object? value) =>
    value is String ? DateTime.tryParse(value) : null;

/// Loads the activity to answer from the local database.
///
/// Returns null if it is missing, deleted or not synced yet. Does not throw
/// on a missing row.
Future<SubmitActivity?> loadSubmitActivity(
  PowerSyncDatabase db,
  String activityId,
) async {
  final row = await db.getOptional(
    'SELECT a.id, a.game_id, a.name, a."desc" AS description, '
    'a.answer_schema, a.can_resubmit, a.subsection_id, '
    'a.points, a.release_time_offset_minutes AS offset_minutes, '
    'g.starts_at, g.game_options FROM activities a '
    'LEFT JOIN games g ON g.id = a.game_id '
    'WHERE a.id = ? AND a.deleted_at IS NULL',
    <Object?>[activityId],
  );
  if (kDebugMode) debugPrint('schema row: ${row?['answer_schema']}');
  if (row == null) return null;
  final Object? options = row['game_options'];
  final String? subsectionId = row['subsection_id'] as String?;
  return SubmitActivity(
    id: row['id'] as String,
    gameId: row['game_id'] as String,
    name: (row['name'] as String?) ?? '',
    description: (row['description'] as String?) ?? '',
    schema: AnswerSchema.parse(row['answer_schema'] as String?),
    canResubmit: row['can_resubmit'] == 1 &&
        gameOptionBool(
          options,
          allowResubmissionOptionKey,
          defaultValue: true,
        ),
    adminOnlySubmission: subsectionId != null &&
        adminOnlySubmissionSubsections(options).contains(subsectionId),
    points: row['points'] as int?,
    releaseAt: releaseAt(
      row['starts_at'] as String?,
      (row['offset_minutes'] as int?) ?? 0,
    ),
  );
}

/// Reads the user's latest answer from the local database.
///
/// Right for the signed-in user, whose own answers are synced. Returns null
/// when there is none.
Future<LatestAnswer?> loadLatestLocal(
  PowerSyncDatabase db, {
  required String activityId,
  required String userId,
}) async {
  final row = await db.getOptional(
    'SELECT answer, points, created_at FROM answers '
    'WHERE activity_id = ? AND user_id = ? AND deleted_at IS NULL '
    'ORDER BY created_at DESC LIMIT 1',
    <Object?>[activityId, userId],
  );
  if (row == null) return null;
  return LatestAnswer(
    summary: describeAnswer(row['answer'] as String?),
    points: row['points'] as int?,
    createdAt: _parse(row['created_at']),
  );
}

/// Reads another user's latest answer from the server.
///
/// For admins submitting on someone's behalf, since other users' answers are
/// not synced to their device. Subject to RLS. Throws on network failure.
Future<LatestAnswer?> loadLatestRemote({
  required String activityId,
  required String userId,
}) async {
  final List<Map<String, dynamic>> rows = await Supabase.instance.client
      .from('answers')
      .select('answer, points, created_at')
      .eq('activity_id', activityId)
      .eq('user_id', userId)
      .isFilter('deleted_at', null)
      .order('created_at', ascending: false)
      .limit(1);
  if (rows.isEmpty) return null;
  final Map<String, dynamic> row = rows.first;
  return LatestAnswer(
    summary: describeAnswer(row['answer'] as String?),
    points: row['points'] as int?,
    createdAt: _parse(row['created_at']),
  );
}

/// Generates an id with the local database, so no UUID package is needed.
Future<String> newId(PowerSyncDatabase db) async {
  final row = await db.get('SELECT uuid() AS id');
  return row['id'] as String;
}

/// Uploads a photo to private storage, converted to WebP when possible, and
/// returns its path.
///
/// The path is `gameId/userId/answerId.ext`; storage policies and the
/// database trigger both depend on that layout. [mimeType] must be a key of
/// [allowedImageTypes]. If the WebP conversion fails, the original bytes are
/// uploaded with their own type and extension. Throws [ArgumentError] if the
/// type is not allowed, and a storage exception if the upload fails. A failed
/// answer insert afterwards leaves the file orphaned.
Future<String> uploadSubmissionImage({
  required String gameId,
  required String userId,
  required String answerId,
  required Uint8List bytes,
  required String mimeType,
}) async {
  final String? originalExtension = allowedImageTypes[mimeType];
  if (originalExtension == null) throw ArgumentError('Unsupported image type');
  final Uint8List? webp = await _toWebp(bytes);
  final bool converted = webp != null;
  final String extension = converted ? 'webp' : originalExtension;
  final String path = '$gameId/$userId/$answerId.$extension';
  await Supabase.instance.client.storage.from(_bucket).uploadBinary(
        path,
        webp ?? bytes,
        fileOptions: FileOptions(contentType: converted ? 'image/webp' : mimeType),
      );
  return path;
}

/// Re-encodes [bytes] to WebP.
///
/// Returns null if the device cannot encode WebP or the conversion fails.
/// Does not throw.
Future<Uint8List?> _toWebp(Uint8List bytes) async {
  try {
    return await FlutterImageCompress.compressWithList(
      bytes,
      format: CompressFormat.webp,
      quality: _webpQuality,
    );
  } on UnsupportedError {
    return null;
  } on PlatformException {
    return null;
  }
}

/// Downloads a submitted photo from private storage.
///
/// [path] a storage path from an answer. Allowed by the storage policies for
/// the photo's owner and for graders. Throws if the download fails or access
/// is denied.
Future<Uint8List> downloadSubmissionImage(String path) {
  return Supabase.instance.client.storage.from(_bucket).download(path);
}

/// Records an answer locally; PowerSync uploads it in the background.
///
/// [userId] whose answer it is, [submittedBy] who typed it in. The server
/// overwrites `submitted_by`, `created_at` and every grading field, and
/// rejects it if the rules fail (not open yet, no resubmission, wrong type),
/// which the connector logs. Throws if the local write fails.
Future<void> insertAnswer(
  PowerSyncDatabase db, {
  required String id,
  required String activityId,
  required String userId,
  required String submittedBy,
  required String answerJson,
}) async {
  await db.execute(
    'INSERT INTO answers (id, activity_id, user_id, answer, points, '
    'automatically_graded, created_at, submitted_by) '
    'VALUES (?, ?, ?, ?, NULL, 0, ?, ?)',
    <Object?>[
      id,
      activityId,
      userId,
      answerJson,
      DateTime.now().toUtc().toIso8601String(),
      submittedBy,
    ],
  );
}
