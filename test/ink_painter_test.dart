import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ink_note/editor/ink_painter.dart';
import 'package:ink_note/models.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('lasso selection keeps object colors and does not tint its interior',
      () async {
    const size = Size(100, 100);
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder)
      ..drawRect(
        Offset.zero & size,
        Paint()..color = Colors.white,
      );
    InkPainter(
      strokes: <InkObject>[
        InkStroke(
          tool: InkTool.pen,
          color: const Color(0xFFFF0000),
          width: 8,
          pressureSensitivity: 0,
          isSelected: true,
          points: const <InkPoint>[
            InkPoint(.2, .5, 1),
            InkPoint(.8, .5, 1),
          ],
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
  });
}
