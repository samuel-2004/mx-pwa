import 'dart:convert';
import 'dart:typed_data';

import 'package:file_saver/file_saver.dart' show FileSaver, MimeType;

import 'geographical_activity_data.dart'
    show GeoParticipant, GeoSubmission;
import 'geo.dart' show isValidLatLng;

/// Builds and downloads a GPX track for each selected participant.
class GpxExporter {
  const GpxExporter();

  /// Saves location submissions for [selectedParticipantIds] as GPX tracks.
  ///
  /// Track points are ordered by answer submission time. [participants]
  /// supplies track names, and [submissions] supplies the recorded locations.
  /// Throws [ArgumentError] when no participant is selected, and propagates
  /// file-save errors.
  Future<void> download({
    required List<GeoParticipant> participants,
    required List<GeoSubmission> submissions,
    required Set<String> selectedParticipantIds,
  }) async {
    if (selectedParticipantIds.isEmpty) {
      throw ArgumentError.value(
        selectedParticipantIds,
        'selectedParticipantIds',
        'Select at least one participant.',
      );
    }

    final String gpx = buildGpx(
      participants: participants,
      submissions: submissions,
      selectedParticipantIds: selectedParticipantIds,
    );
    await FileSaver.instance.saveFile(
      name: 'participant-paths.gpx',
      bytes: Uint8List.fromList(utf8.encode(gpx)),
      mimeType: MimeType.xml,
    );
  }

  /// Creates a GPX 1.1 document for selected participants.
  ///
  /// [participants] supplies track names; [submissions] supplies track points.
  /// Only [selectedParticipantIds] are included. Points are ordered by answer
  /// submission time. Returns valid XML text and does not write a file.
  String buildGpx({
    required List<GeoParticipant> participants,
    required List<GeoSubmission> submissions,
    required Set<String> selectedParticipantIds,
  }) {
    final StringBuffer xml = StringBuffer()
      ..writeln('<?xml version=\"1.0\" encoding=\"UTF-8\"?>')
      ..writeln(
        '<gpx version=\"1.1\" creator=\"MX\" '
        'xmlns=\"http://www.topografix.com/GPX/1/1\">',
      )
      ..writeln(
        '<metadata><name>Participant submission paths</name></metadata>',
      );

    final List<GeoSubmission> selectedSubmissions = submissions
        .where(
          (GeoSubmission submission) =>
              selectedParticipantIds.contains(submission.participantId) &&
              isValidLatLng(
                submission.point.lat,
                submission.point.lng,
              ),
        )
        .toList()
      ..sort(_compareSubmissions);
    final Map<String, List<GeoSubmission>> tracksByParticipant =
        <String, List<GeoSubmission>>{};
    for (final GeoSubmission submission in selectedSubmissions) {
      (tracksByParticipant[submission.participantId] ??= <GeoSubmission>[])
          .add(submission);
    }

    for (final GeoParticipant participant in participants) {
      if (!selectedParticipantIds.contains(participant.id)) continue;
      final List<GeoSubmission> track =
          tracksByParticipant[participant.id] ?? <GeoSubmission>[];
      if (track.isEmpty) continue;

      xml
        ..writeln('<trk>')
        ..writeln('<name>${_escapeXml(participant.name)}</name>')
        ..writeln('<trkseg>');
      for (final GeoSubmission submission in track) {
        final String lat = submission.point.lat.toStringAsFixed(7);
        final String lon = submission.point.lng.toStringAsFixed(7);
        final DateTime? timestamp =
            submission.createdAt ?? submission.point.capturedAt;
        xml.write('<trkpt lat=\"$lat\" lon=\"$lon\">');
        if (timestamp != null) {
          xml.write('<time>${timestamp.toUtc().toIso8601String()}</time>');
        }
        xml.write('<name>${_escapeXml(submission.activityName)}</name>');
        xml.writeln('</trkpt>');
      }
      xml
        ..writeln('</trkseg>')
        ..writeln('</trk>');
    }
    xml.writeln('</gpx>');
    return xml.toString();
  }

  int _compareSubmissions(GeoSubmission a, GeoSubmission b) {
    final DateTime? aTime = a.createdAt;
    final DateTime? bTime = b.createdAt;
    if (aTime == null && bTime != null) return 1;
    if (aTime != null && bTime == null) return -1;
    if (aTime != null && bTime != null) {
      final int timeOrder = aTime.compareTo(bTime);
      if (timeOrder != 0) return timeOrder;
    }
    return a.answerId.compareTo(b.answerId);
  }

  String _escapeXml(String value) {
    final String safe = value.replaceAll(
      RegExp(r'[\x00-\x08\x0B\x0C\x0E-\x1F]'),
      '',
    );
    return safe
        .replaceAll('&', '&amp;')
        .replaceAll('<', '&lt;')
        .replaceAll('>', '&gt;')
        .replaceAll('\"', '&quot;')
        .replaceAll('\'', '&apos;');
  }
}
