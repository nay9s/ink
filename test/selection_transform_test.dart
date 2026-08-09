import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ink_note/editor/selection_transform.dart';
import 'package:ink_note/models.dart';

void main() {
  test('corner hit testing uses a finger-friendly target', () {
    const bounds = Rect.fromLTWH(100, 120, 200, 160);

    expect(
      hitTestSelectionResizeHandle(
        const Offset(315, 292),
        bounds,
        hitRadius: 24,
      ),
      SelectionResizeHandle.bottomRight,
    );
    expect(
      hitTestSelectionResizeHandle(const Offset(200, 200), bounds),
      isNull,
    );
  });

  test('resize scale follows the dragged corner and stays on the page', () {
    const bounds = Rect.fromLTWH(.2, .2, .3, .2);
    final enlarged = selectionUniformScaleForDrag(
      initialBounds: bounds,
      handle: SelectionResizeHandle.bottomRight,
      startPointer: bounds.bottomRight,
      currentPointer: const Offset(.8, .6),
    );
    final clamped = selectionUniformScaleForDrag(
      initialBounds: bounds,
      handle: SelectionResizeHandle.bottomRight,
      startPointer: bounds.bottomRight,
      currentPointer: const Offset(2, 2),
    );

    expect(enlarged, greaterThan(1));
    expect(clamped, closeTo(8 / 3, .0001));
  });

  test('image resizing preserves aspect ratio around the opposite corner', () {
    final image = InkImage(
      path: 'image.png',
      x: .2,
      y: .25,
      width: .3,
      height: .2,
      isSelected: true,
    );

    final resized =
        scaleSelectionObject(image, anchor: const Offset(.2, .25), scale: 1.5)
            as InkImage;

    expect(resized.x, .2);
    expect(resized.y, .25);
    expect(resized.width, closeTo(.45, 1e-9));
    expect(resized.height, closeTo(.3, 1e-9));
    expect(resized.width / resized.height, closeTo(1.5, 1e-9));
  });

  test('lasso group scales stroke coordinates and stroke width together', () {
    final stroke = InkStroke(
      tool: InkTool.pen,
      color: Colors.black,
      width: 2,
      isSelected: true,
      points: const [InkPoint(.3, .3, .5), InkPoint(.4, .5, .5)],
    );

    final resized =
        scaleSelectionObject(stroke, anchor: const Offset(.2, .2), scale: 2)
            as InkStroke;

    expect(resized.points.first.x, closeTo(.4, 1e-9));
    expect(resized.points.first.y, closeTo(.4, 1e-9));
    expect(resized.points.last.x, closeTo(.6, 1e-9));
    expect(resized.points.last.y, closeTo(.8, 1e-9));
    expect(resized.width, 4);
  });
}
