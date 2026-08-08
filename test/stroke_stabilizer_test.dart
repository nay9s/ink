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

  test('default stabilization stays close to the Pencil tip', () {
    final stabilizer = StrokeStabilizer()
      ..start(const InkPoint(.1, .5, .5), timestamp: Duration.zero);
    const raw = InkPoint(.3, .5, .5);

    final result = stabilizer.filter(
      raw,
      canvas,
      strength: .45,
      timestamp: const Duration(milliseconds: 8),
    );
    final lagPixels = (raw.x - result.x) * canvas.width;

    expect(lagPixels, lessThanOrEqualTo(2.1));
  });

  test('maximum strength keeps the virtual pen within its lag bound', () {
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

    expect(lagPixels, lessThanOrEqualTo(8.8));
    expect(result.x, lessThan(raw.x));
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

  test('finishing a curved stroke cannot overshoot or reverse', () {
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
    final tail = stabilizer.finish(const InkPoint(.3, .68, .5), canvas);

    expect(tail, isNotEmpty);
    expect(tail.last.x, .3);
    expect(tail.last.y, .68);
    var previousDistance = const Offset(
      .3,
      .68,
    ).translate(-current.x, -current.y).distance;
    for (final point in tail) {
      expect(point.x, inInclusiveRange(current.x, .3));
      expect(point.y, inInclusiveRange(current.y, .68));
      final distance = Offset(.3 - point.x, .68 - point.y).distance;
      expect(distance, lessThanOrEqualTo(previousDistance + 1e-9));
      previousDistance = distance;
    }
  });
}
