import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ink_note/models.dart';

void main() {
  test('new strokes persist the prefix-stable geometry version', () {
    final stroke = InkStroke(
      tool: InkTool.pen,
      color: Colors.black,
      width: 2,
      points: const <InkPoint>[InkPoint(.1, .2, .4), InkPoint(.3, .4, .6)],
    );

    final restored = InkStroke.fromJson(
      Map<String, dynamic>.from(stroke.toJson()),
    );

    expect(stroke.geometryVersion, 2);
    expect(restored.geometryVersion, 2);
  });

  test('strokes saved before geometry versioning retain legacy rendering', () {
    final legacyJson = <String, dynamic>{
      'type': 'stroke',
      'tool': InkTool.pen.name,
      'color': Colors.black.toARGB32(),
      'width': 2.0,
      'dashed': false,
      'pressureSensitivity': .7,
      'points': <Map<String, Object>>[
        const InkPoint(.1, .2, .4).toJson(),
        const InkPoint(.3, .4, .6).toJson(),
      ],
    };

    final restored = InkStroke.fromJson(legacyJson);

    expect(restored.geometryVersion, 1);
  });
}
