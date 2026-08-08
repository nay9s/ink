import 'dart:math' as math;
import 'dart:ui';

/// A position and pressure sample used while constructing a rendered stroke.
class StrokeGeometrySample {
  const StrokeGeometrySample(this.offset, this.pressure);

  final Offset offset;
  final double pressure;

  StrokeGeometrySample interpolate(StrokeGeometrySample other, double t) =>
      StrokeGeometrySample(
        Offset.lerp(offset, other.offset, t)!,
        pressure + (other.pressure - pressure) * t,
      );
}

/// Keeps live Pencil samples in their authored positions while removing only
/// invalid values and near-duplicates.
///
/// Unlike [prepareStrokeSamples], this operation is causal: appending a new
/// point never moves an older point. That prevents the visible part of an
/// active stroke from wobbling behind the Pencil while more samples arrive.
List<StrokeGeometrySample> prepareLiveStrokeSamples(
  Iterable<StrokeGeometrySample> input, {
  double minimumDistance = .05,
}) {
  final resolvedMinimum = minimumDistance.isFinite
      ? math.max(0.0, minimumDistance)
      : .05;
  final minimumDistanceSquared = resolvedMinimum * resolvedMinimum;
  final output = <StrokeGeometrySample>[];
  for (final sample in input) {
    if (!sample.offset.dx.isFinite ||
        !sample.offset.dy.isFinite ||
        !sample.pressure.isFinite) {
      continue;
    }
    if (output.isEmpty ||
        (sample.offset - output.last.offset).distanceSquared >=
            minimumDistanceSquared) {
      output.add(sample);
    }
  }
  return output;
}

/// Normalizes sample spacing and removes high-frequency Pencil jitter.
///
/// The filter is symmetric, so unlike live stabilization it adds no visible
/// tip lag. Long curves receive the full smoothing amount, while deliberate
/// corners retain more of their original position.
List<StrokeGeometrySample> prepareStrokeSamples(
  Iterable<StrokeGeometrySample> input, {
  required double sampleSpacing,
  int smoothingPasses = 5,
}) {
  final spacing = sampleSpacing.isFinite && sampleSpacing > 0
      ? sampleSpacing
      : 1.0;
  final minimumDistanceSquared = math.pow(spacing * .025, 2).toDouble();
  final source = <StrokeGeometrySample>[];
  for (final sample in input) {
    if (!sample.offset.dx.isFinite ||
        !sample.offset.dy.isFinite ||
        !sample.pressure.isFinite) {
      continue;
    }
    if (source.isEmpty ||
        (sample.offset - source.last.offset).distanceSquared >=
            minimumDistanceSquared) {
      source.add(sample);
    }
  }
  if (source.length < 3) return source;

  // Very short sample lists already act as spline control points. Expanding a
  // three-point curve into a polyline first would preserve its corner instead
  // of allowing the cubic spline below to round it naturally.
  if (source.length < 5) return source;
  var filtered = _resampleByArcLength(source, spacing);
  if (filtered.length < 3) return filtered;

  for (var pass = 0; pass < smoothingPasses; pass++) {
    final next = <StrokeGeometrySample>[filtered.first];
    for (var index = 1; index < filtered.length - 1; index++) {
      final p0 = filtered[math.max(0, index - 2)];
      final p1 = filtered[index - 1];
      final current = filtered[index];
      final p3 = filtered[index + 1];
      final p4 = filtered[math.min(filtered.length - 1, index + 2)];
      final weightedOffset = Offset(
        (p0.offset.dx +
                p1.offset.dx * 4 +
                current.offset.dx * 6 +
                p3.offset.dx * 4 +
                p4.offset.dx) /
            16,
        (p0.offset.dy +
                p1.offset.dy * 4 +
                current.offset.dy * 6 +
                p3.offset.dy * 4 +
                p4.offset.dy) /
            16,
      );
      final cornerBlend = _cornerSmoothingBlend(filtered, index);
      final smoothedOffset = Offset.lerp(
        current.offset,
        weightedOffset,
        cornerBlend,
      )!;
      final smoothedPressure =
          (p0.pressure +
              p1.pressure * 4 +
              current.pressure * 6 +
              p3.pressure * 4 +
              p4.pressure) /
          16;
      next.add(
        StrokeGeometrySample(
          smoothedOffset,
          current.pressure + (smoothedPressure - current.pressure) * .85,
        ),
      );
    }
    next.add(filtered.last);
    filtered = next;
  }
  return filtered;
}

/// Samples the same cubic spline used by [createSmoothStrokePath].
///
/// Variable-width outlines, dashed strokes, and PDF export need explicit
/// points rather than a [Path]. Keeping them on the same spline prevents those
/// tools from developing a different, more angular centerline.
List<StrokeGeometrySample> sampleSmoothStrokeCurve(
  List<StrokeGeometrySample> points, {
  required double maximumSegmentLength,
}) {
  if (points.length < 2) return List<StrokeGeometrySample>.of(points);
  final segmentLength =
      maximumSegmentLength.isFinite && maximumSegmentLength > 0
      ? maximumSegmentLength
      : 1.0;
  final output = <StrokeGeometrySample>[points.first];
  final offsets = points.map((sample) => sample.offset).toList(growable: false);

  for (var index = 0; index < points.length - 1; index++) {
    final handles = _curveHandles(offsets, index);
    final start = points[index];
    final end = points[index + 1];
    final controlLength =
        (handles.$1 - start.offset).distance +
        (handles.$2 - handles.$1).distance +
        (end.offset - handles.$2).distance;
    final steps = (controlLength / segmentLength).ceil().clamp(1, 96).toInt();
    final pressureControls = _pressureHandles(points, index);

    for (var step = 1; step <= steps; step++) {
      final t = step / steps;
      output.add(
        StrokeGeometrySample(
          _cubicOffset(start.offset, handles.$1, handles.$2, end.offset, t),
          _cubicValue(
            start.pressure,
            pressureControls.$1,
            pressureControls.$2,
            end.pressure,
            t,
          ).clamp(.03, 1.0),
        ),
      );
    }
  }
  return output;
}

Path createSmoothStrokePath(List<Offset> points) {
  final path = Path();
  appendSmoothStrokePath(path, points, moveToFirst: true);
  return path;
}

/// Builds a low-cost path for a stroke that is still receiving Pencil input.
///
/// Midpoint quadratics only revise the newest segment when a point is added;
/// the already-painted prefix stays stable instead of being globally
/// resampled on every frame.
Path createIncrementalStrokePath(List<Offset> points) {
  final path = Path();
  if (points.isEmpty) return path;
  path.moveTo(points.first.dx, points.first.dy);
  if (points.length == 1) return path;
  if (points.length == 2) {
    path.lineTo(points.last.dx, points.last.dy);
    return path;
  }
  for (var index = 1; index < points.length - 1; index++) {
    final current = points[index];
    final next = points[index + 1];
    final midpoint = (current + next) / 2;
    path.quadraticBezierTo(current.dx, current.dy, midpoint.dx, midpoint.dy);
  }
  final last = points.last;
  path.quadraticBezierTo(last.dx, last.dy, last.dx, last.dy);
  return path;
}

/// Appends a centripetal Catmull-Rom curve converted to cubic Beziers.
///
/// Its tangent is shared at every join, which avoids the subtle curvature
/// steps visible in a chain of midpoint quadratics when the page is enlarged.
void appendSmoothStrokePath(
  Path path,
  List<Offset> points, {
  required bool moveToFirst,
}) {
  if (points.isEmpty) return;
  if (moveToFirst) {
    path.moveTo(points.first.dx, points.first.dy);
  } else {
    path.lineTo(points.first.dx, points.first.dy);
  }
  if (points.length == 1) return;
  if (points.length == 2) {
    path.lineTo(points.last.dx, points.last.dy);
    return;
  }

  for (var index = 0; index < points.length - 1; index++) {
    final controls = _curveHandles(points, index);
    final end = points[index + 1];
    path.cubicTo(
      controls.$1.dx,
      controls.$1.dy,
      controls.$2.dx,
      controls.$2.dy,
      end.dx,
      end.dy,
    );
  }
}

List<StrokeGeometrySample> _resampleByArcLength(
  List<StrokeGeometrySample> source,
  double spacing,
) {
  final output = <StrokeGeometrySample>[source.first];
  var distanceUntilNext = spacing;

  for (var index = 1; index < source.length; index++) {
    var segmentStart = source[index - 1];
    final segmentEnd = source[index];
    var segmentDistance = (segmentEnd.offset - segmentStart.offset).distance;
    if (segmentDistance <= 1e-6) continue;

    while (segmentDistance + 1e-9 >= distanceUntilNext) {
      final t = (distanceUntilNext / segmentDistance).clamp(0.0, 1.0);
      final sample = segmentStart.interpolate(segmentEnd, t);
      output.add(sample);
      segmentStart = sample;
      segmentDistance = (segmentEnd.offset - segmentStart.offset).distance;
      distanceUntilNext = spacing;
      if (segmentDistance <= 1e-6) break;
    }
    distanceUntilNext -= segmentDistance;
    if (distanceUntilNext <= 1e-6) distanceUntilNext = spacing;
  }

  final last = source.last;
  final finalDistance = (last.offset - output.last.offset).distance;
  if (finalDistance <= spacing * .25) {
    output[output.length - 1] = last;
  } else {
    output.add(last);
  }
  return output;
}

double _cornerSmoothingBlend(List<StrokeGeometrySample> points, int index) {
  // Look far enough past sample-to-sample Pencil jitter to distinguish it
  // from an intentional corner. A short window mistakes an alternating wobble
  // for a series of tiny corners and prevents the low-pass filter doing its
  // job.
  final before = points[math.max(0, index - 10)].offset;
  final current = points[index].offset;
  final after = points[math.min(points.length - 1, index + 10)].offset;
  final incoming = current - before;
  final outgoing = after - current;
  if (incoming.distanceSquared <= 1e-8 || outgoing.distanceSquared <= 1e-8) {
    return 1;
  }
  final cosine =
      (incoming.dx * outgoing.dx + incoming.dy * outgoing.dy) /
      (incoming.distance * outgoing.distance);
  final angle = math.acos(cosine.clamp(-1.0, 1.0));
  const fullSmoothingAngle = math.pi / 9; // 20 degrees.
  const cornerAngle = math.pi * 4 / 9; // 80 degrees.
  if (angle <= fullSmoothingAngle) return 1;
  if (angle >= cornerAngle) return .18;
  final t = (angle - fullSmoothingAngle) / (cornerAngle - fullSmoothingAngle);
  return 1 - t * .82;
}

(Offset, Offset) _curveHandles(List<Offset> points, int index) {
  final p1 = points[index];
  final p2 = points[index + 1];
  final p0 = index > 0 ? points[index - 1] : p1 * 2 - p2;
  final p3 = index + 2 < points.length ? points[index + 2] : p2 * 2 - p1;
  final chord = (p2 - p1).distance;
  if (chord <= 1e-6) return (p1, p2);

  // Alpha 0.5 is the centripetal form. It follows uneven Pencil samples
  // without the loops and overshoot of a uniform Catmull-Rom spline.
  final dt01 = math.sqrt(math.max((p1 - p0).distance, 1e-6));
  final dt12 = math.sqrt(math.max((p2 - p1).distance, 1e-6));
  final dt23 = math.sqrt(math.max((p3 - p2).distance, 1e-6));
  final tangent1 =
      ((p1 - p0) / dt01 - (p2 - p0) / (dt01 + dt12) + (p2 - p1) / dt12) * dt12;
  final tangent2 =
      ((p2 - p1) / dt12 - (p3 - p1) / (dt12 + dt23) + (p3 - p2) / dt23) * dt12;
  final maximumHandle = chord * .65;
  final first = _limitedHandle(p1, p1 + tangent1 / 3, maximumHandle);
  final second = _limitedHandle(p2, p2 - tangent2 / 3, maximumHandle);
  return (first, second);
}

(double, double) _pressureHandles(
  List<StrokeGeometrySample> points,
  int index,
) {
  final p1 = points[index].pressure;
  final p2 = points[index + 1].pressure;
  final p0 = index > 0 ? points[index - 1].pressure : p1 * 2 - p2;
  final p3 = index + 2 < points.length
      ? points[index + 2].pressure
      : p2 * 2 - p1;
  final minimum = math.min(p1, p2);
  final maximum = math.max(p1, p2);
  return (
    (p1 + (p2 - p0) / 6).clamp(minimum, maximum),
    (p2 - (p3 - p1) / 6).clamp(minimum, maximum),
  );
}

Offset _limitedHandle(Offset origin, Offset handle, double maximumLength) {
  final delta = handle - origin;
  if (delta.distance <= maximumLength || delta.distance <= 1e-9) return handle;
  return origin + delta / delta.distance * maximumLength;
}

Offset _cubicOffset(Offset p0, Offset p1, Offset p2, Offset p3, double t) =>
    Offset(
      _cubicValue(p0.dx, p1.dx, p2.dx, p3.dx, t),
      _cubicValue(p0.dy, p1.dy, p2.dy, p3.dy, t),
    );

double _cubicValue(double p0, double p1, double p2, double p3, double t) {
  final inverse = 1 - t;
  return inverse * inverse * inverse * p0 +
      3 * inverse * inverse * t * p1 +
      3 * inverse * t * t * p2 +
      t * t * t * p3;
}
