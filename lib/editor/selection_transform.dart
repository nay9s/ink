import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../models.dart';

enum SelectionResizeHandle { topLeft, topRight, bottomLeft, bottomRight }

Offset selectionResizeHandlePosition(
  Rect bounds,
  SelectionResizeHandle handle,
) => switch (handle) {
  SelectionResizeHandle.topLeft => bounds.topLeft,
  SelectionResizeHandle.topRight => bounds.topRight,
  SelectionResizeHandle.bottomLeft => bounds.bottomLeft,
  SelectionResizeHandle.bottomRight => bounds.bottomRight,
};

Offset selectionResizeOppositeAnchor(
  Rect bounds,
  SelectionResizeHandle handle,
) => switch (handle) {
  SelectionResizeHandle.topLeft => bounds.bottomRight,
  SelectionResizeHandle.topRight => bounds.bottomLeft,
  SelectionResizeHandle.bottomLeft => bounds.topRight,
  SelectionResizeHandle.bottomRight => bounds.topLeft,
};

SelectionResizeHandle? hitTestSelectionResizeHandle(
  Offset position,
  Rect bounds, {
  double hitRadius = 24,
}) {
  SelectionResizeHandle? nearest;
  var nearestDistance = double.infinity;
  for (final handle in SelectionResizeHandle.values) {
    final distance =
        (position - selectionResizeHandlePosition(bounds, handle)).distance;
    if (distance <= hitRadius && distance < nearestDistance) {
      nearest = handle;
      nearestDistance = distance;
    }
  }
  return nearest;
}

Rect? inkPointBounds(Iterable<InkPoint> points) {
  final iterator = points.iterator;
  if (!iterator.moveNext()) return null;
  var minX = iterator.current.x;
  var maxX = minX;
  var minY = iterator.current.y;
  var maxY = minY;
  while (iterator.moveNext()) {
    minX = math.min(minX, iterator.current.x);
    maxX = math.max(maxX, iterator.current.x);
    minY = math.min(minY, iterator.current.y);
    maxY = math.max(maxY, iterator.current.y);
  }
  return Rect.fromLTRB(minX, minY, maxX, maxY);
}

double selectionUniformScaleForDrag({
  required Rect initialBounds,
  required SelectionResizeHandle handle,
  required Offset startPointer,
  required Offset currentPointer,
  Rect allowedBounds = const Rect.fromLTWH(0, 0, 1, 1),
  double minimumExtent = .025,
}) {
  final anchor = selectionResizeOppositeAnchor(initialBounds, handle);
  final corner = selectionResizeHandlePosition(initialBounds, handle);
  final initialVector = corner - anchor;
  final denominator = initialVector.distanceSquared;
  if (!denominator.isFinite || denominator <= 1e-12) return 1;

  final targetCorner = corner + (currentPointer - startPointer);
  final targetVector = targetCorner - anchor;
  var scale =
      (targetVector.dx * initialVector.dx +
          targetVector.dy * initialVector.dy) /
      denominator;

  final largestExtent = math.max(initialBounds.width, initialBounds.height);
  final minimumScale = largestExtent <= 1e-9
      ? 1.0
      : math.max(.04, minimumExtent / largestExtent);
  var maximumScale = double.infinity;
  maximumScale = math.min(
    maximumScale,
    _axisScaleLimit(
      anchor.dx,
      initialVector.dx,
      allowedBounds.left,
      allowedBounds.right,
    ),
  );
  maximumScale = math.min(
    maximumScale,
    _axisScaleLimit(
      anchor.dy,
      initialVector.dy,
      allowedBounds.top,
      allowedBounds.bottom,
    ),
  );
  if (!maximumScale.isFinite || maximumScale <= 0) maximumScale = 20;
  if (!scale.isFinite) scale = 1;
  return scale.clamp(minimumScale, math.max(minimumScale, maximumScale));
}

double _axisScaleLimit(
  double anchor,
  double vector,
  double minimum,
  double maximum,
) {
  if (vector.abs() <= 1e-12) return double.infinity;
  final limit = vector > 0
      ? (maximum - anchor) / vector
      : (minimum - anchor) / vector;
  return limit > 0 ? limit : double.infinity;
}

Offset scaleSelectionOffset(Offset point, Offset anchor, double scale) =>
    anchor + (point - anchor) * scale;

InkPoint scaleSelectionPoint(InkPoint point, Offset anchor, double scale) {
  final transformed = scaleSelectionOffset(
    Offset(point.x, point.y),
    anchor,
    scale,
  );
  return InkPoint(
    transformed.dx.clamp(0.0, 1.0),
    transformed.dy.clamp(0.0, 1.0),
    point.pressure,
  );
}

InkObject scaleSelectionObject(
  InkObject object, {
  required Offset anchor,
  required double scale,
}) {
  if (object is InkStroke) {
    return object.copyWith(
      points: object.points
          .map((point) => scaleSelectionPoint(point, anchor, scale))
          .toList(growable: false),
      width: math.max(.25, object.width * scale),
      isSelected: object.isSelected,
    );
  }
  if (object is InkText) {
    final origin = scaleSelectionOffset(
      Offset(object.x, object.y),
      anchor,
      scale,
    );
    return object.copyWith(
      x: origin.dx.clamp(0.0, 1.0),
      y: origin.dy.clamp(0.0, 1.0),
      width: (object.width * scale).clamp(.02, 1.0),
      fontSize: math.max(4, object.fontSize * scale),
      isSelected: object.isSelected,
    );
  }
  if (object is InkImage) {
    final origin = scaleSelectionOffset(
      Offset(object.x, object.y),
      anchor,
      scale,
    );
    final width = (object.width * scale).clamp(.01, 1.0);
    final height = (object.height * scale).clamp(.01, 1.0);
    return object.copyWith(
      x: origin.dx.clamp(0.0, math.max(0.0, 1 - width)),
      y: origin.dy.clamp(0.0, math.max(0.0, 1 - height)),
      width: width,
      height: height,
      isSelected: object.isSelected,
    );
  }
  return object;
}
