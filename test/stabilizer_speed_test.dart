import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:ink_note/editor/stroke_stabilizer.dart';
import 'package:ink_note/models.dart';

/// The stabilizer exists to take tremor out of slow pen input. It must not
/// pay for that by bending the letter when the pen actually moves.
///
/// A fixed time constant did exactly that: measured against unfiltered input,
/// it was 1.20x, 1.58x and 2.03x *worse* than no filtering at 8, 16 and 24
/// pixels per sample. These tests pin the speed-adaptive behaviour that
/// replaced it.
void main() {
  const canvas = Size(1500, 900);
  const tremorPx = 1.1;
  const glyphScale = 90.0;

  /// A bowl with an ascender loop, the shape most Thai letters are built
  /// from. Curvature the whole way round is where corner-cutting shows.
  Offset glyphAt(double t) {
    final angle = t * math.pi * 2.35 - math.pi * .55;
    final radius = (1 - t * .22) * glyphScale;
    return const Offset(500, 450) +
        Offset(
          math.cos(angle) * radius * .78 + t * glyphScale * .5,
          math.sin(angle) * radius,
        );
  }

  double distanceToGlyph(Offset point) {
    var nearest = double.infinity;
    for (var step = 0; step <= 900; step++) {
      final distance = (point - glyphAt(step / 900)).distance;
      if (distance < nearest) nearest = distance;
    }
    return nearest;
  }

  /// Mean distance from the shape actually drawn, for the raw samples and for
  /// the stabilized ones, when the glyph is written at [sampleStepPx] of pen
  /// travel per sample.
  (double raw, double filtered) errorsAt(
    double sampleStepPx, {
    double strength = .45,
    int seed = 0,
  }) {
    final sampleCount = (glyphScale * 9 / sampleStepPx).round();
    final random = math.Random(seed);
    final stabilizer = StrokeStabilizer();
    var rawError = 0.0;
    var filteredError = 0.0;
    var counted = 0;

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
        continue;
      }
      final filtered = stabilizer.filter(
        raw,
        canvas,
        strength: strength,
        timestamp: timestamp,
      );
      rawError += distanceToGlyph(
        Offset(raw.x * canvas.width, raw.y * canvas.height),
      );
      filteredError += distanceToGlyph(
        Offset(filtered.x * canvas.width, filtered.y * canvas.height),
      );
      counted++;
    }
    return (rawError / counted, filteredError / counted);
  }

  double relativeErrorAt(double sampleStepPx, {double strength = .45}) {
    var raw = 0.0;
    var filtered = 0.0;
    for (var seed = 0; seed < 5; seed++) {
      final (r, f) = errorsAt(sampleStepPx, strength: strength, seed: seed);
      raw += r;
      filtered += f;
    }
    return filtered / raw;
  }

  test('smoothing never bends the letter more than not smoothing at all', () {
    // Every speed from a crawl to brisk handwriting. The bar is break-even
    // rather than exactly 1.0 because at the fastest speeds the filter is
    // barely acting at all and lands within a percent of the raw input.
    for (final step in <double>[1, 2, 4, 8, 16, 24]) {
      expect(
        relativeErrorAt(step),
        lessThanOrEqualTo(1.02),
        reason: 'at $step px per sample the filter is worse than raw input',
      );
    }
  });

  test('smoothing still earns its keep when the pen is slow', () {
    // Where tremor dominates, the filter should remove a clear majority of it.
    expect(relativeErrorAt(1), lessThan(.7));
    expect(relativeErrorAt(2), lessThan(.7));
  });

  test('the strongest smoothing is still safe at speed', () {
    // Turning the setting up must not reintroduce the distortion; a fixed
    // time constant at strength 1.0 was over 6x worse than raw input.
    expect(relativeErrorAt(16, strength: 1), lessThanOrEqualTo(1.02));
    expect(relativeErrorAt(24, strength: 1), lessThanOrEqualTo(1.02));
  });

  test('smoothing off is still a passthrough', () {
    final (raw, filtered) = errorsAt(8, strength: 0);
    expect(filtered, closeTo(raw, 1e-9));
  });
}
