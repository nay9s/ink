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
