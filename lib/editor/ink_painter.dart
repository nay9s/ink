import 'dart:math' as math;
import 'dart:ui' as ui;
import 'package:flutter/material.dart';

import '../models.dart';
import 'selection_transform.dart';
import 'stroke_geometry.dart';

class InkPainter extends CustomPainter {
  static const double _lassoStrokeWidth = 1.25;
  static const double _lassoDashLength = 6.5;
  static const double _lassoGapLength = 4.5;

  InkPainter({
    required this.strokes,
    this.activeStroke,
    this.lassoPath = const [],
    this.selectionPath = const [],
    this.template = BackgroundTemplate.blank,
    this.contentScale = 1.0,
    this.selectionOverlayScale,
    this.eraserCursor,
    this.eraserDiameter = 0,
    this.eraserBorderWidth = 1.5,
    this.images = const <String, ui.Image>{},
  });

  final List<InkObject> strokes;
  final InkObject? activeStroke;
  final List<InkPoint> lassoPath;
  final List<InkPoint> selectionPath;
  final BackgroundTemplate template;

  /// Optional scale for callers that resize the page's layout without using a
  /// canvas or ancestor transform. Never pass an InteractiveViewer zoom here:
  /// its transform already scales paint widths along with the page.
  final double contentScale;

  /// Scale used only for selection outlines and resize handles. Editors whose
  /// canvas is transformed by an ancestor pass the inverse viewer zoom here,
  /// keeping this interaction chrome a constant size on screen.
  final double? selectionOverlayScale;
  final InkPoint? eraserCursor;
  final double eraserDiameter;
  final double eraserBorderWidth;
  final Map<String, ui.Image> images;

  double get _scale => contentScale.clamp(.25, 8.0).toDouble();
  double get _selectionScale =>
      (selectionOverlayScale ?? contentScale).clamp(.05, 8.0).toDouble();

  @override
  void paint(Canvas canvas, Size size) {
    paintInto(canvas, Offset.zero & size);
  }

  /// Draws into an arbitrary target [rect] instead of always assuming the
  /// canvas origin is the page's top-left corner — used both by [paint]
  /// (rect always starts at the origin) and by native PDF page painting
  /// (e.g. pdfrx's `pagePaintCallbacks`), where the page's current on-screen
  /// rect moves and scales as the user pans/zooms a viewer we don't own.
  void paintInto(Canvas canvas, Rect rect) {
    _drawTemplate(canvas, rect);
    final currentActive = activeStroke;

    for (final stroke in strokes.whereType<InkStroke>()) {
      if (stroke.tool == InkTool.highlighter) {
        _paintStroke(canvas, rect, stroke);
      }
    }
    if (currentActive is InkStroke &&
        currentActive.tool == InkTool.highlighter) {
      _paintStroke(canvas, rect, currentActive);
    }

    for (final object in strokes) {
      if (object is InkStroke && object.tool != InkTool.highlighter) {
        _paintStroke(canvas, rect, object);
      } else if (object is InkText) {
        _paintText(canvas, rect, object);
      } else if (object is InkImage) {
        _paintImage(canvas, rect, object);
      }
    }
    if (currentActive is InkStroke &&
        currentActive.tool != InkTool.highlighter) {
      _paintStroke(canvas, rect, currentActive);
    } else if (currentActive is InkText) {
      _paintText(canvas, rect, currentActive);
    }

    _drawLassoPath(canvas, rect);
    _drawSelectionLasso(canvas, rect);
    if (selectionPath.isEmpty) _drawSelectionBox(canvas, rect);
    _drawEraserCursor(canvas, rect);
  }

  Offset _offsetFor(InkPoint point, Rect rect) => Offset(
    rect.left + point.x * rect.width,
    rect.top + point.y * rect.height,
  );

  void _drawTemplate(Canvas canvas, Rect rect) {
    if (template == BackgroundTemplate.blank) return;

    final paint = Paint()
      ..isAntiAlias = true
      ..color = Colors.blueAccent.withValues(alpha: 0.2)
      ..strokeWidth = math.max(.75, _scale)
      ..style = PaintingStyle.stroke;

    if (template == BackgroundTemplate.ruled) {
      final spacing = rect.height / 25;
      for (double y = spacing * 2; y < rect.height; y += spacing) {
        canvas.drawLine(
          Offset(rect.left, rect.top + y),
          Offset(rect.right, rect.top + y),
          paint,
        );
      }
      final marginPaint = Paint()
        ..isAntiAlias = true
        ..color = Colors.redAccent.withValues(alpha: 0.3)
        ..strokeWidth = math.max(.75, _scale);
      canvas.drawLine(
        Offset(rect.left + rect.width * 0.15, rect.top),
        Offset(rect.left + rect.width * 0.15, rect.bottom),
        marginPaint,
      );
    } else if (template == BackgroundTemplate.grid) {
      final spacing = rect.width / 20;
      for (double y = 0; y < rect.height; y += spacing) {
        canvas.drawLine(
          Offset(rect.left, rect.top + y),
          Offset(rect.right, rect.top + y),
          paint,
        );
      }
      for (double x = 0; x < rect.width; x += spacing) {
        canvas.drawLine(
          Offset(rect.left + x, rect.top),
          Offset(rect.left + x, rect.bottom),
          paint,
        );
      }
    } else if (template == BackgroundTemplate.dotted) {
      final spacing = rect.width / 20;
      final dotPaint = Paint()
        ..isAntiAlias = true
        ..color = Colors.grey.withValues(alpha: 0.5);
      for (double y = spacing; y < rect.height; y += spacing) {
        for (double x = spacing; x < rect.width; x += spacing) {
          canvas.drawCircle(
            Offset(rect.left + x, rect.top + y),
            1.5 * _scale,
            dotPaint,
          );
        }
      }
    }
  }

  void _drawLassoPath(Canvas canvas, Rect rect) {
    if (lassoPath.length < 2) return;
    final paint = Paint()
      ..isAntiAlias = true
      ..color = Colors.blueAccent
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..strokeWidth = _lassoStrokeWidth * _selectionScale;
    var phase = 0.0;
    var previous = _offsetFor(lassoPath.first, rect);
    for (final point in lassoPath.skip(1)) {
      final next = _offsetFor(point, rect);
      phase = _drawDashedSegment(
        canvas,
        previous,
        next,
        paint,
        phase: phase,
        dashLength: _lassoDashLength * _selectionScale,
        gapLength: _lassoGapLength * _selectionScale,
      );
      previous = next;
    }
  }

  void _drawSelectionLasso(Canvas canvas, Rect rect) {
    if (selectionPath.length < 3) return;
    final border = Paint()
      ..isAntiAlias = true
      ..color = Colors.blueAccent
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..strokeWidth = _lassoStrokeWidth * _selectionScale;
    var phase = 0.0;
    var previous = _offsetFor(selectionPath.first, rect);
    for (final point in selectionPath.skip(1)) {
      final next = _offsetFor(point, rect);
      phase = _drawDashedSegment(
        canvas,
        previous,
        next,
        border,
        phase: phase,
        dashLength: _lassoDashLength * _selectionScale,
        gapLength: _lassoGapLength * _selectionScale,
      );
      previous = next;
    }
    _drawDashedSegment(
      canvas,
      previous,
      _offsetFor(selectionPath.first, rect),
      border,
      phase: phase,
      dashLength: _lassoDashLength * _selectionScale,
      gapLength: _lassoGapLength * _selectionScale,
    );

    final normalizedBounds = inkPointBounds(selectionPath);
    if (normalizedBounds != null) {
      _drawResizeHandles(
        canvas,
        Rect.fromLTRB(
          rect.left + normalizedBounds.left * rect.width,
          rect.top + normalizedBounds.top * rect.height,
          rect.left + normalizedBounds.right * rect.width,
          rect.top + normalizedBounds.bottom * rect.height,
        ),
      );
    }
  }

  void _drawSelectionBox(Canvas canvas, Rect rect) {
    var minX = double.infinity;
    var minY = double.infinity;
    var maxX = -double.infinity;
    var maxY = -double.infinity;
    var hasSelection = false;

    for (final object in strokes) {
      if (!object.isSelected) continue;
      hasSelection = true;
      if (object is InkStroke) {
        for (final point in object.points) {
          minX = math.min(minX, point.x);
          maxX = math.max(maxX, point.x);
          minY = math.min(minY, point.y);
          maxY = math.max(maxY, point.y);
        }
      } else if (object is InkText) {
        final textWidth =
            (object.text.length * object.fontSize * 0.6 * _scale) / rect.width;
        final textHeight = object.fontSize * _scale / rect.height;
        minX = math.min(minX, object.x);
        maxX = math.max(maxX, object.x + textWidth);
        minY = math.min(minY, object.y);
        maxY = math.max(maxY, object.y + textHeight);
      } else if (object is InkImage) {
        minX = math.min(minX, object.x);
        maxX = math.max(maxX, object.x + object.width);
        minY = math.min(minY, object.y);
        maxY = math.max(maxY, object.y + object.height);
      }
    }

    if (!hasSelection || minX == double.infinity) return;

    final padding = selectionOutlinePadding * _selectionScale;
    final selectionRect = Rect.fromLTRB(
      rect.left + minX * rect.width - padding,
      rect.top + minY * rect.height - padding,
      rect.left + maxX * rect.width + padding,
      rect.top + maxY * rect.height + padding,
    );
    final paint = Paint()
      ..isAntiAlias = true
      ..color = Colors.blueAccent
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2 * _selectionScale;
    canvas.drawRect(selectionRect, paint);

    _drawResizeHandles(canvas, selectionRect);
  }

  void _drawResizeHandles(Canvas canvas, Rect selectionRect) {
    final handlePaint = Paint()
      ..isAntiAlias = true
      ..color = Colors.white;
    final handleBorder = Paint()
      ..isAntiAlias = true
      ..color = Colors.blueAccent
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2 * _selectionScale;
    final handleRadius = selectionHandleRadius * _selectionScale;
    for (final handle in SelectionResizeHandle.values) {
      final point = selectionResizeHandlePosition(selectionRect, handle);
      canvas.drawCircle(point, handleRadius, handlePaint);
      canvas.drawCircle(point, handleRadius, handleBorder);
    }
  }

  double _pressureWidth(
    InkStroke stroke,
    double pressure,
    double progress, {
    double speed = 0,
  }) {
    final rawPressure = pressure.clamp(.03, 1.0).toDouble();
    final sensitivity = stroke.pressureSensitivity.clamp(0.0, 1.0).toDouble();
    final pressureValue =
        ((1 - sensitivity) * .72 + sensitivity * math.sqrt(rawPressure))
            .clamp(.08, 1.0)
            .toDouble();
    final baseWidth = stroke.width * _scale;
    final speedReduction = 1 - speed.clamp(0.0, 1.0).toDouble() * .12;

    switch (stroke.tool) {
      case InkTool.fountainPen:
        final endTaper = ((1 - progress) / .035).clamp(.48, 1.0).toDouble();
        return baseWidth *
            (.48 + pressureValue * 1.12) *
            speedReduction *
            endTaper;
      case InkTool.brushPen:
        final startTaper = (progress / .055).clamp(.18, 1.0).toDouble();
        final endTaper = ((1 - progress) / .12).clamp(.12, 1.0).toDouble();
        return baseWidth *
            (.28 + pressureValue * 1.55) *
            startTaper *
            endTaper *
            speedReduction;
      case InkTool.highlighter:
        return baseWidth;
      case InkTool.pen:
      default:
        // A ball pen stays nearly constant, while retaining a very small
        // amount of pressure response so Pencil input does not feel digital.
        return baseWidth * (.96 + pressureValue * .08);
    }
  }

  double _geometryUnit(Rect rect) => math.max(rect.width.abs() / 1000, .0001);

  List<StrokeGeometrySample> _filteredRenderPoints(
    InkStroke stroke,
    Rect rect,
  ) {
    final samples = stroke.points.map(
      (point) => StrokeGeometrySample(_offsetFor(point, rect), point.pressure),
    );
    if (stroke.geometryVersion >= 2) {
      return prepareStableStrokeSamples(
        samples,
        minimumDistance: .05 * _geometryUnit(rect),
      );
    }
    return prepareStrokeSamples(
      samples,
      // Preserve the established appearance of strokes stored before the
      // prefix-stable capture pipeline was introduced.
      sampleSpacing: 3 * _geometryUnit(rect),
    );
  }

  List<StrokeGeometrySample> _interpolatedPoints(
    List<StrokeGeometrySample> source,
    Rect rect,
  ) => sampleSmoothStrokeCurve(
    source,
    maximumSegmentLength: .8 * _geometryUnit(rect),
  );

  void _drawVariableStroke(
    Canvas canvas,
    InkStroke stroke,
    List<StrokeGeometrySample> points,
    Paint paint,
  ) {
    if (points.length < 2) return;
    final left = <Offset>[];
    final right = <Offset>[];
    final widths = <double>[];

    for (var index = 0; index < points.length; index++) {
      final previous = points[index == 0 ? 0 : index - 1].offset;
      final next =
          points[index + 1 < points.length ? index + 1 : points.length - 1]
              .offset;
      var tangent = next - previous;
      if (tangent.distanceSquared < .0001) {
        tangent = const Offset(1, 0);
      } else {
        tangent = tangent / tangent.distance;
      }
      final normal = Offset(-tangent.dy, tangent.dx);
      final progress = index / math.max(1, points.length - 1);
      final localSpeed = (next - previous).distance / 9;
      final width = _pressureWidth(
        stroke,
        points[index].pressure,
        progress,
        speed: localSpeed,
      );
      widths.add(width);
      left.add(points[index].offset + normal * (width / 2));
      right.add(points[index].offset - normal * (width / 2));
    }

    final outline = Path();
    appendSmoothStrokePath(outline, left, moveToFirst: true);
    appendSmoothStrokePath(
      outline,
      right.reversed.toList(),
      moveToFirst: false,
    );
    outline.close();

    final fill = Paint()
      ..isAntiAlias = true
      ..style = PaintingStyle.fill
      ..color = paint.color;
    canvas.drawPath(outline, fill);
    canvas.drawCircle(points.first.offset, widths.first / 2, fill);
    canvas.drawCircle(points.last.offset, widths.last / 2, fill);
  }

  void _paintStroke(Canvas canvas, Rect rect, InkStroke stroke) {
    if (stroke.points.isEmpty) return;

    final paint = Paint()
      ..isAntiAlias = true
      ..style = PaintingStyle.stroke
      ..color = stroke.color
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;

    if (stroke.tool == InkTool.highlighter) {
      paint
        ..color = paint.color.withValues(alpha: 0.28)
        ..strokeCap = StrokeCap.square
        ..blendMode = BlendMode.multiply;
    }

    if (stroke.tool == InkTool.shape && stroke.points.length > 1) {
      paint.strokeWidth = stroke.width * _scale;
      final start = _offsetFor(stroke.points.first, rect);
      final end = _offsetFor(stroke.points.last, rect);
      if (stroke.dashed) {
        _drawDashedSegment(canvas, start, end, paint);
      } else {
        canvas.drawLine(start, end, paint);
      }
      return;
    }

    if (stroke.points.length == 1) {
      final point = stroke.points.first;
      final radius = _pressureWidth(stroke, point.pressure, 0) / 2;
      paint.style = PaintingStyle.fill;
      // Match the line thickness exactly. A floor here (it used to be .75)
      // pinned the dot to ~1.5 units wide, so every pen-down flashed a dot up
      // to 3x the pen width before the second point arrived — a stroke always
      // has a single point for that first frame. Sub-pixel dots stay visible
      // through antialiasing, and grow with the page like the line does.
      canvas.drawCircle(_offsetFor(point, rect), math.max(radius, .01), paint);
      return;
    }

    final centerPoints = _filteredRenderPoints(stroke, rect);
    final renderPoints = _interpolatedPoints(centerPoints, rect);

    if (stroke.dashed) {
      var dashPhase = 0.0;
      for (var index = 0; index < renderPoints.length - 1; index++) {
        final first = renderPoints[index];
        final second = renderPoints[index + 1];
        final pressure = (first.pressure + second.pressure) / 2;
        paint.strokeWidth = _pressureWidth(
          stroke,
          pressure,
          index / math.max(1, renderPoints.length - 1),
        );
        dashPhase = _drawDashedSegment(
          canvas,
          first.offset,
          second.offset,
          paint,
          phase: dashPhase,
        );
      }
      return;
    }

    if (stroke.tool == InkTool.fountainPen || stroke.tool == InkTool.brushPen) {
      _drawVariableStroke(canvas, stroke, renderPoints, paint);
      return;
    }

    final averagePressure =
        renderPoints
            .map((point) => point.pressure)
            .fold<double>(0, (sum, pressure) => sum + pressure) /
        renderPoints.length;
    paint.strokeWidth = _pressureWidth(stroke, averagePressure, .5);
    canvas.drawPath(
      createSmoothStrokePath(
        centerPoints.map((point) => point.offset).toList(growable: false),
      ),
      paint,
    );
  }

  void _drawEraserCursor(Canvas canvas, Rect rect) {
    final cursor = eraserCursor;
    if (cursor == null || eraserDiameter <= 0) return;
    final center = _offsetFor(cursor, rect);
    final radius = eraserDiameter / 2;
    final borderWidth = eraserBorderWidth.clamp(0.0, radius * 2).toDouble();
    final fill = Paint()
      ..isAntiAlias = true
      ..style = PaintingStyle.fill
      ..color = Colors.white.withValues(alpha: .22);
    final border = Paint()
      ..isAntiAlias = true
      ..style = PaintingStyle.stroke
      ..strokeWidth = borderWidth
      ..color = Colors.black.withValues(alpha: .46);
    canvas.drawCircle(center, radius, fill);
    // Keep the outline inside the hit area. A centered outline at [radius]
    // makes the visible ring larger by half its stroke width.
    canvas.drawCircle(center, math.max(0, radius - borderWidth / 2), border);
  }

  double _drawDashedSegment(
    Canvas canvas,
    Offset start,
    Offset end,
    Paint paint, {
    double phase = 0,
    double? dashLength,
    double? gapLength,
  }) {
    final delta = end - start;
    final distance = delta.distance;
    if (distance <= 0) return phase;
    final direction = delta / distance;
    final resolvedDashLength = dashLength ?? 10.0 * _scale;
    final resolvedGapLength = gapLength ?? 7.0 * _scale;
    final cycle = resolvedDashLength + resolvedGapLength;
    var traveled = 0.0;
    var currentPhase = phase % cycle;

    while (traveled < distance) {
      final inDash = currentPhase < resolvedDashLength;
      final remainingInPart = inDash
          ? resolvedDashLength - currentPhase
          : cycle - currentPhase;
      final step = math.min(remainingInPart, distance - traveled);
      if (inDash && step > 0) {
        canvas.drawLine(
          start + direction * traveled,
          start + direction * (traveled + step),
          paint,
        );
      }
      traveled += step;
      currentPhase = (currentPhase + step) % cycle;
    }
    return (phase + distance) % cycle;
  }

  void _paintText(Canvas canvas, Rect rect, InkText textObject) {
    final textSpan = TextSpan(
      text: textObject.text,
      style: TextStyle(
        color: textObject.color,
        fontSize: textObject.fontSize * _scale,
        fontWeight: textObject.bold ? FontWeight.bold : FontWeight.normal,
        fontStyle: textObject.italic ? FontStyle.italic : FontStyle.normal,
        height: textObject.lineHeight,
      ),
    );
    final maxWidth = math.max(48.0, textObject.width * rect.width);
    final textPainter = TextPainter(
      text: textSpan,
      textDirection: TextDirection.ltr,
      textAlign: textObject.textAlign,
    )..layout(maxWidth: maxWidth);
    final origin = Offset(
      rect.left + textObject.x * rect.width,
      rect.top + textObject.y * rect.height,
    );
    textPainter.paint(canvas, origin);

    if (textObject.isSelected) {
      final selectionRect = Rect.fromLTWH(
        origin.dx - 5,
        origin.dy - 4,
        maxWidth + 10,
        math.max(textPainter.height, textObject.fontSize * _scale) + 8,
      );
      final selectionPaint = Paint()
        ..color = Colors.blue
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5;
      canvas.drawRRect(
        RRect.fromRectAndRadius(selectionRect, const Radius.circular(5)),
        selectionPaint,
      );
    }
  }

  void _paintImage(Canvas canvas, Rect rect, InkImage imageObject) {
    final image = images[imageObject.path];
    if (image == null || imageObject.width <= 0 || imageObject.height <= 0) {
      return;
    }
    final target = Rect.fromLTWH(
      rect.left + imageObject.x * rect.width,
      rect.top + imageObject.y * rect.height,
      imageObject.width * rect.width,
      imageObject.height * rect.height,
    );
    paintImage(
      canvas: canvas,
      rect: target,
      image: image,
      fit: BoxFit.fill,
      filterQuality: FilterQuality.high,
    );
  }

  @override
  bool shouldRepaint(covariant InkPainter oldDelegate) => true;
}
