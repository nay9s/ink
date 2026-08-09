import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:ink_note/editor/stroke_geometry.dart';
import 'package:ink_note/editor/stroke_stabilizer.dart';
import 'package:ink_note/models.dart';

/// Writing slowly delivers 120Hz samples a fraction of a pixel apart, so each
/// is dominated by jitter rather than by where the stroke is going. These
/// tests pin the control-point spacing that keeps that noise out of the
/// rendered curve.
void main() {
  const canvas = Size(1000, 1000);

  // A gentle arc, the shape a letter is built from. It turns ~2.1 rad.
  Offset truePathAt(double t) =>
      Offset(200 + t * 300, 500 - math.sin(t * math.pi) * 120);

  List<InkPoint> capture({
    required double sampleStepPx,
    required double minimumDistance,
    required int seed,
  }) {
    const arcLength = 340.0;
    final sampleCount = (arcLength / sampleStepPx).round();
    final random = math.Random(seed);
    final stabilizer = StrokeStabilizer();
    final captured = <InkPoint>[];

    for (var i = 0; i <= sampleCount; i++) {
      final ideal = truePathAt(i / sampleCount);
      final raw = InkPoint(
        (ideal.dx + (random.nextDouble() * 2 - 1) * .4) / canvas.width,
        (ideal.dy + (random.nextDouble() * 2 - 1) * .4) / canvas.height,
        .5,
      );
      final timestamp = Duration(milliseconds: i * 8);
      if (i == 0) {
        stabilizer.start(raw, timestamp: timestamp);
        captured.add(raw);
        continue;
      }
      captured.addAll(
        strokeCapturePointsTowards(
          captured.last,
          stabilizer.filter(
            raw,
            canvas,
            strength: .45,
            timestamp: timestamp,
          ),
          canvas,
          minimumDistance: minimumDistance,
        ),
      );
    }
    return captured;
  }

  List<StrokeGeometrySample> render(List<InkPoint> captured) =>
      sampleSmoothStrokeCurve(
        prepareStableStrokeSamples(
          captured.map(
            (p) => StrokeGeometrySample(
              Offset(p.x * canvas.width, p.y * canvas.height),
              p.pressure,
            ),
          ),
          minimumDistance: .05,
        ),
        maximumSegmentLength: .5,
      );

  /// Total turning of the rendered centerline, resampled at a fixed spacing so
  /// dense and sparse inputs are measured alike. Anything above the arc's own
  /// ~2.1 rad is wobble.
  double totalTurning(List<InkPoint> captured) {
    final walk = <Offset>[];
    for (final sample in render(captured)) {
      if (walk.isEmpty || (sample.offset - walk.last).distance >= 2) {
        walk.add(sample.offset);
      }
    }
    if (walk.length < 3) return 0;
    var turning = 0.0;
    for (var i = 1; i < walk.length - 1; i++) {
      final a = walk[i] - walk[i - 1];
      final b = walk[i + 1] - walk[i];
      if (a.distance < 1e-9 || b.distance < 1e-9) continue;
      turning += math.acos(
        ((a.dx * b.dx + a.dy * b.dy) / (a.distance * b.distance)).clamp(
          -1.0,
          1.0,
        ),
      );
    }
    return turning;
  }

  double furthestFromTruePath(List<InkPoint> captured) {
    var worst = 0.0;
    for (final sample in render(captured)) {
      var nearest = double.infinity;
      for (var step = 0; step <= 300; step++) {
        final distance = (sample.offset - truePathAt(step / 300)).distance;
        if (distance < nearest) nearest = distance;
      }
      if (nearest > worst) worst = nearest;
    }
    return worst;
  }

  double averageOver(
    double Function(List<InkPoint>) measure, {
    required double sampleStepPx,
    required double minimumDistance,
  }) {
    const runs = 8;
    var total = 0.0;
    for (var seed = 0; seed < runs; seed++) {
      total += measure(
        capture(
          sampleStepPx: sampleStepPx,
          minimumDistance: minimumDistance,
          seed: seed,
        ),
      );
    }
    return total / runs;
  }

  // The spacing capture actually ships with, versus keeping every sample.
  const shipped = kMinimumControlPointSpacing;
  const everySample = .15;

  test('the shipped spacing removes most of the slow-writing wobble', () {
    final dense = averageOver(
      totalTurning,
      sampleStepPx: .5,
      minimumDistance: everySample,
    );
    final spaced = averageOver(
      totalTurning,
      sampleStepPx: .5,
      minimumDistance: shipped,
    );

    expect(dense, greaterThan(12));
    expect(spaced, lessThan(dense * .55));
  });

  test('spacing does not pull the line off the path the hand drew', () {
    final dense = averageOver(
      furthestFromTruePath,
      sampleStepPx: .5,
      minimumDistance: everySample,
    );
    final spaced = averageOver(
      furthestFromTruePath,
      sampleStepPx: .5,
      minimumDistance: shipped,
    );

    // Noise is dropped, not the trajectory: fidelity must not get worse.
    expect(spaced, lessThan(dense + .1));
  });

  test('fast strokes are left alone', () {
    // Samples already further apart than the minimum, so nothing is dropped.
    final dense = averageOver(
      totalTurning,
      sampleStepPx: 6,
      minimumDistance: everySample,
    );
    final spaced = averageOver(
      totalTurning,
      sampleStepPx: 6,
      minimumDistance: shipped,
    );

    expect(spaced, closeTo(dense, dense * .15));
  });
}
