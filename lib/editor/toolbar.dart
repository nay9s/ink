import 'package:flutter/material.dart';

import '../models.dart';
import 'toolbar_docking.dart';

enum FloatingToolbarSection { both, primary, options }

class FloatingEditorToolbar extends StatelessWidget {
  const FloatingEditorToolbar({
    super.key,
    required this.tool,
    required this.color,
    required this.width,
    required this.canUndo,
    required this.canRedo,
    required this.onTool,
    required this.onColor,
    required this.onOpenColorPalette,
    required this.paletteColors,
    required this.onWidth,
    required this.eraserMode,
    required this.onEraserModeChanged,
    required this.eraseHighlighterOnly,
    required this.onEraseHighlighterOnlyChanged,
    required this.eraserAutoDeselect,
    required this.onEraserAutoDeselectChanged,
    required this.onPenTap,
    required this.onPenSettings,
    required this.onUndo,
    required this.onRedo,
    required this.onToggleZoomMode,
    required this.zoomMode,
    required this.presets,
    required this.highlighterPresets,
    required this.onWidthPresetTap,
    required this.onAddWidthPreset,
    required this.onZoomIn,
    required this.onZoomOut,
    required this.onResetZoom,
    required this.dashed,
    required this.onDashedChanged,
    required this.textSize,
    required this.onTextSizeChanged,
    required this.textBold,
    required this.onTextBoldChanged,
    required this.textItalic,
    required this.onTextItalicChanged,
    required this.textAlign,
    required this.onTextAlignChanged,
    required this.lineHeight,
    required this.onLineHeightChanged,
    required this.onAddImage,
    this.canPaste = false,
    this.onPaste,
    this.section = FloatingToolbarSection.both,
    this.axis = Axis.horizontal,
    this.dragCallbacks = const ToolbarDragCallbacks(),
  });

  final InkTool tool;
  final Color color;
  final double width;
  final bool canUndo;
  final bool canRedo;
  final ValueChanged<InkTool> onTool;
  final ValueChanged<Color> onColor;
  final VoidCallback onOpenColorPalette;
  final List<Color> paletteColors;
  final ValueChanged<double> onWidth;
  final EraserMode eraserMode;
  final ValueChanged<EraserMode> onEraserModeChanged;
  final bool eraseHighlighterOnly;
  final ValueChanged<bool> onEraseHighlighterOnlyChanged;
  final bool eraserAutoDeselect;
  final ValueChanged<bool> onEraserAutoDeselectChanged;
  final VoidCallback onPenTap;
  final VoidCallback onPenSettings;
  final VoidCallback onUndo;
  final VoidCallback onRedo;
  final VoidCallback onToggleZoomMode;
  final bool zoomMode;
  final List<PenPreset> presets;
  final List<PenPreset> highlighterPresets;
  final ValueChanged<int> onWidthPresetTap;
  final VoidCallback onAddWidthPreset;
  final VoidCallback onZoomIn;
  final VoidCallback onZoomOut;
  final VoidCallback onResetZoom;
  final bool dashed;
  final ValueChanged<bool> onDashedChanged;
  final double textSize;
  final ValueChanged<double> onTextSizeChanged;
  final bool textBold;
  final ValueChanged<bool> onTextBoldChanged;
  final bool textItalic;
  final ValueChanged<bool> onTextItalicChanged;
  final TextAlign textAlign;
  final ValueChanged<TextAlign> onTextAlignChanged;
  final double lineHeight;
  final ValueChanged<double> onLineHeightChanged;
  final VoidCallback onAddImage;
  final bool canPaste;
  final VoidCallback? onPaste;
  final FloatingToolbarSection section;
  final Axis axis;
  final ToolbarDragCallbacks dragCallbacks;

  static const quickWidths = [1.5, 2.0, 3.0];

  bool get _isPenTool =>
      tool == InkTool.pen ||
      tool == InkTool.fountainPen ||
      tool == InkTool.brushPen;

  bool get _usesDrawingControls =>
      _isPenTool || tool == InkTool.highlighter || tool == InkTool.shape;

  @override
  Widget build(BuildContext context) {
    final effectivePresets = presets.isNotEmpty
        ? presets
        : quickWidths
              .map((size) => PenPreset(size: size, smoothing: .45))
              .toList();

    final primaryCard = _ToolbarCard(
      axis: axis,
      prominent: true,
      child: _toolbarFlex(axis, [
        _ToolButton(
          icon: zoomMode ? Icons.pan_tool : Icons.select_all,
          label: 'Pan & zoom',
          selected: zoomMode,
          onTap: onToggleZoomMode,
        ),
        _Divider(axis: axis, extent: 28),
        _ToolButton(
          icon: Icons.edit_outlined,
          label: 'Pen',
          selected: _isPenTool && !zoomMode,
          onTap: onPenTap,
        ),
        _ToolButton(
          icon: Icons.border_color_outlined,
          label: 'Highlighter',
          selected: tool == InkTool.highlighter && !zoomMode,
          onTap: () => onTool(InkTool.highlighter),
        ),
        _ToolButton(
          icon: Icons.auto_fix_normal_outlined,
          label: 'Eraser',
          selected: tool == InkTool.eraser && !zoomMode,
          onTap: () => onTool(InkTool.eraser),
        ),
        _ToolButton(
          icon: Icons.text_fields_rounded,
          label: 'Text',
          selected: tool == InkTool.text && !zoomMode,
          onTap: () => onTool(InkTool.text),
        ),
        _ToolButton(
          icon: Icons.image_outlined,
          label: 'Add image',
          selected: tool == InkTool.image && !zoomMode,
          onTap: onAddImage,
        ),
        _ToolButton(
          icon: Icons.gesture_rounded,
          label: 'Lasso',
          selected: tool == InkTool.lasso && !zoomMode,
          onTap: () => onTool(InkTool.lasso),
        ),
        _Divider(axis: axis, extent: 28),
        _ToolbarDragHandle(
          key: dragCallbacks.enabled
              ? const ValueKey('primary-toolbar-drag-handle')
              : null,
          axis: axis,
          callbacks: dragCallbacks,
          label: 'Move Primary Toolbar',
        ),
      ]),
    );
    final optionsCard = _ToolbarCard(
      axis: axis,
      child: _toolbarFlex(axis, [
        ..._buildContextControls(context, effectivePresets, axis),
        _Divider(axis: axis),
        _ToolbarDragHandle(
          key: dragCallbacks.enabled
              ? const ValueKey('options-toolbar-drag-handle')
              : null,
          axis: axis,
          callbacks: dragCallbacks,
          label: 'Move Tool Options Bar',
        ),
      ]),
    );
    final cards = switch (section) {
      FloatingToolbarSection.primary => <Widget>[primaryCard],
      FloatingToolbarSection.options => <Widget>[optionsCard],
      FloatingToolbarSection.both => <Widget>[
        primaryCard,
        const SizedBox.square(dimension: 5),
        optionsCard,
      ],
    };
    final depthAxis = axis == Axis.horizontal ? Axis.vertical : Axis.horizontal;

    return Container(
      constraints: axis == Axis.horizontal
          ? const BoxConstraints(maxWidth: 980)
          : const BoxConstraints(maxHeight: 980),
      margin: axis == Axis.horizontal
          ? const EdgeInsets.fromLTRB(8, 1, 8, 5)
          : const EdgeInsets.fromLTRB(1, 8, 5, 8),
      child: IconButtonTheme(
        data: IconButtonThemeData(
          style: IconButton.styleFrom(
            minimumSize: const Size(32, 32),
            maximumSize: const Size(32, 32),
            padding: EdgeInsets.zero,
            iconSize: 17,
          ),
        ),
        child: DefaultTextStyle.merge(
          style: const TextStyle(fontSize: 12),
          child: SingleChildScrollView(
            scrollDirection: axis,
            child: Flex(
              direction: depthAxis,
              mainAxisSize: MainAxisSize.min,
              children: cards,
            ),
          ),
        ),
      ),
    );
  }

  List<Widget> _buildContextControls(
    BuildContext context,
    List<PenPreset> effectivePresets,
    Axis axis,
  ) {
    if (zoomMode) {
      return <Widget>[
        _ActionButton(icon: Icons.remove, onTap: onZoomOut),
        _ActionButton(icon: Icons.center_focus_strong, onTap: onResetZoom),
        _ActionButton(icon: Icons.add, onTap: onZoomIn),
      ];
    }

    if (tool == InkTool.eraser) {
      return <Widget>[
        PopupMenuButton<EraserMode>(
          tooltip: 'Eraser mode',
          onSelected: onEraserModeChanged,
          itemBuilder: (_) => const [
            PopupMenuItem(
              value: EraserMode.precision,
              child: ListTile(
                dense: true,
                leading: Icon(Icons.blur_circular_outlined),
                title: Text('Precision Eraser'),
                subtitle: Text('Erase part of a stroke'),
              ),
            ),
            PopupMenuItem(
              value: EraserMode.stroke,
              child: ListTile(
                dense: true,
                leading: Icon(Icons.gesture_outlined),
                title: Text('Stroke Eraser'),
                subtitle: Text('Erase the whole stroke'),
              ),
            ),
          ],
          child: _DropdownChip(
            icon: eraserMode == EraserMode.precision
                ? Icons.blur_circular_outlined
                : Icons.gesture_outlined,
            label: eraserMode == EraserMode.precision
                ? 'Precision'
                : 'Whole stroke',
            compact: axis == Axis.vertical,
          ),
        ),
        _AxisGap(axis: axis, extent: 7),
        for (final size in const [16.0, 28.0, 48.0])
          _EraserSizeButton(
            size: size,
            selected: (width - size).abs() < 1,
            onTap: () => onWidth(size),
          ),
        _Divider(axis: axis),
        _OptionChip(
          icon: Icons.highlight_alt_outlined,
          label: 'Highlighter only',
          selected: eraseHighlighterOnly,
          compact: axis == Axis.vertical,
          onTap: () => onEraseHighlighterOnlyChanged(!eraseHighlighterOnly),
        ),
        _AxisGap(axis: axis, extent: 5),
        _OptionChip(
          icon: Icons.keyboard_return_rounded,
          label: 'Auto return',
          selected: eraserAutoDeselect,
          compact: axis == Axis.vertical,
          onTap: () => onEraserAutoDeselectChanged(!eraserAutoDeselect),
        ),
      ];
    }

    if (tool == InkTool.text) {
      return <Widget>[
        _ColorDot(color: color, selected: true, onTap: onOpenColorPalette),
        _AxisGap(axis: axis, extent: 6),
        PopupMenuButton<double>(
          onSelected: onTextSizeChanged,
          itemBuilder: (_) => const [
            PopupMenuItem(value: 16, child: Text('16')),
            PopupMenuItem(value: 20, child: Text('20')),
            PopupMenuItem(value: 24, child: Text('24')),
            PopupMenuItem(value: 32, child: Text('32')),
            PopupMenuItem(value: 40, child: Text('40')),
          ],
          child: _DropdownChip(
            label: textSize.round().toString(),
            compact: axis == Axis.vertical,
          ),
        ),
        _AxisGap(axis: axis, extent: 6),
        _DropdownChip(
          icon: Icons.font_download_outlined,
          label: 'Modern',
          compact: axis == Axis.vertical,
        ),
        _ToggleButton(
          label: 'B',
          selected: textBold,
          onTap: () => onTextBoldChanged(!textBold),
        ),
        _ToggleButton(
          label: 'I',
          italic: true,
          selected: textItalic,
          onTap: () => onTextItalicChanged(!textItalic),
        ),
        IconButton(
          tooltip: 'Alignment',
          onPressed: () {
            final next = switch (textAlign) {
              TextAlign.left => TextAlign.center,
              TextAlign.center => TextAlign.right,
              _ => TextAlign.left,
            };
            onTextAlignChanged(next);
          },
          icon: Icon(
            textAlign == TextAlign.center
                ? Icons.format_align_center
                : textAlign == TextAlign.right
                ? Icons.format_align_right
                : Icons.format_align_left,
          ),
        ),
        IconButton(
          tooltip: 'Line spacing',
          onPressed: () =>
              onLineHeightChanged(lineHeight >= 1.8 ? 1.0 : lineHeight + .2),
          icon: const Icon(Icons.format_line_spacing),
        ),
        _Divider(axis: axis),
        _DropdownChip(
          icon: Icons.push_pin_outlined,
          label: 'Pin Text Tool',
          compact: axis == Axis.vertical,
        ),
        if (canPaste && onPaste != null) ...[
          _Divider(axis: axis),
          IconButton(
            tooltip: 'Paste',
            onPressed: onPaste,
            icon: const Icon(Icons.content_paste_rounded),
          ),
        ],
      ];
    }

    if (_usesDrawingControls) {
      final activePresets = tool == InkTool.highlighter
          ? (highlighterPresets.isNotEmpty
                ? highlighterPresets
                : const [
                    PenPreset(size: 8, smoothing: .45),
                    PenPreset(size: 14, smoothing: .45),
                    PenPreset(size: 20, smoothing: .45),
                  ])
          : effectivePresets;
      return <Widget>[
        _PenTypeButton(tool: tool, onTap: onPenSettings),
        _AxisGap(axis: axis, extent: 6),
        _Divider(axis: axis),
        _ToolbarAxisScroller(
          axis: axis,
          extent: 106,
          child: _toolbarFlex(axis, [
            for (
              var presetIndex = 0;
              presetIndex < activePresets.length;
              presetIndex++
            )
              _WidthButton(
                width: activePresets[presetIndex].size,
                selected: (width - activePresets[presetIndex].size).abs() < .2,
                onTap: () => onWidthPresetTap(presetIndex),
              ),
          ]),
        ),
        _CircleActionButton(
          icon: Icons.add_rounded,
          tooltip: 'Add size preset',
          onTap: onAddWidthPreset,
        ),
        _Divider(axis: axis),
        if (tool != InkTool.highlighter) ...[
          _AxisGap(axis: axis, extent: 3),
          _LineButton(
            dashed: false,
            selected: !dashed,
            onTap: () => onDashedChanged(false),
          ),
          _LineButton(
            dashed: true,
            selected: dashed,
            onTap: () => onDashedChanged(true),
          ),
        ],
        _Divider(axis: axis),
        _ToolbarAxisScroller(
          axis: axis,
          extent: 166,
          child: _toolbarFlex(axis, [
            for (final itemColor in paletteColors)
              _ColorDot(
                color: itemColor,
                selected: itemColor.toARGB32() == color.toARGB32(),
                onTap: () => onColor(itemColor),
              ),
          ]),
        ),
        _Divider(axis: axis),
        _CircleActionButton(
          icon: Icons.add,
          tooltip: 'More colors',
          onTap: onOpenColorPalette,
        ),
      ];
    }

    return <Widget>[
      if (axis == Axis.horizontal)
        const Padding(
          padding: EdgeInsets.symmetric(horizontal: 12, vertical: 7),
          child: Text('Draw around objects to select them'),
        )
      else
        const Tooltip(
          message: 'Draw around objects to select them',
          child: SizedBox(
            width: 34,
            height: 34,
            child: Icon(Icons.gesture_rounded, size: 18),
          ),
        ),
      if (tool == InkTool.lasso && canPaste && onPaste != null) ...[
        _Divider(axis: axis),
        IconButton(
          tooltip: 'Paste',
          onPressed: onPaste,
          icon: const Icon(Icons.content_paste_rounded),
        ),
      ],
    ];
  }
}

Widget _toolbarFlex(Axis axis, List<Widget> children) =>
    Flex(direction: axis, mainAxisSize: MainAxisSize.min, children: children);

class _AxisGap extends StatelessWidget {
  const _AxisGap({required this.axis, required this.extent});

  final Axis axis;
  final double extent;

  @override
  Widget build(BuildContext context) => SizedBox(
    width: axis == Axis.horizontal ? extent : 0,
    height: axis == Axis.vertical ? extent : 0,
  );
}

class _ToolbarAxisScroller extends StatefulWidget {
  const _ToolbarAxisScroller({
    required this.axis,
    required this.extent,
    required this.child,
  });

  final Axis axis;
  final double extent;
  final Widget child;

  @override
  State<_ToolbarAxisScroller> createState() => _ToolbarAxisScrollerState();
}

class _ToolbarAxisScrollerState extends State<_ToolbarAxisScroller> {
  final ScrollController _controller = ScrollController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: widget.axis == Axis.horizontal
          ? widget.extent
          : _ToolbarCard.contentExtent,
      height: widget.axis == Axis.vertical
          ? widget.extent
          : _ToolbarCard.contentExtent,
      child: SingleChildScrollView(
        controller: _controller,
        scrollDirection: widget.axis,
        child: widget.child,
      ),
    );
  }
}

class _ToolbarCard extends StatelessWidget {
  const _ToolbarCard({
    required this.axis,
    required this.child,
    this.prominent = false,
  });

  final Axis axis;
  final Widget child;
  final bool prominent;

  static const double height = 42;
  static const double contentExtent = 36;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final cardExtent = prominent ? 52.0 : height;
    final cardContentExtent = prominent ? 44.0 : contentExtent;
    return Container(
      width: axis == Axis.vertical ? cardExtent : null,
      height: axis == Axis.horizontal ? cardExtent : null,
      decoration: BoxDecoration(
        color: scheme.surface.withValues(alpha: .97),
        borderRadius: BorderRadius.circular(prominent ? 18 : 14),
        border: Border.all(color: Theme.of(context).dividerColor),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: .11),
            blurRadius: prominent ? 15 : 12,
            offset: Offset(0, prominent ? 5 : 4),
          ),
        ],
      ),
      padding: axis == Axis.horizontal
          ? EdgeInsets.symmetric(
              horizontal: prominent ? 6 : 4,
              vertical: prominent ? 3 : 2,
            )
          : EdgeInsets.symmetric(
              horizontal: prominent ? 3 : 2,
              vertical: prominent ? 6 : 4,
            ),
      child: Center(
        child: SizedBox(
          width: axis == Axis.vertical ? cardContentExtent : null,
          height: axis == Axis.horizontal ? cardContentExtent : null,
          child: child,
        ),
      ),
    );
  }
}

class _Divider extends StatelessWidget {
  const _Divider({required this.axis, this.extent = 21});

  final Axis axis;
  final double extent;

  @override
  Widget build(BuildContext context) => Container(
    width: axis == Axis.horizontal ? 1 : extent,
    height: axis == Axis.vertical ? 1 : extent,
    margin: axis == Axis.horizontal
        ? const EdgeInsets.symmetric(horizontal: 4)
        : const EdgeInsets.symmetric(vertical: 4),
    color: Theme.of(context).dividerColor,
  );
}

class _ToolbarDragHandle extends StatelessWidget {
  const _ToolbarDragHandle({
    super.key,
    required this.axis,
    required this.callbacks,
    required this.label,
  });

  final Axis axis;
  final ToolbarDragCallbacks callbacks;
  final String label;

  @override
  Widget build(BuildContext context) => Tooltip(
    message: '$label — hold and drag',
    child: GestureDetector(
      behavior: HitTestBehavior.opaque,
      onLongPressStart: callbacks.onStart,
      onLongPressMoveUpdate: callbacks.onUpdate,
      onLongPressEnd: callbacks.onEnd,
      onLongPressCancel: callbacks.onCancel,
      child: SizedBox(
        width: axis == Axis.horizontal ? 24 : 40,
        height: axis == Axis.vertical ? 24 : 40,
        child: Center(
          child: RotatedBox(
            quarterTurns: axis == Axis.vertical ? 1 : 0,
            child: Icon(
              Icons.drag_indicator_rounded,
              size: 17,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ),
      ),
    ),
  );
}

class _ToolButton extends StatelessWidget {
  const _ToolButton({
    required this.icon,
    required this.label,
    required this.selected,
    required this.onTap,
  });
  final IconData icon;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Tooltip(
      message: label,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(13),
        child: Container(
          width: 42,
          height: 40,
          margin: const EdgeInsets.symmetric(horizontal: 1),
          decoration: BoxDecoration(
            color: selected ? scheme.primaryContainer : Colors.transparent,
            borderRadius: BorderRadius.circular(13),
          ),
          child: Icon(icon, size: 21, color: selected ? scheme.primary : null),
        ),
      ),
    );
  }
}

class _ActionButton extends StatelessWidget {
  const _ActionButton({required this.icon, required this.onTap});
  final IconData icon;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) =>
      IconButton(onPressed: onTap, icon: Icon(icon));
}

class _CircleActionButton extends StatelessWidget {
  const _CircleActionButton({
    required this.icon,
    required this.onTap,
    this.tooltip,
  });

  final IconData icon;
  final VoidCallback onTap;
  final String? tooltip;

  @override
  Widget build(BuildContext context) {
    final child = InkWell(
      onTap: onTap,
      customBorder: const CircleBorder(),
      child: Container(
        width: 30,
        height: 30,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          border: Border.all(color: Theme.of(context).dividerColor),
        ),
        child: Icon(icon, size: 16),
      ),
    );
    if (tooltip == null) return child;
    return Tooltip(message: tooltip!, child: child);
  }
}

class _PenTypeButton extends StatelessWidget {
  const _PenTypeButton({required this.tool, required this.onTap});

  final InkTool tool;
  final VoidCallback onTap;

  IconData get _icon => switch (tool) {
    InkTool.fountainPen => Icons.edit_outlined,
    InkTool.brushPen => Icons.brush_outlined,
    InkTool.highlighter => Icons.border_color_outlined,
    _ => Icons.mode_edit_outline_rounded,
  };

  String get _label => switch (tool) {
    InkTool.fountainPen => 'Fountain Pen settings',
    InkTool.brushPen => 'Brush Pen settings',
    InkTool.highlighter => 'Highlighter settings',
    _ => 'Ball Pen settings',
  };

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Tooltip(
      message: _label,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(11),
        child: Container(
          width: 36,
          height: 32,
          decoration: BoxDecoration(
            color: scheme.primaryContainer,
            borderRadius: BorderRadius.circular(11),
          ),
          child: Icon(_icon, size: 18, color: scheme.primary),
        ),
      ),
    );
  }
}

class _DropdownChip extends StatelessWidget {
  const _DropdownChip({this.icon, required this.label, this.compact = false});
  final IconData? icon;
  final String label;
  final bool compact;

  @override
  Widget build(BuildContext context) => Container(
    width: compact ? 34 : null,
    height: compact ? 30 : null,
    padding: compact
        ? EdgeInsets.zero
        : const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
    decoration: BoxDecoration(
      color: Theme.of(
        context,
      ).colorScheme.surfaceContainerHighest.withValues(alpha: .55),
      borderRadius: BorderRadius.circular(10),
    ),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (compact)
          icon == null
              ? Text(
                  label,
                  style: const TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w800,
                  ),
                )
              : Icon(icon, size: 16)
        else ...[
          if (icon != null) ...[Icon(icon, size: 15), const SizedBox(width: 4)],
          Text(label, style: const TextStyle(fontWeight: FontWeight.w700)),
          const SizedBox(width: 4),
          const Icon(Icons.expand_more, size: 14),
        ],
      ],
    ),
  );
}

class _OptionChip extends StatelessWidget {
  const _OptionChip({
    required this.icon,
    required this.label,
    required this.selected,
    required this.onTap,
    this.compact = false,
  });

  final IconData icon;
  final String label;
  final bool selected;
  final VoidCallback onTap;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Tooltip(
      message: label,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(10),
        child: Container(
          width: compact ? 34 : null,
          height: 30,
          padding: compact
              ? EdgeInsets.zero
              : const EdgeInsets.symmetric(horizontal: 8),
          decoration: BoxDecoration(
            color: selected
                ? scheme.primaryContainer
                : scheme.surfaceContainerHighest.withValues(alpha: .4),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color: selected ? scheme.primary : Colors.transparent,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                icon,
                size: 15,
                color: selected ? scheme.primary : scheme.onSurfaceVariant,
              ),
              if (!compact) ...[
                const SizedBox(width: 4),
                Text(
                  label,
                  style: TextStyle(
                    fontWeight: FontWeight.w700,
                    color: selected ? scheme.primary : null,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _WidthButton extends StatelessWidget {
  const _WidthButton({
    required this.width,
    required this.selected,
    required this.onTap,
  });

  final double width;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final label = width == width.roundToDouble()
        ? width.toStringAsFixed(0)
        : width.toStringAsFixed(1);
    final dotSize = (width * 1.8 + 3).clamp(6.0, 24.0).toDouble();
    return Tooltip(
      message: selected ? '$label pt — tap again to edit' : '$label pt',
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(14),
        child: Container(
          width: 32,
          height: 30,
          margin: const EdgeInsets.symmetric(horizontal: 1.5),
          decoration: BoxDecoration(
            color: selected
                ? Theme.of(context).colorScheme.surfaceContainerHighest
                : Colors.transparent,
            borderRadius: BorderRadius.circular(10),
          ),
          child: Center(
            child: Container(
              width: dotSize,
              height: dotSize,
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.onSurface,
                shape: BoxShape.circle,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _EraserSizeButton extends StatelessWidget {
  const _EraserSizeButton({
    required this.size,
    required this.selected,
    required this.onTap,
  });
  final double size;
  final bool selected;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) => InkWell(
    onTap: onTap,
    customBorder: const CircleBorder(),
    child: Container(
      width: 35,
      height: 35,
      margin: const EdgeInsets.symmetric(horizontal: 3),
      alignment: Alignment.center,
      child: Container(
        width: (size * .55).clamp(14.0, 36.0).toDouble(),
        height: (size * .55).clamp(14.0, 36.0).toDouble(),
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: Colors.transparent,
          border: Border.all(
            color: selected
                ? Theme.of(context).colorScheme.primary
                : Theme.of(context).dividerColor,
            width: selected ? 3 : 2,
          ),
        ),
      ),
    ),
  );
}

class _LineButton extends StatelessWidget {
  const _LineButton({
    required this.dashed,
    required this.selected,
    required this.onTap,
  });
  final bool dashed;
  final bool selected;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) => InkWell(
    onTap: onTap,
    borderRadius: BorderRadius.circular(14),
    child: Container(
      width: 35,
      height: 30,
      margin: const EdgeInsets.symmetric(horizontal: 1.5),
      decoration: BoxDecoration(
        color: selected
            ? Theme.of(context).colorScheme.surfaceContainerHighest
            : Colors.transparent,
        borderRadius: BorderRadius.circular(10),
      ),
      child: CustomPaint(painter: _LinePainter(dashed: dashed)),
    ),
  );
}

class _LinePainter extends CustomPainter {
  const _LinePainter({required this.dashed});
  final bool dashed;
  @override
  void paint(Canvas canvas, Size size) {
    final p = Paint()
      ..color = Colors.black54
      ..strokeWidth = 2
      ..strokeCap = StrokeCap.round;
    final y = size.height / 2;
    if (!dashed) {
      canvas.drawLine(Offset(7, y), Offset(size.width - 7, y), p);
    } else {
      for (double x = 7; x < size.width - 7; x += 9) {
        canvas.drawLine(
          Offset(x, y),
          Offset((x + 5).clamp(0.0, size.width - 7).toDouble(), y),
          p,
        );
      }
    }
  }

  @override
  bool shouldRepaint(covariant _LinePainter oldDelegate) =>
      oldDelegate.dashed != dashed;
}

class _ColorDot extends StatelessWidget {
  const _ColorDot({
    required this.color,
    required this.selected,
    required this.onTap,
  });
  final Color color;
  final bool selected;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) => InkWell(
    onTap: onTap,
    customBorder: const CircleBorder(),
    child: Container(
      width: 26,
      height: 21,
      margin: const EdgeInsets.symmetric(horizontal: 3),
      decoration: BoxDecoration(
        color: color,
        shape: BoxShape.circle,
        border: Border.all(
          color: selected
              ? Theme.of(context).colorScheme.onSurface
              : Colors.transparent,
          width: 2,
        ),
      ),
    ),
  );
}

class _ToggleButton extends StatelessWidget {
  const _ToggleButton({
    required this.label,
    required this.selected,
    required this.onTap,
    this.italic = false,
  });
  final String label;
  final bool selected;
  final VoidCallback onTap;
  final bool italic;
  @override
  Widget build(BuildContext context) => InkWell(
    onTap: onTap,
    borderRadius: BorderRadius.circular(12),
    child: Container(
      width: 29,
      height: 29,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: selected
            ? Theme.of(context).colorScheme.primaryContainer
            : Colors.transparent,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontWeight: FontWeight.bold,
          fontStyle: italic ? FontStyle.italic : FontStyle.normal,
          fontSize: 14,
        ),
      ),
    ),
  );
}
