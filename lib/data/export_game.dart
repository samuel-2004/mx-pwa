import 'dart:convert';
import 'dart:typed_data';

import 'package:dart_quill_delta/dart_quill_delta.dart' show Delta;
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter_quill_to_pdf/flutter_quill_to_pdf.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:powersync/powersync.dart' show PowerSyncDatabase;
import 'package:file_saver/file_saver.dart';

import 'activity_writes.dart' show AnswerType;
import 'export_data.dart';

const double _pageMargin = 32;

/// Exports a game's subsections and activities as CSV, PDF, Markdown or JSON.
///
/// Read the data once with [loadExportData], then pass it to any exporter.
/// Subsection descriptions are rich text (Quill); they keep their formatting
/// in the PDF and become plain text in the other formats.
class ExportActivity {
  const ExportActivity();

  Future<void> downloadFile(
    PowerSyncDatabase db,
    String filetype,
  ) async {
    final ExportData data = await _load(db);
    final String type = filetype.toLowerCase();

    late final Uint8List bytes;
    late final String extension;
    late final MimeType mimeType;

    switch (type) {
      case 'csv':
        bytes = _exportCSV(data);
        extension = 'csv';
        mimeType = MimeType.csv;

      case 'pdf':
        bytes = await _exportPDF(data);
        extension = 'pdf';
        mimeType = MimeType.pdf;

      case 'md':
        bytes = _exportMD(data);
        extension = 'md';
        mimeType = MimeType.text;

      case 'json':
        bytes = _exportJSON(data);
        extension = 'json';
        mimeType = MimeType.json;

      default:
        throw ArgumentError('Unsupported export filetype: $filetype');
    }

    await _save(
      name: _fileName(data.gameName, extension),
      bytes: bytes,
      mimeType: mimeType,
    );
  }

  Future<void> _save({
    required String name,
    required Uint8List bytes,
    required MimeType mimeType,
  }) async {
    await FileSaver.instance.saveFile(
      name: name,
      bytes: bytes,
      mimeType: mimeType,
    );
  }

  String _fileName(String gameName, String extension) {
    String name = gameName.trim();

    if (name.isEmpty) {
      name = 'game-export';
    }

    name = name.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');

    return '$name.$extension';
  }

  /// One line per activity: subsection, activity, description, points.
  Uint8List _exportCSV(ExportData data) {
    final List<String> lines = <String>['Subsection,Activity,Description,Points'];
    for (final ExportSubsection subsection in data.subsections) {
      for (final ExportActivityItem activity in subsection.activities) {
        lines.add(
          <String>[
            _csvCell(subsection.name),
            _csvCell(activity.name),
            _csvCell(activity.description),
            activity.points?.toString() ?? '',
          ].join(','),
        );
      }
    }
    String joined = lines.join('\n');
    return Uint8List.fromList(utf8.encode(joined));
  }

  /// One page group per subsection that has activities.
  Future<Uint8List> _exportPDF(ExportData data) async {
    final pw.Document pdf = pw.Document(title: data.gameName);
    bool addedPage = false;

    for (final ExportSubsection subsection in data.subsections) {
      if (subsection.activities.isEmpty) continue;

      // Convert the subsection description raw input/Delta into a rich PDF widget
      final pw.Widget? description =
          await _descriptionWidget(subsection.description);

      pdf.addPage(
        pw.MultiPage(
          pageFormat: PdfPageFormat.a4,
          margin: const pw.EdgeInsets.all(_pageMargin),
          build: (pw.Context context) => <pw.Widget>[
            pw.Text(
              data.gameName,
              style: pw.TextStyle(fontSize: 10, fontWeight: pw.FontWeight.bold),
            ),
            pw.SizedBox(height: 8),
            pw.Text(
              subsection.name,
              style: pw.TextStyle(fontSize: 18, fontWeight: pw.FontWeight.bold),
            ),
            pw.SizedBox(height: 12),
            if (description != null) ...<pw.Widget>[
              description,
              pw.SizedBox(height: 16),
            ],
            _activityTable(subsection.activities),
          ],
        ),
      );
      addedPage = true;
    }

    if (!addedPage) {
      pdf.addPage(
        pw.Page(
          build: (pw.Context context) =>
              pw.Center(child: pw.Text('No activities to export.')),
        ),
      );
    }
    return pdf.save();
  }

  Uint8List _exportMD(ExportData data) {
    final StringBuffer out = StringBuffer();
    for (final ExportSubsection subsection in data.subsections) {
      if (subsection.activities.isEmpty) continue;
      if (out.isNotEmpty) out.writeln();

      out.writeln('# ${subsection.name}');
      out.writeln();
      final String description = subsection.descriptionText;
      if (description.isNotEmpty) {
        out.writeln(description);
        out.writeln();
      }
      out.writeln('| Activity | Description | Points |');
      out.writeln('| --- | --- | ---: |');
      for (final ExportActivityItem activity in subsection.activities) {
        out.writeln(
          '| ${_markdownCell(activity.name)} '
          '| ${_markdownCell(activity.description)} '
          '| ${activity.points ?? ''} |',
        );
      }
    }
    String output = out.toString().trim();
    return Uint8List.fromList(utf8.encode(output));
  }

  Uint8List _exportJSON(ExportData data) {
    String out = jsonEncode(<Map<String, Object?>>[
      for (final ExportSubsection subsection in data.subsections)
        <String, Object?>{
          'name': subsection.name,
          'desc': <String, Object?>{
            'quill': subsection.description?.toJson() ?? <Object?>[],
            'plaintext': subsection.descriptionText,
          },
          if (subsection.viewOnly) 'view_only': true,
          'activities': <Map<String, Object?>>[
            for (final ExportActivityItem activity in subsection.activities)
              <String, Object?>{
                'activity': activity.name,
                'description': activity.description,
                'types': <String>[
                  for (final AnswerType type in activity.types)
                    type.wireName,
                ],
                'points': activity.points,
              },
          ],
        },
    ]);
    return Uint8List.fromList(utf8.encode(out));
  }

  Future<pw.Widget?> _descriptionWidget(Delta? description) async {
    if (description == null || description.isEmpty) {
      return null;
    }

    final PDFConverter converter = PDFConverter(
      document: description,
      pageFormat: PDFPageFormat.all(
        width: PdfPageFormat.a4.width,
        height: PdfPageFormat.a4.height,
        margin: 0,
      ),
      fallbacks: const <pw.Font>[],
      // ignore: experimental_member_use
      isWeb: kIsWeb,
    );

    return converter.generateWidget(
      maxWidth: PdfPageFormat.a4.width - (_pageMargin * 2),
    );
  }

  pw.Widget _activityTable(List<ExportActivityItem> activities) {
    final bool hasDescriptions = activities
        .any((ExportActivityItem a) => a.description.trim().isNotEmpty);

    final Map<int, pw.TableColumnWidth> widths = <int, pw.TableColumnWidth>{};
    int column = 0;
    widths[column++] = const pw.FixedColumnWidth(35);
    widths[column++] = const pw.FlexColumnWidth(2);
    if (hasDescriptions) widths[column++] = const pw.FlexColumnWidth(3);
    widths[column++] = const pw.FixedColumnWidth(35);
    widths[column++] = const pw.FixedColumnWidth(45);

    return pw.Table(
      border: pw.TableBorder.all(),
      columnWidths: widths,
      defaultVerticalAlignment: pw.TableCellVerticalAlignment.middle,
      children: <pw.TableRow>[
        pw.TableRow(
          decoration: const pw.BoxDecoration(color: PdfColors.grey300),
          children: <pw.Widget>[
            _headerCell('Num'),
            _headerCell('Activity'),
            if (hasDescriptions) _headerCell('Description'),
            _headerCell(''),
            _headerCell('Points'),
          ],
        ),
        for (int i = 0; i < activities.length; i++)
          pw.TableRow(
            children: <pw.Widget>[
              _cell('${i + 1}'),
              _cell(activities[i].name),
              if (hasDescriptions) _cell(activities[i].description),
              pw.Padding(
                padding: const pw.EdgeInsets.all(5),
                child: pw.Center(
                  child: pw.Container(
                    width: 12,
                    height: 12,
                    decoration: pw.BoxDecoration(border: pw.Border.all()),
                  ),
                ),
              ),
              _cell(activities[i].points?.toString() ?? ''),
            ],
          ),
      ],
    );
  }

  pw.Widget _headerCell(String text) {
    return pw.Padding(
      padding: const pw.EdgeInsets.all(5),
      child: pw.Text(
        text,
        style: pw.TextStyle(fontWeight: pw.FontWeight.bold, fontSize: 9),
      ),
    );
  }

  pw.Widget _cell(String text) {
    return pw.Padding(
      padding: const pw.EdgeInsets.all(5),
      child: pw.Text(text, style: const pw.TextStyle(fontSize: 9)),
    );
  }

  String _markdownCell(String value) =>
      value.replaceAll('|', r'\|').replaceAll('\n', '<br>');

  String _csvCell(String value) {
    final String safe = value.isNotEmpty && '=+-@\t\r'.contains(value[0])
        ? "'$value"
        : value;
    if (safe.contains(',') ||
        safe.contains('"') ||
        safe.contains('\n') ||
        safe.contains('\r')) {
      return '"${safe.replaceAll('"', '""')}"';
    }
    return safe;
  }

  Future<ExportData> _load(PowerSyncDatabase db) async {
    final ExportData? data = await loadExportData(db);

    if (data == null) {
      throw StateError('Game data has not synced yet.');
    }

    return data;
  }
}
