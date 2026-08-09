import 'dart:math' as math;
import 'dart:ui' show PointerDeviceKind;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ink_note/editor/editor_screen.dart';
import 'package:ink_note/editor/ink_painter.dart';
import 'package:ink_note/models.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  Future<Rect> pumpEditor(WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(1024, 768));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final now = DateTime(2026, 8, 9);
    final document = InkDocument(
      id: 'hold-to-snap-test',
      title: 'Hold to snap test',
      colorValue: Colors.blue.toARGB32(),
      createdAt: now,
      updatedAt: now,
      pages: const <List<InkObject>>[<InkObject>[]],
    );
    await tester.pumpWidget(
      MaterialApp(
        home: EditorScreen(
          document: document,
          openDocuments: <InkDocument>[document],
          activeDocumentId: document.id,
          onSelectTab: (_) {},
          onCloseTab: (_) {},
          onNewTab: () {},
          onExit: () {},
          onDocumentSaved: (_) {},
        ),
      ),
    );
    await tester.pumpAndSettle();
    return tester.getRect(find.byKey(const ValueKey('ink-canvas-0')));
  }

  InkStroke? activeStroke(WidgetTester tester) {
    final painter =
        tester.widget<CustomPaint>(
              find.byKey(const ValueKey('ink-canvas-0')),
            ).painter!
            as InkPainter;
    return painter.activeStroke as InkStroke?;
  }

  /// Holds the pen "still" the way real hardware does: samples keep arriving
  /// with sub-pixel jitter rather than stopping.
  Future<void> holdStill(
    WidgetTester tester,
    TestGesture gesture,
    Offset at, {
    required Duration total,
  }) async {
    const step = Duration(milliseconds: 8);
    final ticks = total.inMilliseconds ~/ step.inMilliseconds;
    for (var i = 0; i < ticks; i++) {
      await gesture.moveTo(
        at + Offset(math.sin(i * 1.3) * .4, math.cos(i * 1.1) * .4),
      );
      await tester.pump(step);
    }
  }

  /// Drags in a straight run of samples far enough apart that each one counts
  /// as real movement, so the hold countdown keeps restarting while drawing.
  Future<void> dragTo(
    WidgetTester tester,
    TestGesture gesture,
    Offset from,
    Offset to, {
    int steps = 20,
  }) async {
    for (var i = 1; i <= steps; i++) {
      await gesture.moveTo(Offset.lerp(from, to, i / steps)!);
      await tester.pump(const Duration(milliseconds: 8));
    }
  }

  Rect strokeBounds(InkStroke stroke) {
    var bounds = Rect.fromPoints(
      Offset(stroke.points.first.x, stroke.points.first.y),
      Offset(stroke.points.first.x, stroke.points.first.y),
    );
    for (final point in stroke.points) {
      bounds = bounds.expandToInclude(
        Rect.fromPoints(Offset(point.x, point.y), Offset(point.x, point.y)),
      );
    }
    return bounds;
  }

  testWidgets('holding still after a drag snaps the stroke to a line', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final canvas = await pumpEditor(tester);
    Offset at(double x, double y) => Offset(
      canvas.left + canvas.width * x,
      canvas.top + canvas.height * y,
    );

    final gesture = await tester.startGesture(
      at(.2, .32),
      kind: PointerDeviceKind.stylus,
    );
    for (var i = 1; i <= 12; i++) {
      await gesture.moveTo(at(.2 + i * .04, .32 + i * .012));
      await tester.pump(const Duration(milliseconds: 8));
    }
    expect(activeStroke(tester)!.shapeKind, InkShapeKind.none);

    // A held Pencil never stops emitting samples, so the countdown has to
    // survive that jitter.
    await holdStill(
      tester,
      gesture,
      at(.68, .464),
      total: const Duration(milliseconds: 1400),
    );

    final snapped = activeStroke(tester)!;
    expect(snapped.shapeKind, InkShapeKind.line);
    expect(snapped.points.length, 2);

    // The line can still be extended after snapping.
    await gesture.moveTo(at(.85, .53));
    await tester.pump(const Duration(milliseconds: 8));
    final extended = activeStroke(tester)!;
    expect(extended.shapeKind, InkShapeKind.line);
    expect(extended.points.last.x, greaterThan(snapped.points.last.x));

    await gesture.up();
    await tester.pump(const Duration(milliseconds: 30));
  });

  /// The corners a rectangle is drawn through, anticlockwise from the top
  /// left and back to it — the order reported as broken, where the pen ends
  /// up at the corner it started from rather than at the bottom right.
  const cornerTour = <Offset>[
    Offset(.25, .22),
    Offset(.25, .62),
    Offset(.7, .62),
    Offset(.7, .22),
    Offset(.25, .22),
  ];

  testWidgets('a box drawn back to its first corner snaps to the whole box', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final canvas = await pumpEditor(tester);
    Offset at(Offset fraction) => Offset(
      canvas.left + canvas.width * fraction.dx,
      canvas.top + canvas.height * fraction.dy,
    );

    final gesture = await tester.startGesture(
      at(cornerTour.first),
      kind: PointerDeviceKind.stylus,
    );
    for (var i = 1; i < cornerTour.length; i++) {
      await dragTo(tester, gesture, at(cornerTour[i - 1]), at(cornerTour[i]));
    }

    await holdStill(
      tester,
      gesture,
      at(cornerTour.last),
      total: const Duration(milliseconds: 700),
    );

    final snapped = activeStroke(tester)!;
    expect(snapped.shapeKind, InkShapeKind.rectangle);

    // The pen finished back at the top-left corner. Dragging the *opposite*
    // corner onto it collapsed the box into a speck there, so the snapped
    // shape has to still cover what was drawn.
    final bounds = strokeBounds(snapped);
    expect(bounds.left, closeTo(.25, .03));
    expect(bounds.top, closeTo(.22, .03));
    expect(bounds.right, closeTo(.7, .03));
    expect(bounds.bottom, closeTo(.62, .03));

    await gesture.up();
    await tester.pump(const Duration(milliseconds: 30));
  });

  testWidgets('a snapped box resizes from the corner the pen is on', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final canvas = await pumpEditor(tester);
    Offset at(Offset fraction) => Offset(
      canvas.left + canvas.width * fraction.dx,
      canvas.top + canvas.height * fraction.dy,
    );

    final gesture = await tester.startGesture(
      at(cornerTour.first),
      kind: PointerDeviceKind.stylus,
    );
    for (var i = 1; i < cornerTour.length; i++) {
      await dragTo(tester, gesture, at(cornerTour[i - 1]), at(cornerTour[i]));
    }
    await holdStill(
      tester,
      gesture,
      at(cornerTour.last),
      total: const Duration(milliseconds: 700),
    );
    expect(activeStroke(tester)!.shapeKind, InkShapeKind.rectangle);

    // Pull the held corner up and left; the far corner must stay put.
    await dragTo(
      tester,
      gesture,
      at(cornerTour.last),
      at(const Offset(.12, .1)),
    );

    final bounds = strokeBounds(activeStroke(tester)!);
    expect(bounds.left, closeTo(.12, .03));
    expect(bounds.top, closeTo(.1, .03));
    expect(bounds.right, closeTo(.7, .03));
    expect(bounds.bottom, closeTo(.62, .03));

    await gesture.up();
    await tester.pump(const Duration(milliseconds: 30));
  });

  testWidgets('a circle drawn back to its start snaps to the whole circle', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final canvas = await pumpEditor(tester);
    Offset at(Offset fraction) => Offset(
      canvas.left + canvas.width * fraction.dx,
      canvas.top + canvas.height * fraction.dy,
    );

    const center = Offset(.45, .42);
    const radius = Offset(.18, .18);
    Offset onCircle(double turn) => Offset(
      center.dx + math.cos(turn * 2 * math.pi) * radius.dx,
      center.dy + math.sin(turn * 2 * math.pi) * radius.dy,
    );

    final gesture = await tester.startGesture(
      at(onCircle(0)),
      kind: PointerDeviceKind.stylus,
    );
    for (var i = 1; i <= 48; i++) {
      await gesture.moveTo(at(onCircle(i / 48)));
      await tester.pump(const Duration(milliseconds: 8));
    }

    await holdStill(
      tester,
      gesture,
      at(onCircle(1)),
      total: const Duration(milliseconds: 700),
    );

    final snapped = activeStroke(tester)!;
    expect(snapped.shapeKind, InkShapeKind.ellipse);

    final bounds = strokeBounds(snapped);
    expect(bounds.left, closeTo(center.dx - radius.dx, .03));
    expect(bounds.right, closeTo(center.dx + radius.dx, .03));
    expect(bounds.top, closeTo(center.dy - radius.dy, .03));
    expect(bounds.bottom, closeTo(center.dy + radius.dy, .03));

    await gesture.up();
    await tester.pump(const Duration(milliseconds: 30));
  });

  testWidgets('holding for half a second is enough to snap', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final canvas = await pumpEditor(tester);
    Offset at(double x, double y) => Offset(
      canvas.left + canvas.width * x,
      canvas.top + canvas.height * y,
    );

    final gesture = await tester.startGesture(
      at(.2, .32),
      kind: PointerDeviceKind.stylus,
    );
    await dragTo(tester, gesture, at(.2, .32), at(.68, .464));
    expect(activeStroke(tester)!.shapeKind, InkShapeKind.none);

    await holdStill(
      tester,
      gesture,
      at(.68, .464),
      total: const Duration(milliseconds: 560),
    );

    expect(activeStroke(tester)!.shapeKind, InkShapeKind.line);

    await gesture.up();
    await tester.pump(const Duration(milliseconds: 30));
  });

  testWidgets('continuous drawing never snaps mid-stroke', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final canvas = await pumpEditor(tester);
    Offset at(double x, double y) => Offset(
      canvas.left + canvas.width * x,
      canvas.top + canvas.height * y,
    );

    final gesture = await tester.startGesture(
      at(.15, .3),
      kind: PointerDeviceKind.stylus,
    );
    // Slow but genuine movement for well over the hold timeout.
    for (var i = 1; i <= 160; i++) {
      await gesture.moveTo(at(.15 + i * .004, .3 + math.sin(i * .12) * .05));
      await tester.pump(const Duration(milliseconds: 12));
    }

    expect(activeStroke(tester)!.shapeKind, InkShapeKind.none);
    await gesture.up();
    await tester.pump(const Duration(milliseconds: 30));
  });
}
