import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ink_note/editor/stroke_geometry.dart';
import 'package:ink_note/editor/stroke_stabilizer.dart';
import 'package:ink_note/models.dart';

void main() {
  const canvas = Size(500, 500);

  test('zero strength follows raw input exactly', () {
    final stabilizer = StrokeStabilizer()
      ..start(const InkPoint(.1, .2, .4), timestamp: Duration.zero);
    const raw = InkPoint(.7, .65, .9);

    final result = stabilizer.filter(
      raw,
      canvas,
      strength: 0,
      timestamp: const Duration(milliseconds: 8),
    );

    expect(result.x, raw.x);
    expect(result.y, raw.y);
    expect(result.pressure, raw.pressure);
  });

  test('strong stabilization reduces cross-axis hand jitter', () {
    final stabilizer = StrokeStabilizer()
      ..start(const InkPoint(.1, .5, .5), timestamp: Duration.zero);
    final rawOffsets = <double>[];
    final stabilizedOffsets = <double>[];

    for (var index = 1; index <= 40; index++) {
      final offset = index.isEven ? 5.0 : -5.0;
      final raw = InkPoint(.1 + index * .012, .5 + offset / canvas.height, .5);
      final result = stabilizer.filter(
        raw,
        canvas,
        strength: .9,
        timestamp: Duration(microseconds: index * 8333),
      );
      if (index > 8) {
        rawOffsets.add(offset.abs());
        stabilizedOffsets.add(((result.y - .5) * canvas.height).abs());
      }
    }

    final rawAverage = rawOffsets.reduce((a, b) => a + b) / rawOffsets.length;
    final stabilizedAverage =
        stabilizedOffsets.reduce((a, b) => a + b) / stabilizedOffsets.length;
    expect(stabilizedAverage, lessThan(rawAverage * .5));
  });

  /// This input is deliberately extreme: +/-5px reversing on *every* sample
  /// is a Nyquist-rate oscillation an order of magnitude larger than real
  /// Pencil noise. It used to be held to 35% of its amplitude, which the
  /// filter could only manage by smoothing just as hard at ordinary writing
  /// speed — where that same smoothing was measurably bending letters out of
  /// shape (see stabilizer_speed_test.dart). Speed-adaptive smoothing trades
  /// some attenuation of this synthetic case for shape accuracy across every
  /// real writing speed; it must still clearly attenuate it.
  test('default stabilization attenuates visible sample zigzags', () {
    final stabilizer = StrokeStabilizer()
      ..start(const InkPoint(.1, .5, .5), timestamp: Duration.zero);
    final rawOffsets = <double>[];
    final stabilizedOffsets = <double>[];

    for (var index = 1; index <= 40; index++) {
      final offset = index.isEven ? 5.0 : -5.0;
      final raw = InkPoint(.1 + index * .012, .5 + offset / canvas.height, .5);
      final result = stabilizer.filter(
        raw,
        canvas,
        strength: .45,
        timestamp: Duration(microseconds: index * 8333),
      );
      if (index > 8) {
        rawOffsets.add(offset.abs());
        stabilizedOffsets.add(((result.y - .5) * canvas.height).abs());
      }
    }

    final rawAverage = rawOffsets.reduce((a, b) => a + b) / rawOffsets.length;
    final stabilizedAverage =
        stabilizedOffsets.reduce((a, b) => a + b) / stabilizedOffsets.length;
    expect(stabilizedAverage, lessThan(rawAverage * .55));
  });

  test('maximum strength keeps the filtered centerline bounded', () {
    final stabilizer = StrokeStabilizer()
      ..start(const InkPoint(0, .5, .5), timestamp: Duration.zero);
    const raw = InkPoint(.2, .5, .5);

    final result = stabilizer.filter(
      raw,
      canvas,
      strength: 1,
      timestamp: const Duration(milliseconds: 8),
    );
    final lagPixels = (raw.x - result.x) * canvas.width;

    expect(lagPixels, lessThanOrEqualTo(19.6));
    expect(result.x, lessThan(raw.x));
  });

  test('default centerline stays bounded and never retracts', () {
    final stabilizer = StrokeStabilizer()
      ..start(const InkPoint(.1, .5, .5), timestamp: Duration.zero);
    var previousX = .1;

    for (var index = 1; index <= 24; index++) {
      final raw = InkPoint(.1 + index * .01, .5, .5);
      final result = stabilizer.filter(
        raw,
        canvas,
        strength: .45,
        timestamp: Duration(microseconds: index * 8333),
      );
      final lagPixels = (raw.x - result.x) * canvas.width;

      expect(lagPixels, lessThanOrEqualTo(7.7));
      expect(result.x, greaterThanOrEqualTo(previousX));
      previousX = result.x;
    }
  });

  test('finishing a stroke restores the exact lift-off point', () {
    final stabilizer = StrokeStabilizer()
      ..start(const InkPoint(.1, .5, .4), timestamp: Duration.zero);
    stabilizer.filter(
      const InkPoint(.3, .52, .7),
      canvas,
      strength: 1,
      timestamp: const Duration(milliseconds: 8),
    );
    const liftOff = InkPoint(.34, .51, .8);

    final tail = stabilizer.finish(liftOff, canvas);

    expect(tail, isNotEmpty);
    expect(tail.last.x, liftOff.x);
    expect(tail.last.y, liftOff.y);
    expect(tail.last.pressure, liftOff.pressure);
    expect(stabilizer.isActive, isFalse);
    expect(stabilizer.lastRawPoint, isNull);
  });

  test('finishing a stroke advances monotonically without overshoot', () {
    final stabilizer = StrokeStabilizer()
      ..start(const InkPoint(.1, .5, .5), timestamp: Duration.zero);
    stabilizer.filter(
      const InkPoint(.2, .5, .5),
      canvas,
      strength: 1,
      timestamp: const Duration(milliseconds: 8),
    );
    final current = stabilizer.filter(
      const InkPoint(.3, .52, .5),
      canvas,
      strength: 1,
      timestamp: const Duration(milliseconds: 16),
    );
    const liftOff = InkPoint(.3, .68, .5);
    final tail = stabilizer.finish(liftOff, canvas);
    final chord = Offset(
      (liftOff.x - current.x) * canvas.width,
      (liftOff.y - current.y) * canvas.height,
    );
    var previousProgress = 0.0;

    expect(tail, isNotEmpty);
    for (final sample in tail) {
      final delta = Offset(
        (sample.x - current.x) * canvas.width,
        (sample.y - current.y) * canvas.height,
      );
      final progress =
          (delta.dx * chord.dx + delta.dy * chord.dy) / chord.distanceSquared;
      final perpendicularDistance =
          (delta.dx * chord.dy - delta.dy * chord.dx).abs() / chord.distance;

      expect(progress, greaterThanOrEqualTo(previousProgress - 1e-9));
      expect(progress, inInclusiveRange(0.0, 1.0));
      expect(perpendicularDistance, lessThan(1e-6));
      previousProgress = progress;
    }
    expect(tail.last.x, liftOff.x);
    expect(tail.last.y, liftOff.y);
  });

  group('capture keeps curves smooth', () {
    test('a far sample contributes exactly one control point, itself', () {
      const start = InkPoint(.2, .2, .5);
      const target = InkPoint(.6, .5, .7);
      final spacer = StrokeControlPointSpacer()..start(start);

      final appended = spacer.add(target, canvas);

      // A single sample past the span is its own mean, so a fast stroke —
      // whose samples already land a span apart — is captured unchanged.
      // Subdividing instead would place collinear points on the chord, which
      // the renderer's spline then follows as a straight line.
      expect(appended, isNotNull);
      expect(appended!.x, target.x);
      expect(appended.y, target.y);
    });

    test('a sub-pixel move contributes nothing yet', () {
      const start = InkPoint(.5, .5, .5);
      const target = InkPoint(.5001, .5001, .5);
      final spacer = StrokeControlPointSpacer()..start(start);

      expect(spacer.add(target, canvas), isNull);
    });

    test('samples within a span are averaged, not thinned', () {
      const start = InkPoint(.5, .5, .5);
      final spacer = StrokeControlPointSpacer(spanPixels: 4)..start(start);

      // Four samples marching right, alternating a pixel above and below the
      // true path. Thinning would keep the last one and its full error; the
      // mean sits on the path instead.
      InkPoint? emitted;
      for (var i = 1; i <= 4; i++) {
        final wobble = i.isEven ? 1.0 : -1.0;
        emitted ??= spacer.add(
          InkPoint(
            .5 + i / canvas.width,
            .5 + wobble / canvas.height,
            .5,
          ),
          canvas,
        );
      }

      expect(emitted, isNotNull);
      // Mean of -1, +1, -1, +1 is 0: the wobble cancels.
      expect(emitted!.y * canvas.height, closeTo(.5 * canvas.height, .001));
    });

    test('a new stroke does not inherit the previous span', () {
      final spacer = StrokeControlPointSpacer(spanPixels: 4)
        ..start(const InkPoint(.1, .1, .5));
      spacer.add(const InkPoint(.1, .105, .5), canvas);

      spacer.start(const InkPoint(.8, .8, .5));
      final emitted = spacer.add(
        InkPoint(.8 + 5 / canvas.width, .8, .5),
        canvas,
      );

      // Averaging in the abandoned stroke's samples would drag this far left.
      expect(emitted, isNotNull);
      expect(emitted!.x, closeTo(.8 + 5 / canvas.width, .0001));
    });

    test('captured circle renders as a curve, not a polygon', () {
      // Chords this long are what a quickly drawn circle produces; before
      // capture stopped subdividing, the rendered centerline matched a pure
      // polygon's deviation (~1.6px here) instead of following the arc.
      const center = Offset(250, 250);
      const radius = 70.0;
      const chord = 30.0;
      final steps = (2 * math.pi * radius / chord).round();

      InkPoint pointAt(int index) {
        final angle = index / steps * 2 * math.pi;
        return InkPoint(
          (center.dx + math.cos(angle) * radius) / canvas.width,
          (center.dy + math.sin(angle) * radius) / canvas.height,
          .5,
        );
      }

      final spacer = StrokeControlPointSpacer()..start(pointAt(0));
      final captured = <InkPoint>[pointAt(0)];
      for (var index = 1; index <= steps; index++) {
        final point = spacer.add(pointAt(index), canvas);
        if (point != null) captured.add(point);
      }

      // Same pipeline the painter uses for a geometry-version 2 stroke.
      final controlPoints = prepareStableStrokeSamples(
        captured.map(
          (point) => StrokeGeometrySample(
            Offset(point.x * canvas.width, point.y * canvas.height),
            point.pressure,
          ),
        ),
        minimumDistance: .05 * canvas.width / 1000,
      );
      final rendered = sampleSmoothStrokeCurve(
        controlPoints,
        maximumSegmentLength: .4,
      );

      // Ignore the ends, where tangents are extrapolated rather than known.
      final skip = (rendered.length * .1).round();
      var worstDeviation = 0.0;
      for (var index = skip; index < rendered.length - skip; index++) {
        final deviation =
            ((rendered[index].offset - center).distance - radius).abs();
        if (deviation > worstDeviation) worstDeviation = deviation;
      }

      final polygonSagitta =
          radius - math.sqrt(radius * radius - chord * chord / 4);
      expect(polygonSagitta, greaterThan(1.5));
      expect(worstDeviation, lessThan(.25));
    });
  });
}
