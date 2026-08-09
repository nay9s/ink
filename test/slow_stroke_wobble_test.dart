import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:ink_note/editor/stroke_geometry.dart';
import 'package:ink_note/editor/stroke_stabilizer.dart';
import 'package:ink_note/models.dart';

/// Writing slowly delivers 120Hz samples a fraction of a pixel apart, so each
/// is dominated by tremor rather than by where the stroke is going. These
/// tests pin how that noise is kept out of the rendered curve.
///
/// The glyph and tremor here are sized the way real handwriting is: letters a
/// couple of hundred pixels tall with about a pixel of hand tremor. An earlier
/// version of this file used a 900px stroke with 0.45px tremor, a 2000:1 ratio
/// that made every option look smooth and hid the difference between them.
void main() {
  const canvas = Size(1500, 560);
  const origin = Offset(400, 300);
  const glyphScale = 130.0;
  const tremorPx = 1.1;

  /// A bowl with an ascender loop, the shape most Thai letters are built
  /// from: curvature the whole way round, which is where wobble shows up
  /// first. It turns about 7.4 rad.
  Offset glyphAt(double t) {
    final angle = t * math.pi * 2.35 - math.pi * .55;
    final radius = (1 - t * .22) * glyphScale;
    return origin +
        Offset(
          math.cos(angle) * radius * .78 + t * glyphScale * .5,
          math.sin(angle) * radius,
        );
  }

  /// Runs the real capture pipeline over the glyph. With [average] the shipped
  /// [StrokeControlPointSpacer] is used; without it, samples are simply
  /// thinned to the same spacing, which is what the spacer replaced.
  List<InkPoint> capture({
    required double spacing,
    required bool average,
    required int seed,
    double sampleStepPx = .5,
  }) {
    final sampleCount = (glyphScale * 9 / sampleStepPx).round();
    final random = math.Random(seed);
    final stabilizer = StrokeStabilizer();
    final spacer = StrokeControlPointSpacer(spanPixels: spacing);
    final captured = <InkPoint>[];

    for (var i = 0; i <= sampleCount; i++) {
      final ideal = glyphAt(i / sampleCount);
      final raw = InkPoint(
        (ideal.dx + (random.nextDouble() * 2 - 1) * tremorPx) / canvas.width,
        (ideal.dy + (random.nextDouble() * 2 - 1) * tremorPx) / canvas.height,
        .5,
      );
      final timestamp = Duration(milliseconds: i * 8);
      if (i == 0) {
        stabilizer.start(raw, timestamp: timestamp);
        spacer.start(raw);
        captured.add(raw);
        continue;
      }
      // The shipped default smoothing.
      final filtered = stabilizer.filter(
        raw,
        canvas,
        strength: .45,
        timestamp: timestamp,
      );
      if (average) {
        final point = spacer.add(filtered, canvas);
        if (point != null) captured.add(point);
        continue;
      }
      final previous = captured.last;
      final dx = (filtered.x - previous.x) * canvas.width;
      final dy = (filtered.y - previous.y) * canvas.height;
      if (math.sqrt(dx * dx + dy * dy) >= spacing) captured.add(filtered);
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

  /// Total turning of the rendered centerline, walked at a fixed spacing so
  /// dense and sparse inputs are measured alike. Anything above the glyph's
  /// own ~7.4 rad is wobble.
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

  double furthestFromGlyph(List<InkPoint> captured) {
    var worst = 0.0;
    for (final sample in render(captured)) {
      var nearest = double.infinity;
      for (var step = 0; step <= 600; step++) {
        final distance = (sample.offset - glyphAt(step / 600)).distance;
        if (distance < nearest) nearest = distance;
      }
      if (nearest > worst) worst = nearest;
    }
    return worst;
  }

  double averageOver(
    double Function(List<InkPoint>) measure, {
    required double spacing,
    required bool average,
    double sampleStepPx = .5,
  }) {
    const runs = 6;
    var total = 0.0;
    for (var seed = 0; seed < runs; seed++) {
      total += measure(
        capture(
          spacing: spacing,
          average: average,
          seed: seed,
          sampleStepPx: sampleStepPx,
        ),
      );
    }
    return total / runs;
  }

  const shipped = kControlPointSpanPixels;

  test('averaging a span beats thinning it, at the same point count', () {
    final thinned = averageOver(
      totalTurning,
      spacing: shipped,
      average: false,
    );
    final averaged = averageOver(
      totalTurning,
      spacing: shipped,
      average: true,
    );

    // Both store one point per span, so this is not a density effect: the
    // mean of a span's samples simply carries less of their tremor.
    expect(
      capture(spacing: shipped, average: true, seed: 0).length,
      closeTo(capture(spacing: shipped, average: false, seed: 0).length, 6),
    );
    expect(averaged, lessThan(thinned * .6));
  });

  test('averaging removes most of the slow-writing wobble', () {
    final everySample = averageOver(
      totalTurning,
      spacing: .15,
      average: false,
    );
    final averaged = averageOver(
      totalTurning,
      spacing: shipped,
      average: true,
    );

    expect(everySample, greaterThan(60));
    expect(averaged, lessThan(everySample * .25));
  });

  test('averaging does not pull the line off the path the hand drew', () {
    final everySample = averageOver(
      furthestFromGlyph,
      spacing: .15,
      average: false,
    );
    final averaged = averageOver(
      furthestFromGlyph,
      spacing: shipped,
      average: true,
    );

    // Noise is cancelled, not traded for drift: fidelity must not get worse.
    expect(averaged, lessThan(everySample + .02));
  });

  test('fast strokes are not degraded', () {
    // Samples already arrive further apart than a span, so nearly every span
    // holds a single sample whose mean is itself. Only where the stabilizer
    // is still catching up early in the stroke does a span hold two, so this
    // asserts the outcome rather than byte-identical points.
    const fast = 12.0;
    final captured = capture(
      spacing: shipped,
      average: true,
      seed: 0,
      sampleStepPx: fast,
    );
    final thinned = capture(
      spacing: shipped,
      average: false,
      seed: 0,
      sampleStepPx: fast,
    );

    expect(captured.length, closeTo(thinned.length, 2));
    expect(
      averageOver(
        totalTurning,
        spacing: shipped,
        average: true,
        sampleStepPx: fast,
      ),
      lessThanOrEqualTo(
        averageOver(
          totalTurning,
          spacing: shipped,
          average: false,
          sampleStepPx: fast,
        ),
      ),
    );
    expect(
      averageOver(
        furthestFromGlyph,
        spacing: shipped,
        average: true,
        sampleStepPx: fast,
      ),
      lessThan(
        averageOver(
              furthestFromGlyph,
              spacing: shipped,
              average: false,
              sampleStepPx: fast,
            ) +
            .02,
      ),
    );
  });
}
