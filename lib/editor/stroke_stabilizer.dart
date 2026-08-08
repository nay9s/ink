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

    // Keep the middle of the slider responsive: the previous linear mapping
    // made the default 45% setting feel like the ink was attached by a rubber
    // band. Squaring the setting reserves the heavier stabilization for the
    // upper end while still filtering tiny Pencil jitter at normal settings.
    final effectiveStrength = amount * amount;
    final timeConstantMs = 1.5 + 28.0 * math.pow(effectiveStrength, 1.35);
    final follow = 1 - math.exp(-elapsedMs / timeConstantMs);
    final previousPixels = _toPixels(previous, screenSize);
    final rawPixels = _toPixels(raw, screenSize);
    var nextPixels = previousPixels + (rawPixels - previousPixels) * follow;

    // Bound latency like a short rubber band. Fast strokes remain responsive
    // instead of falling farther and farther behind the Pencil.
    final maximumLag = .75 + 8.0 * math.pow(effectiveStrength, 1.15);
    final lag = rawPixels - nextPixels;
    if (lag.distance > maximumLag) {
      nextPixels = rawPixels - lag / lag.distance * maximumLag;
    }

    final pressureTimeConstant = math.max(1.5, timeConstantMs * .35);
    final pressureFollow = 1 - math.exp(-elapsedMs / pressureTimeConstant);
    final pressure =
        previous.pressure + (raw.pressure - previous.pressure) * pressureFollow;
    final result = _fromPixels(nextPixels, pressure, screenSize);
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
    final distance = (rawPixels - previousPixels).distance;
    final pressureDistance = (raw.pressure - previous.pressure).abs();
    if (distance < .15 && pressureDistance < .001) {
      reset();
      return const <InkPoint>[];
    }

    // The lag is deliberately capped to only a few screen pixels, so a short
    // interpolation is both smoother and safer than a cubic tail. The former
    // cubic could overshoot when Pencil direction changed just before lift-off
    // and leave a visible hook or zig-zag at the end of a stroke.
    final steps = (distance / 1.5).ceil().clamp(1, 6).toInt();
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
