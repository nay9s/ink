import 'dart:math' as math;
import 'dart:ui';

import '../models.dart';

/// A shape a freehand stroke was recognised as, with the two points the
/// snapped stroke should keep: the endpoints for [InkShapeKind.line], or
/// opposite corners of the bounding box for the closed shapes.
class RecognizedShape {
  const RecognizedShape({
    required this.kind,
    required this.start,
    required this.end,
  });

  final InkShapeKind kind;
  final InkPoint start;
  final InkPoint end;
}

/// Recognises a line, rectangle or ellipse in freehand [points], or returns
/// null when nothing fits well enough.
///
/// Returning null matters: hold-to-snap fires whenever the pen pauses, so an
/// ordinary pause mid-word must leave the handwriting untouched rather than
/// mangle it into the nearest shape.
///
/// [points] are in normalized page space (0..1 on both axes), so distances
/// are compared against the stroke's own size rather than absolute units and
/// recognition behaves the same at any page size or zoom.
RecognizedShape? recognizeShape(List<InkPoint> points) {
  final samples = <Offset>[];
  for (final point in points) {
    if (!point.x.isFinite || !point.y.isFinite) continue;
    final offset = Offset(point.x, point.y);
    if (samples.isEmpty || (offset - samples.last).distance > 1e-6) {
      samples.add(offset);
    }
  }
  if (samples.length < 8) return null;

  var pathLength = 0.0;
  for (var index = 1; index < samples.length; index++) {
    pathLength += (samples[index] - samples[index - 1]).distance;
  }
  // Too small to be a deliberate shape; also guards the ratios below.
  if (pathLength < .04) return null;

  var bounds = Rect.fromPoints(samples.first, samples.first);
  for (final sample in samples) {
    bounds = bounds.expandToInclude(Rect.fromPoints(sample, sample));
  }
  final diagonal = bounds.bottomRight - bounds.topLeft;
  if (diagonal.distance < .03) return null;

  // Closed means the stroke came back to where it started, so the gap is
  // judged against the shape's own size. Comparing it to path length instead
  // would call any long wandering scribble closed.
  final closingGap = (samples.last - samples.first).distance;
  final isClosed = closingGap < diagonal.distance * .25;

  if (!isClosed) {
    final straightness = _maxDistanceFromChord(samples);
    final chord = (samples.last - samples.first).distance;
    if (chord > .03 && straightness < chord * .09) {
      return RecognizedShape(
        kind: InkShapeKind.line,
        start: _asPoint(samples.first, points.first),
        end: _asPoint(samples.last, points.last),
      );
    }
    return null;
  }

  // A closed stroke has to hug either the bounding box or the inscribed
  // ellipse. Whichever it tracks more closely wins, and if it tracks neither
  // (a loop, a scribble) it stays freehand.
  final rectangleError = _averageError(samples, _distanceToRectangle, bounds);
  final ellipseError = _averageError(samples, _distanceToEllipse, bounds);
  final tolerance = diagonal.distance * .085;
  if (rectangleError > tolerance && ellipseError > tolerance) return null;

  final kind = rectangleError <= ellipseError
      ? InkShapeKind.rectangle
      : InkShapeKind.ellipse;
  final pressure = points.first.pressure;
  return RecognizedShape(
    kind: kind,
    start: InkPoint(bounds.left, bounds.top, pressure),
    end: InkPoint(bounds.right, bounds.bottom, pressure),
  );
}

InkPoint _asPoint(Offset offset, InkPoint source) =>
    InkPoint(offset.dx, offset.dy, source.pressure);

double _maxDistanceFromChord(List<Offset> samples) {
  final start = samples.first;
  final end = samples.last;
  final chord = end - start;
  final length = chord.distance;
  if (length <= 1e-9) return double.infinity;
  var worst = 0.0;
  for (final sample in samples) {
    final delta = sample - start;
    final distance =
        (delta.dx * chord.dy - delta.dy * chord.dx).abs() / length;
    if (distance > worst) worst = distance;
  }
  return worst;
}

double _averageError(
  List<Offset> samples,
  double Function(Offset sample, Rect bounds) distance,
  Rect bounds,
) {
  var total = 0.0;
  for (final sample in samples) {
    total += distance(sample, bounds);
  }
  return total / samples.length;
}

/// Distance from a point to the bounding box outline (not its interior).
double _distanceToRectangle(Offset sample, Rect bounds) {
  final left = (sample.dx - bounds.left).abs();
  final right = (sample.dx - bounds.right).abs();
  final top = (sample.dy - bounds.top).abs();
  final bottom = (sample.dy - bounds.bottom).abs();
  final horizontal = math.min(left, right);
  final vertical = math.min(top, bottom);
  final insideHorizontally =
      sample.dx >= bounds.left && sample.dx <= bounds.right;
  final insideVertically = sample.dy >= bounds.top && sample.dy <= bounds.bottom;
  if (insideHorizontally && insideVertically) {
    // Inside the box: the nearest edge is whichever side is closest.
    return math.min(horizontal, vertical);
  }
  if (insideHorizontally) return vertical;
  if (insideVertically) return horizontal;
  return math.sqrt(horizontal * horizontal + vertical * vertical);
}

/// Approximate distance from a point to the ellipse inscribed in [bounds],
/// using the radial deviation, which is accurate enough to rank a hand-drawn
/// ellipse against a rectangle.
double _distanceToEllipse(Offset sample, Rect bounds) {
  final radiusX = bounds.width / 2;
  final radiusY = bounds.height / 2;
  if (radiusX <= 1e-9 || radiusY <= 1e-9) return double.infinity;
  final normalizedX = (sample.dx - bounds.center.dx) / radiusX;
  final normalizedY = (sample.dy - bounds.center.dy) / radiusY;
  final radius = math.sqrt(normalizedX * normalizedX + normalizedY * normalizedY);
  if (radius <= 1e-9) return math.min(radiusX, radiusY);
  // Scale the sample onto the ellipse along its own ray and measure the gap.
  final onEllipse = Offset(
    bounds.center.dx + normalizedX / radius * radiusX,
    bounds.center.dy + normalizedY / radius * radiusY,
  );
  return (sample - onEllipse).distance;
}
