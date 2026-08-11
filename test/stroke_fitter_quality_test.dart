import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:ink_note/editor/stroke_fitter.dart';
import 'package:ink_note/editor/stroke_geometry.dart';
import 'package:ink_note/editor/stroke_stabilizer.dart';
import 'package:ink_note/models.dart';

void main() {
  const canvas = Size(1500, 900);

  test('completed fitting improves slow, normal, and fast handwriting', () {
    for (final step in <double>[.5, 2, 4, 8, 16]) {
      var capturedP95 = 0.0;
      var fittedP95 = 0.0;
      var fittedWorst = 0.0;
      var fittedError = 0.0;

      for (var seed = 0; seed < 8; seed++) {
        final raw = _noisyGlyph(canvas, sampleStepPx: step, seed: seed);
        final captured = _capture(raw, canvas);
        final fitted = finishSmoothStroke(captured, canvas, smoothing: .45);
        final before = _quality(captured, canvas, _glyphAt);
        final after = _quality(fitted, canvas, _glyphAt);

        capturedP95 += before.p95 / 8;
        fittedP95 += after.p95 / 8;
        fittedWorst = math.max(fittedWorst, after.worst);
        fittedError += after.meanError / 8;

        expect(fitted.first, captured.first, reason: 'speed=$step seed=$seed');
        expect(fitted.last, captured.last, reason: 'speed=$step seed=$seed');
      }

      expect(
        fittedP95,
        lessThan(capturedP95 * .58),
        reason: 'typical tangent change at $step px/sample',
      );
      expect(
        fittedWorst,
        lessThan(.3),
        reason: 'no visible fitted kink at $step px/sample',
      );
      expect(
        fittedError,
        lessThan(.8),
        reason: 'fit stays within a sub-pixel average of the authored glyph',
      );
    }
  });

  test(
    'capture and fitting are invariant across the full editor zoom range',
    () {
      const zooms = <double>[.1, .25, .5, 1, 2, 4, 6];
      const baseCanvas = Size(1500, 900);

      for (final step in <double>[.5, 3, 12]) {
        List<Offset>? baseline;
        for (final zoom in zooms) {
          final size = Size(baseCanvas.width * zoom, baseCanvas.height * zoom);
          final raw = _fixedScreenGlyph(size, sampleStepPx: step, seed: 41);
          final fitted = finishSmoothStroke(
            _capture(raw, size),
            size,
            smoothing: .45,
          );
          final pixels = fitted
              .map((point) => _pixels(point, size))
              .toList(growable: false);

          baseline ??= pixels;
          expect(
            pixels.length,
            baseline.length,
            reason: 'zoom=$zoom speed=$step',
          );
          for (var index = 0; index < pixels.length; index++) {
            expect(
              (pixels[index] - baseline[index]).distance,
              lessThan(1e-7),
              reason: 'zoom=$zoom speed=$step point=$index',
            );
          }
        }
      }
    },
  );

  test('a stroke captured zoomed out remains smooth when magnified', () {
    const captureSize = Size(375, 225);
    final fitted = finishSmoothStroke(
      _capture(
        _noisyGlyph(
          captureSize,
          sampleStepPx: 1,
          seed: 9,
          scale: 45,
          center: const Offset(190, 115),
        ),
        captureSize,
      ),
      captureSize,
      smoothing: .45,
    );

    for (final magnification in <double>[1, 2, 4, 8, 16, 24]) {
      final rendered = _walkRendered(
        fitted,
        Size(
          captureSize.width * magnification,
          captureSize.height * magnification,
        ),
      );
      expect(
        _turnStats(rendered).worst,
        lessThan(.32),
        reason: 'magnification=$magnification',
      );
    }
  });

  test('deliberate corners survive fitting at every capture speed', () {
    const apex = Offset(500, 350);
    for (final step in <double>[.5, 2, 8, 16]) {
      final raw = _noisyCorner(canvas, sampleStepPx: step, seed: 31);
      final fitted = finishSmoothStroke(
        _capture(raw, canvas),
        canvas,
        smoothing: .45,
      );
      final rendered = _walkRendered(fitted, canvas, spacing: .5);
      final apexDistance = rendered
          .map((point) => (point - apex).distance)
          .reduce(math.min);

      expect(apexDistance, lessThan(2.6), reason: 'speed=$step');
      expect(
        _turnStats(_walkAtSpacing(rendered, 3)).worst,
        greaterThan(.65),
        reason: 'the corner must not be rounded into an ordinary curve',
      );
    }
  });

  test('small handwriting loops remain open and on their authored radius', () {
    for (final radius in <double>[8, 16, 32, 64]) {
      final raw = _noisyLoop(canvas, radius: radius, seed: radius.round());
      final captured = _capture(raw, canvas);
      final fitted = finishSmoothStroke(captured, canvas, smoothing: .45);
      final rendered = _walkRendered(fitted, canvas, spacing: .5);
      const center = Offset(500, 430);
      final radialErrors = rendered
          .map((point) => ((point - center).distance - radius).abs())
          .toList(growable: false);
      final meanError =
          radialErrors.reduce((a, b) => a + b) / radialErrors.length;

      expect(meanError, lessThan(1.4), reason: 'radius=$radius');
      expect(
        rendered.map((point) => point.dx).reduce(math.max) -
            rendered.map((point) => point.dx).reduce(math.min),
        greaterThan(radius * 1.7),
        reason: 'the loop must not collapse',
      );
      expect(fitted.first, captured.first);
      expect(fitted.last, captured.last);
    }
  });

  test('smoothing off and very short marks are preserved exactly', () {
    const points = <InkPoint>[
      InkPoint(.2, .3, .4),
      InkPoint(.21, .31, .5),
      InkPoint(.22, .305, .6),
    ];

    expect(
      finishSmoothStroke(points, canvas, smoothing: 0),
      orderedEquals(points),
    );
    expect(
      finishSmoothStroke(points, canvas, smoothing: 1),
      orderedEquals(points),
    );
  });
}

List<InkPoint> _capture(List<InkPoint> raw, Size size) {
  final stabilizer = StrokeStabilizer();
  final spacer = StrokeControlPointSpacer();
  final output = <InkPoint>[raw.first];
  stabilizer.start(raw.first, timestamp: Duration.zero);
  spacer.start(raw.first);

  for (var index = 1; index < raw.length; index++) {
    final filtered = stabilizer.filter(
      raw[index],
      size,
      strength: .45,
      timestamp: Duration(microseconds: index * 8333),
    );
    final point = spacer.add(filtered, size);
    if (point != null) output.add(point);
  }
  if ((_pixels(output.last, size) - _pixels(raw.last, size)).distance > .05) {
    output.add(raw.last);
  }
  return output;
}

List<InkPoint> _noisyGlyph(
  Size size, {
  required double sampleStepPx,
  required int seed,
  double scale = 90,
  Offset center = const Offset(500, 450),
}) {
  final count = (scale * 9 / sampleStepPx).round().clamp(16, 2400);
  final random = math.Random(seed);
  return <InkPoint>[
    for (var index = 0; index <= count; index++)
      _toInkPoint(
        _glyphAt(index / count, scale: scale, center: center) + _noise(random),
        size,
      ),
  ];
}

List<InkPoint> _fixedScreenGlyph(
  Size size, {
  required double sampleStepPx,
  required int seed,
}) {
  const scale = 24.0;
  const center = Offset(72, 45);
  final count = (scale * 9 / sampleStepPx).round().clamp(16, 1200);
  final random = math.Random(seed);
  return <InkPoint>[
    for (var index = 0; index <= count; index++)
      _toInkPoint(
        _glyphAt(index / count, scale: scale, center: center) + _noise(random),
        size,
      ),
  ];
}

List<InkPoint> _noisyCorner(
  Size size, {
  required double sampleStepPx,
  required int seed,
}) {
  const apex = Offset(500, 350);
  final random = math.Random(seed);
  final raw = <InkPoint>[];

  void addSegment(Offset start, Offset end, {required bool includeStart}) {
    final count = math.max(2, ((end - start).distance / sampleStepPx).ceil());
    for (var index = includeStart ? 0 : 1; index <= count; index++) {
      raw.add(
        _toInkPoint(
          Offset.lerp(start, end, index / count)! + _noise(random),
          size,
        ),
      );
    }
  }

  addSegment(const Offset(350, 500), apex, includeStart: true);
  addSegment(apex, const Offset(680, 540), includeStart: false);
  return raw;
}

List<InkPoint> _noisyLoop(
  Size size, {
  required double radius,
  required int seed,
}) {
  const center = Offset(500, 430);
  final random = math.Random(seed);
  final count = math.max(24, (2 * math.pi * radius / .75).round());
  return <InkPoint>[
    for (var index = 0; index <= count; index++)
      _toInkPoint(
        center +
            Offset(
              math.cos(index / count * math.pi * 2) * radius,
              math.sin(index / count * math.pi * 2) * radius,
            ) +
            _noise(random, amplitude: .8),
        size,
      ),
  ];
}

Offset _glyphAt(
  double t, {
  double scale = 90,
  Offset center = const Offset(500, 450),
}) {
  final angle = t * math.pi * 2.35 - math.pi * .55;
  final radius = (1 - t * .22) * scale;
  return center +
      Offset(
        math.cos(angle) * radius * .78 + t * scale * .5,
        math.sin(angle) * radius,
      );
}

Offset _noise(math.Random random, {double amplitude = 1.1}) => Offset(
  (random.nextDouble() * 2 - 1) * amplitude,
  (random.nextDouble() * 2 - 1) * amplitude,
);

InkPoint _toInkPoint(Offset offset, Size size) =>
    InkPoint(offset.dx / size.width, offset.dy / size.height, .5);

Offset _pixels(InkPoint point, Size size) =>
    Offset(point.x * size.width, point.y * size.height);

List<Offset> _walkRendered(
  List<InkPoint> points,
  Size size, {
  double spacing = 3,
}) {
  final rendered = sampleSmoothStrokeCurve(
    prepareStableStrokeSamples(
      points.map(
        (point) => StrokeGeometrySample(_pixels(point, size), point.pressure),
      ),
    ),
    maximumSegmentLength: .5,
  );
  return _walkAtSpacing(
    rendered.map((sample) => sample.offset).toList(growable: false),
    spacing,
  );
}

({double worst, double p95, double meanError}) _quality(
  List<InkPoint> points,
  Size size,
  Offset Function(double t) idealAt,
) {
  final walked = _walkRendered(points, size);
  final turns = _turnStats(walked);
  var error = 0.0;
  for (final point in walked) {
    var nearest = double.infinity;
    for (var index = 0; index <= 900; index++) {
      nearest = math.min(nearest, (point - idealAt(index / 900)).distance);
    }
    error += nearest;
  }
  return (
    worst: turns.worst,
    p95: turns.p95,
    meanError: walked.isEmpty ? 0 : error / walked.length,
  );
}

({double worst, double p95}) _turnStats(List<Offset> points) {
  final turns = <double>[];
  for (var index = 1; index < points.length - 1; index++) {
    final before = points[index] - points[index - 1];
    final after = points[index + 1] - points[index];
    if (before.distanceSquared < 1e-9 || after.distanceSquared < 1e-9) continue;
    turns.add(
      math.acos(
        ((before.dx * after.dx + before.dy * after.dy) /
                (before.distance * after.distance))
            .clamp(-1.0, 1.0),
      ),
    );
  }
  if (turns.isEmpty) return (worst: 0, p95: 0);
  turns.sort();
  return (worst: turns.last, p95: turns[(turns.length * .95).floor()]);
}

List<Offset> _walkAtSpacing(List<Offset> source, double spacing) {
  if (source.isEmpty) return const <Offset>[];
  final output = <Offset>[source.first];
  var remaining = spacing;
  for (var index = 1; index < source.length; index++) {
    var start = source[index - 1];
    final end = source[index];
    var distance = (end - start).distance;
    while (distance >= remaining && distance > 1e-9) {
      start = Offset.lerp(start, end, remaining / distance)!;
      output.add(start);
      distance = (end - start).distance;
      remaining = spacing;
    }
    remaining -= distance;
    if (remaining <= 1e-9) remaining = spacing;
  }
  return output;
}
