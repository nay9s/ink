import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ink_note/editor/selection_toolbar_layout.dart';

void main() {
  const viewport = Size(800, 600);
  const toolbar = Size(240, 46);

  test('selection toolbar is centered above the lasso bounds', () {
    final position = selectionToolbarPosition(
      viewportSize: viewport,
      toolbarSize: toolbar,
      anchor: const Rect.fromLTWH(300, 300, 200, 100),
      topInset: 106,
    );

    expect(position, const Offset(280, 244));
  });

  test('selection toolbar moves below a lasso near the top toolbar', () {
    final position = selectionToolbarPosition(
      viewportSize: viewport,
      toolbarSize: toolbar,
      anchor: const Rect.fromLTWH(300, 115, 200, 70),
      topInset: 106,
    );

    expect(position, const Offset(280, 195));
  });

  test('selection toolbar remains inside horizontal viewport edges', () {
    final leftPosition = selectionToolbarPosition(
      viewportSize: viewport,
      toolbarSize: toolbar,
      anchor: const Rect.fromLTWH(0, 300, 40, 80),
      topInset: 106,
    );
    final rightPosition = selectionToolbarPosition(
      viewportSize: viewport,
      toolbarSize: toolbar,
      anchor: const Rect.fromLTWH(760, 300, 40, 80),
      topInset: 106,
    );

    expect(leftPosition.dx, 8);
    expect(rightPosition.dx, 552);
  });

  test('selection toolbar stays above a lasso near the bottom controls', () {
    final position = selectionToolbarPosition(
      viewportSize: viewport,
      toolbarSize: toolbar,
      anchor: const Rect.fromLTWH(300, 540, 200, 40),
      topInset: 106,
      bottomMargin: 58,
    );

    expect(position, const Offset(280, 484));
  });

  test('selection toolbar avoids independently docked side rails', () {
    final leftPosition = selectionToolbarPosition(
      viewportSize: viewport,
      toolbarSize: toolbar,
      anchor: const Rect.fromLTWH(0, 300, 40, 80),
      leftInset: 70,
      rightInset: 120,
    );
    final rightPosition = selectionToolbarPosition(
      viewportSize: viewport,
      toolbarSize: toolbar,
      anchor: const Rect.fromLTWH(760, 300, 40, 80),
      leftInset: 70,
      rightInset: 120,
    );

    expect(leftPosition.dx, 70);
    expect(rightPosition.dx, 440);
  });
}
