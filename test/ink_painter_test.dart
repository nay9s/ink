import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ink_note/editor/ink_painter.dart';
import 'package:ink_note/models.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'lasso selection keeps object colors and does not tint its interior',
    () async {
      const size = Size(100, 100);
      final recorder = ui.PictureRecorder();
      final canvas = Canvas(recorder)
        ..drawRect(Offset.zero & size, Paint()..color = Colors.white);
      InkPainter(
        strokes: <InkObject>[
          InkStroke(
            tool: InkTool.pen,
            color: const Color(0xFFFF0000),
            width: 8,
            pressureSensitivity: 0,
            isSelected: true,
            points: const <InkPoint>[InkPoint(.2, .5, 1), InkPoint(.8, .5, 1)],
          ),
        ],
        selectionPath: const <InkPoint>[
          InkPoint(.1, .1, 1),
          InkPoint(.9, .1, 1),
          InkPoint(.9, .9, 1),
          InkPoint(.1, .9, 1),
        ],
      ).paint(canvas, size);

      final image = await recorder.endRecording().toImage(100, 100);
      final bytes = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
      expect(bytes, isNotNull);

      Color pixelAt(int x, int y) {
        final offset = (y * 100 + x) * 4;
        return Color.fromARGB(
          bytes!.getUint8(offset + 3),
          bytes.getUint8(offset),
          bytes.getUint8(offset + 1),
          bytes.getUint8(offset + 2),
        );
      }

      expect(pixelAt(50, 30), Colors.white);
      final strokePixel = pixelAt(50, 50);
      expect(strokePixel.r, greaterThan(.95));
      expect(strokePixel.g, lessThan(.05));
      expect(strokePixel.b, lessThan(.05));
      image.dispose();
    },
  );

  test('lasso outline stays visually thin', () async {
    const size = Size(100, 100);
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder)
      ..drawRect(Offset.zero & size, Paint()..color = Colors.white);
    InkPainter(
      strokes: const <InkObject>[],
      lassoPath: const <InkPoint>[InkPoint(.1, .5, 1), InkPoint(.9, .5, 1)],
    ).paint(canvas, size);

    final image = await recorder.endRecording().toImage(100, 100);
    final bytes = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
    expect(bytes, isNotNull);

    var coloredRows = 0;
    for (var y = 0; y < 100; y++) {
      final offset = (y * 100 + 13) * 4;
      final red = bytes!.getUint8(offset);
      final green = bytes.getUint8(offset + 1);
      final blue = bytes.getUint8(offset + 2);
      if (blue > 180 && blue > red + 20 && blue > green) coloredRows++;
    }

    expect(coloredRows, lessThanOrEqualTo(2));
    image.dispose();
  });

  test('a stroke keeps identical geometry when it becomes committed', () async {
    final stroke = InkStroke(
      tool: InkTool.pen,
      color: Colors.green,
      width: 5,
      pressureSensitivity: .7,
      points: const <InkPoint>[
        InkPoint(.25, .2, .4),
        InkPoint(.31, .26, .55),
        InkPoint(.29, .36, .7),
        InkPoint(.38, .43, .65),
        InkPoint(.34, .55, .5),
        InkPoint(.44, .67, .45),
      ],
    );

    Future<List<int>> render({required bool active}) async {
      const size = Size(160, 160);
      final recorder = ui.PictureRecorder();
      final canvas = Canvas(recorder)
        ..drawRect(Offset.zero & size, Paint()..color = Colors.white);
      InkPainter(
        strokes: active ? const <InkObject>[] : <InkObject>[stroke],
        activeStroke: active ? stroke : null,
      ).paint(canvas, size);
      final image = await recorder.endRecording().toImage(160, 160);
      final bytes = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
      image.dispose();
      return bytes!.buffer.asUint8List().toList(growable: false);
    }

    expect(await render(active: true), await render(active: false));
  });
}
