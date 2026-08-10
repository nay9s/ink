import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../models.dart';

/// Distance the pen travels, in screen pixels, per stored control point.
///
/// Writing slowly delivers 120Hz samples only a fraction of a pixel apart, so
/// each one is dominated by hand tremor and sensor noise rather than by the
/// stroke's direction. Storing them all made the renderer's spline turn
/// through every bit of that noise, which reads as a furry, jagged line.
///
/// 4px keeps enough points for the small marks Thai script is full of while
/// giving each span roughly eight samples to average — see
/// [StrokeControlPointSpacer] for why averaging rather than thinning is what
/// removes the noise.
const double kControlPointSpanPixels = 4;

/// Turns the stream of stabilized pen samples into stored control points, one
/// per [spanPixels] of travel, each the mean of the samples along that span.
///
/// Averaging is the point. Simply dropping the samples in between — keeping
/// whichever one happens to land past the threshold — leaves every stored
/// point carrying its full tremor, so the line stops being furry only to start
/// showing angular kinks instead, and pushing the spacing out far enough to
/// hide those flattens real curvature. Averaging N samples pulls the noise
/// down by sqrt(N) while leaving the point on the path the hand drew, so the
/// same number of control points comes out roughly twice as smooth.
///
/// Fast strokes are unaffected: their samples already arrive further apart
/// than a span, so each span holds one sample and the mean is that sample.
///
/// Spans are measured from the pen's real position rather than from the
/// emitted mean, which sits about half a span behind it. Measuring from the
/// mean would halve the spacing and undo the averaging.
class StrokeControlPointSpacer {
  StrokeControlPointSpacer({this.spanPixels = kControlPointSpanPixels});

  final double spanPixels;

  InkPoint? _spanStart;
  double _sumX = 0;
  double _sumY = 0;
  double _sumPressure = 0;
  int _count = 0;

  void start(InkPoint point) {
    _spanStart = point;
    _clearSpan();
  }

  void reset() {
    _spanStart = null;
    _clearSpan();
  }

  /// The control point to store for [sample], or null while the pen has not
  /// yet travelled a full span.
  InkPoint? add(InkPoint sample, Size screenSize) {
    final spanStart = _spanStart;
    if (spanStart == null) {
      start(sample);
      return null;
    }
    if (!sample.x.isFinite || !sample.y.isFinite) return null;

    _sumX += sample.x;
    _sumY += sample.y;
    _sumPressure += sample.pressure;
    _count++;

    final dx = (sample.x - spanStart.x) * screenSize.width;
    final dy = (sample.y - spanStart.y) * screenSize.height;
    final travelled = math.sqrt(dx * dx + dy * dy);
    if (!travelled.isFinite || travelled < spanPixels) return null;

    final mean = InkPoint(
      _sumX / _count,
      _sumY / _count,
      _sumPressure / _count,
    );
    _spanStart = sample;
    _clearSpan();
    return mean;
  }

  void _clearSpan() {
    _sumX = 0;
    _sumY = 0;
    _sumPressure = 0;
    _count = 0;
  }
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

  /// Smoothed pen velocity in screen pixels per millisecond.
  Offset? _velocity;

  InkPoint? get lastRawPoint => _lastRawPoint;

  bool get isActive => _position != null;

  void start(InkPoint point, {Duration? timestamp}) {
    _position = point;
    _lastRawPoint = point;
    _lastTimestamp = timestamp;
    _velocity = null;
  }

  /// How far, in screen pixels, the smoothed centerline is allowed to trail
  /// the pen once it is moving steadily.
  ///
  /// A fixed amount of smoothing cannot serve both ends of handwriting. When
  /// the pen dawdles, its samples are dominated by tremor and want heavy
  /// filtering; when it moves, the samples are already far apart and carry
  /// real shape, so the same filtering only lags behind and cuts corners.
  /// Measured against unfiltered input on a 90px glyph, the fixed filter was
  /// 1.20x, 1.58x and 2.03x *worse* than no filtering at 8, 16 and 24 px per
  /// sample — it was bending letters out of shape as soon as writing left a
  /// crawl, and at the strongest setting it was over 6x worse.
  ///
  /// Shrinking the time constant as the pen speeds up — the idea behind the
  /// 1-euro filter — fixes that end without giving up the other. Deriving the
  /// rate from this bound rather than fixing it outright is what makes it
  /// hold at *every* smoothing setting: an EMA tracking a steady speed `v`
  /// settles at a lag of `v * tau`, so scaling `tau` by `1 / (1 + v * tau/L)`
  /// makes that lag approach `L` however large `tau` started. Without it, the
  /// strongest setting still trailed far enough to bend letters.
  ///
  /// At 3px the filter never does worse than raw input at any writing speed
  /// while still removing most of the tremor when the pen is slow.
  static const double _maximumSteadyLagPixels = 3;

  /// Pen speed, in screen pixels per millisecond, below which motion is not
  /// distinguishable from tremor and smoothing stays at full strength.
  ///
  /// Backing off in proportion to speed from a standing start does not work:
  /// an ordinary hand writing at a moderate pace already registers a few
  /// tenths of a pixel per millisecond, so a law anchored at zero stood the
  /// filter down exactly where it was still needed. Holding full strength
  /// below this knee and backing off above it separates the two regimes the
  /// filter actually has to serve.
  ///
  /// Swept jointly with [_maximumSteadyLagPixels] against both requirements —
  /// attenuating a zigzag and never bending the letter — this pair is the
  /// best available compromise. Raising the knee further does attenuate a
  /// synthetic Nyquist-rate zigzag harder, but only by reintroducing the
  /// corner-cutting at ordinary writing speed that this whole change exists
  /// to remove.
  static const double _tremorSpeedPxPerMs = .5;

  /// Time constant for the velocity estimate that drives that backing-off.
  ///
  /// The speed has to be measured from a smoothed *velocity vector*, not from
  /// how far the last sample happened to land. A zigzag alternating either
  /// side of the stroke covers a lot of distance per sample while going
  /// nowhere, so raw per-sample distance reads it as fast motion and tells
  /// the filter to stand down — letting the jitter hide itself from the very
  /// filter meant to remove it. Averaged as a vector, those alternating steps
  /// cancel and only sustained travel survives.
  static const double _velocityTimeConstantMs = 30;

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
    final previousPixels = _toPixels(previous, screenSize);
    final rawPixels = _toPixels(raw, screenSize);

    // Back the smoothing off as the pen speeds up, so it only acts where
    // tremor rather than intent dominates the samples. See
    // _maximumSteadyLagPixels for why the rate is derived from a lag bound,
    // and _velocityTimeConstantMs for why this tracks a velocity vector
    // rather than raw per-sample distance.
    final speedPxPerMs = _updateVelocity(
      previousRaw == null
          ? Offset.zero
          : (rawPixels - _toPixels(previousRaw, screenSize)) / elapsedMs,
      elapsedMs,
    );
    final restingTimeConstant = 3.0 + 45.0 * math.pow(amount, 1.5);
    final deliberateSpeed = math.max(0.0, speedPxPerMs - _tremorSpeedPxPerMs);
    final timeConstantMs =
        restingTimeConstant /
        (1 + deliberateSpeed * restingTimeConstant / _maximumSteadyLagPixels);
    final follow = 1 - math.exp(-elapsedMs / timeConstantMs);
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
    _velocity = null;
  }

  /// Folds [instantaneous] into the running velocity estimate and returns its
  /// magnitude in pixels per millisecond.
  double _updateVelocity(Offset instantaneous, double elapsedMs) {
    if (!instantaneous.dx.isFinite || !instantaneous.dy.isFinite) {
      return _velocity?.distance ?? 0.0;
    }
    final previous = _velocity;
    if (previous == null) {
      _velocity = instantaneous;
    } else {
      final follow = 1 - math.exp(-elapsedMs / _velocityTimeConstantMs);
      _velocity = previous + (instantaneous - previous) * follow;
    }
    final speed = _velocity!.distance;
    return speed.isFinite && speed > 0 ? speed : 0.0;
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
