import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ink_note/editor/toolbar_docking.dart';
import 'package:ink_note/models.dart';

void main() {
  const viewport = Size(1000, 700);
  const primary = ToolbarPlacement(dock: ToolbarDock.top, order: 0);
  const options = ToolbarPlacement(dock: ToolbarDock.top, order: 1);

  test('nearest edge resolves all four docking sides', () {
    expect(nearestToolbarDock(const Offset(500, 8), viewport), ToolbarDock.top);
    expect(
      nearestToolbarDock(const Offset(8, 350), viewport),
      ToolbarDock.left,
    );
    expect(
      nearestToolbarDock(const Offset(992, 350), viewport),
      ToolbarDock.right,
    );
    expect(
      nearestToolbarDock(const Offset(500, 692), viewport),
      ToolbarDock.bottom,
    );
  });

  test('moving Primary is independent and Options slides to the top edge', () {
    final result = resolveToolbarDrop(
      dragged: EditorToolbarKind.primary,
      position: const Offset(10, 350),
      viewport: viewport,
      primary: primary,
      options: options,
    );

    expect(result.primary.dock, ToolbarDock.left);
    expect(result.primary.order, 0);
    expect(result.options.dock, ToolbarDock.top);
    expect(result.options.order, 0);
  });

  test('two toolbars on the same edge can swap outer and inner order', () {
    const primaryLeft = ToolbarPlacement(dock: ToolbarDock.left, order: 0);
    const optionsLeft = ToolbarPlacement(dock: ToolbarDock.left, order: 1);

    final optionsOutside = resolveToolbarDrop(
      dragged: EditorToolbarKind.options,
      position: const Offset(12, 350),
      viewport: viewport,
      primary: primaryLeft,
      options: optionsLeft,
    );
    expect(optionsOutside.options.order, 0);
    expect(optionsOutside.primary.order, 1);

    final primaryInside = resolveToolbarDrop(
      dragged: EditorToolbarKind.primary,
      position: const Offset(120, 350),
      viewport: viewport,
      primary: primaryLeft,
      options: optionsLeft,
    );
    expect(primaryInside.options.order, 0);
    expect(primaryInside.primary.order, 1);
  });

  test('bottom docking respects space reserved for compact page controls', () {
    const insets = EdgeInsets.only(bottom: 60);
    expect(
      nearestToolbarDock(
        const Offset(500, 635),
        viewport,
        reservedInsets: insets,
      ),
      ToolbarDock.bottom,
    );
    expect(
      toolbarDistanceFromEdge(
        const Offset(500, 635),
        viewport,
        ToolbarDock.bottom,
        reservedInsets: insets,
      ),
      5,
    );
  });

  test('invalid or legacy orders normalize without overlapping slots', () {
    final separateEdges = normalizeToolbarDocking(
      primary: const ToolbarPlacement(dock: ToolbarDock.left, order: 1),
      options: const ToolbarPlacement(dock: ToolbarDock.top, order: 1),
    );
    expect(separateEdges.primary.order, 0);
    expect(separateEdges.options.order, 0);

    final sameSlot = normalizeToolbarDocking(
      primary: const ToolbarPlacement(dock: ToolbarDock.right, order: 1),
      options: const ToolbarPlacement(dock: ToolbarDock.right, order: 1),
    );
    expect(sameSlot.primary.order, 0);
    expect(sameSlot.options.order, 1);
  });

  test('toolbar placements persist in editor view state', () {
    const state = EditorViewState(
      primaryToolbarDock: ToolbarDock.right,
      primaryToolbarOrder: 1,
      optionsToolbarDock: ToolbarDock.bottom,
      optionsToolbarOrder: 0,
    );

    final restored = EditorViewState.fromJson(
      Map<String, dynamic>.from(state.toJson()),
    );
    expect(restored.primaryToolbarDock, ToolbarDock.right);
    expect(restored.primaryToolbarOrder, 1);
    expect(restored.optionsToolbarDock, ToolbarDock.bottom);
    expect(restored.optionsToolbarOrder, 0);

    final legacy = EditorViewState.fromJson(const <String, dynamic>{});
    expect(legacy.primaryToolbarDock, ToolbarDock.top);
    expect(legacy.primaryToolbarOrder, 0);
    expect(legacy.optionsToolbarDock, ToolbarDock.top);
    expect(legacy.optionsToolbarOrder, 1);
  });

  testWidgets('one drag gesture docks a toolbar independently', (tester) async {
    var currentPrimary = primary;
    var currentOptions = options;
    ToolbarDockingResult? changed;

    Widget toolbarBuilder(
      EditorToolbarKind kind,
      Axis axis,
      ToolbarDragCallbacks callbacks,
    ) => GestureDetector(
      key: callbacks.enabled ? ValueKey('${kind.name}-test-handle') : null,
      behavior: HitTestBehavior.opaque,
      onPanStart: callbacks.onStart == null
          ? null
          : (details) => callbacks.onStart!(details.globalPosition),
      onPanUpdate: callbacks.onUpdate == null
          ? null
          : (details) => callbacks.onUpdate!(details.globalPosition),
      onPanEnd: callbacks.onEnd == null ? null : (_) => callbacks.onEnd!(),
      onPanCancel: callbacks.onCancel,
      child: SizedBox(
        width: axis == Axis.horizontal ? 150 : 44,
        height: axis == Axis.horizontal ? 44 : 150,
        child: ColoredBox(
          color: kind == EditorToolbarKind.primary ? Colors.blue : Colors.grey,
        ),
      ),
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, setHarnessState) => DockableEditorToolbars(
              primary: currentPrimary,
              options: currentOptions,
              primaryBuilder: (context, axis, callbacks) =>
                  toolbarBuilder(EditorToolbarKind.primary, axis, callbacks),
              optionsBuilder: (context, axis, callbacks) =>
                  toolbarBuilder(EditorToolbarKind.options, axis, callbacks),
              onChanged: (result) {
                changed = result;
                setHarnessState(() {
                  currentPrimary = result.primary;
                  currentOptions = result.options;
                });
              },
            ),
          ),
        ),
      ),
    );

    final handle = find.byKey(const ValueKey('primary-test-handle'));
    final gesture = await tester.startGesture(tester.getCenter(handle));
    await gesture.moveTo(const Offset(12, 300));
    await tester.pump();
    await gesture.up();
    await tester.pumpAndSettle();

    expect(changed, isNotNull);
    expect(changed!.primary.dock, ToolbarDock.left);
    expect(changed!.primary.order, 0);
    expect(changed!.options.dock, ToolbarDock.top);
    expect(changed!.options.order, 0);

    final primarySize = tester.getSize(
      find.byKey(const ValueKey('primary-toolbar')),
    );
    expect(primarySize.height, greaterThan(primarySize.width));
    expect(
      tester.getCenter(find.byKey(const ValueKey('options-toolbar'))).dy,
      lessThan(60),
    );
  });
}
