import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:ink_note/editor/shape_recognizer.dart';
import 'package:ink_note/models.dart';

/// Adds a small repeatable wobble so the inputs look hand-drawn rather than
/// mathematically perfect.
double _wobble(int index, double amount) =>
    math.sin(index * 1.7) * amount + math.cos(index * .9) * amount * .5;

List<InkPoint> _line({
  required double x1,
  required double y1,
  required double x2,
  required double y2,
  int samples = 40,
  double noise = .002,
}) => <InkPoint>[
  for (var i = 0; i <= samples; i++)
    InkPoint(
      x1 + (x2 - x1) * (i / samples) + _wobble(i, noise),
      y1 + (y2 - y1) * (i / samples) + _wobble(i + 7, noise),
      .5,
    ),
];

List<InkPoint> _rectangle(Rect bounds, {double noise = .003}) {
  final corners = <Offset>[
    bounds.topLeft,
    bounds.topRight,
    bounds.bottomRight,
    bounds.bottomLeft,
    bounds.topLeft,
  ];
  final points = <InkPoint>[];
  var index = 0;
  for (var side = 0; side < corners.length - 1; side++) {
    for (var step = 0; step < 16; step++) {
      final t = step / 16;
      final position = Offset.lerp(corners[side], corners[side + 1], t)!;
      points.add(
        InkPoint(
          position.dx + _wobble(index, noise),
          position.dy + _wobble(index + 3, noise),
          .5,
        ),
      );
      index++;
    }
  }
  points.add(InkPoint(corners.last.dx, corners.last.dy, .5));
  return points;
}

List<InkPoint> _ellipse(Rect bounds, {double noise = .003}) {
  const samples = 64;
  return <InkPoint>[
    for (var i = 0; i <= samples; i++)
      InkPoint(
        bounds.center.dx +
            math.cos(i / samples * 2 * math.pi) * bounds.width / 2 +
            _wobble(i, noise),
        bounds.center.dy +
            math.sin(i / samples * 2 * math.pi) * bounds.height / 2 +
            _wobble(i + 5, noise),
        .5,
      ),
  ];
}

void main() {
  test('a dragged line is recognised and keeps its endpoints', () {
    final shape = recognizeShape(_line(x1: .1, y1: .2, x2: .8, y2: .5));

    expect(shape, isNotNull);
    expect(shape!.kind, InkShapeKind.line);
    expect(shape.start.x, closeTo(.1, .02));
    expect(shape.start.y, closeTo(.2, .02));
    expect(shape.end.x, closeTo(.8, .02));
    expect(shape.end.y, closeTo(.5, .02));
  });

  test('a drawn box is recognised as a rectangle over its bounds', () {
    const bounds = Rect.fromLTRB(.2, .25, .7, .6);
    final shape = recognizeShape(_rectangle(bounds));

    expect(shape, isNotNull);
    expect(shape!.kind, InkShapeKind.rectangle);
    expect(shape.start.x, closeTo(bounds.left, .02));
    expect(shape.start.y, closeTo(bounds.top, .02));
    expect(shape.end.x, closeTo(bounds.right, .02));
    expect(shape.end.y, closeTo(bounds.bottom, .02));
  });

  test('a drawn circle is recognised as an ellipse, not a rectangle', () {
    final shape = recognizeShape(
      _ellipse(const Rect.fromLTRB(.3, .3, .7, .7)),
    );

    expect(shape, isNotNull);
    expect(shape!.kind, InkShapeKind.ellipse);
  });

  test('an oval is recognised even when far from circular', () {
    final shape = recognizeShape(
      _ellipse(const Rect.fromLTRB(.1, .4, .9, .55)),
    );

    expect(shape?.kind, InkShapeKind.ellipse);
  });

  test('recognition does not depend on drawing direction', () {
    final forward = recognizeShape(_rectangle(const Rect.fromLTRB(.2, .2, .6, .5)));
    final reversed = recognizeShape(
      _rectangle(const Rect.fromLTRB(.2, .2, .6, .5)).reversed.toList(),
    );

    expect(forward?.kind, InkShapeKind.rectangle);
    expect(reversed?.kind, InkShapeKind.rectangle);
    expect(reversed!.start.x, closeTo(forward!.start.x, .01));
    expect(reversed.end.y, closeTo(forward.end.y, .01));
  });

  group('leaves handwriting alone', () {
    test('a scribble is not a shape', () {
      final scribble = <InkPoint>[
        for (var i = 0; i <= 60; i++)
          InkPoint(
            .3 + i / 200 + math.sin(i * .8) * .05,
            .4 + math.cos(i * 1.3) * .08,
            .5,
          ),
      ];

      expect(recognizeShape(scribble), isNull);
    });

    test('a curved open stroke is not a line', () {
      final arc = <InkPoint>[
        for (var i = 0; i <= 40; i++)
          InkPoint(
            .2 + i / 40 * .5,
            .5 - math.sin(i / 40 * math.pi) * .2,
            .5,
          ),
      ];

      expect(recognizeShape(arc), isNull);
    });

    test('a tiny tick is ignored', () {
      final tick = _line(x1: .5, y1: .5, x2: .505, y2: .508, samples: 10);

      expect(recognizeShape(tick), isNull);
    });

    test('a letter-sized downstroke stays freehand', () {
      // Hold-to-snap fires on any pause, so this size floor is what stops a
      // pause mid-word from turning the stem of an "h" into a snapped line
      // and putting the editor into shape-drag mode. Normal handwriting runs
      // about .015-.03 of page height per letter; recognition starts at .04.
      final stem = _line(x1: .3, y1: .4, x2: .302, y2: .425, samples: 20);

      expect(recognizeShape(stem), isNull);
    });

    test('too few samples are ignored', () {
      expect(
        recognizeShape(<InkPoint>[
          const InkPoint(.1, .1, .5),
          const InkPoint(.8, .8, .5),
        ]),
        isNull,
      );
    });
  });
}
