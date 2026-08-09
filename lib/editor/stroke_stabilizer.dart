import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../models.dart';

/// A bounded, time-based low-pass filter for live pen input.
///
/// The filter works in screen pixels so the selected strength feels the same
/// at every page size and zoom level. A maximum trailing distance keeps the
/// virtual pen close to the real Pencil, while [finish] restores the exact
/// lift-off position so stabilized strokes never end short.
class StrokeStabilizer {
  InkPoint? _position;
  InkPoint? _previousPosition;
  InkPoint? _lastRawPoint;
  InkPoint? _previousRawPoint;
  Duration? _lastTimestamp;

  InkPoint? get lastRawPoint => _lastRawPoint;

  bool get isActive => _position != null;

  void start(InkPoint point, {Duration? timestamp}) {
    _position = point;
    _previousPosition = null;
    _lastRawPoint = point;
    _previousRawPoint = null;
    _lastTimestamp = timestamp;
  }

  InkPoint filter(
    InkPoint raw,
    Size screenSize, {
    required double strength,
    Duration? timestamp,
  }) {
    final previous = _position;
    final previousRaw = _lastRawPoint;
    _lastRawPoint = raw;
    if (previous == null) {
      start(raw, timestamp: timestamp);
      return raw;
    }

    final amount = strength.clamp(0.0, 1.0).toDouble();
    if (amount <= 0 || !_isUsable(screenSize)) {
      _previousPosition = previous;
      _previousRawPoint = previousRaw;
      _position = raw;
      _lastTimestamp = timestamp;
      return raw;
    }

    final elapsedMs = _elapsedMilliseconds(timestamp);
    _lastTimestamp = timestamp;

    // Keep the live tip responsive. The earlier range allowed the virtual pen
    // to trail far enough behind a curved Pencil movement that the visible
    // stroke appeared to pull inward while it was still being written.
    // Calculating alpha from elapsed time keeps the feel consistent between
    // 60 Hz mouse and 120 Hz Pencil samples.
    final timeConstantMs = 2.0 + 24.0 * math.pow(amount, 1.5);
    final follow = 1 - math.exp(-elapsedMs / timeConstantMs);
    final previousPixels = _toPixels(previous, screenSize);
    final rawPixels = _toPixels(raw, screenSize);
    var nextPixels = previousPixels + (rawPixels - previousPixels) * follow;

    // Bound latency like a short rubber band. Fast strokes remain responsive
    // instead of falling farther and farther behind the Pencil.
    final maximumLag = 1.0 + 10.0 * math.pow(amount, 1.35);
    final lag = rawPixels - nextPixels;
    if (lag.distance > maximumLag) {
      nextPixels = rawPixels - lag / lag.distance * maximumLag;
    }

    final pressureTimeConstant = math.max(2.0, timeConstantMs * .45);
    final pressureFollow = 1 - math.exp(-elapsedMs / pressureTimeConstant);
    final pressure =
        previous.pressure + (raw.pressure - previous.pressure) * pressureFollow;
    final result = _fromPixels(nextPixels, pressure, screenSize);
    _previousPosition = previous;
    _previousRawPoint = previousRaw;
    _position = result;
    return result;
  }

  /// Produces a short, smooth tail ending at the exact lift-off sample.
  List<InkPoint> finish(InkPoint raw, Size screenSize) {
    final previous = _position;
    _lastRawPoint = raw;
    if (previous == null || !_isUsable(screenSize)) {
      reset();
      return <InkPoint>[raw];
    }

    final previousPixels = _toPixels(previous, screenSize);
    final rawPixels = _toPixels(raw, screenSize);
    final chord = rawPixels - previousPixels;
    final distance = chord.distance;
    final pressureDistance = (raw.pressure - previous.pressure).abs();
    if (distance < .15 && pressureDistance < .001) {
      reset();
      return const <InkPoint>[];
    }

    // Continue along the recent stabilized and raw Pencil directions before
    // arriving at lift-off. A direct interpolation to [raw] creates a visible
    // elbow whenever the filter trails a curved stroke.
    final previousPositionPixels = _previousPosition == null
        ? previousPixels
        : _toPixels(_previousPosition!, screenSize);
    final previousRawPixels = _previousRawPoint == null
        ? rawPixels
        : _toPixels(_previousRawPoint!, screenSize);
    final startMotion = previousPixels - previousPositionPixels;
    final endMotion = rawPixels - previousRawPixels;
    final startDirection = _forwardDirection(startMotion, chord);
    final endDirection = _forwardDirection(endMotion, chord);
    final startHandleLength = math.min(
      distance * .48,
      math.max(distance * .2, startMotion.distance * 1.8),
    );
    final endHandleLength = math.min(
      distance * .4,
      math.max(distance * .14, endMotion.distance * 1.15),
    );
    final control1 = previousPixels + startDirection * startHandleLength;
    final control2 = rawPixels - endDirection * endHandleLength;
    final estimatedLength =
        (control1 - previousPixels).distance +
        (control2 - control1).distance +
        (rawPixels - control2).distance;
    final steps = (estimatedLength / 2.5).ceil().clamp(1, 12).toInt();
    final tail = <InkPoint>[];
    for (var step = 1; step <= steps; step++) {
      final t = step / steps;
      final eased = t * t * (3 - 2 * t);
      final point = _cubicPoint(
        previousPixels,
        control1,
        control2,
        rawPixels,
        t,
      );
      tail.add(
        _fromPixels(
          point,
          previous.pressure + (raw.pressure - previous.pressure) * eased,
          screenSize,
        ),
      );
    }
    reset();
    return tail;
  }

  void reset() {
    _position = null;
    _previousPosition = null;
    _lastRawPoint = null;
    _previousRawPoint = null;
    _lastTimestamp = null;
  }

  Offset _forwardDirection(Offset motion, Offset chord) {
    if (chord.distanceSquared <= 1e-8) return const Offset(1, 0);
    final chordDirection = chord / chord.distance;
    if (motion.distanceSquared <= 1e-8) return chordDirection;
    final motionDirection = motion / motion.distance;
    final alignment =
        motionDirection.dx * chordDirection.dx +
        motionDirection.dy * chordDirection.dy;
    return alignment < -.1 ? chordDirection : motionDirection;
  }

  Offset _cubicPoint(Offset p0, Offset p1, Offset p2, Offset p3, double t) {
    final inverse = 1 - t;
    return p0 * (inverse * inverse * inverse) +
        p1 * (3 * inverse * inverse * t) +
        p2 * (3 * inverse * t * t) +
        p3 * (t * t * t);
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
