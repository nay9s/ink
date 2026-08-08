import 'dart:math' as math;

import 'package:flutter/widgets.dart';

/// Resolves a compact contextual toolbar above [anchor] whenever there is
/// enough room, otherwise below it. The result is clamped to the visible
/// viewport so selections near an edge never push actions off-screen.
Offset selectionToolbarPosition({
  required Size viewportSize,
  required Size toolbarSize,
  required Rect anchor,
  double gap = 10,
  double horizontalMargin = 8,
  double? leftInset,
  double? rightInset,
  double topInset = 8,
  double bottomMargin = 8,
}) {
  final effectiveLeftInset = leftInset ?? horizontalMargin;
  final effectiveRightInset = rightInset ?? horizontalMargin;
  final availableRight = math.max(0.0, viewportSize.width - toolbarSize.width);
  final minLeft = math.min(effectiveLeftInset, availableRight);
  final maxLeft = math.max(
    minLeft,
    viewportSize.width - toolbarSize.width - effectiveRightInset,
  );
  final left = (anchor.center.dx - toolbarSize.width / 2)
      .clamp(minLeft, maxLeft)
      .toDouble();

  final availableBottom = math.max(
    0.0,
    viewportSize.height - toolbarSize.height - bottomMargin,
  );
  final minTop = math.min(topInset, availableBottom);
  final maxTop = math.max(minTop, availableBottom);
  final above = anchor.top - gap - toolbarSize.height;
  final below = anchor.bottom + gap;
  final roomAbove = anchor.top - gap - minTop;
  final roomBelow = viewportSize.height - bottomMargin - anchor.bottom - gap;
  final preferredTop = roomAbove >= toolbarSize.height || roomAbove >= roomBelow
      ? above
      : below;
  final top = preferredTop.clamp(minTop, maxTop).toDouble();

  return Offset(left, top);
}

class SelectionToolbarLayoutDelegate extends SingleChildLayoutDelegate {
  const SelectionToolbarLayoutDelegate({
    required this.anchor,
    this.gap = 10,
    this.horizontalMargin = 8,
    this.leftInset,
    this.rightInset,
    this.topInset = 8,
    this.bottomMargin = 8,
  });

  final Rect anchor;
  final double gap;
  final double horizontalMargin;
  final double? leftInset;
  final double? rightInset;
  final double topInset;
  final double bottomMargin;

  @override
  BoxConstraints getConstraintsForChild(BoxConstraints constraints) =>
      constraints.loosen();

  @override
  Offset getPositionForChild(Size size, Size childSize) {
    return selectionToolbarPosition(
      viewportSize: size,
      toolbarSize: childSize,
      anchor: anchor,
      gap: gap,
      horizontalMargin: horizontalMargin,
      leftInset: leftInset,
      rightInset: rightInset,
      topInset: topInset,
      bottomMargin: bottomMargin,
    );
  }

  @override
  bool shouldRelayout(covariant SelectionToolbarLayoutDelegate oldDelegate) {
    return oldDelegate.anchor != anchor ||
        oldDelegate.gap != gap ||
        oldDelegate.horizontalMargin != horizontalMargin ||
        oldDelegate.leftInset != leftInset ||
        oldDelegate.rightInset != rightInset ||
        oldDelegate.topInset != topInset ||
        oldDelegate.bottomMargin != bottomMargin;
  }
}
