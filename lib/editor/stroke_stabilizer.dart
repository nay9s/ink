import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../models.dart';

/// Minimum spacing between captured control points, in screen pixels.
///
/// Writing slowly delivers 120Hz samples only a fraction of a pixel apart, so
/// each one is dominated by hand and sensor jitter rather than by the stroke's
/// direction. Keeping them all made the renderer's spline turn through every
/// bit of that noise, which reads as a jagged line. Spacing control points out
/// shrinks the angle each jitter can introduce: measured on a jittered slow
/// arc it removes roughly two thirds of the excess turning while leaving the
/// path itself where the hand drew it, and fast strokes are untouched because
/// their samples already land further apart than this.
const double kMinimumControlPointSpacing = 4;

/// Control points to append when the stabilized pen position moves from
/// [start] to [target].
///
/// This deliberately never subdivides the gap. Interpolated points would sit
/// exactly on the straight chord between two real samples, and the renderer's
/// spline passes through every control point — a cubic whose endpoints and
/// tangents all lie on one line *is* that line. Filling gaps therefore pins
/// the curve flat along each chord and turns handwriting into a polygon with
/// rounded corners. The painter already curves between sparse control points
/// (see createSmoothStrokePath in stroke_geometry.dart), so the correct
/// contribution here is the single real sample.
List<InkPoint> strokeCapturePointsTowards(
  InkPoint start,
  InkPoint target,
  Size size, {
  double minimumDistance = kMinimumControlPointSpacing,
}) {
  final dxPixels = (target.x - start.x) * size.width;
  final dyPixels = (target.y - start.y) * size.height;
  final distancePixels = math.sqrt(dxPixels * dxPixels + dyPixels * dyPixels);
  if (!distancePixels.isFinite || distancePixels < minimumDistance) {
    return const <InkPoint>[];
  }
  return <InkPoint>[target];
}

/// A bounded, time-based low-pass filter for live pen input.
///
/// The filter works in screen pixels so the selected strength feels the same
/// at every page size and zoom level. A maximum trailing distance keeps the
/// virtual pen close to the real Pencil, while [finish] restores the exact
/// lift-off position so stabilized strokes never end short.
class StrokeStabilizer {
  InkPoint? _position;
  InkPoint? _lastRawPoint;
  Duration? _lastTimestamp;

  InkPoint? get lastRawPoint => _lastRawPoint;

  bool get isActive => _position != null;

  void start(InkPoint point, {Duration? timestamp}) {
    _position = point;
    _lastRawPoint = point;
    _lastTimestamp = timestamp;
  }

  InkPoint filter(
    InkPoint raw,
    Size screenSize, {
    required double strength,
    Duration? timestamp,
  }) {
    final previous = _position;
    _lastRawPoint = raw;
    if (previous == null) {
      start(raw, timestamp: timestamp);
      return raw;
    }

    final amount = strength.clamp(0.0, 1.0).toDouble();
    if (amount <= 0 || !_isUsable(screenSize)) {
      _position = raw;
      _lastTimestamp = timestamp;
      return raw;
    }

    final elapsedMs = _elapsedMilliseconds(timestamp);
    _lastTimestamp = timestamp;

    // The editor renders the exact raw Pencil tip separately, so this internal
    // centerline can filter more of the sample-to-sample wobble without making
    // the visible ink feel delayed. Calculating alpha from elapsed time keeps
    // the result consistent between 60 Hz mouse and 120 Hz Pencil samples.
    final timeConstantMs = 3.0 + 45.0 * math.pow(amount, 1.5);
    final follow = 1 - math.exp(-elapsedMs / timeConstantMs);
    final previousPixels = _toPixels(previous, screenSize);
    final rawPixels = _toPixels(raw, screenSize);
    var nextPixels = previousPixels + (rawPixels - previousPixels) * follow;

    // Bound the filtered centerline like a short rubber band. The exact raw
    // endpoint remains visible at all times, while this limit prevents a fast
    // curve from being rounded so aggressively that handwriting changes shape.
    final maximumLag = 1.5 + 18.0 * math.pow(amount, 1.35);
    final lag = rawPixels - nextPixels;
    if (lag.distance > maximumLag) {
      nextPixels = rawPixels - lag / lag.distance * maximumLag;
    }

    final pressureTimeConstant = math.max(2.0, timeConstantMs * .45);
    final pressureFollow = 1 - math.exp(-elapsedMs / pressureTimeConstant);
    final pressure =
        previous.pressure + (raw.pressure - previous.pressure) * pressureFollow;
    final result = _fromPixels(nextPixels, pressure, screenSize);
    _position = result;
    return result;
  }

  /// Produces a short, monotonic tail ending at the exact lift-off sample.
  List<InkPoint> finish(InkPoint raw, Size screenSize) {
    final previous = _position;
    _lastRawPoint = raw;
    if (previous == null || !_isUsable(screenSize)) {
      reset();
      return <InkPoint>[raw];
    }

    final previousPixels = _toPixels(previous, screenSize);
    final rawPixels = _toPixels(raw, screenSize);
    final distance = (rawPixels - previousPixels).distance;
    final pressureDistance = (raw.pressure - previous.pressure).abs();
    if (distance < .15 && pressureDistance < .001) {
      reset();
      return const <InkPoint>[];
    }

    // Never use a cubic recovery tail here. Directional control handles can
    // overshoot a tight turn and make the visible endpoint hook or pull back
    // when the Pencil lifts. The renderer already joins these short samples
    // smoothly; monotonic interpolation is both stable and exact.
    final steps = (distance / 1.5).ceil().clamp(1, 8).toInt();
    final tail = <InkPoint>[];
    for (var step = 1; step <= steps; step++) {
      final t = step / steps;
      final eased = t * t * (3 - 2 * t);
      tail.add(
        InkPoint(
          previous.x + (raw.x - previous.x) * eased,
          previous.y + (raw.y - previous.y) * eased,
          previous.pressure + (raw.pressure - previous.pressure) * eased,
        ),
      );
    }
    reset();
    return tail;
  }

  void reset() {
    _position = null;
    _lastRawPoint = null;
    _lastTimestamp = null;
  }

  double _elapsedMilliseconds(Duration? timestamp) {
    final previousTimestamp = _lastTimestamp;
    if (timestamp == null || previousTimestamp == null) return 1000 / 120;
    final elapsed = (timestamp - previousTimestamp).inMicroseconds / 1000.0;
    if (!elapsed.isFinite || elapsed <= 0) return 1000 / 120;
    return elapsed.clamp(1.0, 40.0).toDouble();
  }

  bool _isUsable(Size size) =>
      size.width.isFinite &&
      size.height.isFinite &&
      size.width > 0 &&
      size.height > 0;

  Offset _toPixels(InkPoint point, Size size) =>
      Offset(point.x * size.width, point.y * size.height);

  InkPoint _fromPixels(Offset point, double pressure, Size size) => InkPoint(
    (point.dx / size.width).clamp(0.0, 1.0),
    (point.dy / size.height).clamp(0.0, 1.0),
    pressure.clamp(.03, 1.0),
  );
}
