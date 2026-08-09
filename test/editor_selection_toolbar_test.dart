import 'dart:ui' show PointerDeviceKind;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ink_note/editor/editor_screen.dart';
import 'package:ink_note/editor/ink_painter.dart';
import 'package:ink_note/models.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets('selection actions appear near the selected content', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    await tester.binding.setSurfaceSize(const Size(1024, 768));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final now = DateTime(2026, 8, 9);
    final document = InkDocument(
      id: 'selection-toolbar-test',
      title: 'Selection toolbar test',
      colorValue: Colors.blue.toARGB32(),
      createdAt: now,
      updatedAt: now,
      pages: [
        <InkObject>[
          InkStroke(
            tool: InkTool.pen,
            color: Colors.blue,
            width: 4,
            pressureSensitivity: 0,
            isSelected: true,
            points: const [InkPoint(.35, .3, 1), InkPoint(.65, .3, 1)],
          ),
        ],
      ],
    );

    await tester.pumpWidget(
      MaterialApp(
        home: EditorScreen(
          document: document,
          openDocuments: [document],
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

    final lasso = find.byTooltip('Lasso');
    expect(lasso, findsOneWidget);
    final primaryToolbarY = tester.getCenter(lasso).dy;
    await tester.tap(lasso);
    await tester.pumpAndSettle();

    final cut = find.byTooltip('Cut');
    expect(cut, findsOneWidget);
    // Resizing is done by dragging the selection's corner handles, so the
    // toolbar carries layer ordering instead of a redundant resize dialog.
    expect(find.byTooltip('Resize'), findsNothing);
    expect(find.byTooltip('Send to back'), findsOneWidget);
    expect(find.byTooltip('Bring to front'), findsOneWidget);
    expect(tester.getCenter(cut).dy, greaterThan(primaryToolbarY + 100));
    final actionsSize = tester.getSize(
      find.byKey(const ValueKey('selection-actions-toolbar')),
    );
    // Net one more button than before (resize out, two layer actions in).
    expect(actionsSize.width, lessThan(320));
    expect(actionsSize.height, lessThan(60));

    await tester.tap(cut);
    await tester.pumpAndSettle();
    expect(find.byTooltip('Cut'), findsNothing);
    expect(find.byTooltip('Paste'), findsOneWidget);
  });

  testWidgets('a finger selects an image and resizes it from a corner', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    await tester.binding.setSurfaceSize(const Size(1024, 768));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final now = DateTime(2026, 8, 9);
    final document = InkDocument(
      id: 'finger-image-resize-test',
      title: 'Finger image resize test',
      colorValue: Colors.blue.toARGB32(),
      createdAt: now,
      updatedAt: now,
      pages: [
        <InkObject>[
          InkImage(
            path: 'missing-test-image.png',
            x: .3,
            y: .15,
            width: .2,
            height: .12,
          ),
        ],
      ],
    );
    await tester.pumpWidget(
      MaterialApp(
        home: EditorScreen(
          document: document,
          openDocuments: [document],
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
    final imageCenter = Offset(
      canvasRect.left + canvasRect.width * .4,
      canvasRect.top + canvasRect.height * .21,
    );

    await tester.tapAt(imageCenter);
    await tester.pumpAndSettle();
    expect(find.byTooltip('Cut'), findsOneWidget);

    final resizeStart = Offset(
      canvasRect.left + canvasRect.width * .5 + 12,
      canvasRect.top + canvasRect.height * .27 + 12,
    );
    final gesture = await tester.startGesture(resizeStart);
    await gesture.moveBy(const Offset(90, 60));
    await tester.pump();
    await gesture.up();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpAndSettle();

    final painter = tester.widget<CustomPaint>(canvas).painter! as InkPainter;
    final resized = painter.strokes.single as InkImage;
    expect(resized.width, greaterThan(.2));
    expect(resized.height, greaterThan(.12));
    expect(resized.width / resized.height, closeTo(5 / 3, .001));
  });

  testWidgets('lasso selection resizes the selected ink from a corner', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    await tester.binding.setSurfaceSize(const Size(1024, 768));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final now = DateTime(2026, 8, 9);
    final document = InkDocument(
      id: 'lasso-resize-test',
      title: 'Lasso resize test',
      colorValue: Colors.blue.toARGB32(),
      createdAt: now,
      updatedAt: now,
      pages: [
        <InkObject>[
          InkStroke(
            tool: InkTool.pen,
            color: Colors.blue,
            width: 4,
            pressureSensitivity: 0,
            points: const [InkPoint(.4, .26, 1), InkPoint(.5, .31, 1)],
          ),
        ],
      ],
    );

    await tester.pumpWidget(
      MaterialApp(
        home: EditorScreen(
          document: document,
          openDocuments: [document],
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
    await tester.tap(find.byTooltip('Lasso'));
    await tester.pumpAndSettle();

    final canvas = find.byKey(const ValueKey('ink-canvas-0'));
    final canvasRect = tester.getRect(canvas);
    Offset pagePoint(double x, double y) => Offset(
      canvasRect.left + canvasRect.width * x,
      canvasRect.top + canvasRect.height * y,
    );

    final lasso = await tester.startGesture(
      pagePoint(.32, .2),
      kind: PointerDeviceKind.stylus,
    );
    for (final point in <Offset>[
      pagePoint(.62, .2),
      pagePoint(.62, .4),
      pagePoint(.32, .4),
      pagePoint(.32, .2),
    ]) {
      await lasso.moveTo(point);
      await tester.pump();
    }
    await lasso.up();
    await tester.pumpAndSettle();
    expect(find.byTooltip('Cut'), findsOneWidget);

    final resize = await tester.startGesture(
      pagePoint(.62, .4),
      kind: PointerDeviceKind.stylus,
    );
    await resize.moveBy(const Offset(100, 65));
    await tester.pump();
    await resize.up();
    await tester.pumpAndSettle();

    final painter = tester.widget<CustomPaint>(canvas).painter! as InkPainter;
    final resizedStroke = painter.strokes.single as InkStroke;
    expect(resizedStroke.width, greaterThan(4));
    expect(resizedStroke.points.last.x, greaterThan(.5));
    expect(resizedStroke.points.last.y, greaterThan(.31));
  });

  testWidgets('layer actions move the selected image behind and in front', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    await tester.binding.setSurfaceSize(const Size(1024, 768));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final now = DateTime(2026, 8, 9);
    // Objects paint in list order, so the image starting last is in front.
    final document = InkDocument(
      id: 'layer-order-test',
      title: 'Layer order test',
      colorValue: Colors.blue.toARGB32(),
      createdAt: now,
      updatedAt: now,
      pages: [
        <InkObject>[
          InkStroke(
            tool: InkTool.pen,
            color: Colors.blue,
            width: 4,
            pressureSensitivity: 0,
            points: const [InkPoint(.1, .6, 1), InkPoint(.2, .65, 1)],
          ),
          InkImage(
            path: 'missing-test-image.png',
            x: .3,
            y: .15,
            width: .2,
            height: .12,
          ),
        ],
      ],
    );
    await tester.pumpWidget(
      MaterialApp(
        home: EditorScreen(
          document: document,
          openDocuments: [document],
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
    await tester.tapAt(
      Offset(
        canvasRect.left + canvasRect.width * .4,
        canvasRect.top + canvasRect.height * .21,
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byTooltip('Send to back'), findsOneWidget);

    List<InkObject> objectsNow() =>
        (tester.widget<CustomPaint>(canvas).painter! as InkPainter).strokes;

    expect(objectsNow().last, isA<InkImage>());

    await tester.tap(find.byTooltip('Send to back'));
    await tester.pumpAndSettle();
    expect(objectsNow().first, isA<InkImage>());
    expect(objectsNow().last, isA<InkStroke>());

    await tester.tap(find.byTooltip('Bring to front'));
    await tester.pumpAndSettle();
    expect(objectsNow().last, isA<InkImage>());
    expect(objectsNow().first, isA<InkStroke>());
  });
}
