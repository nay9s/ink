import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../models.dart';

/// A stroke recovered from a PDF's own native annotations, paired with which
/// page (within that PDF, 0-based) it belongs to.
class ImportedInkStroke {
  const ImportedInkStroke({required this.pdfPageIndex, required this.stroke});

  final int pdfPageIndex;
  final InkStroke stroke;
}

/// One-time recovery for notes that were edited before PDF-page ink moved
/// into the Flutter InkPainter layer (see EditorScreen._showNativePdfReader).
/// Those notes have real ink baked directly into their PDF file as native
/// PDFAnnotations; this pulls that ink out once and strips it from the PDF
/// file so it isn't left double-baked once Flutter also owns it.
class NativePdfInkImporter {
  NativePdfInkImporter._();

  static const MethodChannel _channel =
      MethodChannel('ink_note/pdf_ink_importer');

  /// Returns strokes recovered from [pdfPath]'s own annotations, or an empty
  /// list if there was nothing to import (including on platforms without
  /// this channel, e.g. Android).
  static Future<List<ImportedInkStroke>> extractStrokes(
    String pdfPath,
  ) async {
    if (defaultTargetPlatform != TargetPlatform.iOS) return const [];

    List<Object?>? raw;
    try {
      raw = await _channel.invokeMethod<List<Object?>>(
        'extractAndStrip',
        <String, Object>{'path': pdfPath},
      );
    } on MissingPluginException {
      return const [];
    } on PlatformException {
      return const [];
    }
    if (raw == null || raw.isEmpty) return const [];

    final imported = <ImportedInkStroke>[];
    for (final entry in raw) {
      final stroke = _decodeStroke(entry);
      if (stroke != null) imported.add(stroke);
    }
    return imported;
  }

  static ImportedInkStroke? _decodeStroke(Object? entry) {
    if (entry is! Map) return null;
    final map = Map<String, dynamic>.from(entry);
    final pageIndex = map['pageIndex'] as int?;
    final toolName = map['tool'] as String?;
    final colorValue = map['color'] as int?;
    final width = (map['width'] as num?)?.toDouble();
    final pageWidth = (map['pageWidth'] as num?)?.toDouble();
    final pageHeight = (map['pageHeight'] as num?)?.toDouble();
    final rawPoints = map['points'] as List?;
    if (pageIndex == null ||
        toolName == null ||
        colorValue == null ||
        width == null ||
        pageWidth == null ||
        pageHeight == null ||
        rawPoints == null ||
        pageWidth <= 0 ||
        pageHeight <= 0 ||
        rawPoints.length < 2) {
      return null;
    }

    final tool = InkTool.values.byName(toolName);
    final points = <InkPoint>[];
    for (final rawPoint in rawPoints) {
      if (rawPoint is! List || rawPoint.length < 2) continue;
      final x = (rawPoint[0] as num).toDouble();
      final y = (rawPoint[1] as num).toDouble();
      // Native PDF page space has its origin bottom-left with Y increasing
      // upward (standard PDF convention); InkPoint fraction space matches
      // the rest of Flutter's rendering, origin top-left with Y increasing
      // downward — hence the flip on Y but not X.
      final fractionX = (x / pageWidth).clamp(0.0, 1.0);
      final fractionY = (1 - (y / pageHeight)).clamp(0.0, 1.0);
      // Per-point pressure was never stored in the flattened PDF
      // annotation, so every recovered point gets a neutral mid pressure —
      // renders at a uniform width regardless of pressureSensitivity.
      points.add(InkPoint(fractionX, fractionY, 0.5));
    }
    if (points.length < 2) return null;

    return ImportedInkStroke(
      pdfPageIndex: pageIndex,
      stroke: InkStroke(
        tool: tool,
        color: Color(colorValue),
        width: width,
        points: points,
      ),
    );
  }
}
