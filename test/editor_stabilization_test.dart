import 'dart:ui' show PointerDeviceKind;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ink_note/editor/editor_screen.dart';
import 'package:ink_note/editor/ink_painter.dart';
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
