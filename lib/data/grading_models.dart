import 'activity_writes.dart';

/// Which answers the grading list shows.
enum GradingStatus {
  pending('pending', 'Pending'),
  graded('graded', 'Graded'),
  all('all', 'All');

  const GradingStatus(this.wireName, this.label);

  final String wireName;
  final String label;
}

/// One thing a player submitted, in a form ready to display.
class GradingPart {
  const GradingPart({
    required this.type,
    this.text,
    this.selected = const <String>[],
    this.imageUrl,
  });

  final AnswerType type;

  /// The short answer text.
  final String? text;

  /// The chosen options.
  final List<String> selected;

  /// A temporary link to the photo, or null if it could not be signed.
  final String? imageUrl;
}

/// A player's latest answer to one activity, with its current grade.
class GradingItem {
  const GradingItem({
    required this.id,
    required this.activityName,
    required this.activityDescription,
    required this.maxPoints,
    required this.subsectionName,
    required this.username,
    required this.createdAt,
    required this.points,
    required this.gradedAt,
    required this.gradedByName,
    required this.parts,
  });

  final String id;
  final String activityName;
  final String activityDescription;

  /// The most the activity is worth, or null if it has no limit.
  final int? maxPoints;
  final String? subsectionName;
  final String username;
  final DateTime? createdAt;

  /// Null means not graded yet.
  final int? points;
  final DateTime? gradedAt;
  final String? gradedByName;
  final List<GradingPart> parts;

  /// Reads one answer from the `grading` Edge Function's JSON. Does not
  /// throw on missing fields.
  factory GradingItem.fromJson(Map<String, dynamic> json) {
    final Object? rawParts = json['parts'];
    final List<GradingPart> parts = <GradingPart>[];
    if (rawParts is Map<String, dynamic>) {
      for (final AnswerType type in AnswerType.values) {
        final Object? part = rawParts[type.wireName];
        if (part is! Map<String, dynamic>) continue;
        final Object? selected = part['selected'];
        parts.add(
          GradingPart(
            type: type,
            text: part['text'] as String?,
            selected: selected is List<dynamic>
                ? <String>[
                    for (final Object? s in selected)
                      if (s is String) s,
                  ]
                : const <String>[],
            imageUrl: part['url'] as String?,
          ),
        );
      }
    }
    return GradingItem(
      id: json['id'] as String,
      activityName: (json['activity_name'] as String?) ?? '',
      activityDescription: (json['activity_description'] as String?) ?? '',
      maxPoints: json['max_points'] as int?,
      subsectionName: json['subsection_name'] as String?,
      username: (json['username'] as String?) ?? 'Unknown',
      createdAt: DateTime.tryParse((json['created_at'] as String?) ?? ''),
      points: json['points'] as int?,
      gradedAt: DateTime.tryParse((json['graded_at'] as String?) ?? ''),
      gradedByName: json['graded_by_name'] as String?,
      parts: parts,
    );
  }

  /// A copy showing [points] as just graded by the current user, or as
  /// ungraded when [points] is null.
  GradingItem withGrade(int? points) {
    return GradingItem(
      id: id,
      activityName: activityName,
      activityDescription: activityDescription,
      maxPoints: maxPoints,
      subsectionName: subsectionName,
      username: username,
      createdAt: createdAt,
      points: points,
      gradedAt: points == null ? null : DateTime.now().toUtc(),
      gradedByName: points == null ? null : 'you',
      parts: parts,
    );
  }
}

/// An activity the caller may grade, for the filter menu.
class GradingActivity {
  const GradingActivity({
    required this.id,
    required this.name,
    required this.subsectionName,
  });

  final String id;
  final String name;
  final String? subsectionName;
}

/// One response from the grading list.
class GradingPage {
  const GradingPage({
    required this.items,
    required this.activities,
    required this.truncated,
  });

  final List<GradingItem> items;
  final List<GradingActivity> activities;

  /// True when more answers matched than were returned.
  final bool truncated;

  /// Reads the `grading` Edge Function's list response. Does not throw on
  /// missing fields.
  factory GradingPage.fromJson(Map<String, dynamic> json) {
    final Object? answers = json['answers'];
    final Object? activities = json['activities'];
    return GradingPage(
      items: answers is List<dynamic>
          ? <GradingItem>[
              for (final Object? a in answers)
                if (a is Map<String, dynamic>) GradingItem.fromJson(a),
            ]
          : const <GradingItem>[],
      activities: activities is List<dynamic>
          ? <GradingActivity>[
              for (final Object? a in activities)
                if (a is Map<String, dynamic>)
                  GradingActivity(
                    id: a['id'] as String,
                    name: (a['name'] as String?) ?? '',
                    subsectionName: a['subsection_name'] as String?,
                  ),
            ]
          : const <GradingActivity>[],
      truncated: json['truncated'] == true,
    );
  }
}