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

  test('a snapped shape survives a save and reload', () {
    final stroke = InkStroke(
      tool: InkTool.pen,
      color: Colors.black,
      width: 2,
      shapeKind: InkShapeKind.rectangle,
      points: const <InkPoint>[InkPoint(.1, .2, .5), InkPoint(.6, .7, .5)],
    );

    final restored = InkStroke.fromJson(
      Map<String, dynamic>.from(stroke.toJson()),
    );

    expect(restored.shapeKind, InkShapeKind.rectangle);
    expect(restored.points.first.x, .1);
    expect(restored.points.last.y, .7);
  });

  test('strokes saved before shape snapping stay freehand', () {
    final restored = InkStroke.fromJson(<String, dynamic>{
      'type': 'stroke',
      'tool': 'pen',
      'color': 0xFF000000,
      'width': 2.0,
      'points': <Map<String, Object>>[
        <String, Object>{'x': .1, 'y': .2, 'p': .5},
        <String, Object>{'x': .3, 'y': .4, 'p': .5},
      ],
    });

    expect(restored.shapeKind, InkShapeKind.none);
  });

  test('shape assist defaults on and round-trips', () {
    const settings = AppSettings();
    expect(settings.shapeAssist, isTrue);

    final restored = AppSettings.fromJson(
      Map<String, dynamic>.from(settings.copyWith(shapeAssist: false).toJson()),
    );
    expect(restored.shapeAssist, isFalse);

    // Settings written before the toggle existed opt in by default.
    expect(AppSettings.fromJson(<String, dynamic>{}).shapeAssist, isTrue);
  });
}
