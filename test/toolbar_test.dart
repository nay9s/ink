import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ink_note/editor/toolbar.dart';
import 'package:ink_note/editor/toolbar_docking.dart';
import 'package:ink_note/models.dart';

void main() {
  testWidgets('highlighter has its own enlarged primary tool button', (
    tester,
  ) async {
    InkTool? selectedTool;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Align(
            alignment: Alignment.topCenter,
            child: _buildToolbar(onTool: (tool) => selectedTool = tool),
          ),
        ),
      ),
    );

    final highlighter = find.byTooltip('Highlighter');
    expect(highlighter, findsOneWidget);

    final highlighterInkWell = find
        .ancestor(
          of: find.byIcon(Icons.border_color_outlined),
          matching: find.byType(InkWell),
        )
        .first;
    final hitTarget = tester.getSize(highlighterInkWell);
    expect(hitTarget.width, greaterThanOrEqualTo(42));
    expect(hitTarget.height, greaterThanOrEqualTo(40));

    await tester.tap(highlighter);
    expect(selectedTool, InkTool.highlighter);
  });

  testWidgets('each toolbar section supports a compact vertical rail', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _buildToolbar(
                section: FloatingToolbarSection.primary,
                axis: Axis.vertical,
              ),
              _buildToolbar(
                section: FloatingToolbarSection.options,
                axis: Axis.vertical,
              ),
            ],
          ),
        ),
      ),
    );

    expect(tester.takeException(), isNull);
    expect(find.byTooltip('Pen'), findsOneWidget);
    expect(find.byTooltip('Add size preset'), findsOneWidget);
    expect(find.byType(FloatingEditorToolbar), findsNWidgets(2));
  });

  testWidgets('toolbar grip starts moving with one drag gesture', (
    tester,
  ) async {
    var starts = 0;
    var updates = 0;
    var ends = 0;
    final callbacks = ToolbarDragCallbacks(
      onStart: (_) => starts++,
      onUpdate: (_) => updates++,
      onEnd: () => ends++,
      onCancel: () {},
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Align(
            alignment: Alignment.topCenter,
            child: _buildToolbar(
              section: FloatingToolbarSection.primary,
              dragCallbacks: callbacks,
            ),
          ),
        ),
      ),
    );

    final handle = find.byKey(const ValueKey('primary-toolbar-drag-handle'));
    final gesture = await tester.startGesture(tester.getCenter(handle));
    await gesture.moveBy(const Offset(40, 0));
    await tester.pump();

    expect(starts, 1);

    await gesture.moveBy(const Offset(20, 0));
    await tester.pump();
    expect(updates, greaterThan(0));

    await gesture.up();
    await tester.pump();
    expect(ends, 1);
  });

  testWidgets('every tool keeps a full-width options rail on the sides', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1024, 768);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final callbacks = ToolbarDragCallbacks(
      onStart: (_) {},
      onUpdate: (_) {},
      onEnd: () {},
      onCancel: () {},
    );
    for (final tool in InkTool.values) {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Align(
              alignment: Alignment.centerRight,
              child: _buildToolbar(
                tool: tool,
                width: tool == InkTool.eraser ? 28 : 2,
                section: FloatingToolbarSection.options,
                axis: Axis.vertical,
                dragCallbacks: callbacks,
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      expect(tester.takeException(), isNull, reason: '${tool.name} overflowed');
      final toolbarSize = tester.getSize(find.byType(FloatingEditorToolbar));
      expect(
        toolbarSize.width,
        inInclusiveRange(56, 64),
        reason: '${tool.name} rail was squeezed',
      );
      expect(
        tester
            .getSize(find.byKey(const ValueKey('options-toolbar-drag-handle')))
            .width,
        greaterThanOrEqualTo(44),
        reason: '${tool.name} drag handle was squeezed',
      );
    }
  });
}

FloatingEditorToolbar _buildToolbar({
  ValueChanged<InkTool>? onTool,
  InkTool tool = InkTool.pen,
  double width = 2,
  FloatingToolbarSection section = FloatingToolbarSection.both,
  Axis axis = Axis.horizontal,
  ToolbarDragCallbacks dragCallbacks = const ToolbarDragCallbacks(),
}) => FloatingEditorToolbar(
  tool: tool,
  color: Colors.black,
  width: width,
  canUndo: false,
  canRedo: false,
  onTool: onTool ?? (_) {},
  onColor: (_) {},
  onOpenColorPalette: () {},
  paletteColors: const [Colors.black],
  onWidth: (_) {},
  eraserMode: EraserMode.precision,
  onEraserModeChanged: (_) {},
  eraseHighlighterOnly: false,
  onEraseHighlighterOnlyChanged: (_) {},
  eraserAutoDeselect: false,
  onEraserAutoDeselectChanged: (_) {},
  onPenTap: () {},
  onPenSettings: () {},
  onUndo: () {},
  onRedo: () {},
  onToggleZoomMode: () {},
  zoomMode: false,
  presets: const [PenPreset(size: 2, smoothing: .45)],
  highlighterPresets: const [PenPreset(size: 14, smoothing: .45)],
  onWidthPresetTap: (_) {},
  onAddWidthPreset: () {},
  onZoomIn: () {},
  onZoomOut: () {},
  onResetZoom: () {},
  dashed: false,
  onDashedChanged: (_) {},
  textSize: 20,
  onTextSizeChanged: (_) {},
  textBold: false,
  onTextBoldChanged: (_) {},
  textItalic: false,
  onTextItalicChanged: (_) {},
  textAlign: TextAlign.left,
  onTextAlignChanged: (_) {},
  lineHeight: 1.2,
  onLineHeightChanged: (_) {},
  onAddImage: () {},
  section: section,
  axis: axis,
  dragCallbacks: dragCallbacks,
);
