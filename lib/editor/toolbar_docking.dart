import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../models.dart';

enum EditorToolbarKind { primary, options }

@immutable
class ToolbarPlacement {
  const ToolbarPlacement({required this.dock, required this.order});

  final ToolbarDock dock;

  /// Distance order from the selected edge: zero is closest to the edge.
  final int order;

  ToolbarPlacement copyWith({ToolbarDock? dock, int? order}) =>
      ToolbarPlacement(dock: dock ?? this.dock, order: order ?? this.order);
}

@immutable
class ToolbarDockingResult {
  const ToolbarDockingResult({required this.primary, required this.options});

  final ToolbarPlacement primary;
  final ToolbarPlacement options;

  ToolbarPlacement placementFor(EditorToolbarKind kind) =>
      kind == EditorToolbarKind.primary ? primary : options;
}

ToolbarDockingResult normalizeToolbarDocking({
  required ToolbarPlacement primary,
  required ToolbarPlacement options,
}) {
  final normalizedPrimary = primary.copyWith(order: primary.order.clamp(0, 1));
  final normalizedOptions = options.copyWith(order: options.order.clamp(0, 1));

  if (normalizedPrimary.dock != normalizedOptions.dock) {
    return ToolbarDockingResult(
      primary: normalizedPrimary.copyWith(order: 0),
      options: normalizedOptions.copyWith(order: 0),
    );
  }
  if (normalizedPrimary.order == normalizedOptions.order) {
    return ToolbarDockingResult(
      primary: normalizedPrimary.copyWith(order: 0),
      options: normalizedOptions.copyWith(order: 1),
    );
  }
  return ToolbarDockingResult(
    primary: normalizedPrimary,
    options: normalizedOptions,
  );
}

Axis toolbarAxisForDock(ToolbarDock dock) =>
    dock == ToolbarDock.top || dock == ToolbarDock.bottom
    ? Axis.horizontal
    : Axis.vertical;

ToolbarDock nearestToolbarDock(
  Offset position,
  Size viewport, {
  EdgeInsets reservedInsets = EdgeInsets.zero,
}) {
  final left = reservedInsets.left;
  final top = reservedInsets.top;
  final right = math.max(left, viewport.width - reservedInsets.right);
  final bottom = math.max(top, viewport.height - reservedInsets.bottom);
  final distances = <ToolbarDock, double>{
    ToolbarDock.top: (position.dy - top).abs(),
    ToolbarDock.left: (position.dx - left).abs(),
    ToolbarDock.right: (right - position.dx).abs(),
    ToolbarDock.bottom: (bottom - position.dy).abs(),
  };
  return distances.entries.reduce((a, b) => a.value <= b.value ? a : b).key;
}

ToolbarDock toolbarDockWithHysteresis({
  required Offset position,
  required Size viewport,
  required ToolbarDock currentDock,
  EdgeInsets reservedInsets = EdgeInsets.zero,
  double switchHysteresis = 28,
}) {
  final nearest = nearestToolbarDock(
    position,
    viewport,
    reservedInsets: reservedInsets,
  );
  if (nearest == currentDock) return nearest;

  final nearestDistance = toolbarDistanceFromEdge(
    position,
    viewport,
    nearest,
    reservedInsets: reservedInsets,
  );
  final currentDistance = toolbarDistanceFromEdge(
    position,
    viewport,
    currentDock,
    reservedInsets: reservedInsets,
  );
  return nearestDistance + switchHysteresis < currentDistance
      ? nearest
      : currentDock;
}

double toolbarDistanceFromEdge(
  Offset position,
  Size viewport,
  ToolbarDock dock, {
  EdgeInsets reservedInsets = EdgeInsets.zero,
}) => switch (dock) {
  ToolbarDock.top => (position.dy - reservedInsets.top).abs(),
  ToolbarDock.left => (position.dx - reservedInsets.left).abs(),
  ToolbarDock.right =>
    (viewport.width - reservedInsets.right - position.dx).abs(),
  ToolbarDock.bottom =>
    (viewport.height - reservedInsets.bottom - position.dy).abs(),
};

ToolbarDockingResult resolveToolbarDrop({
  required EditorToolbarKind dragged,
  required Offset position,
  required Size viewport,
  required ToolbarPlacement primary,
  required ToolbarPlacement options,
  EdgeInsets reservedInsets = EdgeInsets.zero,
  double outerDropDepth = 62,
  ToolbarDock? targetDock,
}) {
  final resolvedTargetDock =
      targetDock ??
      nearestToolbarDock(position, viewport, reservedInsets: reservedInsets);
  final otherKind = dragged == EditorToolbarKind.primary
      ? EditorToolbarKind.options
      : EditorToolbarKind.primary;
  final other = otherKind == EditorToolbarKind.primary ? primary : options;
  late ToolbarPlacement draggedPlacement;
  late ToolbarPlacement otherPlacement;

  if (other.dock == resolvedTargetDock) {
    final dropIsOuter =
        toolbarDistanceFromEdge(
          position,
          viewport,
          resolvedTargetDock,
          reservedInsets: reservedInsets,
        ) <=
        outerDropDepth;
    draggedPlacement = ToolbarPlacement(
      dock: resolvedTargetDock,
      order: dropIsOuter ? 0 : 1,
    );
    otherPlacement = other.copyWith(order: dropIsOuter ? 1 : 0);
  } else {
    draggedPlacement = ToolbarPlacement(dock: resolvedTargetDock, order: 0);
    // A toolbar left alone at an edge always slides into the outer slot.
    otherPlacement = other.copyWith(order: 0);
  }

  return dragged == EditorToolbarKind.primary
      ? ToolbarDockingResult(primary: draggedPlacement, options: otherPlacement)
      : ToolbarDockingResult(
          primary: otherPlacement,
          options: draggedPlacement,
        );
}

class ToolbarDragCallbacks {
  const ToolbarDragCallbacks({
    this.onStart,
    this.onUpdate,
    this.onEnd,
    this.onCancel,
  });

  final ValueChanged<Offset>? onStart;
  final ValueChanged<Offset>? onUpdate;
  final VoidCallback? onEnd;
  final VoidCallback? onCancel;

  bool get enabled => onStart != null && onUpdate != null && onEnd != null;
}

typedef DockedToolbarBuilder =
    Widget Function(
      BuildContext context,
      Axis axis,
      ToolbarDragCallbacks dragCallbacks,
    );

class DockableEditorToolbars extends StatefulWidget {
  const DockableEditorToolbars({
    super.key,
    required this.primary,
    required this.options,
    required this.primaryBuilder,
    required this.optionsBuilder,
    required this.onChanged,
    this.reservedInsets = EdgeInsets.zero,
  });

  final ToolbarPlacement primary;
  final ToolbarPlacement options;
  final DockedToolbarBuilder primaryBuilder;
  final DockedToolbarBuilder optionsBuilder;
  final ValueChanged<ToolbarDockingResult> onChanged;
  final EdgeInsets reservedInsets;

  @override
  State<DockableEditorToolbars> createState() => _DockableEditorToolbarsState();
}

class _DockableEditorToolbarsState extends State<DockableEditorToolbars> {
  final GlobalKey _surfaceKey = GlobalKey();
  final Map<EditorToolbarKind, GlobalKey> _toolbarKeys = {
    for (final kind in EditorToolbarKind.values) kind: GlobalKey(),
  };
  EditorToolbarKind? _dragging;
  Offset? _dragPosition;
  Offset? _dragStartPosition;
  Offset? _dragGrabOffset;
  Size? _dragFeedbackSize;
  Axis? _dragFeedbackAxis;
  ToolbarDockingResult? _preview;

  ToolbarDragCallbacks _dragCallbacks(EditorToolbarKind kind, Size viewport) =>
      ToolbarDragCallbacks(
        onStart: (globalPosition) => _startDrag(kind, globalPosition, viewport),
        onUpdate: (globalPosition) => _updateDrag(globalPosition, viewport),
        onEnd: () => _finishDrag(viewport),
        onCancel: _cancelDrag,
      );

  Offset _localPosition(Offset globalPosition) {
    final context = _surfaceKey.currentContext;
    final box = context?.findRenderObject() as RenderBox?;
    return box?.globalToLocal(globalPosition) ?? globalPosition;
  }

  ToolbarDockingResult _resolve(
    EditorToolbarKind kind,
    Offset localPosition,
    Size viewport, {
    ToolbarDock? targetDock,
  }) => resolveToolbarDrop(
    dragged: kind,
    position: localPosition,
    viewport: viewport,
    primary: widget.primary,
    options: widget.options,
    reservedInsets: widget.reservedInsets,
    targetDock: targetDock,
  );

  Rect? _toolbarRect(EditorToolbarKind kind) {
    final surfaceBox =
        _surfaceKey.currentContext?.findRenderObject() as RenderBox?;
    final toolbarBox =
        _toolbarKeys[kind]?.currentContext?.findRenderObject() as RenderBox?;
    if (surfaceBox == null || toolbarBox == null || !toolbarBox.hasSize) {
      return null;
    }
    final topLeft = surfaceBox.globalToLocal(
      toolbarBox.localToGlobal(Offset.zero),
    );
    return topLeft & toolbarBox.size;
  }

  ToolbarDockingResult get _currentDocking =>
      normalizeToolbarDocking(primary: widget.primary, options: widget.options);

  void _startDrag(
    EditorToolbarKind kind,
    Offset globalPosition,
    Size viewport,
  ) {
    final local = _localPosition(globalPosition);
    final toolbarRect = _toolbarRect(kind);
    setState(() {
      _dragging = kind;
      _dragPosition = local;
      _dragStartPosition = local;
      _dragGrabOffset = toolbarRect == null
          ? Offset.zero
          : local - toolbarRect.topLeft;
      _dragFeedbackSize = toolbarRect?.size;
      _dragFeedbackAxis = toolbarAxisForDock(_placementFor(kind).dock);
      _preview = _currentDocking;
    });
  }

  void _updateDrag(Offset globalPosition, Size viewport) {
    final kind = _dragging;
    if (kind == null) return;
    final local = _localPosition(globalPosition);
    final start = _dragStartPosition;
    final currentDock =
        _preview?.placementFor(kind).dock ?? _placementFor(kind).dock;
    final targetDock = start != null && (local - start).distance < 24
        ? _placementFor(kind).dock
        : toolbarDockWithHysteresis(
            position: local,
            viewport: viewport,
            currentDock: currentDock,
            reservedInsets: widget.reservedInsets,
          );
    setState(() {
      _dragPosition = local;
      _preview = _resolve(kind, local, viewport, targetDock: targetDock);
    });
  }

  void _finishDrag(Size viewport) {
    final kind = _dragging;
    final position = _dragPosition;
    if (kind == null || position == null) return;
    final targetDock =
        _preview?.placementFor(kind).dock ?? _placementFor(kind).dock;
    final result = _resolve(kind, position, viewport, targetDock: targetDock);
    setState(() {
      _clearDragState();
    });
    widget.onChanged(result);
  }

  void _cancelDrag() {
    if (_dragging == null) return;
    setState(() {
      _clearDragState();
    });
  }

  void _clearDragState() {
    _dragging = null;
    _dragPosition = null;
    _dragStartPosition = null;
    _dragGrabOffset = null;
    _dragFeedbackSize = null;
    _dragFeedbackAxis = null;
    _preview = null;
  }

  ToolbarPlacement _placementFor(EditorToolbarKind kind) =>
      kind == EditorToolbarKind.primary ? widget.primary : widget.options;

  DockedToolbarBuilder _builderFor(EditorToolbarKind kind) =>
      kind == EditorToolbarKind.primary
      ? widget.primaryBuilder
      : widget.optionsBuilder;

  Widget _toolbar(
    BuildContext context,
    EditorToolbarKind kind,
    ToolbarDock dock,
    Size viewport,
  ) {
    final axis = toolbarAxisForDock(dock);
    final maxWidth = math.max(
      80.0,
      viewport.width - widget.reservedInsets.horizontal - 16,
    );
    final maxHeight = math.max(
      80.0,
      viewport.height - widget.reservedInsets.vertical - 16,
    );
    return KeyedSubtree(
      key: _toolbarKeys[kind],
      child: ConstrainedBox(
        constraints: axis == Axis.horizontal
            ? BoxConstraints(maxWidth: maxWidth)
            : BoxConstraints(maxHeight: maxHeight),
        child: KeyedSubtree(
          key: ValueKey('${kind.name}-toolbar'),
          child: _builderFor(kind)(
            context,
            axis,
            _dragCallbacks(kind, viewport),
          ),
        ),
      ),
    );
  }

  Widget _dockGroup(BuildContext context, ToolbarDock dock, Size viewport) {
    final kinds =
        EditorToolbarKind.values
            .where((kind) => _placementFor(kind).dock == dock)
            .toList()
          ..sort(
            (a, b) => _placementFor(a).order.compareTo(_placementFor(b).order),
          );
    if (kinds.isEmpty) return const SizedBox.shrink();

    final children = <Widget>[];
    final visualKinds =
        (dock == ToolbarDock.bottom || dock == ToolbarDock.right
                ? kinds.reversed
                : kinds)
            .toList();
    for (var index = 0; index < visualKinds.length; index++) {
      final kind = visualKinds[index];
      if (index > 0) {
        final previousKind = visualKinds[index - 1];
        children.add(
          SizedBox.square(
            dimension: kind == _dragging || previousKind == _dragging ? 0 : 4,
          ),
        );
      }
      // Keep the original gesture recognizer mounted while it owns the
      // pointer. Offstage removes its layout slot so the remaining toolbar
      // can slide to the edge immediately without cancelling the drag.
      children.add(
        Offstage(
          key: ValueKey('${dock.name}-${kind.name}-toolbar-slot'),
          offstage: kind == _dragging,
          child: _toolbar(context, kind, dock, viewport),
        ),
      );
    }

    final group = toolbarAxisForDock(dock) == Axis.horizontal
        ? Column(mainAxisSize: MainAxisSize.min, children: children)
        : Row(mainAxisSize: MainAxisSize.min, children: children);
    const margin = 6.0;
    return switch (dock) {
      ToolbarDock.top => Positioned(
        top: widget.reservedInsets.top + margin,
        left: widget.reservedInsets.left,
        right: widget.reservedInsets.right,
        child: group,
      ),
      ToolbarDock.bottom => Positioned(
        bottom: widget.reservedInsets.bottom + margin,
        left: widget.reservedInsets.left,
        right: widget.reservedInsets.right,
        child: group,
      ),
      ToolbarDock.left => Positioned(
        top: widget.reservedInsets.top,
        bottom: widget.reservedInsets.bottom,
        left: widget.reservedInsets.left + margin,
        child: Center(child: group),
      ),
      ToolbarDock.right => Positioned(
        top: widget.reservedInsets.top,
        bottom: widget.reservedInsets.bottom,
        right: widget.reservedInsets.right + margin,
        child: Center(child: group),
      ),
    };
  }

  Widget _dropIndicator(Size viewport) {
    final kind = _dragging;
    final preview = _preview;
    if (kind == null || preview == null) return const SizedBox.shrink();
    final placement = preview.placementFor(kind);
    final color = Theme.of(context).colorScheme.primary.withValues(alpha: .26);
    final edgeOffset = 8.0 + placement.order * 54;
    return switch (placement.dock) {
      ToolbarDock.top => Positioned(
        top: widget.reservedInsets.top + edgeOffset,
        left: viewport.width * .24,
        right: viewport.width * .24,
        child: _DockIndicator(color: color, horizontal: true),
      ),
      ToolbarDock.bottom => Positioned(
        bottom: widget.reservedInsets.bottom + edgeOffset,
        left: viewport.width * .24,
        right: viewport.width * .24,
        child: _DockIndicator(color: color, horizontal: true),
      ),
      ToolbarDock.left => Positioned(
        left: widget.reservedInsets.left + edgeOffset,
        top: viewport.height * .24,
        bottom: viewport.height * .24,
        child: _DockIndicator(color: color, horizontal: false),
      ),
      ToolbarDock.right => Positioned(
        right: widget.reservedInsets.right + edgeOffset,
        top: viewport.height * .24,
        bottom: viewport.height * .24,
        child: _DockIndicator(color: color, horizontal: false),
      ),
    };
  }

  Widget _dragFeedback(BuildContext context, Size viewport) {
    final kind = _dragging;
    final position = _dragPosition;
    final grabOffset = _dragGrabOffset;
    final axis = _dragFeedbackAxis;
    if (kind == null ||
        position == null ||
        grabOffset == null ||
        axis == null) {
      return const SizedBox.shrink();
    }
    final feedbackSize = _dragFeedbackSize ?? Size.zero;
    final desiredTopLeft = position - grabOffset;
    final safeTopLeft = Offset(
      desiredTopLeft.dx.clamp(
        0.0,
        math.max(0.0, viewport.width - feedbackSize.width),
      ),
      desiredTopLeft.dy.clamp(
        0.0,
        math.max(0.0, viewport.height - feedbackSize.height),
      ),
    );
    return Positioned(
      left: safeTopLeft.dx,
      top: safeTopLeft.dy,
      child: IgnorePointer(
        child: RepaintBoundary(
          key: ValueKey('${kind.name}-toolbar-drag-feedback'),
          child: Opacity(
            opacity: .9,
            child: ConstrainedBox(
              constraints: axis == Axis.horizontal
                  ? BoxConstraints(
                      maxWidth: math.max(
                        80.0,
                        viewport.width - widget.reservedInsets.horizontal - 16,
                      ),
                    )
                  : BoxConstraints(
                      maxHeight: math.max(
                        80.0,
                        viewport.height - widget.reservedInsets.vertical - 16,
                      ),
                    ),
              child: _builderFor(kind)(
                context,
                axis,
                const ToolbarDragCallbacks(),
              ),
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final viewport = Size(constraints.maxWidth, constraints.maxHeight);
      return SizedBox.expand(
        key: _surfaceKey,
        child: Stack(
          clipBehavior: Clip.hardEdge,
          children: [
            for (final dock in ToolbarDock.values)
              _dockGroup(context, dock, viewport),
            _dropIndicator(viewport),
            _dragFeedback(context, viewport),
          ],
        ),
      );
    },
  );
}

class _DockIndicator extends StatelessWidget {
  const _DockIndicator({required this.color, required this.horizontal});

  final Color color;
  final bool horizontal;

  @override
  Widget build(BuildContext context) => Container(
    width: horizontal ? null : 7,
    height: horizontal ? 7 : null,
    decoration: BoxDecoration(
      color: color,
      borderRadius: BorderRadius.circular(99),
    ),
  );
}
