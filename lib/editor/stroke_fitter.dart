// Fits cubic Béziers to the raw pen samples of a finished stroke.
//
// Filtering and fitting solve the same problem from opposite ends, and only
// one of them can win both halves of it. A filter sees each sample as it
// arrives and has to decide immediately how much to trust it, so removing
// tremor always costs lag, and lag on a curve is a cut corner. A fit sees the
// whole stroke at once and asks a different question — which smooth curve best
// explains all of these samples — so the tremor cancels statistically rather
// than being smeared, and nothing is displaced in the process.
//
// This is the classic approach from Philip Schneider's "An Algorithm for
// Automatically Fitting Digitized Curves" (Graphics Gems, 1990), which vector
// tools have used for their freehand pencils for decades: parameterise the
// samples by chord length, solve least squares for the two interior control
// points, and where the result strays further than the tolerance, split at the
// worst point and fit each half.
//
// Corners are found before any fitting starts and used as hard segment
// boundaries, so a deliberate angle is never averaged away with the tremor
// around it — the one thing a position filter cannot help but do.

import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../models.dart';

Offset _normalized(Offset vector) {
  final length = vector.distance;
  if (!length.isFinite || length < 1e-12) return Offset.zero;
  return vector / length;
}

/// Span, in screen pixels, that each sample handed to the fit represents.
///
/// Comfortably above the amplitude of hand tremor, so consecutive samples
/// differ by where the pen went rather than by how it shook.
const double _sampleSpanPx = 2;

/// Collapses each [span] of travel to the mean of the samples along it.
///
/// Thinning instead — keeping one sample per span and discarding the rest —
/// is not enough. Least squares only cancels noise when a segment holds many
/// samples, and with a tolerance not far above the tremor the fit keeps
/// splitting into short segments that hold few; each one then reproduces the
/// tremor of its own handful of points and the result wobbles. Averaging
/// first drops the noise by sqrt of the samples in a span, so the segments
/// stay long and the fit has something clean to follow.
void _averageInPlace(
  List<Offset> pixels,
  List<double> pressures,
  double span,
) {
  final outPixels = <Offset>[pixels.first];
  final outPressures = <double>[pressures.first];

  var spanStart = pixels.first;
  var sum = Offset.zero;
  var pressureSum = 0.0;
  var count = 0;

  for (var i = 1; i < pixels.length; i++) {
    sum += pixels[i];
    pressureSum += pressures[i];
    count++;
    if ((pixels[i] - spanStart).distance < span) continue;
    outPixels.add(sum / count.toDouble());
    outPressures.add(pressureSum / count);
    spanStart = pixels[i];
    sum = Offset.zero;
    pressureSum = 0;
    count = 0;
  }

  // The exact lift-off point is where the hand stopped; never average it away.
  if ((outPixels.last - pixels.last).distance > 1e-6) {
    outPixels.add(pixels.last);
    outPressures.add(pressures.last);
  }

  pixels
    ..clear()
    ..addAll(outPixels);
  pressures
    ..clear()
    ..addAll(outPressures);
}

/// A cubic Bézier segment in screen pixels.
@immutable
class StrokeCubic {
  const StrokeCubic(this.p0, this.p1, this.p2, this.p3);

  final Offset p0;
  final Offset p1;
  final Offset p2;
  final Offset p3;

  Offset pointAt(double t) {
    final u = 1 - t;
    return p0 * (u * u * u) +
        p1 * (3 * u * u * t) +
        p2 * (3 * u * t * t) +
        p3 * (t * t * t);
  }

  Offset derivativeAt(double t) {
    final u = 1 - t;
    return (p1 - p0) * (3 * u * u) +
        (p2 - p1) * (6 * u * t) +
        (p3 - p2) * (3 * t * t);
  }

  Offset secondDerivativeAt(double t) {
    final u = 1 - t;
    return (p2 - p1 * 2 + p0) * (6 * u) + (p3 - p2 * 2 + p1) * (6 * t);
  }

  /// Rough arc length, enough to choose how densely to sample.
  double approximateLength({int steps = 16}) {
    var length = 0.0;
    var previous = p0;
    for (var i = 1; i <= steps; i++) {
      final current = pointAt(i / steps);
      length += (current - previous).distance;
      previous = current;
    }
    return length;
  }
}

/// Refits [rawSamples] and returns the points to store for the stroke.
///
/// [tolerancePx] is how far the fitted curve may sit from the samples: it is
/// the knob that trades faithfulness for smoothness, and it is meaningful in a
/// way a filter strength never was, because it is a distance rather than a
/// blend factor. Anything below roughly the amplitude of hand tremor makes the
/// fit chase the tremor.
///
/// Returns [rawSamples] unchanged when there is too little to fit, so callers
/// never have to special-case dots and flicks.
List<InkPoint> fitStrokePoints(
  List<InkPoint> rawSamples,
  Size screenSize, {
  required double tolerancePx,
  double resamplePx = 2.5,
}) {
  if (rawSamples.length < 4 ||
      screenSize.width <= 0 ||
      screenSize.height <= 0 ||
      !screenSize.width.isFinite ||
      !screenSize.height.isFinite) {
    return rawSamples;
  }

  final pixels = <Offset>[];
  final pressures = <double>[];
  for (final sample in rawSamples) {
    if (!sample.x.isFinite || !sample.y.isFinite) continue;
    final offset = Offset(
      sample.x * screenSize.width,
      sample.y * screenSize.height,
    );
    // Duplicate samples carry no direction and break the parameterisation.
    if (pixels.isNotEmpty && (offset - pixels.last).distance < 1e-6) continue;
    pixels.add(offset);
    pressures.add(sample.pressure);
  }
  if (pixels.length < 4) return rawSamples;

  // Average the samples into spans first. Writing slowly delivers them a
  // fraction of a pixel apart, where the step between neighbours is almost
  // entirely tremor: chord-length parameterisation then measures noise rather
  // than progress along the stroke, and every direction estimate taken from
  // two nearby samples points somewhere random. Both the fit and the corner
  // search need steps long enough to carry real direction.
  _averageInPlace(pixels, pressures, _sampleSpanPx);
  if (pixels.length < 4) return rawSamples;

  final corners = _detectCorners(pixels);
  final fitted = <InkPoint>[];

  var runStart = 0;
  for (final boundary in <int>[...corners, pixels.length - 1]) {
    if (boundary <= runStart) continue;
    final run = pixels.sublist(runStart, boundary + 1);
    final runPressures = pressures.sublist(runStart, boundary + 1);
    final curves = _fitCubics(run, tolerancePx);
    _appendSampled(
      fitted,
      curves,
      run,
      runPressures,
      screenSize,
      resamplePx,
      includeFirst: fitted.isEmpty,
    );
    runStart = boundary;
  }

  // A degenerate fit is worse than no fit.
  if (fitted.length < 2) return rawSamples;
  return fitted;
}

/// Tolerance in screen pixels for a given smoothing setting.
///
/// The floor sits just above the amplitude of ordinary hand tremor, because a
/// tolerance below that makes the fit reproduce the tremor faithfully, which
/// is precisely what it exists to avoid.
/// Swept on a jittered glyph: below about 1.5px the fit starts reproducing the
/// tremor (turning more than doubles), and above about 2.6px it stops buying
/// smoothness and only costs faithfulness. The range here spans that band, so
/// every setting of the slider is useful and none of them is bad.
double strokeFitTolerance(double smoothing) {
  final amount = smoothing.clamp(0.0, 1.0).toDouble();
  return 1.5 + 1.8 * amount;
}

/// Indices where the stroke turns hard enough to be a deliberate corner.
///
/// The angle is measured across a short span rather than between neighbouring
/// samples, because at 120Hz two adjacent samples are mostly tremor and every
/// one of them would look like a corner.
List<int> _detectCorners(
  List<Offset> pixels, {
  double spanPx = 12,
  double minimumTurn = 1.15,
}) {
  final corners = <int>[];
  final scores = <int, double>{};

  for (var i = 1; i < pixels.length - 1; i++) {
    final back = _walkBack(pixels, i, spanPx);
    final forward = _walkForward(pixels, i, spanPx);
    if (back == null || forward == null) continue;
    final incoming = pixels[i] - back;
    final outgoing = forward - pixels[i];
    if (incoming.distance < 1e-6 || outgoing.distance < 1e-6) continue;
    final cosine =
        (incoming.dx * outgoing.dx + incoming.dy * outgoing.dy) /
        (incoming.distance * outgoing.distance);
    final turn = math.acos(cosine.clamp(-1.0, 1.0));
    if (turn >= minimumTurn) scores[i] = turn;
  }

  // Keep only the sharpest index in each cluster, so one corner yields one
  // boundary instead of a smear of them.
  final candidates = scores.keys.toList()..sort();
  var clusterStart = 0;
  while (clusterStart < candidates.length) {
    var clusterEnd = clusterStart;
    while (clusterEnd + 1 < candidates.length &&
        candidates[clusterEnd + 1] - candidates[clusterEnd] <= 3) {
      clusterEnd++;
    }
    var best = candidates[clusterStart];
    for (var k = clusterStart; k <= clusterEnd; k++) {
      if (scores[candidates[k]]! > scores[best]!) best = candidates[k];
    }
    corners.add(best);
    clusterStart = clusterEnd + 1;
  }
  return corners;
}

Offset? _walkBack(List<Offset> pixels, int index, double spanPx) {
  var travelled = 0.0;
  for (var i = index; i > 0; i--) {
    travelled += (pixels[i] - pixels[i - 1]).distance;
    if (travelled >= spanPx) return pixels[i - 1];
  }
  return null;
}

Offset? _walkForward(List<Offset> pixels, int index, double spanPx) {
  var travelled = 0.0;
  for (var i = index; i < pixels.length - 1; i++) {
    travelled += (pixels[i + 1] - pixels[i]).distance;
    if (travelled >= spanPx) return pixels[i + 1];
  }
  return null;
}

List<StrokeCubic> _fitCubics(List<Offset> points, double tolerancePx) {
  if (points.length < 2) return const <StrokeCubic>[];
  final leftTangent = _normalized(points[1] - points.first);
  final rightTangent = _normalized(
    points[points.length - 2] - points.last,
  );
  return _fitRecursive(points, leftTangent, rightTangent, tolerancePx, 0);
}

List<StrokeCubic> _fitRecursive(
  List<Offset> points,
  Offset leftTangent,
  Offset rightTangent,
  double tolerancePx,
  int depth,
) {
  if (points.length == 2) {
    final distance = (points.last - points.first).distance / 3;
    return <StrokeCubic>[
      StrokeCubic(
        points.first,
        points.first + leftTangent * distance,
        points.last + rightTangent * distance,
        points.last,
      ),
    ];
  }

  var parameters = _chordLengthParameterize(points);
  var curve = _generateBezier(points, parameters, leftTangent, rightTangent);
  var (maxError, splitIndex) = _maximumError(points, curve, parameters);
  if (maxError <= tolerancePx) return <StrokeCubic>[curve];

  // Close enough to be worth improving the parameterisation before splitting:
  // chord length is only an approximation of the true arc parameter, and
  // correcting it often turns a near miss into a fit.
  if (maxError <= tolerancePx * tolerancePx && depth < 8) {
    for (var attempt = 0; attempt < 12; attempt++) {
      parameters = _reparameterize(points, curve, parameters);
      curve = _generateBezier(points, parameters, leftTangent, rightTangent);
      (maxError, splitIndex) = _maximumError(points, curve, parameters);
      if (maxError <= tolerancePx) return <StrokeCubic>[curve];
    }
  }

  // Guard against pathological inputs rather than recursing without bound.
  if (depth >= 16 || splitIndex <= 0 || splitIndex >= points.length - 1) {
    return <StrokeCubic>[curve];
  }

  final centerTangent = _normalized(
    points[splitIndex - 1] - points[splitIndex + 1],
  );
  return <StrokeCubic>[
    ..._fitRecursive(
      points.sublist(0, splitIndex + 1),
      leftTangent,
      centerTangent,
      tolerancePx,
      depth + 1,
    ),
    ..._fitRecursive(
      points.sublist(splitIndex),
      Offset(-centerTangent.dx, -centerTangent.dy),
      rightTangent,
      tolerancePx,
      depth + 1,
    ),
  ];
}

/// Least-squares solve for the two interior control points, with the ends and
/// their tangent directions held fixed.
StrokeCubic _generateBezier(
  List<Offset> points,
  List<double> parameters,
  Offset leftTangent,
  Offset rightTangent,
) {
  final first = points.first;
  final last = points.last;

  var c00 = 0.0;
  var c01 = 0.0;
  var c11 = 0.0;
  var x0 = 0.0;
  var x1 = 0.0;

  for (var i = 0; i < points.length; i++) {
    final t = parameters[i];
    final u = 1 - t;
    final b0 = u * u * u;
    final b1 = 3 * u * u * t;
    final b2 = 3 * u * t * t;
    final b3 = t * t * t;

    final a0 = leftTangent * b1;
    final a1 = rightTangent * b2;

    c00 += a0.dx * a0.dx + a0.dy * a0.dy;
    c01 += a0.dx * a1.dx + a0.dy * a1.dy;
    c11 += a1.dx * a1.dx + a1.dy * a1.dy;

    final target = points[i] - (first * (b0 + b1) + last * (b2 + b3));
    x0 += a0.dx * target.dx + a0.dy * target.dy;
    x1 += a1.dx * target.dx + a1.dy * target.dy;
  }

  final determinant = c00 * c11 - c01 * c01;
  var alphaLeft = 0.0;
  var alphaRight = 0.0;
  if (determinant.abs() > 1e-12) {
    alphaLeft = (x0 * c11 - x1 * c01) / determinant;
    alphaRight = (c00 * x1 - c01 * x0) / determinant;
  }

  // A negative or vanishing handle means the solve produced a curve that
  // doubles back. Fall back to the standard heuristic instead.
  final chord = (last - first).distance;
  if (alphaLeft < 1e-6 || alphaRight < 1e-6) {
    alphaLeft = chord / 3;
    alphaRight = chord / 3;
  }

  // Bound the handles. The solve is unconstrained, so samples that wander —
  // a stroke that nearly doubles back, or dense samples whose parameters are
  // crowded — can drive a handle far past the segment it belongs to. Left
  // unbounded that ballooned the curve tens of pixels away from the pen; left
  // merely generous it still let a segment fold back on itself into a cusp,
  // which read as a sharp kink in the middle of a smooth arc. A cubic needs
  // about .55 of its chord to trace a quarter circle, so a limit near the
  // chord leaves ample room for any curvature a pen stroke actually has.
  final limit = chord;
  if (alphaLeft > limit) alphaLeft = limit;
  if (alphaRight > limit) alphaRight = limit;

  return StrokeCubic(
    first,
    first + leftTangent * alphaLeft,
    last + rightTangent * alphaRight,
    last,
  );
}

List<double> _chordLengthParameterize(List<Offset> points) {
  final parameters = <double>[0];
  for (var i = 1; i < points.length; i++) {
    parameters.add(
      parameters[i - 1] + (points[i] - points[i - 1]).distance,
    );
  }
  final total = parameters.last;
  if (total <= 0) {
    return <double>[for (var i = 0; i < points.length; i++) i / (points.length - 1)];
  }
  for (var i = 0; i < parameters.length; i++) {
    parameters[i] = parameters[i] / total;
  }
  return parameters;
}

List<double> _reparameterize(
  List<Offset> points,
  StrokeCubic curve,
  List<double> parameters,
) => <double>[
  for (var i = 0; i < points.length; i++)
    _newtonRaphson(curve, points[i], parameters[i]),
];

double _newtonRaphson(StrokeCubic curve, Offset point, double t) {
  final difference = curve.pointAt(t) - point;
  final first = curve.derivativeAt(t);
  final second = curve.secondDerivativeAt(t);
  final numerator = difference.dx * first.dx + difference.dy * first.dy;
  final denominator =
      first.dx * first.dx +
      first.dy * first.dy +
      difference.dx * second.dx +
      difference.dy * second.dy;
  if (denominator.abs() < 1e-12) return t;
  return (t - numerator / denominator).clamp(0.0, 1.0);
}

(double, int) _maximumError(
  List<Offset> points,
  StrokeCubic curve,
  List<double> parameters,
) {
  var worst = 0.0;
  var index = points.length ~/ 2;
  for (var i = 1; i < points.length - 1; i++) {
    final distance = (curve.pointAt(parameters[i]) - points[i]).distance;
    if (distance > worst) {
      worst = distance;
      index = i;
    }
  }
  return (worst, index);
}

/// Walks the fitted curves at a fixed spacing, carrying pressure across from
/// the samples the run was fitted to.
void _appendSampled(
  List<InkPoint> output,
  List<StrokeCubic> curves,
  List<Offset> run,
  List<double> runPressures,
  Size screenSize,
  double resamplePx, {
  required bool includeFirst,
}) {
  if (curves.isEmpty) return;
  final cumulative = <double>[0];
  for (var i = 1; i < run.length; i++) {
    cumulative.add(cumulative[i - 1] + (run[i] - run[i - 1]).distance);
  }
  final runLength = cumulative.last;

  double pressureAt(double fraction) {
    if (runLength <= 0) return runPressures.first;
    final target = fraction.clamp(0.0, 1.0) * runLength;
    for (var i = 1; i < cumulative.length; i++) {
      if (cumulative[i] >= target) {
        final span = cumulative[i] - cumulative[i - 1];
        final blend = span <= 0 ? 0.0 : (target - cumulative[i - 1]) / span;
        return runPressures[i - 1] +
            (runPressures[i] - runPressures[i - 1]) * blend;
      }
    }
    return runPressures.last;
  }

  InkPoint toInkPoint(Offset pixels, double fraction) => InkPoint(
    (pixels.dx / screenSize.width).clamp(0.0, 1.0),
    (pixels.dy / screenSize.height).clamp(0.0, 1.0),
    pressureAt(fraction).clamp(.03, 1.0),
  );

  // Walk every curve of the run as one continuous path and emit points at a
  // uniform distance along it.
  //
  // Stepping each curve separately instead — so many steps per curve — packs
  // the output tightly wherever the fit produced a short segment, and points a
  // fraction of a pixel apart carry no reliable direction. The renderer's
  // spline then turns through that noise, which put a visible kink at exactly
  // the segment boundaries the fit was meant to hide. This is the same trap
  // that dense capture fell into; the fix is the same, and it belongs on the
  // way out as well as on the way in.
  final densePoints = <Offset>[curves.first.p0];
  final cumulativeLength = <double>[0];
  for (final curve in curves) {
    final steps = math.max(8, curve.approximateLength().ceil());
    for (var step = 1; step <= steps; step++) {
      final point = curve.pointAt(step / steps);
      final previous = densePoints.last;
      densePoints.add(point);
      cumulativeLength.add(
        cumulativeLength.last + (point - previous).distance,
      );
    }
  }
  final totalLength = cumulativeLength.last;
  if (totalLength <= 0) return;

  if (includeFirst) output.add(toInkPoint(densePoints.first, 0));

  var target = resamplePx;
  var index = 1;
  while (target < totalLength) {
    while (index < cumulativeLength.length - 1 &&
        cumulativeLength[index] < target) {
      index++;
    }
    final spanStart = cumulativeLength[index - 1];
    final span = cumulativeLength[index] - spanStart;
    final blend = span <= 0 ? 0.0 : (target - spanStart) / span;
    output.add(
      toInkPoint(
        Offset.lerp(densePoints[index - 1], densePoints[index], blend)!,
        target / totalLength,
      ),
    );
    target += resamplePx;
  }

  // Finish on the run's exact endpoint — for a corner that is the corner
  // itself, and for the last run it is where the pen left the page. Replace
  // rather than append when the last emitted point is nearly on top of it, so
  // the walk never ends in the very cluster it set out to avoid.
  final endPoint = toInkPoint(densePoints.last, 1);
  if (output.length > 1) {
    final previous = output.last;
    final gap = Offset(
      (endPoint.x - previous.x) * screenSize.width,
      (endPoint.y - previous.y) * screenSize.height,
    ).distance;
    if (gap < resamplePx * .5) output.removeLast();
  }
  output.add(endPoint);
}
