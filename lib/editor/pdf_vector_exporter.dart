import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:pdf_document/pdf_document.dart' as pdf;

import '../models.dart';

/// Converts the app's top-left display coordinates into PDF user space.
///
/// PDF coordinates start at the bottom-left of the unrotated crop box, while
/// points stored by the editor are normalized against the page as displayed.
class PdfPageCoordinateMapper {
  factory PdfPageCoordinateMapper({
    required pdf.PdfRect cropBox,
    required int rotation,
  }) {
    final normalizedRotation = ((rotation % 360) + 360) % 360;
    return PdfPageCoordinateMapper._(
      cropBox: cropBox,
      rotation: normalizedRotation - normalizedRotation % 90,
    );
  }

  const PdfPageCoordinateMapper._({
    required this.cropBox,
    required this.rotation,
  });

  final pdf.PdfRect cropBox;
  final int rotation;

  double get displayWidth =>
      rotation == 90 || rotation == 270 ? cropBox.height : cropBox.width;

  double get displayHeight =>
      rotation == 90 || rotation == 270 ? cropBox.width : cropBox.height;

  /// PDF points represented by one logical editor unit. Editor pen widths
  /// are authored against a 1000-unit-wide page.
  double get pointsPerLogicalUnit =>
      displayWidth / PdfVectorExporter.logicalPageWidth;

  (double, double) fromNormalized(double x, double y) =>
      fromDisplay(x * displayWidth, y * displayHeight);

  /// Maps a display-space point whose origin is the visible top-left corner.
  (double, double) fromDisplay(double x, double y) {
    final (u, v) = switch (rotation) {
      90 => (y, x),
      180 => (cropBox.width - x, y),
      270 => (cropBox.width - y, cropBox.height - x),
      _ => (x, cropBox.height - y),
    };
    return (cropBox.left + u, cropBox.bottom + v);
  }

  /// Maps a top-left display rectangle to its enclosing PDF-space rectangle.
  pdf.PdfRect rectFromDisplay({
    required double left,
    required double top,
    required double width,
    required double height,
  }) {
    final corners = <(double, double)>[
      fromDisplay(left, top),
      fromDisplay(left + width, top),
      fromDisplay(left, top + height),
      fromDisplay(left + width, top + height),
    ];
    final xs = corners.map((point) => point.$1);
    final ys = corners.map((point) => point.$2);
    return pdf.PdfRect(
      xs.reduce(math.min),
      ys.reduce(math.min),
      xs.reduce(math.max),
      ys.reduce(math.max),
    );
  }
}

/// Exports editor objects onto the original document as native PDF
/// annotations. Ink remains a vector centerline with a generated spline
/// appearance instead of being flattened into a page-sized PNG.
class PdfVectorExporter {
  const PdfVectorExporter._();

  static const double logicalPageWidth = 1000;
  static const double _dashLength = 10;
  static const double _dashGap = 7;

  static Uint8List export({
    required Uint8List sourcePdf,
    required List<List<InkObject>> pages,
    Map<String, Uint8List> imageBytesByPath = const <String, Uint8List>{},
  }) {
    final document = pdf.PdfDocument.open(sourcePdf);
    if (pages.length > document.pageCount) {
      throw StateError(
        'The note has ${pages.length} pages but the PDF has '
        '${document.pageCount}.',
      );
    }

    final editor = pdf.PdfEditor(document);
    final decodedImages = <String, pdf.PdfEmbeddableImage>{};
    var changed = false;
    for (var pageIndex = 0; pageIndex < pages.length; pageIndex++) {
      final page = document.page(pageIndex);
      final mapper = PdfPageCoordinateMapper(
        cropBox: page.cropBox,
        rotation: page.rotation,
      );
      final objects = pages[pageIndex];
      // Match InkPainter's compositing order: translucent highlighters sit
      // behind opaque ink regardless of when they were authored.
      for (final stroke in objects.whereType<InkStroke>().where(
        (stroke) => stroke.tool == InkTool.highlighter,
      )) {
        changed = _addStroke(editor, pageIndex, mapper, stroke) || changed;
      }
      for (final object in objects) {
        if (object case final InkStroke stroke) {
          if (stroke.tool == InkTool.highlighter) continue;
          changed = _addStroke(editor, pageIndex, mapper, stroke) || changed;
        } else if (object case final InkText text) {
          changed = _addText(editor, pageIndex, mapper, text) || changed;
        } else if (object case final InkImage image) {
          changed =
              _addImage(
                editor,
                pageIndex,
                mapper,
                image,
                imageBytesByPath,
                decodedImages,
              ) ||
              changed;
        }
      }
    }

    return changed ? editor.save() : Uint8List.fromList(sourcePdf);
  }

  static bool _addStroke(
    pdf.PdfEditor editor,
    int pageIndex,
    PdfPageCoordinateMapper mapper,
    InkStroke stroke,
  ) {
    if (stroke.points.isEmpty || !stroke.width.isFinite || stroke.width <= 0) {
      return false;
    }

    final samples = stroke.tool == InkTool.shape
        ? _shapeSamples(stroke, mapper)
        : _filteredSamples(stroke, mapper);
    if (samples.isEmpty) return false;

    final pageScale = mapper.pointsPerLogicalUnit;
    final hasVariableWidth =
        samples.length > 1 &&
        ((stroke.dashed &&
                stroke.tool != InkTool.shape &&
                stroke.tool != InkTool.highlighter) ||
            stroke.tool == InkTool.fountainPen ||
            stroke.tool == InkTool.brushPen);
    final averagePressure = _averagePressure(samples);
    final samplesWithWidths = <_PdfInkSample>[
      for (var index = 0; index < samples.length; index++)
        samples[index].withWidth(
          _desiredWidth(
            stroke,
            samples[index].pressure,
            index / math.max(1, samples.length - 1),
            pageScale,
            useAveragePenPressure: !hasVariableWidth,
            averagePressure: averagePressure,
          ),
        ),
    ];

    final paths = stroke.dashed && samplesWithWidths.length > 1
        ? _splitDashed(samplesWithWidths, pageScale)
        : <List<_PdfInkSample>>[samplesWithWidths];
    if (paths.isEmpty) return false;

    final constantWidth = samplesWithWidths.first.width;
    final widest = paths
        .expand((path) => path)
        .map((sample) => sample.width)
        .reduce(math.max);
    final authoredBaseWidth = math.max(.1, stroke.width * pageScale);
    final baseWidth = hasVariableWidth
        ? math.max(authoredBaseWidth, widest / 1.6)
        : math.max(.1, constantWidth);

    final pdfPaths = <List<(double, double)>>[
      for (final path in paths)
        <(double, double)>[for (final sample in path) (sample.x, sample.y)],
    ];
    final pressurePaths = hasVariableWidth
        ? <List<double>?>[
            for (final path in paths)
              <double>[
                for (final sample in path)
                  ((sample.width / baseWidth - .4) / 1.2)
                      .clamp(0.0, 1.0)
                      .toDouble(),
              ],
          ]
        : null;
    final argb = stroke.color.toARGB32();

    editor.addInk(
      pageIndex,
      pdfPaths,
      color: argb & 0x00FFFFFF,
      strokeWidth: baseWidth,
      opacity: stroke.tool == InkTool.highlighter
          ? .28
          : ((argb >> 24) & 0xFF) / 255,
      pressures: pressurePaths,
      contents: 'Ink Note ${stroke.tool.name}',
      author: 'Ink Note',
    );
    return true;
  }

  static List<_PdfInkSample> _shapeSamples(
    InkStroke stroke,
    PdfPageCoordinateMapper mapper,
  ) {
    final points = stroke.points.length == 1
        ? <InkPoint>[stroke.points.first]
        : <InkPoint>[stroke.points.first, stroke.points.last];
    return <_PdfInkSample>[
      for (final point in points)
        () {
          final mapped = mapper.fromNormalized(point.x, point.y);
          return _PdfInkSample(mapped.$1, mapped.$2, point.pressure);
        }(),
    ];
  }

  static List<_PdfInkSample> _filteredSamples(
    InkStroke stroke,
    PdfPageCoordinateMapper mapper,
  ) {
    final source = <_PdfInkSample>[];
    final minimumDistanceSquared = math
        .pow(.01 * mapper.pointsPerLogicalUnit, 2)
        .toDouble();
    for (final point in stroke.points) {
      if (!point.x.isFinite || !point.y.isFinite || !point.pressure.isFinite) {
        continue;
      }
      final mapped = mapper.fromNormalized(point.x, point.y);
      final sample = _PdfInkSample(mapped.$1, mapped.$2, point.pressure);
      if (source.isEmpty ||
          sample.distanceSquaredTo(source.last) >= minimumDistanceSquared) {
        source.add(sample);
      }
    }
    if (source.length < 3) return source;

    var filtered = source;
    for (var pass = 0; pass < 2; pass++) {
      final next = <_PdfInkSample>[filtered.first];
      for (var index = 1; index < filtered.length - 1; index++) {
        final previous = filtered[index - 1];
        final current = filtered[index];
        final following = filtered[index + 1];
        next.add(
          _PdfInkSample(
            (previous.x + current.x * 4 + following.x) / 6,
            (previous.y + current.y * 4 + following.y) / 6,
            (previous.pressure + current.pressure * 4 + following.pressure) / 6,
          ),
        );
      }
      next.add(filtered.last);
      filtered = next;
    }
    return filtered;
  }

  static double _averagePressure(List<_PdfInkSample> samples) =>
      samples
          .map((sample) => sample.pressure)
          .fold<double>(0, (sum, pressure) => sum + pressure) /
      samples.length;

  static double _desiredWidth(
    InkStroke stroke,
    double pressure,
    double progress,
    double pageScale, {
    required bool useAveragePenPressure,
    required double averagePressure,
  }) {
    final effectivePressure = useAveragePenPressure
        ? averagePressure
        : pressure;
    final rawPressure = effectivePressure.clamp(.03, 1.0).toDouble();
    final sensitivity = stroke.pressureSensitivity.clamp(0.0, 1.0).toDouble();
    final pressureValue =
        ((1 - sensitivity) * .72 + sensitivity * math.sqrt(rawPressure))
            .clamp(.08, 1.0)
            .toDouble();
    final baseWidth = stroke.width * pageScale;

    return switch (stroke.tool) {
      InkTool.fountainPen =>
        baseWidth *
            (.48 + pressureValue * 1.12) *
            ((1 - progress) / .035).clamp(.48, 1.0),
      InkTool.brushPen =>
        baseWidth *
            (.28 + pressureValue * 1.55) *
            (progress / .055).clamp(.18, 1.0) *
            ((1 - progress) / .12).clamp(.12, 1.0),
      InkTool.highlighter => baseWidth,
      InkTool.shape => baseWidth,
      _ => baseWidth * (.96 + pressureValue * .08),
    };
  }

  static List<List<_PdfInkSample>> _splitDashed(
    List<_PdfInkSample> samples,
    double pageScale,
  ) {
    final dashLength = _dashLength * pageScale;
    final cycle = dashLength + _dashGap * pageScale;
    final output = <List<_PdfInkSample>>[];
    var phase = 0.0;

    for (var index = 0; index < samples.length - 1; index++) {
      final start = samples[index];
      final end = samples[index + 1];
      final dx = end.x - start.x;
      final dy = end.y - start.y;
      final distance = math.sqrt(dx * dx + dy * dy);
      if (distance <= 0) continue;
      var travelled = 0.0;
      var currentPhase = phase % cycle;

      while (travelled < distance) {
        final inDash = currentPhase < dashLength;
        final remainingInPart = inDash
            ? dashLength - currentPhase
            : cycle - currentPhase;
        final step = math.min(remainingInPart, distance - travelled);
        if (inDash && step > 0) {
          final startT = travelled / distance;
          final endT = (travelled + step) / distance;
          output.add(<_PdfInkSample>[
            start.interpolate(end, startT),
            start.interpolate(end, endT),
          ]);
        }
        travelled += step;
        currentPhase = (currentPhase + step) % cycle;
      }
      phase = (phase + distance) % cycle;
    }
    return output;
  }

  static bool _addText(
    pdf.PdfEditor editor,
    int pageIndex,
    PdfPageCoordinateMapper mapper,
    InkText text,
  ) {
    if (text.text.isEmpty || !text.fontSize.isFinite || text.fontSize <= 0) {
      return false;
    }

    final maxLogicalWidth = math.max(48.0, text.width * logicalPageWidth);
    final textPainter = TextPainter(
      text: TextSpan(
        text: text.text,
        style: TextStyle(
          fontSize: text.fontSize,
          fontWeight: text.bold ? FontWeight.bold : FontWeight.normal,
          fontStyle: text.italic ? FontStyle.italic : FontStyle.normal,
          height: text.lineHeight,
        ),
      ),
      textDirection: TextDirection.ltr,
      textAlign: text.textAlign,
    )..layout(maxWidth: maxLogicalWidth);
    final logicalHeight = math.max(textPainter.height, text.fontSize);
    textPainter.dispose();

    final scale = mapper.pointsPerLogicalUnit;
    const pdfTextPadding = 3.0;
    final rect = mapper.rectFromDisplay(
      left: text.x * mapper.displayWidth - pdfTextPadding,
      top: text.y * mapper.displayHeight - pdfTextPadding,
      width: maxLogicalWidth * scale + pdfTextPadding * 2,
      height: logicalHeight * scale + pdfTextPadding * 2,
    );
    final argb = text.color.toARGB32();
    editor.addFreeText(
      pageIndex,
      rect,
      text.text,
      fontSize: text.fontSize * scale,
      font: pdf.PdfStandardFont.styled(
        pdf.PdfStandardFontFamily.sans,
        bold: text.bold,
        italic: text.italic,
      ),
      align: switch (text.textAlign) {
        TextAlign.center => pdf.PdfTextAlign.center,
        TextAlign.right || TextAlign.end => pdf.PdfTextAlign.right,
        _ => pdf.PdfTextAlign.left,
      },
      color: argb & 0x00FFFFFF,
      borderWidth: 0,
      lineSpacing: text.lineHeight,
      pageRotation: mapper.rotation,
      author: 'Ink Note',
    );
    return true;
  }

  static bool _addImage(
    pdf.PdfEditor editor,
    int pageIndex,
    PdfPageCoordinateMapper mapper,
    InkImage image,
    Map<String, Uint8List> imageBytesByPath,
    Map<String, pdf.PdfEmbeddableImage> decodedImages,
  ) {
    if (image.path.isEmpty ||
        !image.x.isFinite ||
        !image.y.isFinite ||
        !image.width.isFinite ||
        !image.height.isFinite ||
        image.width <= 0 ||
        image.height <= 0) {
      return false;
    }
    final bytes = imageBytesByPath[image.path];
    if (bytes == null) {
      throw StateError('Inserted image bytes are missing for ${image.path}.');
    }
    final decoded = decodedImages.putIfAbsent(
      image.path,
      () => pdf.PdfEmbeddableImage.decode(bytes),
    );
    final rect = mapper.rectFromDisplay(
      left: image.x * mapper.displayWidth,
      top: image.y * mapper.displayHeight,
      width: image.width * mapper.displayWidth,
      height: image.height * mapper.displayHeight,
    );
    editor.addImageStamp(
      pageIndex,
      rect,
      decoded,
      pageRotation: mapper.rotation,
      author: 'Ink Note',
    );
    return true;
  }
}

class _PdfInkSample {
  const _PdfInkSample(this.x, this.y, this.pressure, [this.width = 0]);

  final double x;
  final double y;
  final double pressure;
  final double width;

  double distanceSquaredTo(_PdfInkSample other) {
    final dx = x - other.x;
    final dy = y - other.y;
    return dx * dx + dy * dy;
  }

  _PdfInkSample withWidth(double value) => _PdfInkSample(x, y, pressure, value);

  _PdfInkSample interpolate(_PdfInkSample other, double t) => _PdfInkSample(
    x + (other.x - x) * t,
    y + (other.y - y) * t,
    pressure + (other.pressure - pressure) * t,
    width + (other.width - width) * t,
  );
}
