import 'dart:convert';

import 'activity_writes.dart' show AnswerType;
import 'geo.dart';

/// One part of a stored answer, ready to display.
class AnswerPartView {
  const AnswerPartView({
    required this.type,
    this.text,
    this.selected = const <String>[],
    this.imagePath,
    this.geo,
  });

  final AnswerType type;

  /// The text, for a short answer.
  final String? text;

  /// The chosen options, for multiple choice.
  final List<String> selected;

  /// The storage path, for an image.
  final String? imagePath;

  /// The submitted position, for a location.
  final GeoPoint? geo;
}

String? _string(Object? value) => value is String ? value : null;

/// Reads stored answer JSON into displayable parts, in form order.
///
/// Understands the current `{"parts": {...}}` shape and the older single-type
/// shape. Returns an empty list for missing or invalid input. Does not throw.
List<AnswerPartView> parseAnswerParts(String? json) {
  if (json == null) return const <AnswerPartView>[];
  try {
    Object? decoded = jsonDecode(json);
    if (decoded is String) decoded = jsonDecode(decoded);
    if (decoded is! Map<String, dynamic>) return const <AnswerPartView>[];
    final Object? parts = decoded['parts'];
    final Object? legacyType = decoded['type'];
    final Map<String, dynamic> byType = parts is Map<String, dynamic>
        ? parts
        : <String, dynamic>{if (legacyType is String) legacyType: decoded};

    final List<AnswerPartView> out = <AnswerPartView>[];
    for (final AnswerType type in AnswerType.values) {
      final Object? part = byType[type.wireName];
      if (part is! Map<String, dynamic>) continue;
      switch (type) {
        case AnswerType.shortAnswer:
          out.add(AnswerPartView(type: type, text: _string(part['text'])));
        case AnswerType.multipleChoice:
          final Object? selected = part['selected'];
          out.add(
            AnswerPartView(
              type: type,
              selected: selected is List<dynamic>
                  ? <String>[
                      for (final Object? o in selected)
                        if (o is String) o,
                    ]
                  : const <String>[],
            ),
          );
        case AnswerType.checkbox:
          out.add(AnswerPartView(type: type));
        case AnswerType.image:
          out.add(AnswerPartView(type: type, imagePath: _string(part['path'])));
        case AnswerType.geo:
          out.add(AnswerPartView(type: type, geo: GeoPoint.tryParse(part)));
      }
    }
    return out;
  } on FormatException {
    return const <AnswerPartView>[];
  }
}