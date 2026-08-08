import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ink_note/editor/toolbar.dart';
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
}

FloatingEditorToolbar _buildToolbar({
  ValueChanged<InkTool>? onTool,
  FloatingToolbarSection section = FloatingToolbarSection.both,
  Axis axis = Axis.horizontal,
}) => FloatingEditorToolbar(
  tool: InkTool.pen,
  color: Colors.black,
  width: 2,
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
);
