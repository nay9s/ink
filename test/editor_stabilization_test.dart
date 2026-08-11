import 'dart:math' as math;
import 'dart:ui' show PointerDeviceKind;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ink_note/editor/editor_screen.dart';
import 'package:ink_note/editor/ink_painter.dart';
import 'package:ink_note/editor/stroke_geometry.dart';
import 'package:ink_note/models.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets(
    'live stabilized ink keeps the exact Pencil tip through lift-off',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      await tester.binding.setSurfaceSize(const Size(1024, 768));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final now = DateTime(2026, 8, 9);
      final document = InkDocument(
        id: 'stabilization-tip-test',
        title: 'Stabilization tip test',
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

      final canvas = find.byKey(const ValueKey('ink-canvas-0'));
      expect(canvas, findsOneWidget);
      final canvasRect = tester.getRect(canvas);
      Offset pagePoint(double x, double y) => Offset(
        canvasRect.left + canvasRect.width * x,
        canvasRect.top + canvasRect.height * y,
      );

      final gesture = await tester.startGesture(
        pagePoint(.2, .32),
        kind: PointerDeviceKind.stylus,
      );
      final firstTip = pagePoint(.54, .39);
      await gesture.moveTo(firstTip);
      await tester.pump(const Duration(milliseconds: 8));
      _expectActiveTipAt(tester, canvas, canvasRect, firstTip);

      final finalTip = pagePoint(.72, .46);
      await gesture.moveTo(finalTip);
      await tester.pump(const Duration(milliseconds: 8));
      final liveStroke = _activeStroke(tester, canvas);
      _expectTipAt(liveStroke, canvasRect, finalTip);
      final visiblePoints = List<InkPoint>.of(liveStroke.points);

      await gesture.up();
      await tester.pump(const Duration(milliseconds: 20));

      final painter = tester.widget<CustomPaint>(canvas).painter! as InkPainter;
      final committed = painter.strokes.single as InkStroke;
      expect(committed.geometryVersion, 2);
      expect(committed.points.length, visiblePoints.length);
      for (var index = 0; index < visiblePoints.length; index++) {
        expect(committed.points[index].x, visiblePoints[index].x);
        expect(committed.points[index].y, visiblePoints[index].y);
        expect(committed.points[index].pressure, visiblePoints[index].pressure);
      }
      _expectTipAt(committed, canvasRect, finalTip);
    },
  );

  testWidgets('Pencil lift refines remaining facets without moving endpoints', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    await tester.binding.setSurfaceSize(const Size(1024, 768));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final now = DateTime(2026, 8, 11);
    final document = InkDocument(
      id: 'completed-stroke-fit-test',
      title: 'Completed stroke fit test',
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

    final canvas = find.byKey(const ValueKey('ink-canvas-0'));
    final canvasRect = tester.getRect(canvas);
    Offset pagePoint(double x, double y) => Offset(
      canvasRect.left + canvasRect.width * x,
      canvasRect.top + canvasRect.height * y,
    );

    final start = pagePoint(.18, .48);
    final gesture = await tester.startGesture(
      start,
      kind: PointerDeviceKind.stylus,
    );
    Offset finalTip = start;
    for (var index = 1; index <= 42; index++) {
      finalTip = pagePoint(
        .18 + index * .012,
        .48 + (index.isEven ? 1.1 : -1.1) / canvasRect.height,
      );
      await gesture.moveTo(finalTip);
      await tester.pump(const Duration(milliseconds: 8));
    }

    final live = _activeStroke(tester, canvas);
    final liveTurn = _p95TangentTurn(live, canvasRect.size);
    _expectTipAt(live, canvasRect, finalTip);

    await gesture.up();
    await tester.pump(const Duration(milliseconds: 20));

    final painter = tester.widget<CustomPaint>(canvas).painter! as InkPainter;
    final committed = painter.strokes.single as InkStroke;
    _expectTipAt(committed, canvasRect, finalTip);
    expect(committed.points.first, live.points.first);
    expect(committed.points.last, live.points.last);
    expect(committed.points, isNot(orderedEquals(live.points)));
    expect(
      _p95TangentTurn(committed, canvasRect.size),
      lessThan(liveTurn * .82),
    );
  });
}

InkStroke _activeStroke(WidgetTester tester, Finder canvas) {
  final painter = tester.widget<CustomPaint>(canvas).painter! as InkPainter;
  return painter.activeStroke! as InkStroke;
}

void _expectActiveTipAt(
  WidgetTester tester,
  Finder canvas,
  Rect canvasRect,
  Offset expected,
) {
  _expectTipAt(_activeStroke(tester, canvas), canvasRect, expected);
}

void _expectTipAt(InkStroke stroke, Rect canvasRect, Offset expected) {
  final actual = Offset(
    canvasRect.left + stroke.points.last.x * canvasRect.width,
    canvasRect.top + stroke.points.last.y * canvasRect.height,
  );
  expect((actual - expected).distance, lessThan(.2));
}

double _p95TangentTurn(InkStroke stroke, Size size) {
  final rendered = sampleSmoothStrokeCurve(
    stroke.points
        .map(
          (point) => StrokeGeometrySample(
            Offset(point.x * size.width, point.y * size.height),
            point.pressure,
          ),
        )
        .toList(growable: false),
    maximumSegmentLength: .5,
  );
  final turns = <double>[];
  for (var index = 1; index < rendered.length - 1; index++) {
    final before = rendered[index].offset - rendered[index - 1].offset;
    final after = rendered[index + 1].offset - rendered[index].offset;
    if (before.distanceSquared < 1e-9 || after.distanceSquared < 1e-9) continue;
    final cosine =
        (before.dx * after.dx + before.dy * after.dy) /
        (before.distance * after.distance);
    turns.add(math.acos(cosine.clamp(-1.0, 1.0)));
  }
  turns.sort();
  return turns[(turns.length * .95).floor()];
}
