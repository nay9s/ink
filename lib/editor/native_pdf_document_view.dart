import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Controls commands that must be handled by the operating-system PDF editor.
///
/// The Flutter editor owns the toolbar, while iOS owns the vector PDF
/// annotations. This controller bridges Undo, Redo and Save to that native
/// annotation history.
class NativePdfController {
  MethodChannel? _channel;

  bool canUndo = false;
  bool canRedo = false;
  bool supportsAppHistory = false;
  VoidCallback? onStateChanged;

  Future<void> undo() async {
    if (!supportsAppHistory || !canUndo) return;
    await _channel?.invokeMethod<void>('undo');
  }

  Future<void> redo() async {
    if (!supportsAppHistory || !canRedo) return;
    await _channel?.invokeMethod<void>('redo');
  }

  Future<void> save() async {
    await _channel?.invokeMethod<void>('save');
  }

  void _attach(MethodChannel channel) {
    _channel = channel;
    _updateHistory(
      canUndo: false,
      canRedo: false,
      supportsAppHistory: false,
    );
  }

  void _detach(MethodChannel channel) {
    if (_channel != channel) return;
    _channel = null;
    _updateHistory(
      canUndo: false,
      canRedo: false,
      supportsAppHistory: false,
    );
  }

  void _updateHistory({
    required bool canUndo,
    required bool canRedo,
    required bool supportsAppHistory,
  }) {
    if (this.canUndo == canUndo &&
        this.canRedo == canRedo &&
        this.supportsAppHistory == supportsAppHistory) {
      return;
    }
    this.canUndo = canUndo;
    this.canRedo = canRedo;
    this.supportsAppHistory = supportsAppHistory;
    onStateChanged?.call();
  }
}

/// Hosts the operating-system PDF viewer and keeps Flutter's page controls in
/// sync with the page currently visible inside the native viewer.
class NativePdfDocumentView extends StatefulWidget {
  const NativePdfDocumentView({
    super.key,
    required this.path,
    required this.controller,
    this.page = 0,
    required this.tool,
    required this.colorValue,
    required this.strokeWidth,
    required this.eraserMode,
    this.allowFinger = false,
    this.onPageChanged,
    this.onDocumentChanged,
  });

  static const String viewType = 'ink_note/native_pdf_view';

  final String path;
  final NativePdfController controller;
  final int page;
  final String tool;
  final int colorValue;
  final double strokeWidth;
  final String eraserMode;
  final bool allowFinger;
  final ValueChanged<int>? onPageChanged;
  final VoidCallback? onDocumentChanged;

  @override
  State<NativePdfDocumentView> createState() =>
      _NativePdfDocumentViewState();
}

class _NativePdfDocumentViewState extends State<NativePdfDocumentView> {
  MethodChannel? _channel;
  int? _lastNativePage;

  Map<String, Object> get _creationParams => <String, Object>{
        'path': widget.path,
        'initialPage': widget.page,
        'tool': widget.tool,
        'color': widget.colorValue,
        'width': widget.strokeWidth,
        'eraserMode': widget.eraserMode,
        'allowFinger': widget.allowFinger,
      };

  Set<Factory<OneSequenceGestureRecognizer>> get _gestures =>
      <Factory<OneSequenceGestureRecognizer>>{
        Factory<OneSequenceGestureRecognizer>(EagerGestureRecognizer.new),
      };

  @override
  void didUpdateWidget(covariant NativePdfDocumentView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller && _channel != null) {
      oldWidget.controller._detach(_channel!);
      widget.controller._attach(_channel!);
    }
    if (oldWidget.path != widget.path) return;
    if (oldWidget.page != widget.page && widget.page != _lastNativePage) {
      unawaited(
        _channel?.invokeMethod<void>('goToPage', <String, Object>{
          'page': widget.page,
        }),
      );
    }
    if (oldWidget.tool != widget.tool ||
        oldWidget.colorValue != widget.colorValue ||
        oldWidget.strokeWidth != widget.strokeWidth ||
        oldWidget.eraserMode != widget.eraserMode ||
        oldWidget.allowFinger != widget.allowFinger) {
      unawaited(_sendTool());
    }
  }

  Future<void> _sendTool() async {
    await _channel?.invokeMethod<void>('setTool', <String, Object>{
      'tool': widget.tool,
      'color': widget.colorValue,
      'width': widget.strokeWidth,
      'eraserMode': widget.eraserMode,
      'allowFinger': widget.allowFinger,
    });
  }

  Future<void> _onPlatformViewCreated(int id) async {
    final channel = MethodChannel('ink_note/native_pdf_view_$id');
    _channel = channel;
    widget.controller._attach(channel);
    channel.setMethodCallHandler((call) async {
      final arguments = call.arguments;
      switch (call.method) {
        case 'pageChanged':
          final page = arguments is Map ? arguments['page'] as int? : null;
          if (page == null || page < 0) return;
          _lastNativePage = page;
          widget.onPageChanged?.call(page);
          return;
        case 'historyChanged':
          if (arguments is! Map) return;
          widget.controller._updateHistory(
            canUndo: arguments['canUndo'] == true,
            canRedo: arguments['canRedo'] == true,
            supportsAppHistory: arguments['supportsAppHistory'] == true,
          );
          return;
        case 'documentChanged':
          widget.onDocumentChanged?.call();
          return;
      }
    });
    await channel.invokeMethod<void>('goToPage', <String, Object>{
      'page': widget.page,
    });
    await _sendTool();
  }

  @override
  void dispose() {
    final channel = _channel;
    if (channel != null) {
      widget.controller._detach(channel);
      channel.setMethodCallHandler(null);
    }
    _channel = null;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (defaultTargetPlatform == TargetPlatform.iOS) {
      return UiKitView(
        viewType: NativePdfDocumentView.viewType,
        creationParams: _creationParams,
        creationParamsCodec: const StandardMessageCodec(),
        gestureRecognizers: _gestures,
        onPlatformViewCreated: _onPlatformViewCreated,
      );
    }
    if (defaultTargetPlatform == TargetPlatform.android) {
      return AndroidView(
        viewType: NativePdfDocumentView.viewType,
        creationParams: _creationParams,
        creationParamsCodec: const StandardMessageCodec(),
        gestureRecognizers: _gestures,
        onPlatformViewCreated: _onPlatformViewCreated,
      );
    }
    return const Center(
      child: Text('Native PDF viewing is available on iOS and Android.'),
    );
  }
}
