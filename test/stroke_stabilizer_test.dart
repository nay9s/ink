import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
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

  test('maximum strength keeps the virtual pen close to the Pencil', () {
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

    expect(lagPixels, lessThanOrEqualTo(11.1));
    expect(result.x, lessThan(raw.x));
  });

  test('default strength stays within five pixels and never retracts', () {
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

      expect(lagPixels, lessThanOrEqualTo(4.5));
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
}
