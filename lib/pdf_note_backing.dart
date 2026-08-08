import 'dart:io';
import 'dart:typed_data';

import 'package:pdf_document/pdf_document.dart' as pdf;

/// Creates and extends the real PDF file used underneath a notebook.
class PdfNoteBacking {
  const PdfNoteBacking._();

  static const double defaultPageWidth = 600;
  static const double defaultAspectRatio = 1.35;

  static Uint8List createBlankBytes({
    int pageCount = 1,
    double aspectRatio = defaultAspectRatio,
  }) {
    final ratio = _validAspectRatio(aspectRatio);
    return pdf.PdfBlankDocument.create(
      pageSize: pdf.PdfPageSize(defaultPageWidth, defaultPageWidth * ratio),
      pageCount: pageCount,
    );
  }

  static Future<File> createBlank({
    required Directory documentsDirectory,
    required String documentId,
  }) async {
    final directory = await _backingDirectory(
      documentsDirectory,
      documentId,
    ).create(recursive: true);
    final output = File('${directory.path}${Platform.pathSeparator}source.pdf');
    await output.writeAsBytes(createBlankBytes(), flush: true);
    return output;
  }

  /// Appends a blank page and writes the result to an alternate revision.
  ///
  /// pdfrx may still have [source] open. Alternating between two managed
  /// files gives the viewer a new path (and therefore a clean reload) without
  /// keeping an unbounded copy of the PDF for every page added.
  static Future<File> appendBlankPage({
    required File source,
    required Directory documentsDirectory,
    required String documentId,
    required int expectedPageCount,
    required double aspectRatio,
  }) async {
    if (!await source.exists()) {
      throw StateError('The PDF backing file is missing.');
    }

    final document = pdf.PdfDocument.open(await source.readAsBytes());
    if (document.pageCount != expectedPageCount) {
      throw StateError(
        'The PDF has ${document.pageCount} pages, but the note has '
        '$expectedPageCount.',
      );
    }

    final ratio = _validAspectRatio(aspectRatio);
    final editor = pdf.PdfEditor(document)
      ..insertBlankPage(
        width: defaultPageWidth,
        height: defaultPageWidth * ratio,
      );
    final bytes = editor.save();

    final directory = await _backingDirectory(
      documentsDirectory,
      documentId,
    ).create(recursive: true);
    final sourceName = source.uri.pathSegments.last.toLowerCase();
    final revisionName = sourceName == 'source-pages-a.pdf'
        ? 'source-pages-b.pdf'
        : 'source-pages-a.pdf';
    final target = File(
      '${directory.path}${Platform.pathSeparator}$revisionName',
    );
    final temporary = File(
      '${target.path}.tmp-${DateTime.now().microsecondsSinceEpoch}',
    );

    try {
      await temporary.writeAsBytes(bytes, flush: true);
      if (await target.exists()) await target.delete();
      return temporary.rename(target.path);
    } catch (_) {
      if (await temporary.exists()) await temporary.delete();
      rethrow;
    }
  }

  static Directory _backingDirectory(
    Directory documentsDirectory,
    String documentId,
  ) {
    final safeId = documentId
        .replaceAll(RegExp(r'[^a-zA-Z0-9_-]+'), '_')
        .replaceAll(RegExp(r'_+'), '_');
    if (safeId.isEmpty) {
      throw ArgumentError.value(documentId, 'documentId', 'is not valid');
    }
    return Directory(
      '${documentsDirectory.path}${Platform.pathSeparator}ink_note_pdf'
      '${Platform.pathSeparator}$safeId${Platform.pathSeparator}generated',
    );
  }

  static double _validAspectRatio(double value) {
    if (!value.isFinite || value <= .15 || value > 6) {
      return defaultAspectRatio;
    }
    return value;
  }
}
