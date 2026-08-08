import 'package:flutter_test/flutter_test.dart';
import 'package:ink_note/editor/eraser_geometry.dart';

void main() {
  test('canvas-space viewer keeps cursor and hit radius aligned', () {
    final geometry = EraserGeometry(
      screenDiameter: 28,
      canvasToScreenScale: 4,
      hitTestInScreenSpace: false,
    );

    expect(geometry.canvasDiameter, 7);
    expect(geometry.canvasBorderWidth, .375);
    expect(geometry.canvasDiameter * 4, 28);
    expect(geometry.hitRadius, 3.5);
    expect(geometry.hitTestStrokeScale, 1);
  });

  test('pdfrx cursor stays aligned with screen-space eraser after zoom', () {
    final geometry = EraserGeometry(
      screenDiameter: 28,
      canvasToScreenScale: 2.5,
      hitTestInScreenSpace: true,
    );

    expect(geometry.canvasDiameter, closeTo(11.2, .0001));
    expect(geometry.canvasBorderWidth, closeTo(.6, .0001));
    expect(geometry.canvasDiameter * 2.5, closeTo(28, .0001));
    expect(geometry.hitRadius, 14);
    expect(geometry.hitTestStrokeScale, 2.5);
  });

  test('invalid scale falls back safely', () {
    final geometry = EraserGeometry(
      screenDiameter: 16,
      canvasToScreenScale: 0,
      hitTestInScreenSpace: true,
    );

    expect(geometry.canvasDiameter, 16);
    expect(geometry.canvasBorderWidth, 1.5);
    expect(geometry.hitRadius, 8);
    expect(geometry.hitTestStrokeScale, 1);
  });
}
