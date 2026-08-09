import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:ink_note/editor/stroke_geometry.dart';

void main() {
  test('resampling uses even arc-length spacing and keeps exact endpoints', () {
    final result = prepareStrokeSamples(
      const <StrokeGeometrySample>[
        StrokeGeometrySample(Offset(0, 0), .2),
        StrokeGeometrySample(Offset(1, 0), .3),
        StrokeGeometrySample(Offset(7, 0), .5),
        StrokeGeometrySample(Offset(8, 0), .6),
        StrokeGeometrySample(Offset(20, 0), .9),
      ],
      sampleSpacing: 2,
      smoothingPasses: 0,
    );

    expect(result.first.offset, Offset.zero);
    expect(result.last.offset, const Offset(20, 0));
    for (var index = 1; index < result.length; index++) {
      expect(
        (result[index].offset - result[index - 1].offset).distance,
        closeTo(2, .0001),
      );
    }
  });

  test('symmetric filtering removes radial jitter from a long curve', () {
    const radius = 100.0;
    final noisy = <StrokeGeometrySample>[];
    for (var index = 0; index <= 80; index++) {
      final angle = -.9 + index * 1.8 / 80;
      final jitter = index.isEven ? 2.2 : -2.2;
      final noisyRadius = radius + jitter;
      noisy.add(
        StrokeGeometrySample(
          Offset(math.cos(angle) * noisyRadius, math.sin(angle) * noisyRadius),
          .5,
        ),
      );
    }

    final smoothed = prepareStrokeSamples(noisy, sampleSpacing: 2.25);
    final rawError = _meanRadialError(noisy.skip(4).take(noisy.length - 8));
    final smoothError = _meanRadialError(
      smoothed.skip(5).take(smoothed.length - 10),
    );

    expect(smoothError, lessThan(rawError * .45));
    expect(smoothed.first.offset, noisy.first.offset);
    expect(smoothed.last.offset, noisy.last.offset);
  });

  test('deliberate corners remain close to their authored position', () {
    final corner = <StrokeGeometrySample>[
      for (var x = 0.0; x <= 20; x += 2) StrokeGeometrySample(Offset(x, 0), .5),
      for (var y = 2.0; y <= 20; y += 2)
        StrokeGeometrySample(Offset(20, y), .5),
    ];

    final smoothed = prepareStrokeSamples(corner, sampleSpacing: 2);
    final nearestCornerDistance = smoothed
        .map((sample) => (sample.offset - const Offset(20, 0)).distance)
        .reduce(math.min);

    expect(nearestCornerDistance, lessThan(1.5));
  });

  test('short strokes retain their authored control points', () {
    const shortStroke = <StrokeGeometrySample>[
      StrokeGeometrySample(Offset(0, 0), .4),
      StrokeGeometrySample(Offset(10, 10), .6),
      StrokeGeometrySample(Offset(20, 0), .8),
    ];

    final prepared = prepareStrokeSamples(shortStroke, sampleSpacing: 2);

    expect(
      prepared.map((sample) => sample.offset),
      shortStroke.map((sample) => sample.offset),
    );
  });

  test('cubic sampling produces gradual tangent changes', () {
    const controls = <StrokeGeometrySample>[
      StrokeGeometrySample(Offset(0, 0), .4),
      StrokeGeometrySample(Offset(10, 1), .45),
      StrokeGeometrySample(Offset(20, 5), .55),
      StrokeGeometrySample(Offset(30, 12), .65),
      StrokeGeometrySample(Offset(40, 22), .7),
    ];
    final curve = sampleSmoothStrokeCurve(controls, maximumSegmentLength: .5);

    expect(curve.first.offset, controls.first.offset);
    expect(curve.last.offset, controls.last.offset);
    expect(_maximumTangentChange(curve), lessThan(.08));
  });
}

double _meanRadialError(Iterable<StrokeGeometrySample> samples) {
  final errors = samples
      .map((sample) => (sample.offset.distance - 100).abs())
      .toList();
  return errors.reduce((a, b) => a + b) / errors.length;
}

double _maximumTangentChange(List<StrokeGeometrySample> samples) {
  var maximum = 0.0;
  for (var index = 1; index < samples.length - 1; index++) {
    final before = samples[index].offset - samples[index - 1].offset;
    final after = samples[index + 1].offset - samples[index].offset;
    if (before.distanceSquared <= 1e-9 || after.distanceSquared <= 1e-9) {
      continue;
    }
    final cosine =
        (before.dx * after.dx + before.dy * after.dy) /
        (before.distance * after.distance);
    maximum = math.max(maximum, math.acos(cosine.clamp(-1.0, 1.0)));
  }
  return maximum;
}
