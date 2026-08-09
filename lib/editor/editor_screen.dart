import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';
// pdfrx and pdfx both export PdfDocument/PdfPage classes; pdfrx is only
// used for the small pure-PDF-notebook surface below, so keep it prefixed
// rather than hiding symbols from the far more heavily used pdfx import.
import 'package:pdfrx/pdfrx.dart' as pdfrx;
import 'package:pdfx/pdfx.dart';
import 'package:share_plus/share_plus.dart';

import '../models.dart';
import '../noten_archive.dart';
import '../pdf_note_backing.dart';
import '../store.dart';
import 'adaptive_pdf_page.dart';
import 'eraser_geometry.dart';
import 'image_source_sheet.dart';
import 'ink_painter.dart';
import 'native_pdf_document_view.dart';
import 'native_pdf_ink_importer.dart';
import 'native_pdf_page_display.dart';
import 'page_strip.dart';
import 'pdf_vector_exporter.dart';
import 'pdf_zoom_out_size_delegate.dart';
import 'selection_toolbar_layout.dart';
import 'selection_transform.dart';
import 'shape_recognizer.dart';
import 'stroke_stabilizer.dart';
import 'toolbar.dart';
import 'toolbar_docking.dart';

enum _ExportChoice { pdfOrImage, noten }

const _lightEditorWorkspaceColor = Color(0xFFF5F5F5);
const _darkEditorWorkspaceColor = Color(0xFF20232B);

Color _editorWorkspaceColor(BuildContext context) {
  return Theme.of(context).brightness == Brightness.dark
      ? _darkEditorWorkspaceColor
      : _lightEditorWorkspaceColor;
}

class EditorScreen extends StatefulWidget {
  const EditorScreen({
    super.key,
    required this.document,
    required this.openDocuments,
    required this.activeDocumentId,
    required this.onSelectTab,
    required this.onCloseTab,
    required this.onNewTab,
    required this.onExit,
    required this.onDocumentSaved,
  });

  final InkDocument document;
  final List<InkDocument> openDocuments;
  final String activeDocumentId;
  final ValueChanged<String> onSelectTab;
  final ValueChanged<String> onCloseTab;
  final VoidCallback onNewTab;
  final VoidCallback onExit;
  final ValueChanged<InkDocument> onDocumentSaved;

  @override
  State<EditorScreen> createState() => _EditorScreenState();
}

class _EditorScreenState extends State<EditorScreen>
    with WidgetsBindingObserver {
  late List<List<InkObject>> _pages;
  late List<String?> _pageBackgrounds;
  late List<double?> _pageAspectRatios;
  late List<String?> _pagePdfPaths;
  late List<int?> _pagePdfPageNumbers;
  AppSettings _settings = const AppSettings();
  int _currentPageIndex = 0;

  final List<List<List<InkObject>>> _undo = [];
  final List<List<List<InkObject>>> _redo = [];
  final NativePdfController _nativePdfController = NativePdfController();
  final pdfrx.PdfViewerController _pdfrxController =
      pdfrx.PdfViewerController();
  int _pdfrxPageStart = 0;

  InkStroke? _activeStroke;
  InkTool _tool = InkTool.pen;
  Color _color = const Color(0xFF17233C);
  Color _highlighterColor = const Color(0xFFFFFF73);
  double _width = 2;
  double _highlighterWidth = 14;
  double _smoothing = .45;
  double _pressureSensitivity = .7;
  double _eraserSize = 28;
  EraserMode _eraserMode = EraserMode.precision;
  bool _eraseHighlighterOnly = false;
  bool _eraserAutoDeselect = false;
  InkTool _lastDrawingTool = InkTool.pen;
  InkTool _lastPenTool = InkTool.pen;
  InkPoint? _eraserCursor;
  final StrokeStabilizer _strokeStabilizer = StrokeStabilizer();
  bool _activeStrokeHasRawTip = false;
  static const List<PenPreset> _defaultPenSizePresets = [
    PenPreset(size: 1.5, smoothing: .45),
    PenPreset(size: 2, smoothing: .45),
    PenPreset(size: 3, smoothing: .45),
  ];
  static const List<PenPreset> _defaultHighlighterSizePresets = [
    PenPreset(size: 8, smoothing: .45),
    PenPreset(size: 14, smoothing: .45),
    PenPreset(size: 20, smoothing: .45),
  ];

  List<PenPreset> _presets = List<PenPreset>.of(_defaultPenSizePresets);
  List<PenPreset> _highlighterPresets = List<PenPreset>.of(
    _defaultHighlighterSizePresets,
  );
  List<Color> _colorPresets = List<Color>.of(_defaultColorPresets);
  List<Color> _highlighterColorPresets = List<Color>.of(
    _defaultHighlighterColorPresets,
  );

  static const List<Color> _defaultColorPresets = [
    Color(0xFF000000),
    Color(0xFF5F6368),
    Color(0xFF9AA0A6),
    Color(0xFFDADCE0),
    Color(0xFFFFFFFF),
    Color(0xFF8E24AA),
    Color(0xFFE53935),
    Color(0xFFFF5A67),
    Color(0xFFFF8A8F),
    Color(0xFFFF9F1C),
    Color(0xFF1877F2),
    Color(0xFF0D55A5),
    Color(0xFF098765),
    Color(0xFF72C62B),
    Color(0xFFFFFF73),
    Color(0xFFB000F5),
    Color(0xFFF542B3),
    Color(0xFF49CBE8),
  ];
  static const List<Color> _defaultHighlighterColorPresets = [
    Color(0xFFFFFF73),
    Color(0xFFA7F36B),
    Color(0xFF70E1F5),
    Color(0xFFFF8FD1),
    Color(0xFFFFB45E),
    Color(0xFFC9A7FF),
    Color(0xFFFF6B6B),
  ];
  int? _activePointer;
  PointerDeviceKind? _activePointerKind;
  final Set<int> _touchPointers = <int>{};
  bool _temporaryEraser = false;
  bool _interactionChanged = false;
  bool _dirty = false;
  Timer? _saveTimer;
  Timer? _viewSaveTimer;
  Timer? _lineAssistTimer;

  /// Where the pen was when the hold-to-snap countdown last (re)started.
  /// Samples within [_shapeAssistHoldSlack] of it count as holding still.
  InkPoint? _shapeAssistAnchor;
  Timer? _pdfQualityTimer;
  bool _viewStateLoaded = false;
  double _pdfRenderScaleBucket = 1;

  bool _zoomMode = false;
  bool _verticalPageMode = true;
  bool _pagesPanelCollapsed = true;
  bool _dashedStroke = false;
  double _textSize = 24;
  bool _textBold = false;
  bool _textItalic = false;
  TextAlign _textAlign = TextAlign.left;
  double _textLineHeight = 1.2;
  ToolbarDock _primaryToolbarDock = ToolbarDock.top;
  int _primaryToolbarOrder = 0;
  ToolbarDock _optionsToolbarDock = ToolbarDock.top;
  int _optionsToolbarOrder = 1;
  /// Set once hold-to-snap has replaced the live stroke with a recognised
  /// shape, after which the pen drags that shape instead of adding points.
  bool _shapeSnapPreview = false;

  /// Where the pen was at the moment of the snap, and the shape point that
  /// tracks it. The drag is applied as a delta between the two so the
  /// recognised shape stays exactly where it was drawn until the hand moves.
  InkPoint? _shapeSnapPointerOrigin;
  InkPoint? _shapeSnapTrackedOrigin;
  final List<InkPoint> _lassoPath = [];
  final List<InkPoint> _selectionLassoPath = [];
  bool _selectionMoveMode = false;

  /// True only while a selection is actively being dragged or resized, as
  /// opposed to _selectionMoveMode, which stays armed after the pointer
  /// lifts. The selection toolbar is skipped entirely while this is set.
  bool _draggingSelection = false;
  bool _selectionPointerStartedInside = false;
  SelectionResizeHandle? _activeSelectionResizeHandle;
  Rect? _selectionResizeStartBounds;
  Offset? _selectionResizeStartPointer;
  final Map<int, InkObject> _selectionResizeStartObjects = <int, InkObject>{};
  final List<InkPoint> _selectionResizeStartPath = <InkPoint>[];
  final List<InkObject> _selectionClipboard = [];
  final Map<String, ui.Image> _decodedImages = <String, ui.Image>{};
  final Map<String, Future<void>> _imageLoads = <String, Future<void>>{};
  bool _imagePickerOpen = false;
  bool _addingPage = false;
  List<InkObject> get _currentObjects => _pages[_currentPageIndex];

  int? get _nativePdfStartIndex {
    if (_pagePdfPaths.isEmpty || _pagePdfPageNumbers.isEmpty) return null;
    for (var start = 0; start < _pages.length; start++) {
      if (start >= _pagePdfPaths.length ||
          start >= _pagePdfPageNumbers.length) {
        break;
      }
      final path = _pagePdfPaths[start];
      if (path == null || path.isEmpty || _pagePdfPageNumbers[start] != 1) {
        continue;
      }
      var pageNumber = 1;
      var index = start;
      while (index < _pages.length &&
          index < _pagePdfPaths.length &&
          index < _pagePdfPageNumbers.length &&
          _pagePdfPaths[index] == path &&
          _pagePdfPageNumbers[index] == pageNumber) {
        index++;
        pageNumber++;
      }
      if (index > start) return start;
    }
    return null;
  }

  String? get _nativePdfPath {
    final start = _nativePdfStartIndex;
    if (start == null || start >= _pagePdfPaths.length) return null;
    return _pagePdfPaths[start];
  }

  int get _nativePdfInitialPage {
    final start = _nativePdfStartIndex ?? 0;
    return (_currentPageIndex - start).clamp(0, 1 << 20).toInt();
  }

  // Retired: PDF pages no longer render through the old native platform-view
  // engine (see build()). _qualifiesForLegacyNativeReader below keeps the
  // same "single uninterrupted PDF" detection alive for two things that both
  // still need it: the one-time importer that finds ink trapped in old
  // native PDF annotations, and _usePdfrxViewer, which routes qualifying
  // documents through pdfrx instead of the raster (AdaptivePdfPage) path
  // mixed notebooks use.
  bool get _showNativePdfReader => false;

  bool get _qualifiesForLegacyNativeReader {
    final path = _nativePdfPath;
    if (path == null || _pages.isEmpty) return false;
    // A single native PDF view could only ever represent one uninterrupted
    // PDF document, so this only ever applied to notebooks that are a single
    // imported PDF cover to cover. pdfrx's PdfViewer has the same
    // one-document constraint, so _usePdfrxViewer reuses this exact check.
    return _pagePdfPaths.length == _pages.length &&
        _pagePdfPaths.every((item) => item == path) &&
        _pagePdfPageNumbers.length == _pages.length &&
        _pagePdfPageNumbers.every((item) => item != null);
  }

  /// Pure-PDF notebooks render through pdfrx (real vector rendering, native
  /// text selection, no drift between the page and the ink layer under zoom
  /// — validated on-device via the pdfrx spike) instead of the raster
  /// AdaptivePdfPage fallback mixed notebooks still use. pdfrx's PdfViewer
  /// owns its own multi-page continuous scrolling, so this applies
  /// regardless of _verticalPageMode for a qualifying document.
  bool get _usePdfrxViewer => _qualifiesForLegacyNativeReader;

  bool get _canUndoCurrent =>
      _showNativePdfReader ? _nativePdfController.canUndo : _undo.isNotEmpty;

  bool get _canRedoCurrent =>
      _showNativePdfReader ? _nativePdfController.canRedo : _redo.isNotEmpty;

  double get _continuousViewScale => _continuousTransformationController.value
      .getMaxScaleOnAxis()
      .clamp(.1, 4.0)
      .toDouble();

  double get _eraserCanvasToScreenScale {
    if (_usePdfrxViewer) {
      if (!_pdfrxController.isReady) return 1.0;
      return _pdfrxController.value.getMaxScaleOnAxis();
    }
    return _verticalPageMode
        ? _continuousViewScale
        : _transformationController.value
              .getMaxScaleOnAxis()
              .clamp(.1, 6.0)
              .toDouble();
  }

  EraserGeometry get _eraserGeometry => EraserGeometry(
    screenDiameter: _eraserSize,
    canvasToScreenScale: _eraserCanvasToScreenScale,
    // pdfrx resolves pointer positions against each page's already-
    // transformed screen rect. The other viewers deliver page-local
    // coordinates before their InteractiveViewer transform.
    hitTestInScreenSpace: _usePdfrxViewer,
  );

  double get _eraserCanvasDiameter => _eraserGeometry.canvasDiameter;

  Offset? _lastSelectPosition;
  int? _pendingTouchTapPointer;
  Offset? _pendingTouchTapDownPosition;
  bool _pendingTouchTapMoved = false;

  final GlobalKey _editorViewportKey = GlobalKey();
  final GlobalKey _canvasKey = GlobalKey();
  final TransformationController _transformationController =
      TransformationController();
  final TransformationController _continuousTransformationController =
      TransformationController();
  double _continuousPaperWidth = 0;
  double _continuousGap = 8;
  double _continuousViewportWidth = 0;
  double _continuousViewportHeight = 0;
  double _pageViewportWidth = 0;
  double _pageViewportHeight = 0;
  Offset? _pageGestureScenePoint;
  Offset? _pageGestureStartFocalPoint;
  double _pageGestureStartScale = 1;
  Offset? _continuousGestureScenePoint;
  Offset? _continuousGestureStartFocalPoint;
  double _continuousGestureStartScale = 1;
  bool _correctingPageTransform = false;
  bool _correctingContinuousTransform = false;
  static const double _horizontalPanThreshold = 6.0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _nativePdfController.onStateChanged = () {
      if (mounted) setState(() {});
    };
    _transformationController.addListener(_handlePageTransformChanged);
    _continuousTransformationController.addListener(
      _handleContinuousTransformChanged,
    );
    _pdfrxController.addListener(_handlePdfrxTransformChanged);
    _pages = widget.document.pages
        .map((page) => List<InkObject>.of(page))
        .toList();
    if (_pages.isEmpty) _pages.add([]);
    _pageBackgrounds = List<String?>.of(widget.document.pageBackgrounds);
    while (_pageBackgrounds.length < _pages.length) {
      _pageBackgrounds.add(null);
    }
    _pageAspectRatios = List<double?>.of(widget.document.pageAspectRatios);
    while (_pageAspectRatios.length < _pages.length) {
      _pageAspectRatios.add(null);
    }
    _pagePdfPaths = List<String?>.of(widget.document.pagePdfPaths);
    while (_pagePdfPaths.length < _pages.length) {
      _pagePdfPaths.add(null);
    }
    _pagePdfPageNumbers = List<int?>.of(widget.document.pagePdfPageNumbers);
    while (_pagePdfPageNumbers.length < _pages.length) {
      _pagePdfPageNumbers.add(null);
    }
    unawaited(_loadDocumentImages());
    unawaited(_hydrateMissingPageAspectRatios());

    unawaited(_restorePersistentEditorState());
    unawaited(_importLegacyNativeInkIfNeeded());
  }

  /// Notes edited before PDF-page ink moved into this Flutter layer still
  /// have real ink baked directly into their PDF file as native
  /// PDFAnnotations (see _qualifiesForLegacyNativeReader). Recover it once
  /// so it doesn't silently disappear now that _showNativePdfReader never
  /// renders the native reader.
  Future<void> _importLegacyNativeInkIfNeeded() async {
    if (!_qualifiesForLegacyNativeReader) return;
    final path = _nativePdfPath;
    if (path == null) return;
    final start = _nativePdfStartIndex ?? 0;
    if (start >= _pages.length) return;
    // Only worth the native round-trip if this PDF's pages don't already
    // have ink recorded in the Flutter model.
    final alreadyHasInk = _pages.sublist(start).any((page) => page.isNotEmpty);
    if (alreadyHasInk) return;

    final imported = await NativePdfInkImporter.extractStrokes(path);
    if (imported.isEmpty || !mounted) return;

    setState(() {
      for (final item in imported) {
        final pageIndex = start + item.pdfPageIndex;
        if (pageIndex < 0 || pageIndex >= _pages.length) continue;
        _pages[pageIndex].add(item.stroke);
      }
    });
    _scheduleSave();
  }

  Future<void> _restorePersistentEditorState() async {
    final values = await Future.wait<Object?>([
      AppSettingsStore.load(),
      InkStore.loadPresets(),
      InkStore.loadHighlighterPresets(),
      InkStore.loadColorPresets(),
      InkStore.loadHighlighterColorPresets(),
      AppSessionStore.loadEditorState(widget.document.id),
    ]);
    if (!mounted) return;

    final settings = values[0] as AppSettings;
    _settings = settings;
    final savedPenPresets = values[1] as List<PenPreset>;
    final savedHighlighterPresets = values[2] as List<PenPreset>;
    final savedColors = values[3] as List<Color>;
    final savedHighlighterColors = values[4] as List<Color>;
    final viewState = values[5] as EditorViewState?;
    final uniquePenPresets = _uniqueSizePresets(savedPenPresets);
    final uniqueHighlighterPresets = _uniqueSizePresets(
      savedHighlighterPresets,
    );

    setState(() {
      _smoothing = viewState?.smoothing ?? settings.defaultSmoothing;
      _width = viewState?.width ?? settings.defaultWidth;
      if (uniquePenPresets.isNotEmpty) _presets = uniquePenPresets;
      if (uniqueHighlighterPresets.isNotEmpty) {
        _highlighterPresets = uniqueHighlighterPresets;
      }
      if (savedColors.isNotEmpty) _colorPresets = savedColors;
      if (savedHighlighterColors.isNotEmpty) {
        _highlighterColorPresets = savedHighlighterColors;
      }
      if (viewState != null) {
        final toolbarDocking = normalizeToolbarDocking(
          primary: ToolbarPlacement(
            dock: viewState.primaryToolbarDock,
            order: viewState.primaryToolbarOrder,
          ),
          options: ToolbarPlacement(
            dock: viewState.optionsToolbarDock,
            order: viewState.optionsToolbarOrder,
          ),
        );
        _currentPageIndex = viewState.currentPageIndex
            .clamp(0, _pages.length - 1)
            .toInt();
        _tool = viewState.tool;
        _color = Color(viewState.colorValue);
        _highlighterColor = Color(viewState.highlighterColorValue);
        _highlighterWidth = viewState.highlighterWidth;
        _pressureSensitivity = viewState.pressureSensitivity;
        _eraserSize = viewState.eraserSize;
        _eraserMode = viewState.eraserMode;
        _eraseHighlighterOnly = viewState.eraseHighlighterOnly;
        _eraserAutoDeselect = viewState.eraserAutoDeselect;
        _lastDrawingTool = viewState.lastDrawingTool;
        _lastPenTool = viewState.lastPenTool;
        _zoomMode = viewState.zoomMode;
        _verticalPageMode = viewState.verticalPageMode;
        _pagesPanelCollapsed = viewState.pagesPanelCollapsed;
        _dashedStroke = viewState.dashedStroke;
        _textSize = viewState.textSize;
        _textBold = viewState.textBold;
        _textItalic = viewState.textItalic;
        _textAlign = viewState.textAlign;
        _textLineHeight = viewState.textLineHeight;
        _primaryToolbarDock = toolbarDocking.primary.dock;
        _primaryToolbarOrder = toolbarDocking.primary.order;
        _optionsToolbarDock = toolbarDocking.options.dock;
        _optionsToolbarOrder = toolbarDocking.options.order;
      }
    });

    if (savedPenPresets.length != uniquePenPresets.length) {
      unawaited(InkStore.savePresets(uniquePenPresets));
    }
    if (savedHighlighterPresets.length != uniqueHighlighterPresets.length) {
      unawaited(InkStore.saveHighlighterPresets(uniqueHighlighterPresets));
    }

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (viewState?.pageTransform.length == 16) {
        _transformationController.value = Matrix4.fromList(
          viewState!.pageTransform,
        );
      }
      if (viewState?.continuousTransform.length == 16) {
        _continuousTransformationController.value = Matrix4.fromList(
          viewState!.continuousTransform,
        );
      } else if (_verticalPageMode && _currentPageIndex > 0) {
        _scrollContinuousViewToPage(_currentPageIndex);
      }
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _clampPageHorizontalTransform();
        _clampContinuousHorizontalTransform();
      });
      _viewStateLoaded = true;
      _scheduleViewStateSave();
    });
  }

  @override
  void setState(VoidCallback fn) {
    super.setState(fn);
    if (_viewStateLoaded) _scheduleViewStateSave();
  }

  void _scheduleViewStateSave() {
    if (!_viewStateLoaded) return;
    _viewSaveTimer?.cancel();
    _viewSaveTimer = Timer(
      const Duration(milliseconds: 140),
      () => unawaited(_saveEditorViewState()),
    );
  }

  EditorViewState _captureEditorViewState() => EditorViewState(
    currentPageIndex: _currentPageIndex,
    tool: _tool,
    colorValue: _color.toARGB32(),
    highlighterColorValue: _highlighterColor.toARGB32(),
    width: _width,
    highlighterWidth: _highlighterWidth,
    smoothing: _smoothing,
    pressureSensitivity: _pressureSensitivity,
    eraserSize: _eraserSize,
    eraserMode: _eraserMode,
    eraseHighlighterOnly: _eraseHighlighterOnly,
    eraserAutoDeselect: _eraserAutoDeselect,
    lastDrawingTool: _lastDrawingTool,
    lastPenTool: _lastPenTool,
    zoomMode: _zoomMode,
    verticalPageMode: _verticalPageMode,
    pagesPanelCollapsed: _pagesPanelCollapsed,
    dashedStroke: _dashedStroke,
    textSize: _textSize,
    textBold: _textBold,
    textItalic: _textItalic,
    textAlign: _textAlign,
    textLineHeight: _textLineHeight,
    primaryToolbarDock: _primaryToolbarDock,
    primaryToolbarOrder: _primaryToolbarOrder,
    optionsToolbarDock: _optionsToolbarDock,
    optionsToolbarOrder: _optionsToolbarOrder,
    pageTransform: _transformationController.value.storage.toList(),
    continuousTransform: _continuousTransformationController.value.storage
        .toList(),
  );

  Future<void> _saveEditorViewState() async {
    if (!_viewStateLoaded) return;
    try {
      await AppSessionStore.saveEditorState(
        widget.document.id,
        _captureEditorViewState(),
      );
    } catch (_) {
      // The document content remains safe even if one view-state write fails.
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached ||
        state == AppLifecycleState.hidden) {
      _saveTimer?.cancel();
      _viewSaveTimer?.cancel();
      unawaited(_saveDocument().then<void>((_) {}));
      unawaited(_saveEditorViewState());
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _saveTimer?.cancel();
    _viewSaveTimer?.cancel();
    _lineAssistTimer?.cancel();
    _pdfQualityTimer?.cancel();
    _nativePdfController.onStateChanged = null;
    unawaited(_saveDocument().then<void>((_) {}));
    unawaited(_saveEditorViewState());
    _transformationController
      ..removeListener(_handlePageTransformChanged)
      ..dispose();
    _continuousTransformationController
      ..removeListener(_handleContinuousTransformChanged)
      ..dispose();
    _pdfrxController.removeListener(_handlePdfrxTransformChanged);
    for (final image in _decodedImages.values) {
      image.dispose();
    }
    _decodedImages.clear();
    super.dispose();
  }

  double _pageAspectRatio(int index) {
    final saved = index >= 0 && index < _pageAspectRatios.length
        ? _pageAspectRatios[index]
        : null;
    if (saved == null || !saved.isFinite || saved <= .15) return 1.35;
    return saved.clamp(.15, 6.0).toDouble();
  }

  Future<void> _loadDocumentImages() async {
    final paths = _pages
        .expand((page) => page.whereType<InkImage>())
        .map((image) => image.path)
        .where((path) => path.isNotEmpty)
        .toSet();
    await Future.wait(paths.map(_loadStoredImage));
  }

  Future<void> _loadStoredImage(String path) {
    if (_decodedImages.containsKey(path)) return Future<void>.value();
    return _imageLoads.putIfAbsent(path, () async {
      ui.Codec? codec;
      ui.Image? loadedImage;
      var retained = false;
      try {
        final file = File(path);
        if (!await file.exists()) return;
        codec = await ui.instantiateImageCodec(await file.readAsBytes());
        final frame = await codec.getNextFrame();
        loadedImage = frame.image;
        if (!mounted) return;
        setState(() {
          _decodedImages.remove(path)?.dispose();
          _decodedImages[path] = loadedImage!;
        });
        retained = true;
        if (_pdfrxController.isReady) _pdfrxController.invalidate();
      } catch (_) {
        // Keep the note usable if one inserted image is missing or corrupt.
      } finally {
        if (!retained) loadedImage?.dispose();
        codec?.dispose();
      }
    });
  }

  Future<void> _hydrateMissingPageAspectRatios() async {
    final discovered = <int, double>{};
    for (var index = 0; index < _pages.length; index++) {
      if (_pageAspectRatios[index] != null) continue;
      final background = index < _pageBackgrounds.length
          ? _pageBackgrounds[index]
          : null;
      if (background == null) continue;

      try {
        final file = File(background);
        if (!await file.exists()) continue;
        final codec = await ui.instantiateImageCodec(
          await file.readAsBytes(),
          targetWidth: 24,
        );
        final frame = await codec.getNextFrame();
        final width = frame.image.width.toDouble();
        final height = frame.image.height.toDouble();
        frame.image.dispose();
        codec.dispose();
        if (width > 0 && height > 0) {
          discovered[index] = height / width;
        }
      } catch (_) {
        // Keep the default paper ratio if an old background cannot be decoded.
      }
    }

    if (!mounted || discovered.isEmpty) return;
    setState(() {
      for (final entry in discovered.entries) {
        _pageAspectRatios[entry.key] = entry.value;
      }
    });
    _scheduleSave();
  }

  List<List<InkObject>> _copyPages() =>
      _pages.map((page) => List<InkObject>.of(page)).toList();

  InkDocument _documentSnapshot() {
    final pagesForSave = _copyPages();
    if (_activeStroke != null &&
        _currentPageIndex >= 0 &&
        _currentPageIndex < pagesForSave.length) {
      pagesForSave[_currentPageIndex].add(_activeStroke!);
    }
    return widget.document.copyWith(
      updatedAt: DateTime.now(),
      pages: pagesForSave,
      pageBackgrounds: List<String?>.of(_pageBackgrounds),
      pageAspectRatios: List<double?>.of(_pageAspectRatios),
      pagePdfPaths: List<String?>.of(_pagePdfPaths),
      pagePdfPageNumbers: List<int?>.of(_pagePdfPageNumbers),
    );
  }

  void _snapshot() {
    _undo.add(_copyPages());
    if (_undo.length > 50) _undo.removeAt(0);
    _redo.clear();
  }

  void _scheduleSave() {
    _dirty = true;
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(milliseconds: 180), () {
      unawaited(_saveDocument().then<void>((_) {}));
    });
  }

  Future<bool> _saveDocument() async {
    if (_showNativePdfReader) {
      try {
        await _nativePdfController.save();
      } catch (error) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Could not save PDF annotations: $error')),
          );
        }
        return false;
      }
    }
    if (!_dirty) return true;

    _dirty = false;
    final document = _documentSnapshot();

    try {
      await InkDocumentStore.save(document);
      widget.onDocumentSaved(document);
      return true;
    } catch (error) {
      _dirty = true;
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not save this note: $error')),
        );
      }
      return false;
    }
  }

  Future<void> _saveThen(VoidCallback action) async {
    _saveTimer?.cancel();
    _viewSaveTimer?.cancel();
    final saved = await _saveDocument();
    await _saveEditorViewState();
    if (saved && mounted) action();
  }

  void _selectDocumentTab(String id) {
    if (id == widget.activeDocumentId) return;
    unawaited(_saveThen(() => widget.onSelectTab(id)));
  }

  void _closeDocumentTab(String id) {
    unawaited(_saveThen(() => widget.onCloseTab(id)));
  }

  void _newDocumentTab() {
    unawaited(_saveThen(widget.onNewTab));
  }

  void _exitEditor() {
    unawaited(_saveThen(widget.onExit));
  }

  void _setPenValues({
    required bool highlighter,
    double? width,
    double? smoothing,
    double? pressureSensitivity,
  }) {
    setState(() {
      if (width != null) {
        if (highlighter) {
          _highlighterWidth = width;
        } else {
          _width = width;
        }
      }
      if (smoothing != null) _smoothing = smoothing;
      if (pressureSensitivity != null) {
        _pressureSensitivity = pressureSensitivity;
      }
    });
  }

  List<PenPreset> _uniqueSizePresets(Iterable<PenPreset> values) {
    final result = <PenPreset>[];
    for (final value in values) {
      final exists = result.any((item) => (item.size - value.size).abs() < .01);
      if (!exists) result.add(value);
    }
    return result;
  }

  List<PenPreset> _sizePresetsFor(bool highlighter) =>
      highlighter ? _highlighterPresets : _presets;

  double _activeWidthFor(bool highlighter) =>
      highlighter ? _highlighterWidth : _width;

  Future<double?> _showSizePresetEditor({
    required bool highlighter,
    required double initialValue,
    required bool adding,
  }) async {
    final minValue = highlighter ? 3.0 : .5;
    final maxValue = highlighter ? 32.0 : 12.0;
    final divisions = highlighter ? 58 : 23;
    var value = initialValue.clamp(minValue, maxValue).toDouble();
    var deleteRequested = false;

    await showGeneralDialog<void>(
      context: context,
      barrierDismissible: false,
      barrierLabel: 'Close size preset editor',
      barrierColor: Colors.transparent,
      transitionDuration: const Duration(milliseconds: 160),
      pageBuilder: (dialogContext, _, _) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            final scheme = Theme.of(context).colorScheme;
            final media = MediaQuery.of(context);
            final compact = media.size.width < 650;
            final displayValue = value == value.roundToDouble()
                ? value.toStringAsFixed(0)
                : value.toStringAsFixed(1);

            void closeAndSave() => Navigator.of(dialogContext).pop();

            return Material(
              color: Colors.transparent,
              child: Stack(
                children: [
                  Positioned.fill(
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: closeAndSave,
                      child: const SizedBox.expand(),
                    ),
                  ),
                  SafeArea(
                    child: Align(
                      alignment: Alignment.topCenter,
                      child: Padding(
                        padding: EdgeInsets.only(
                          top: compact ? 112 : 138,
                          left: 12,
                          right: 12,
                        ),
                        child: Material(
                          elevation: 20,
                          color: scheme.surface.withValues(alpha: .99),
                          shadowColor: Colors.black.withValues(alpha: .22),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(22),
                            side: BorderSide(
                              color: scheme.outlineVariant.withValues(
                                alpha: .65,
                              ),
                            ),
                          ),
                          clipBehavior: Clip.antiAlias,
                          child: SizedBox(
                            width: 360,
                            child: Padding(
                              padding: const EdgeInsets.fromLTRB(
                                18,
                                10,
                                18,
                                16,
                              ),
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Row(
                                    children: [
                                      Expanded(
                                        child: Text(
                                          adding
                                              ? 'Add size preset'
                                              : 'Edit size preset',
                                          style: const TextStyle(
                                            fontSize: 18,
                                            fontWeight: FontWeight.w800,
                                          ),
                                        ),
                                      ),
                                      if (!adding)
                                        IconButton(
                                          tooltip: 'Delete preset',
                                          color: scheme.error,
                                          onPressed: () {
                                            deleteRequested = true;
                                            Navigator.of(dialogContext).pop();
                                          },
                                          icon: const Icon(
                                            Icons.delete_outline_rounded,
                                          ),
                                        ),
                                      IconButton(
                                        tooltip: 'Save and close',
                                        onPressed: closeAndSave,
                                        icon: const Icon(Icons.check_rounded),
                                      ),
                                    ],
                                  ),
                                  Container(
                                    height: 62,
                                    decoration: BoxDecoration(
                                      color: scheme.surfaceContainerHighest
                                          .withValues(alpha: .4),
                                      borderRadius: BorderRadius.circular(17),
                                    ),
                                    child: Center(
                                      child: Container(
                                        width: (value * 2 + 8)
                                            .clamp(10, 58)
                                            .toDouble(),
                                        height: (value * 2 + 8)
                                            .clamp(10, 58)
                                            .toDouble(),
                                        decoration: BoxDecoration(
                                          color: scheme.onSurface,
                                          shape: BoxShape.circle,
                                        ),
                                      ),
                                    ),
                                  ),
                                  const SizedBox(height: 10),
                                  Center(
                                    child: Text(
                                      '$displayValue pt',
                                      style: TextStyle(
                                        color: scheme.primary,
                                        fontSize: 22,
                                        fontWeight: FontWeight.w800,
                                      ),
                                    ),
                                  ),
                                  Slider(
                                    value: value,
                                    min: minValue,
                                    max: maxValue,
                                    divisions: divisions,
                                    label: displayValue,
                                    onChanged: (nextValue) =>
                                        setDialogState(() => value = nextValue),
                                  ),
                                  Text(
                                    'Tap outside to save and close automatically.',
                                    style: TextStyle(
                                      fontSize: 12,
                                      color: scheme.onSurfaceVariant,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            );
          },
        );
      },
      transitionBuilder: (_, animation, _, child) {
        final curved = CurvedAnimation(
          parent: animation,
          curve: Curves.easeOutCubic,
          reverseCurve: Curves.easeInCubic,
        );
        return FadeTransition(
          opacity: curved,
          child: SlideTransition(
            position: Tween<Offset>(
              begin: const Offset(0, -.025),
              end: Offset.zero,
            ).animate(curved),
            child: child,
          ),
        );
      },
    );

    return deleteRequested ? double.nan : value;
  }

  Future<double?> _handleSizePresetTap({
    required bool highlighter,
    required int index,
  }) async {
    final presets = _sizePresetsFor(highlighter);
    if (index < 0 || index >= presets.length) return null;

    final preset = presets[index];
    final activeWidth = _activeWidthFor(highlighter);
    if ((activeWidth - preset.size).abs() >= .2) {
      _setPenValues(highlighter: highlighter, width: preset.size);
      return preset.size;
    }

    final replacement = await _showSizePresetEditor(
      highlighter: highlighter,
      initialValue: preset.size,
      adding: false,
    );
    if (!mounted || replacement == null) return null;

    if (replacement.isNaN) {
      if (presets.length <= 1) return preset.size;
      final updated = List<PenPreset>.of(presets)..removeAt(index);
      final fallbackIndex = index.clamp(0, updated.length - 1);
      final fallback = updated[fallbackIndex].size;
      setState(() {
        if (highlighter) {
          _highlighterPresets = updated;
          _highlighterWidth = fallback;
        } else {
          _presets = updated;
          _width = fallback;
        }
      });
      if (highlighter) {
        await InkStore.saveHighlighterPresets(updated);
      } else {
        await InkStore.savePresets(updated);
      }
      return fallback;
    }

    var duplicateIndex = -1;
    for (
      var candidateIndex = 0;
      candidateIndex < presets.length;
      candidateIndex++
    ) {
      if (candidateIndex == index) continue;
      if ((presets[candidateIndex].size - replacement).abs() < .01) {
        duplicateIndex = candidateIndex;
        break;
      }
    }
    if (duplicateIndex >= 0) {
      final existing = presets[duplicateIndex].size;
      _setPenValues(highlighter: highlighter, width: existing);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('This size preset already exists.')),
        );
      }
      return existing;
    }

    final updated = List<PenPreset>.of(presets);
    updated[index] = PenPreset(size: replacement, smoothing: preset.smoothing);
    setState(() {
      if (highlighter) {
        _highlighterPresets = updated;
        _highlighterWidth = replacement;
      } else {
        _presets = updated;
        _width = replacement;
      }
    });
    if (highlighter) {
      await InkStore.saveHighlighterPresets(updated);
    } else {
      await InkStore.savePresets(updated);
    }
    return replacement;
  }

  Future<double?> _addSizePreset({required bool highlighter}) async {
    final newValue = await _showSizePresetEditor(
      highlighter: highlighter,
      initialValue: _activeWidthFor(highlighter),
      adding: true,
    );
    if (!mounted || newValue == null) return null;

    final presets = _sizePresetsFor(highlighter);
    final duplicateIndex = presets.indexWhere(
      (item) => (item.size - newValue).abs() < .01,
    );
    if (duplicateIndex >= 0) {
      final existing = presets[duplicateIndex].size;
      _setPenValues(highlighter: highlighter, width: existing);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('This size preset already exists.')),
        );
      }
      return existing;
    }

    final updated = [
      ...presets,
      PenPreset(size: newValue, smoothing: _smoothing),
    ];
    setState(() {
      if (highlighter) {
        _highlighterPresets = updated;
        _highlighterWidth = newValue;
      } else {
        _presets = updated;
        _width = newValue;
      }
    });
    if (highlighter) {
      await InkStore.saveHighlighterPresets(updated);
    } else {
      await InkStore.savePresets(updated);
    }
    return newValue;
  }

  bool _isPenTool(InkTool tool) =>
      tool == InkTool.pen ||
      tool == InkTool.fountainPen ||
      tool == InkTool.brushPen;

  bool _isPenFamilyTool(InkTool tool) =>
      _isPenTool(tool) || tool == InkTool.highlighter;

  bool _isDrawingTool(InkTool tool) => _isPenFamilyTool(tool);

  void _selectOrOpenPenSettings() {
    if (_isPenTool(_tool) && !_zoomMode) {
      setState(() {
        // Pressing the active pen again enters read mode.
        _zoomMode = true;
        _activeStroke = null;
        _activeStrokeHasRawTip = false;
        _strokeStabilizer.reset();
        _temporaryEraser = false;
        _eraserCursor = null;
      });
      return;
    }

    setState(() {
      final restoredTool = _isPenTool(_lastPenTool)
          ? _lastPenTool
          : InkTool.pen;
      _tool = restoredTool;
      _lastPenTool = restoredTool;
      _lastDrawingTool = restoredTool;
      _zoomMode = false;
    });
  }

  Future<void> _showPenSettings() async {
    setState(() {
      if (!_isPenFamilyTool(_tool)) {
        _tool = _isPenFamilyTool(_lastDrawingTool)
            ? _lastDrawingTool
            : (_isPenTool(_lastPenTool) ? _lastPenTool : InkTool.pen);
      }
      if (_isPenTool(_tool)) _lastPenTool = _tool;
      _lastDrawingTool = _tool;
      _zoomMode = false;
    });

    var localWidth = _tool == InkTool.highlighter ? _highlighterWidth : _width;
    var localSmoothing = _smoothing;
    var localPressureSensitivity = _pressureSensitivity;
    var localColor = _tool == InkTool.highlighter ? _highlighterColor : _color;

    await showGeneralDialog<void>(
      context: context,
      barrierDismissible: false,
      barrierLabel: _tool == InkTool.highlighter
          ? 'Close highlighter settings'
          : 'Close pen tools settings',
      barrierColor: Colors.transparent,
      transitionDuration: const Duration(milliseconds: 180),
      pageBuilder: (dialogContext, _, _) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            final scheme = Theme.of(context).colorScheme;
            final media = MediaQuery.of(context);
            final compact = media.size.width < 650;
            final topOffset = media.padding.top + (compact ? 112.0 : 142.0);
            final maxPanelHeight = math
                .max(300.0, media.size.height - topOffset - 18)
                .toDouble();
            final isHighlighter = _tool == InkTool.highlighter;
            final visibleColors = isHighlighter
                ? _highlighterColorPresets
                : _colorPresets.take(12).toList();
            final activeSizePresets = _sizePresetsFor(isHighlighter);
            final penName = switch (_tool) {
              InkTool.fountainPen => 'Fountain Pen',
              InkTool.brushPen => 'Brush Pen',
              InkTool.highlighter => 'Highlighter',
              _ => 'Ball Pen',
            };
            final penIcon = switch (_tool) {
              InkTool.fountainPen => Icons.edit_outlined,
              InkTool.brushPen => Icons.brush_outlined,
              InkTool.highlighter => Icons.border_color_outlined,
              _ => Icons.mode_edit_outline_rounded,
            };

            void selectPen(InkTool tool) {
              setState(() {
                _tool = tool;
                if (_isPenTool(tool)) _lastPenTool = tool;
                _lastDrawingTool = tool;
              });
              setDialogState(() {
                final selectingHighlighter = tool == InkTool.highlighter;
                localWidth = selectingHighlighter ? _highlighterWidth : _width;
                localColor = selectingHighlighter ? _highlighterColor : _color;
              });
            }

            return Material(
              color: Colors.transparent,
              child: Stack(
                children: [
                  Positioned.fill(
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: () => Navigator.of(dialogContext).pop(),
                      child: const SizedBox.expand(),
                    ),
                  ),
                  SafeArea(
                    child: Align(
                      alignment: Alignment.topCenter,
                      child: Padding(
                        padding: EdgeInsets.fromLTRB(
                          compact ? 10 : 18,
                          compact ? 82 : 108,
                          compact ? 10 : 18,
                          12,
                        ),
                        child: Material(
                          elevation: 22,
                          shadowColor: Colors.black.withValues(alpha: .28),
                          color: scheme.surface.withValues(alpha: .985),
                          surfaceTintColor: scheme.surfaceTint,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(24),
                            side: BorderSide(
                              color: scheme.outlineVariant.withValues(
                                alpha: .7,
                              ),
                            ),
                          ),
                          clipBehavior: Clip.antiAlias,
                          child: ConstrainedBox(
                            constraints: BoxConstraints(
                              maxWidth: 470,
                              maxHeight: maxPanelHeight,
                            ),
                            child: SingleChildScrollView(
                              padding: const EdgeInsets.fromLTRB(
                                18,
                                14,
                                18,
                                18,
                              ),
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Row(
                                    children: [
                                      Container(
                                        width: 38,
                                        height: 38,
                                        decoration: BoxDecoration(
                                          color: scheme.primaryContainer,
                                          borderRadius: BorderRadius.circular(
                                            12,
                                          ),
                                        ),
                                        child: Icon(
                                          penIcon,
                                          color: scheme.primary,
                                          size: 20,
                                        ),
                                      ),
                                      const SizedBox(width: 11),
                                      Expanded(
                                        child: Column(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.start,
                                          children: [
                                            Text(
                                              isHighlighter
                                                  ? 'Highlighter settings'
                                                  : 'Pen tools',
                                              style: TextStyle(
                                                fontSize: 19,
                                                fontWeight: FontWeight.w800,
                                              ),
                                            ),
                                            Text(
                                              isHighlighter
                                                  ? 'Color, size and smoothing'
                                                  : penName,
                                              style: TextStyle(
                                                fontSize: 12,
                                                color: scheme.onSurfaceVariant,
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                      IconButton(
                                        tooltip: 'Close',
                                        onPressed: () =>
                                            Navigator.of(dialogContext).pop(),
                                        icon: const Icon(Icons.close_rounded),
                                      ),
                                    ],
                                  ),
                                  const SizedBox(height: 12),
                                  if (!isHighlighter) ...[
                                    Container(
                                      padding: const EdgeInsets.all(4),
                                      decoration: BoxDecoration(
                                        color: scheme.surfaceContainerHighest
                                            .withValues(alpha: .55),
                                        borderRadius: BorderRadius.circular(17),
                                      ),
                                      child: Row(
                                        children: [
                                          Expanded(
                                            child: _SettingModeChip(
                                              icon: Icons
                                                  .mode_edit_outline_rounded,
                                              label: 'Ball',
                                              selected: _tool == InkTool.pen,
                                              onTap: () =>
                                                  selectPen(InkTool.pen),
                                            ),
                                          ),
                                          Expanded(
                                            child: _SettingModeChip(
                                              icon: Icons.edit_outlined,
                                              label: 'Fountain',
                                              selected:
                                                  _tool == InkTool.fountainPen,
                                              onTap: () => selectPen(
                                                InkTool.fountainPen,
                                              ),
                                            ),
                                          ),
                                          Expanded(
                                            child: _SettingModeChip(
                                              icon: Icons.brush_outlined,
                                              label: 'Brush',
                                              selected:
                                                  _tool == InkTool.brushPen,
                                              onTap: () =>
                                                  selectPen(InkTool.brushPen),
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                    const SizedBox(height: 14),
                                  ],
                                  Container(
                                    height: 72,
                                    decoration: BoxDecoration(
                                      color: scheme.surfaceContainerLowest,
                                      borderRadius: BorderRadius.circular(18),
                                      border: Border.all(
                                        color: scheme.outlineVariant.withValues(
                                          alpha: .55,
                                        ),
                                      ),
                                    ),
                                    child: Center(
                                      child: SizedBox(
                                        width: 270,
                                        height: 58,
                                        child: CustomPaint(
                                          painter: _PenPreviewPainter(
                                            color: localColor,
                                            width: localWidth,
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),
                                  const SizedBox(height: 14),
                                  Row(
                                    children: [
                                      const Expanded(
                                        child: Text(
                                          'Thickness',
                                          style: TextStyle(
                                            fontWeight: FontWeight.w800,
                                          ),
                                        ),
                                      ),
                                      Text(
                                        localWidth.toStringAsFixed(1),
                                        style: TextStyle(
                                          color: scheme.primary,
                                          fontWeight: FontWeight.w800,
                                        ),
                                      ),
                                    ],
                                  ),
                                  const SizedBox(height: 8),
                                  SingleChildScrollView(
                                    scrollDirection: Axis.horizontal,
                                    child: Row(
                                      children: [
                                        for (
                                          var presetIndex = 0;
                                          presetIndex <
                                              activeSizePresets.length;
                                          presetIndex++
                                        )
                                          Padding(
                                            padding: const EdgeInsets.only(
                                              right: 8,
                                            ),
                                            child: _PenWidthChoice(
                                              width:
                                                  activeSizePresets[presetIndex]
                                                      .size,
                                              selected:
                                                  (localWidth -
                                                          activeSizePresets[presetIndex]
                                                              .size)
                                                      .abs() <
                                                  .2,
                                              onTap: () async {
                                                final selectedWidth =
                                                    await _handleSizePresetTap(
                                                      highlighter:
                                                          isHighlighter,
                                                      index: presetIndex,
                                                    );
                                                if (!dialogContext.mounted ||
                                                    selectedWidth == null) {
                                                  return;
                                                }
                                                setDialogState(
                                                  () => localWidth =
                                                      selectedWidth,
                                                );
                                              },
                                            ),
                                          ),
                                        IconButton.filledTonal(
                                          tooltip: 'Add size preset',
                                          onPressed: () async {
                                            final selectedWidth =
                                                await _addSizePreset(
                                                  highlighter: isHighlighter,
                                                );
                                            if (!dialogContext.mounted ||
                                                selectedWidth == null) {
                                              return;
                                            }
                                            setDialogState(
                                              () => localWidth = selectedWidth,
                                            );
                                          },
                                          icon: const Icon(Icons.add_rounded),
                                        ),
                                      ],
                                    ),
                                  ),
                                  const SizedBox(height: 5),
                                  Text(
                                    'Tap a size to use it. Tap the selected size again to edit and save it.',
                                    style: TextStyle(
                                      fontSize: 11,
                                      color: scheme.onSurfaceVariant,
                                    ),
                                  ),
                                  const SizedBox(height: 8),
                                  _SettingSection(
                                    title: 'Stroke stabilization',
                                    trailing: Text(
                                      '${(localSmoothing * 100).round()}%',
                                      style: const TextStyle(
                                        fontWeight: FontWeight.w700,
                                      ),
                                    ),
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Slider(
                                          value: localSmoothing,
                                          min: 0,
                                          max: 1,
                                          divisions: 20,
                                          onChanged: (value) {
                                            setDialogState(
                                              () => localSmoothing = value,
                                            );
                                            _setPenValues(
                                              highlighter: isHighlighter,
                                              smoothing: value,
                                            );
                                          },
                                        ),
                                        Text(
                                          'Higher values reduce hand jitter and keep long strokes straighter, with a little more pen lag.',
                                          style: TextStyle(
                                            fontSize: 11,
                                            color: scheme.onSurfaceVariant,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                  if (!isHighlighter) ...[
                                    const SizedBox(height: 10),
                                    _SettingSection(
                                      title: 'Pressure sensitivity',
                                      trailing: Text(
                                        '${(localPressureSensitivity * 100).round()}%',
                                        style: const TextStyle(
                                          fontWeight: FontWeight.w700,
                                        ),
                                      ),
                                      child: Slider(
                                        value: localPressureSensitivity,
                                        min: 0,
                                        max: 1,
                                        divisions: 20,
                                        onChanged: (value) {
                                          setDialogState(
                                            () => localPressureSensitivity =
                                                value,
                                          );
                                          _setPenValues(
                                            highlighter: false,
                                            pressureSensitivity: value,
                                          );
                                        },
                                      ),
                                    ),
                                  ],
                                  const SizedBox(height: 14),
                                  const Text(
                                    'Color',
                                    style: TextStyle(
                                      fontWeight: FontWeight.w800,
                                    ),
                                  ),
                                  const SizedBox(height: 9),
                                  Wrap(
                                    spacing: 9,
                                    runSpacing: 9,
                                    children: [
                                      for (
                                        var colorIndex = 0;
                                        colorIndex < visibleColors.length;
                                        colorIndex++
                                      )
                                        _FloatingColorButton(
                                          color: visibleColors[colorIndex],
                                          selected:
                                              visibleColors[colorIndex]
                                                  .toARGB32() ==
                                              localColor.toARGB32(),
                                          onTap: () async {
                                            final itemColor =
                                                visibleColors[colorIndex];
                                            final alreadySelected =
                                                itemColor.toARGB32() ==
                                                localColor.toARGB32();
                                            if (!alreadySelected) {
                                              setState(() {
                                                if (isHighlighter) {
                                                  _highlighterColor = itemColor;
                                                } else {
                                                  _color = itemColor;
                                                }
                                              });
                                              setDialogState(
                                                () => localColor = itemColor,
                                              );
                                              return;
                                            }

                                            final replacement =
                                                await _replaceQuickColorSlot(
                                                  highlighter: isHighlighter,
                                                  index: colorIndex,
                                                  initialColor: itemColor,
                                                );
                                            if (!dialogContext.mounted ||
                                                replacement == null) {
                                              return;
                                            }
                                            setDialogState(
                                              () => localColor = replacement,
                                            );
                                          },
                                        ),
                                    ],
                                  ),
                                  const SizedBox(height: 7),
                                  Text(
                                    'Tap the selected color again to replace it',
                                    style: TextStyle(
                                      fontSize: 11,
                                      color: scheme.onSurfaceVariant,
                                    ),
                                  ),
                                  if (!isHighlighter) ...[
                                    const SizedBox(height: 12),
                                    SwitchListTile.adaptive(
                                      contentPadding: EdgeInsets.zero,
                                      dense: true,
                                      title: const Text(
                                        'Dashed stroke',
                                        style: TextStyle(
                                          fontWeight: FontWeight.w700,
                                        ),
                                      ),
                                      value: _dashedStroke,
                                      onChanged: (value) {
                                        setState(() => _dashedStroke = value);
                                        setDialogState(() {});
                                      },
                                    ),
                                  ],
                                  SwitchListTile.adaptive(
                                    contentPadding: EdgeInsets.zero,
                                    dense: true,
                                    title: const Text(
                                      'Snap to shapes',
                                      style: TextStyle(
                                        fontWeight: FontWeight.w700,
                                      ),
                                    ),
                                    subtitle: const Text(
                                      'Hold the pen still for a second to turn '
                                      'what you drew into a straight line, '
                                      'rectangle or ellipse.',
                                      style: TextStyle(fontSize: 11),
                                    ),
                                    value: _settings.shapeAssist,
                                    onChanged: (value) {
                                      final updated = _settings.copyWith(
                                        shapeAssist: value,
                                      );
                                      setState(() => _settings = updated);
                                      setDialogState(() {});
                                      unawaited(AppSettingsStore.save(updated));
                                    },
                                  ),
                                  const SizedBox(height: 4),
                                  Row(
                                    children: [
                                      const Spacer(),
                                      FilledButton(
                                        onPressed: () =>
                                            Navigator.of(dialogContext).pop(),
                                        child: const Text('Done'),
                                      ),
                                    ],
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            );
          },
        );
      },
      transitionBuilder: (_, animation, _, child) {
        final curved = CurvedAnimation(
          parent: animation,
          curve: Curves.easeOutCubic,
          reverseCurve: Curves.easeInCubic,
        );
        return FadeTransition(
          opacity: curved,
          child: SlideTransition(
            position: Tween<Offset>(
              begin: const Offset(0, -.035),
              end: Offset.zero,
            ).animate(curved),
            child: ScaleTransition(
              scale: Tween<double>(begin: .97, end: 1).animate(curved),
              alignment: Alignment.center,
              child: child,
            ),
          ),
        );
      },
    );

    final settings = await AppSettingsStore.load();
    await AppSettingsStore.save(
      settings.copyWith(defaultSmoothing: _smoothing, defaultWidth: _width),
    );
  }

  bool _isStylus(PointerEvent event) =>
      event.kind == PointerDeviceKind.stylus ||
      event.kind == PointerDeviceKind.invertedStylus;

  bool _accept(PointerEvent event) {
    if (_zoomMode) return false;
    if (event.kind == PointerDeviceKind.touch) {
      return _selectionPointerStartedInside;
    }
    if (_tool == InkTool.lasso && _hasSelection) {
      if (_isStylus(event) || event.kind == PointerDeviceKind.mouse) {
        return true;
      }
      return false;
    }
    if (_isStylus(event) || event.kind == PointerDeviceKind.mouse) return true;
    return false;
  }

  bool _shouldCaptureCanvasPointer(PointerDownEvent event) {
    if (event.kind == PointerDeviceKind.mouse || _isStylus(event)) {
      return true;
    }
    if (event.kind != PointerDeviceKind.touch || _zoomMode) {
      return false;
    }
    final renderObject = _canvasKey.currentContext?.findRenderObject();
    if (renderObject is! RenderBox || !renderObject.hasSize) return false;
    final local = renderObject.globalToLocal(event.position);
    return _touchCanEditAt(local, renderObject.size);
  }

  Widget _protectStylusDrawingFromViewportPan(Widget child) {
    if (_zoomMode) return child;
    return RawGestureDetector(
      behavior: HitTestBehavior.opaque,
      gestures: <Type, GestureRecognizerFactory>{
        _ConditionalEagerGestureRecognizer:
            GestureRecognizerFactoryWithHandlers<
              _ConditionalEagerGestureRecognizer
            >(
              () => _ConditionalEagerGestureRecognizer(
                shouldAccept: _shouldCaptureCanvasPointer,
                supportedDevices: const <PointerDeviceKind>{
                  PointerDeviceKind.touch,
                  PointerDeviceKind.stylus,
                  PointerDeviceKind.invertedStylus,
                  PointerDeviceKind.mouse,
                },
              ),
              (recognizer) {
                recognizer.shouldAccept = _shouldCaptureCanvasPointer;
              },
            ),
      },
      child: child,
    );
  }

  bool _eventIsEraser(PointerEvent event) {
    return _tool == InkTool.eraser ||
        event.kind == PointerDeviceKind.invertedStylus ||
        (event.buttons & kPrimaryStylusButton) != 0 ||
        (event.buttons & kSecondaryStylusButton) != 0;
  }

  double _pressure(PointerEvent event) {
    final range = event.pressureMax - event.pressureMin;
    if (range <= 0 || event.kind == PointerDeviceKind.mouse) return .5;
    final normalized = (event.pressure - event.pressureMin) / range;
    if (!normalized.isFinite) return .5;
    return normalized.clamp(.03, 1.0);
  }

  InkPoint _point(PointerEvent event, Size size) {
    return InkPoint(
      (event.localPosition.dx / size.width).clamp(0, 1),
      (event.localPosition.dy / size.height).clamp(0, 1),
      _pressure(event),
    );
  }

  Size _stabilizerScreenSize(Size canvasSize) {
    if (_usePdfrxViewer) return canvasSize;
    final scale =
        (_verticalPageMode
                ? _continuousViewScale
                : _transformationController.value.getMaxScaleOnAxis())
            .clamp(.1, 6.0)
            .toDouble();
    return Size(canvasSize.width * scale, canvasSize.height * scale);
  }

  bool _usesStrokeStabilizer(InkStroke stroke) => stroke.tool != InkTool.shape;

  double _inkPointDistanceInPixels(
    InkPoint first,
    InkPoint second,
    Size screenSize,
  ) {
    final dx = (second.x - first.x) * screenSize.width;
    final dy = (second.y - first.y) * screenSize.height;
    return math.sqrt(dx * dx + dy * dy);
  }

  void _discardActiveStrokeRawTip() {
    final stroke = _activeStroke;
    if (!_activeStrokeHasRawTip || stroke == null || stroke.points.length < 2) {
      _activeStrokeHasRawTip = false;
      return;
    }
    stroke.points.removeLast();
    _activeStrokeHasRawTip = false;
  }

  void _appendExactRawTip(InkPoint raw, Size screenSize) {
    final stroke = _activeStroke;
    if (stroke == null || stroke.points.isEmpty) return;
    if (_inkPointDistanceInPixels(stroke.points.last, raw, screenSize) <= .05) {
      return;
    }
    stroke.points.add(raw);
    _activeStrokeHasRawTip = true;
  }

  void _appendPointTowards(InkPoint target, Size size) {
    final stroke = _activeStroke;
    if (stroke == null || stroke.points.isEmpty) return;

    // Only the real stabilized sample becomes a control point. See
    // strokeCapturePointsTowards for why the gap must not be subdivided.
    stroke.points.addAll(
      strokeCapturePointsTowards(stroke.points.last, target, size),
    );
  }

  void _appendSmoothedPoints(PointerMoveEvent event, Size size) {
    final stroke = _activeStroke;
    if (stroke == null || stroke.points.isEmpty) return;

    // The previous raw endpoint was provisional. Remove it in the same frame,
    // append the next stable control point, then put the new exact Pencil tip
    // back. The visible line therefore reaches the Pencil without baking its
    // high-frequency jitter into the permanent control points.
    _discardActiveStrokeRawTip();
    final raw = _point(event, size);
    final screenSize = _stabilizerScreenSize(size);
    final target = _usesStrokeStabilizer(stroke)
        ? _strokeStabilizer.filter(
            raw,
            screenSize,
            strength: _smoothing,
            timestamp: event.timeStamp,
          )
        : raw;
    _appendPointTowards(target, size);
    _appendExactRawTip(raw, screenSize);
  }

  void _cancelLineAssist() {
    _lineAssistTimer?.cancel();
    _lineAssistTimer = null;
    _shapeAssistAnchor = null;
  }

  bool get _canStraightenActiveStroke =>
      _activeStroke != null &&
      (_activeStroke!.tool == InkTool.pen ||
          _activeStroke!.tool == InkTool.fountainPen ||
          _activeStroke!.tool == InkTool.brushPen ||
          _activeStroke!.tool == InkTool.highlighter) &&
      _activeStroke!.points.length >= 2;

  /// Pencil samples keep arriving at ~120Hz with sub-pixel jitter even when
  /// the pen is held perfectly still, so restarting the countdown on every
  /// sample meant it never elapsed and hold-to-snap never fired. Only real
  /// movement, measured against the anchor rather than the previous sample so
  /// slow drags still accumulate, restarts it.
  static const double _shapeAssistHoldSlack = 3;

  /// How long the pen has to rest before the stroke snaps to a shape.
  ///
  /// A full second was long enough that the snap felt like it was not coming.
  /// Half a second still clears an incidental pause, because the recogniser
  /// has the final say: pausing mid-word leaves the handwriting alone.
  static const Duration _shapeAssistHold = Duration(milliseconds: 500);

  void _restartLineAssistTimer([InkPoint? point, Size? size]) {
    if (!_settings.shapeAssist || !_canStraightenActiveStroke) {
      _cancelLineAssist();
      _shapeAssistAnchor = null;
      return;
    }

    final anchor = _shapeAssistAnchor;
    if (point != null && size != null && anchor != null) {
      final dx = (point.x - anchor.x) * size.width;
      final dy = (point.y - anchor.y) * size.height;
      if (math.sqrt(dx * dx + dy * dy) < _shapeAssistHoldSlack) {
        // Still within the hold: leave any pending countdown running.
        return;
      }
    }

    _cancelLineAssist();
    _shapeAssistAnchor = point;
    _lineAssistTimer = Timer(_shapeAssistHold, () {
      if (!mounted || !_canStraightenActiveStroke) return;
      setState(_snapActiveStrokeToShape);
    });
  }

  /// Orders a recognised shape's two stored points as `[anchor, tracked]`,
  /// where `tracked` is the one that follows the pen afterwards.
  ///
  /// This has to depend on where the pen actually is. A closed shape is drawn
  /// back round to where it started, so the pen finishes on the corner the
  /// hand began from — but the recogniser always reports the bounding box as
  /// `topLeft`..`bottomRight`. Treating `bottomRight` as the tracked point
  /// regardless dragged the far corner onto the pen the instant the next
  /// sample arrived, collapsing a box drawn anticlockwise from its top left
  /// into a speck in that corner. Anchoring the corner diagonally opposite the
  /// pen instead keeps the shape over what was drawn, whichever corner the
  /// hand started from, and makes a later drag resize it from the corner the
  /// hand is already resting on.
  List<InkPoint> _orientSnappedShape(RecognizedShape shape, InkPoint pen) {
    // An open stroke ends at the pen by definition, and extending it from
    // there is the whole point of snapping a line.
    if (shape.kind == InkShapeKind.line) {
      return <InkPoint>[shape.start, shape.end];
    }

    final left = math.min(shape.start.x, shape.end.x);
    final right = math.max(shape.start.x, shape.end.x);
    final top = math.min(shape.start.y, shape.end.y);
    final bottom = math.max(shape.start.y, shape.end.y);
    final pressure = shape.start.pressure;
    final nearLeft = (pen.x - left).abs() <= (pen.x - right).abs();
    final nearTop = (pen.y - top).abs() <= (pen.y - bottom).abs();
    return <InkPoint>[
      InkPoint(nearLeft ? right : left, nearTop ? bottom : top, pressure),
      InkPoint(nearLeft ? left : right, nearTop ? top : bottom, pressure),
    ];
  }

  void _snapActiveStrokeToShape() {
    final stroke = _activeStroke;
    if (stroke == null || stroke.points.length < 2) return;
    final shape = recognizeShape(stroke.points);
    // Nothing recognisable: leave the handwriting exactly as drawn. A pause
    // mid-word must not turn a letter into a box.
    if (shape == null) return;

    // _appendExactRawTip keeps the true Pencil position as the final point,
    // so this is where the hand is resting right now.
    final pen = stroke.points.last;
    final oriented = _orientSnappedShape(shape, pen);
    _activeStroke = stroke.copyWith(
      points: oriented,
      shapeKind: shape.kind,
    );
    _activeStrokeHasRawTip = false;
    _shapeSnapPreview = true;
    _shapeSnapPointerOrigin = pen;
    _shapeSnapTrackedOrigin = oriented.last;
  }

  /// Where a snapped shape's tracked point sits once the pen has reached
  /// [pen].
  ///
  /// Following the pen's movement *since* the snap, rather than jumping the
  /// point onto the pen, matters for closed shapes: the recognised corner is
  /// an extreme of the whole stroke and sits a little away from wherever the
  /// hand happened to stop, so assigning the pen position outright nudged the
  /// shape on the very next sample. A line is unaffected either way, its
  /// recognised endpoint being the last sample.
  InkPoint _shapeSnapTrackedPoint(InkPoint pen) {
    final origin = _shapeSnapPointerOrigin;
    final tracked = _shapeSnapTrackedOrigin;
    if (origin == null || tracked == null) return pen;
    return InkPoint(
      tracked.x + (pen.x - origin.x),
      tracked.y + (pen.y - origin.y),
      tracked.pressure,
    );
  }

  void _clearShapeSnapPreview() {
    _shapeSnapPreview = false;
    _shapeSnapPointerOrigin = null;
    _shapeSnapTrackedOrigin = null;
  }

  void _applyZoomAroundPoint({
    required TransformationController controller,
    required Offset focalPoint,
    required Offset scenePoint,
    required double scale,
  }) {
    controller.value = Matrix4.identity()
      ..translateByDouble(focalPoint.dx, focalPoint.dy, 0, 1)
      ..scaleByDouble(scale, scale, scale, 1.0)
      ..translateByDouble(-scenePoint.dx, -scenePoint.dy, 0, 1);
  }

  void _zoomBy(double factor) {
    if (_pageViewportWidth <= 0 || _pageViewportHeight <= 0) return;
    final controller = _transformationController;
    final currentScale = controller.value.getMaxScaleOnAxis();
    final nextScale = (currentScale * factor).clamp(.1, 6.0).toDouble();
    if ((nextScale - currentScale).abs() < .001) return;
    final focalPoint = Offset(_pageViewportWidth / 2, _pageViewportHeight / 2);
    final scenePoint = controller.toScene(focalPoint);
    _applyZoomAroundPoint(
      controller: controller,
      focalPoint: focalPoint,
      scenePoint: scenePoint,
      scale: nextScale,
    );
    _clampPageHorizontalTransform();
  }

  void _resetZoom() {
    _transformationController.value = Matrix4.identity();
  }

  void _zoomContinuousBy(double factor) {
    if (_continuousViewportWidth <= 0 || _continuousViewportHeight <= 0) {
      return;
    }
    final controller = _continuousTransformationController;
    final currentScale = _continuousViewScale;
    final nextScale = (currentScale * factor).clamp(.1, 4.0).toDouble();
    if ((nextScale - currentScale).abs() < .001) return;

    final focalPoint = Offset(
      _continuousViewportWidth / 2,
      _continuousViewportHeight / 2,
    );
    final scenePoint = controller.toScene(focalPoint);
    _applyZoomAroundPoint(
      controller: controller,
      focalPoint: focalPoint,
      scenePoint: scenePoint,
      scale: nextScale,
    );
    _clampContinuousHorizontalTransform();
  }

  void _beginZoomGesture(
    ScaleStartDetails details, {
    required bool continuous,
  }) {
    final controller = continuous
        ? _continuousTransformationController
        : _transformationController;
    final scenePoint = controller.toScene(details.localFocalPoint);
    final startScale = controller.value.getMaxScaleOnAxis();
    if (continuous) {
      _continuousGestureScenePoint = scenePoint;
      _continuousGestureStartFocalPoint = details.localFocalPoint;
      _continuousGestureStartScale = startScale;
    } else {
      _pageGestureScenePoint = scenePoint;
      _pageGestureStartFocalPoint = details.localFocalPoint;
      _pageGestureStartScale = startScale;
    }
  }

  bool _shouldLockHorizontalPan({
    required double scale,
    required double viewportWidth,
    required double contentWidth,
  }) {
    if (viewportWidth <= 0 || contentWidth <= 0) return true;
    return contentWidth * scale <= viewportWidth + _horizontalPanThreshold;
  }

  bool _clampHorizontalTransform({
    required TransformationController controller,
    required double viewportWidth,
    required double contentWidth,
  }) {
    if (viewportWidth <= 0 || contentWidth <= 0) return false;

    final matrix = controller.value;
    final scale = matrix.getMaxScaleOnAxis();
    if (!scale.isFinite || scale <= 0) return false;
    final translation = matrix.getTranslation();
    final scaledContentWidth = contentWidth * scale;

    final targetX =
        scaledContentWidth <= viewportWidth + _horizontalPanThreshold
        ? (viewportWidth - scaledContentWidth) / 2
        : translation.x
              .clamp(viewportWidth - scaledContentWidth, 0.0)
              .toDouble();

    if ((targetX - translation.x).abs() < .05) return false;
    controller.value = Matrix4.identity()
      ..translateByDouble(targetX, translation.y, 0, 1)
      ..scaleByDouble(scale, scale, scale, 1.0);
    return true;
  }

  void _clampPageHorizontalTransform() {
    _clampHorizontalTransform(
      controller: _transformationController,
      viewportWidth: _pageViewportWidth,
      contentWidth: _pageViewportWidth,
    );
  }

  void _clampContinuousHorizontalTransform() {
    _clampHorizontalTransform(
      controller: _continuousTransformationController,
      viewportWidth: _continuousViewportWidth,
      contentWidth: _continuousPaperWidth,
    );
  }

  void _updateZoomGesture(
    ScaleUpdateDetails details, {
    required bool continuous,
  }) {
    final controller = continuous
        ? _continuousTransformationController
        : _transformationController;
    final scenePoint = continuous
        ? _continuousGestureScenePoint
        : _pageGestureScenePoint;
    final startFocalPoint = continuous
        ? _continuousGestureStartFocalPoint
        : _pageGestureStartFocalPoint;
    if (scenePoint == null || startFocalPoint == null) return;

    final startScale = continuous
        ? _continuousGestureStartScale
        : _pageGestureStartScale;
    final maxScale = continuous ? 4.0 : 6.0;
    final nextScale = (startScale * details.scale)
        .clamp(.1, maxScale)
        .toDouble();
    final viewportWidth = continuous
        ? _continuousViewportWidth
        : _pageViewportWidth;
    final contentWidth = continuous
        ? _continuousPaperWidth
        : _pageViewportWidth;
    final lockHorizontal = _shouldLockHorizontalPan(
      scale: nextScale,
      viewportWidth: viewportWidth,
      contentWidth: contentWidth,
    );

    // While the paper still fits inside the viewport, preserve its horizontal
    // center. Once it is genuinely wider than the viewport, follow the focal
    // point and permit horizontal panning within the paper edges only.
    final focalPoint = lockHorizontal
        ? Offset(startFocalPoint.dx, details.localFocalPoint.dy)
        : details.localFocalPoint;
    _applyZoomAroundPoint(
      controller: controller,
      focalPoint: focalPoint,
      scenePoint: scenePoint,
      scale: nextScale,
    );

    _clampHorizontalTransform(
      controller: controller,
      viewportWidth: viewportWidth,
      contentWidth: contentWidth,
    );
  }

  void _endZoomGesture({required bool continuous}) {
    final controller = continuous
        ? _continuousTransformationController
        : _transformationController;
    _clampHorizontalTransform(
      controller: controller,
      viewportWidth: continuous ? _continuousViewportWidth : _pageViewportWidth,
      contentWidth: continuous ? _continuousPaperWidth : _pageViewportWidth,
    );
    if (continuous) {
      _continuousGestureScenePoint = null;
      _continuousGestureStartFocalPoint = null;
    } else {
      _pageGestureScenePoint = null;
      _pageGestureStartFocalPoint = null;
    }
  }

  void _zoomEditorBy(double factor) {
    if (_verticalPageMode) {
      _zoomContinuousBy(factor);
    } else {
      _zoomBy(factor);
    }
  }

  void _resetEditorZoom() {
    if (_verticalPageMode) {
      _continuousTransformationController.value = Matrix4.identity();
      _scrollContinuousViewToPage(_currentPageIndex);
    } else {
      _resetZoom();
    }
  }

  void _cancelTouchInteractionForPinch() {
    if (_activePointerKind != PointerDeviceKind.touch) return;
    _cancelLineAssist();
    _strokeStabilizer.reset();

    // A drawing/edit snapshot is created when the first finger goes down.
    // Restore it so starting a two-finger gesture never leaves a stray mark.
    if (_undo.isNotEmpty) {
      _pages = _undo.removeLast();
    }

    setState(() {
      _activeStroke = null;
      _activeStrokeHasRawTip = false;
      _activePointer = null;
      _activePointerKind = null;
      _temporaryEraser = false;
      _eraserCursor = null;
      _interactionChanged = false;
      _lastSelectPosition = null;
      _lassoPath.clear();
      _resetSelectionResize();
      _clearShapeSnapPreview();
    });
  }

  void _pointerDown(PointerDownEvent event, Size size) {
    final point = _point(event, size);
    final isTouch = event.kind == PointerDeviceKind.touch;

    if (isTouch) {
      _touchPointers.add(event.pointer);
      if (_touchPointers.length >= 2) {
        _pendingTouchTapPointer = null;
        _pendingTouchTapDownPosition = null;
        _pendingTouchTapMoved = false;
        _selectionPointerStartedInside = false;
        _cancelTouchInteractionForPinch();
        return;
      }
    }

    final isSelectionTool =
        _tool == InkTool.lasso ||
        _tool == InkTool.text ||
        _tool == InkTool.image;
    final canTransformSelection =
        isTouch ||
        (isSelectionTool &&
            (_isStylus(event) || event.kind == PointerDeviceKind.mouse));
    final resizeHandle = canTransformSelection
        ? _selectionResizeHandleAt(event.localPosition, size)
        : null;
    final canSelectImageDirectly = isTouch || isSelectionTool;
    final touchedImageIndex = canSelectImageDirectly && resizeHandle == null
        ? _findImageIndexAt(event.localPosition, size)
        : null;
    var startedInsideSelection =
        resizeHandle != null ||
        (_hasSelection &&
            _selectionContainsLocalOffset(event.localPosition, size)) ||
        touchedImageIndex != null;
    _selectionPointerStartedInside = startedInsideSelection;

    if (_hasSelection && !startedInsideSelection && isTouch) {
      _pendingTouchTapPointer = event.pointer;
      _pendingTouchTapDownPosition = event.localPosition;
      _pendingTouchTapMoved = false;
    }

    if (_activePointer != null) {
      final stylusReplacingPalm =
          _isStylus(event) && _activePointerKind == PointerDeviceKind.touch;
      if (!stylusReplacingPalm) return;
      _activeStroke = null;
      _activeStrokeHasRawTip = false;
      _activePointer = null;
      _activePointerKind = null;
      _strokeStabilizer.reset();
    }
    if (!_accept(event)) return;

    if (touchedImageIndex != null) {
      final image = _currentObjects[touchedImageIndex] as InkImage;
      if (!image.isSelected) {
        _clearSelection();
        _currentObjects[touchedImageIndex] = image.copyWith(isSelected: true);
      }
      _tool = InkTool.lasso;
      _selectionMoveMode = true;
      startedInsideSelection = true;
      _selectionPointerStartedInside = true;
    }

    final movingTextSelection =
        _tool == InkTool.text && _selectionMoveMode && _hasSelection;
    if (_tool == InkTool.text && !movingTextSelection) {
      unawaited(_handleTextTap(point, size));
      return;
    }

    _activePointer = event.pointer;
    _activePointerKind = event.kind;
    _temporaryEraser = _eventIsEraser(event);
    _interactionChanged = false;
    _activeStrokeHasRawTip = false;
    _strokeStabilizer.reset();
    _snapshot();
    final resizingSelection =
        resizeHandle != null &&
        _beginSelectionResize(resizeHandle, point, size);

    setState(() {
      if (resizingSelection) {
        _tool = InkTool.lasso;
        _selectionMoveMode = true;
        _lastSelectPosition = null;
        _lassoPath.clear();
      } else if (_tool == InkTool.lasso || movingTextSelection) {
        _lastSelectPosition = Offset(point.x, point.y);
        if (_tool == InkTool.lasso && _hasSelection && startedInsideSelection) {
          _selectionMoveMode = true;
          _lassoPath.clear();
        } else if (_selectionMoveMode && _hasSelection && movingTextSelection) {
          _lassoPath.clear();
        } else if (_tool == InkTool.lasso) {
          _selectionMoveMode = false;
          _clearSelection();
          _lassoPath
            ..clear()
            ..add(point);
        }
      } else if (_temporaryEraser) {
        _eraserCursor = point;
        _interactionChanged = _eraseAt(point, size);
      } else {
        _clearSelection();
        final activeTool = _tool == InkTool.highlighter
            ? InkTool.highlighter
            : _tool == InkTool.shape
            ? InkTool.shape
            : _tool == InkTool.fountainPen
            ? InkTool.fountainPen
            : _tool == InkTool.brushPen
            ? InkTool.brushPen
            : InkTool.pen;
        _activeStroke = InkStroke(
          tool: activeTool,
          color: activeTool == InkTool.highlighter ? _highlighterColor : _color,
          width: activeTool == InkTool.highlighter ? _highlighterWidth : _width,
          points: [point],
          dashed: activeTool == InkTool.highlighter ? false : _dashedStroke,
          pressureSensitivity: _pressureSensitivity,
        );
        _activeStrokeHasRawTip = false;
        if (_usesStrokeStabilizer(_activeStroke!)) {
          _strokeStabilizer.start(point, timestamp: event.timeStamp);
        }
        _clearShapeSnapPreview();
        _interactionChanged = true;
      }
    });
    // pdfrx owns the page's paint loop, so rebuilding this Flutter widget is
    // not enough to refresh its pagePaintCallbacks. Invalidate on every
    // accepted canvas gesture so a new stroke appears from Pencil-down.
    _invalidatePdfrxInkOverlay();
    _restartLineAssistTimer();
    if (_interactionChanged) _scheduleSave();
  }

  void _clearSelection() {
    for (var index = 0; index < _currentObjects.length; index++) {
      if (_currentObjects[index].isSelected) {
        _currentObjects[index] = _currentObjects[index].copyWith(
          isSelected: false,
        );
      }
    }
    _selectionLassoPath.clear();
    _resetSelectionResize();
  }

  bool get _hasSelection => _currentObjects.any((item) => item.isSelected);

  double get _selectionCanvasToScreenScale =>
      _eraserCanvasToScreenScale.clamp(.1, 8).toDouble();

  double get _selectionHitScale =>
      _usePdfrxViewer ? 1 : _selectionCanvasToScreenScale;

  int? _findImageIndexAt(Offset localPosition, Size canvasSize) {
    if (canvasSize.width <= 0 || canvasSize.height <= 0) return null;
    final hitPadding = 12 / _selectionHitScale;
    for (var index = _currentObjects.length - 1; index >= 0; index--) {
      final object = _currentObjects[index];
      if (object is! InkImage) continue;
      final bounds = Rect.fromLTWH(
        object.x * canvasSize.width,
        object.y * canvasSize.height,
        object.width * canvasSize.width,
        object.height * canvasSize.height,
      );
      if (bounds.inflate(hitPadding).contains(localPosition)) return index;
    }
    return null;
  }

  SelectionResizeHandle? _selectionResizeHandleAt(
    Offset localPosition,
    Size canvasSize,
  ) {
    if (!_hasSelection) return null;
    final bounds = _selectionResizeBounds(canvasSize);
    if (bounds == null) return null;
    return hitTestSelectionResizeHandle(
      localPosition,
      bounds,
      hitRadius: selectionHandleHitRadius / _selectionHitScale,
    );
  }

  bool _touchCanEditAt(Offset localPosition, Size canvasSize) {
    if (_selectionResizeHandleAt(localPosition, canvasSize) != null) {
      return true;
    }
    if (_hasSelection &&
        _selectionContainsLocalOffset(localPosition, canvasSize)) {
      return true;
    }
    return _findImageIndexAt(localPosition, canvasSize) != null;
  }

  Rect? _selectionTransformBounds(Size canvasSize) {
    if (_selectionLassoPath.length >= 3) {
      return inkPointBounds(_selectionLassoPath);
    }
    if (canvasSize.width <= 0 || canvasSize.height <= 0) return null;

    Rect? bounds;
    for (final object in _currentObjects.where((item) => item.isSelected)) {
      Rect? objectBounds;
      if (object is InkStroke) {
        objectBounds = inkPointBounds(object.points);
      } else if (object is InkText) {
        final textBounds = _textBounds(object, canvasSize);
        objectBounds = Rect.fromLTRB(
          textBounds.left / canvasSize.width,
          textBounds.top / canvasSize.height,
          textBounds.right / canvasSize.width,
          textBounds.bottom / canvasSize.height,
        );
      } else if (object is InkImage) {
        objectBounds = Rect.fromLTWH(
          object.x,
          object.y,
          object.width,
          object.height,
        );
      }
      if (objectBounds == null) continue;
      bounds = bounds == null
          ? objectBounds
          : bounds.expandToInclude(objectBounds);
    }
    return bounds;
  }

  /// Bounds used by both the painted corner handles and pointer hit testing.
  /// For direct object selections the outline has a fixed screen-space inset;
  /// a freeform lasso keeps its handles on the lasso's exact bounding corners.
  Rect? _selectionResizeBounds(Size canvasSize) {
    if (canvasSize.width <= 0 || canvasSize.height <= 0) return null;
    final normalizedBounds = _selectionTransformBounds(canvasSize);
    if (normalizedBounds == null) return null;
    final canvasBounds = Rect.fromLTRB(
      normalizedBounds.left * canvasSize.width,
      normalizedBounds.top * canvasSize.height,
      normalizedBounds.right * canvasSize.width,
      normalizedBounds.bottom * canvasSize.height,
    );
    if (_selectionLassoPath.length >= 3) return canvasBounds;
    return canvasBounds.inflate(selectionOutlinePadding / _selectionHitScale);
  }

  bool _beginSelectionResize(
    SelectionResizeHandle handle,
    InkPoint pointer,
    Size canvasSize,
  ) {
    final bounds = _selectionTransformBounds(canvasSize);
    if (bounds == null ||
        math.max(bounds.width.abs(), bounds.height.abs()) <= 1e-6) {
      return false;
    }
    _activeSelectionResizeHandle = handle;
    _selectionResizeStartBounds = bounds;
    _selectionResizeStartPointer = Offset(pointer.x, pointer.y);
    _selectionResizeStartObjects
      ..clear()
      ..addEntries(
        Iterable<int>.generate(_currentObjects.length)
            .where((index) => _currentObjects[index].isSelected)
            .map((index) => MapEntry(index, _currentObjects[index])),
      );
    _selectionResizeStartPath
      ..clear()
      ..addAll(_selectionLassoPath);
    return _selectionResizeStartObjects.isNotEmpty;
  }

  void _resizeSelection(InkPoint pointer, Size canvasSize) {
    final handle = _activeSelectionResizeHandle;
    final bounds = _selectionResizeStartBounds;
    final startPointer = _selectionResizeStartPointer;
    if (handle == null || bounds == null || startPointer == null) return;

    final scale = selectionUniformScaleForDrag(
      initialBounds: bounds,
      handle: handle,
      startPointer: startPointer,
      currentPointer: Offset(pointer.x, pointer.y),
      minimumExtent:
          28 / math.max(canvasSize.width, canvasSize.height).clamp(1, 1e9),
    );
    final anchor = selectionResizeOppositeAnchor(bounds, handle);
    for (final entry in _selectionResizeStartObjects.entries) {
      if (entry.key < 0 || entry.key >= _currentObjects.length) continue;
      _currentObjects[entry.key] = scaleSelectionObject(
        entry.value,
        anchor: anchor,
        scale: scale,
      );
    }
    if (_selectionResizeStartPath.isNotEmpty) {
      _selectionLassoPath
        ..clear()
        ..addAll(
          _selectionResizeStartPath.map(
            (point) => scaleSelectionPoint(point, anchor, scale),
          ),
        );
    }
  }

  void _resetSelectionResize() {
    _activeSelectionResizeHandle = null;
    _selectionResizeStartBounds = null;
    _selectionResizeStartPointer = null;
    _selectionResizeStartObjects.clear();
    _selectionResizeStartPath.clear();
  }

  void _moveSelection(double dx, double dy) {
    for (var index = 0; index < _currentObjects.length; index++) {
      final object = _currentObjects[index];
      if (!object.isSelected) continue;
      if (object is InkStroke) {
        _currentObjects[index] = object.copyWith(
          points: object.points
              .map(
                (item) => InkPoint(
                  (item.x + dx).clamp(0, 1),
                  (item.y + dy).clamp(0, 1),
                  item.pressure,
                ),
              )
              .toList(),
          isSelected: true,
        );
      } else if (object is InkText) {
        _currentObjects[index] = object.copyWith(
          x: (object.x + dx).clamp(0, 1),
          y: (object.y + dy).clamp(0, 1),
          isSelected: true,
        );
      } else if (object is InkImage) {
        _currentObjects[index] = object.copyWith(
          x: (object.x + dx).clamp(0, math.max(0.0, 1 - object.width)),
          y: (object.y + dy).clamp(0, math.max(0.0, 1 - object.height)),
          isSelected: true,
        );
      }
    }
    if (_selectionLassoPath.isNotEmpty) {
      for (var index = 0; index < _selectionLassoPath.length; index++) {
        final point = _selectionLassoPath[index];
        _selectionLassoPath[index] = InkPoint(
          (point.x + dx).clamp(0, 1),
          (point.y + dy).clamp(0, 1),
          point.pressure,
        );
      }
    }
  }

  bool _pointInPolygon(InkPoint point, List<InkPoint> polygon) {
    var inside = false;
    for (var i = 0, j = polygon.length - 1; i < polygon.length; j = i++) {
      final a = polygon[i];
      final b = polygon[j];
      final intersects =
          ((a.y > point.y) != (b.y > point.y)) &&
          (point.x <
              (b.x - a.x) *
                      (point.y - a.y) /
                      ((b.y - a.y).abs() < 1e-9 ? 1e-9 : b.y - a.y) +
                  a.x);
      if (intersects) inside = !inside;
    }
    return inside;
  }

  Rect? _selectionBounds(Size canvasSize) {
    Rect? bounds;
    for (final object in _currentObjects.where((item) => item.isSelected)) {
      Rect? objectBounds;
      if (object is InkStroke && object.points.isNotEmpty) {
        var minX = object.points.first.x;
        var maxX = object.points.first.x;
        var minY = object.points.first.y;
        var maxY = object.points.first.y;
        for (final point in object.points.skip(1)) {
          if (point.x < minX) minX = point.x;
          if (point.x > maxX) maxX = point.x;
          if (point.y < minY) minY = point.y;
          if (point.y > maxY) maxY = point.y;
        }
        final padding = math.max(12.0, object.width * 3);
        objectBounds = Rect.fromLTRB(
          minX * canvasSize.width,
          minY * canvasSize.height,
          maxX * canvasSize.width,
          maxY * canvasSize.height,
        ).inflate(padding);
      } else if (object is InkText) {
        objectBounds = _textBounds(object, canvasSize).inflate(16);
      } else if (object is InkImage) {
        objectBounds = Rect.fromLTWH(
          object.x * canvasSize.width,
          object.y * canvasSize.height,
          object.width * canvasSize.width,
          object.height * canvasSize.height,
        ).inflate(12);
      }
      if (objectBounds == null) continue;
      bounds = bounds == null
          ? objectBounds
          : bounds.expandToInclude(objectBounds);
    }
    return bounds;
  }

  Rect? _selectionVisualBounds(Size canvasSize) {
    if (_selectionLassoPath.length < 3 ||
        canvasSize.width <= 0 ||
        canvasSize.height <= 0) {
      return _selectionBounds(canvasSize);
    }

    var minX = _selectionLassoPath.first.x;
    var maxX = minX;
    var minY = _selectionLassoPath.first.y;
    var maxY = minY;
    for (final point in _selectionLassoPath.skip(1)) {
      minX = math.min(minX, point.x);
      maxX = math.max(maxX, point.x);
      minY = math.min(minY, point.y);
      maxY = math.max(maxY, point.y);
    }
    return Rect.fromLTRB(
      minX * canvasSize.width,
      minY * canvasSize.height,
      maxX * canvasSize.width,
      maxY * canvasSize.height,
    );
  }

  Rect? _selectionBoundsInViewport() {
    if (!_hasSelection) return null;
    final viewportObject = _editorViewportKey.currentContext
        ?.findRenderObject();
    if (viewportObject is! RenderBox || !viewportObject.hasSize) return null;
    final viewportRect = Offset.zero & viewportObject.size;

    if (_usePdfrxViewer) {
      final pageRect = _pdfrxScreenRectForPage(_currentPageIndex);
      if (pageRect == null || pageRect.isEmpty) return null;
      final bounds = _selectionVisualBounds(pageRect.size);
      final shiftedBounds = bounds?.shift(pageRect.topLeft);
      return shiftedBounds != null && shiftedBounds.overlaps(viewportRect)
          ? shiftedBounds
          : null;
    }

    final canvasObject = _canvasKey.currentContext?.findRenderObject();
    if (canvasObject is! RenderBox || !canvasObject.hasSize) return null;
    final bounds = _selectionVisualBounds(canvasObject.size);
    if (bounds == null || bounds.isEmpty) return null;

    final viewportPoints =
        <Offset>[
          bounds.topLeft,
          bounds.topRight,
          bounds.bottomLeft,
          bounds.bottomRight,
        ].map(
          (point) =>
              viewportObject.globalToLocal(canvasObject.localToGlobal(point)),
        );
    var minX = double.infinity;
    var minY = double.infinity;
    var maxX = -double.infinity;
    var maxY = -double.infinity;
    for (final point in viewportPoints) {
      minX = math.min(minX, point.dx);
      maxX = math.max(maxX, point.dx);
      minY = math.min(minY, point.dy);
      maxY = math.max(maxY, point.dy);
    }
    final viewportBounds = Rect.fromLTRB(minX, minY, maxX, maxY);
    return viewportBounds.overlaps(viewportRect) ? viewportBounds : null;
  }

  bool _selectionContainsLocalOffset(Offset offset, Size canvasSize) {
    if (_selectionLassoPath.length >= 3 &&
        canvasSize.width > 0 &&
        canvasSize.height > 0) {
      return _pointInPolygon(
        InkPoint(
          (offset.dx / canvasSize.width).clamp(0, 1),
          (offset.dy / canvasSize.height).clamp(0, 1),
          1,
        ),
        _selectionLassoPath,
      );
    }
    final bounds = _selectionBounds(canvasSize);
    return bounds?.contains(offset) ?? false;
  }

  void _selectInsideLasso() {
    for (var index = 0; index < _currentObjects.length; index++) {
      final object = _currentObjects[index];
      bool selected;
      if (object is InkStroke) {
        selected = object.points.any(
          (point) => _pointInPolygon(point, _lassoPath),
        );
      } else if (object is InkText) {
        selected = _pointInPolygon(InkPoint(object.x, object.y, 1), _lassoPath);
      } else if (object is InkImage) {
        final center = InkPoint(
          object.x + object.width / 2,
          object.y + object.height / 2,
          1,
        );
        selected = _pointInPolygon(center, _lassoPath);
      } else {
        selected = false;
      }
      _currentObjects[index] = object.copyWith(isSelected: selected);
    }
  }

  InkObject _cloneSelectionObject(
    InkObject object, {
    required bool selected,
    double offset = 0,
  }) {
    if (object is InkStroke) {
      return object.copyWith(
        points: object.points
            .map(
              (point) => InkPoint(
                (point.x + offset).clamp(0, 1),
                (point.y + offset).clamp(0, 1),
                point.pressure,
              ),
            )
            .toList(),
        isSelected: selected,
      );
    }
    if (object is InkText) {
      return object.copyWith(
        x: (object.x + offset).clamp(0, 1),
        y: (object.y + offset).clamp(0, 1),
        isSelected: selected,
      );
    }
    if (object is InkImage) {
      return object.copyWith(
        x: (object.x + offset).clamp(0, math.max(0.0, 1 - object.width)),
        y: (object.y + offset).clamp(0, math.max(0.0, 1 - object.height)),
        isSelected: selected,
      );
    }
    return object.copyWith(isSelected: selected);
  }

  void _copySelection() {
    if (!_hasSelection) return;
    setState(() {
      _selectionClipboard
        ..clear()
        ..addAll(
          _currentObjects
              .where((item) => item.isSelected)
              .map((item) => _cloneSelectionObject(item, selected: false)),
        );
    });
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('Selection copied.')));
  }

  void _cutSelection() {
    if (!_hasSelection) return;
    _snapshot();
    setState(() {
      _selectionClipboard
        ..clear()
        ..addAll(
          _currentObjects
              .where((item) => item.isSelected)
              .map((item) => _cloneSelectionObject(item, selected: false)),
        );
      _currentObjects.removeWhere((item) => item.isSelected);
      _selectionMoveMode = false;
      _lassoPath.clear();
      _selectionLassoPath.clear();
    });
    _scheduleSave();
  }

  void _pasteSelection() {
    if (_selectionClipboard.isEmpty) return;
    _snapshot();
    setState(() {
      _clearSelection();
      _currentObjects.addAll(
        _selectionClipboard.map(
          (item) => _cloneSelectionObject(item, selected: true, offset: .025),
        ),
      );
      _selectionMoveMode = true;
      _lassoPath.clear();
    });
    _scheduleSave();
  }

  void _removeSelection() {
    if (!_hasSelection) return;
    _snapshot();
    setState(() {
      _currentObjects.removeWhere((item) => item.isSelected);
      _selectionMoveMode = false;
      _selectionLassoPath.clear();
    });
    _scheduleSave();
  }

  /// Objects paint in list order, so list position is z-order. Moving the
  /// selection to the start or the end of the page's object list is what
  /// "send to back" / "bring to front" mean, and it keeps relative order
  /// among the selected objects themselves.
  void _reorderSelection({required bool toFront}) {
    if (!_hasSelection) return;
    final selected = <InkObject>[];
    final rest = <InkObject>[];
    for (final object in _currentObjects) {
      (object.isSelected ? selected : rest).add(object);
    }
    if (selected.isEmpty || rest.isEmpty) return;

    final reordered = toFront
        ? <InkObject>[...rest, ...selected]
        : <InkObject>[...selected, ...rest];
    // Skip the undo entry and the save when the order already matches.
    var identical = true;
    for (var index = 0; index < reordered.length; index++) {
      if (!_identicalObject(reordered[index], _currentObjects[index])) {
        identical = false;
        break;
      }
    }
    if (identical) return;

    _snapshot();
    setState(() {
      _pages[_currentPageIndex] = reordered;
    });
    _scheduleSave();
    _invalidatePdfrxInkOverlay();
  }

  bool _identicalObject(InkObject a, InkObject b) => a == b || identical(a, b);

  void _sendSelectionToBack() => _reorderSelection(toFront: false);

  void _bringSelectionToFront() => _reorderSelection(toFront: true);

  void _recolorSelection(Color color) {
    if (!_hasSelection) return;
    _snapshot();
    setState(() {
      for (var index = 0; index < _currentObjects.length; index++) {
        final object = _currentObjects[index];
        if (!object.isSelected) continue;
        if (object is InkStroke) {
          _currentObjects[index] = object.copyWith(
            color: color,
            isSelected: true,
          );
        } else if (object is InkText) {
          _currentObjects[index] = object.copyWith(
            color: color,
            isSelected: true,
          );
        }
      }
    });
    _scheduleSave();
  }

  TextPainter _textPainterFor(InkText textObject, Size canvasSize) {
    final painter = TextPainter(
      text: TextSpan(
        text: textObject.text,
        style: TextStyle(
          color: textObject.color,
          fontSize: textObject.fontSize,
          fontWeight: textObject.bold ? FontWeight.bold : FontWeight.normal,
          fontStyle: textObject.italic ? FontStyle.italic : FontStyle.normal,
          height: textObject.lineHeight,
        ),
      ),
      textDirection: TextDirection.ltr,
      textAlign: textObject.textAlign,
    );
    painter.layout(
      maxWidth: math.max(48.0, textObject.width * canvasSize.width),
    );
    return painter;
  }

  Rect _textBounds(InkText textObject, Size canvasSize) {
    final painter = _textPainterFor(textObject, canvasSize);
    final width = math.max(48.0, textObject.width * canvasSize.width);
    return Rect.fromLTWH(
      textObject.x * canvasSize.width,
      textObject.y * canvasSize.height,
      width,
      math.max(painter.height, textObject.fontSize),
    );
  }

  int? _findTextIndexAt(InkPoint point, Size canvasSize) {
    final localPoint = Offset(
      point.x * canvasSize.width,
      point.y * canvasSize.height,
    );
    for (var index = _currentObjects.length - 1; index >= 0; index--) {
      final object = _currentObjects[index];
      if (object is InkText &&
          _textBounds(object, canvasSize).inflate(10).contains(localPoint)) {
        return index;
      }
    }
    return null;
  }

  Future<_TextBoxEditResult?> _showTextBoxEditor(
    InkText textObject, {
    required bool isNew,
  }) async {
    final controller = TextEditingController(text: textObject.text);
    final focusNode = FocusNode();
    var boxWidth = textObject.width.clamp(.15, .9).toDouble();

    _TextBoxEditResult buildResult({bool delete = false}) {
      return _TextBoxEditResult(
        text: controller.text.trim(),
        width: boxWidth,
        delete: delete,
      );
    }

    final result = await showGeneralDialog<_TextBoxEditResult>(
      context: context,
      barrierDismissible: false,
      barrierLabel: 'Close text box editor',
      barrierColor: Colors.transparent,
      transitionDuration: const Duration(milliseconds: 160),
      pageBuilder: (dialogContext, _, _) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            final scheme = Theme.of(context).colorScheme;
            final media = MediaQuery.of(context);
            return Material(
              color: Colors.transparent,
              child: Stack(
                children: [
                  Positioned.fill(
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: () {
                        final result = buildResult();
                        Navigator.of(
                          dialogContext,
                        ).pop(result.text.isEmpty && isNew ? null : result);
                      },
                      child: const SizedBox.expand(),
                    ),
                  ),
                  SafeArea(
                    child: Align(
                      alignment: Alignment.topCenter,
                      child: Padding(
                        padding: EdgeInsets.fromLTRB(
                          12,
                          media.size.width < 650 ? 112 : 138,
                          12,
                          12,
                        ),
                        child: Material(
                          elevation: 22,
                          color: scheme.surface.withValues(alpha: .99),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(22),
                            side: BorderSide(
                              color: scheme.outlineVariant.withValues(
                                alpha: .65,
                              ),
                            ),
                          ),
                          clipBehavior: Clip.antiAlias,
                          child: ConstrainedBox(
                            constraints: const BoxConstraints(maxWidth: 470),
                            child: Padding(
                              padding: const EdgeInsets.fromLTRB(
                                16,
                                10,
                                16,
                                16,
                              ),
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Row(
                                    children: [
                                      Expanded(
                                        child: Text(
                                          isNew
                                              ? 'New text box'
                                              : 'Edit text box',
                                          style: const TextStyle(
                                            fontSize: 19,
                                            fontWeight: FontWeight.w800,
                                          ),
                                        ),
                                      ),
                                      if (!isNew)
                                        IconButton(
                                          tooltip: 'Delete text box',
                                          onPressed: () => Navigator.of(
                                            dialogContext,
                                          ).pop(buildResult(delete: true)),
                                          icon: const Icon(
                                            Icons.delete_outline_rounded,
                                          ),
                                        ),
                                      IconButton(
                                        tooltip: 'Apply and close',
                                        onPressed: () {
                                          final result = buildResult();
                                          Navigator.of(dialogContext).pop(
                                            result.text.isEmpty && isNew
                                                ? null
                                                : result,
                                          );
                                        },
                                        icon: const Icon(Icons.check_rounded),
                                      ),
                                    ],
                                  ),
                                  TextField(
                                    controller: controller,
                                    focusNode: focusNode,
                                    autofocus: true,
                                    minLines: 2,
                                    maxLines: 7,
                                    textInputAction: TextInputAction.newline,
                                    decoration: const InputDecoration(
                                      hintText: 'Type text…',
                                      labelText: 'Text',
                                    ),
                                  ),
                                  const SizedBox(height: 10),
                                  Row(
                                    children: [
                                      const Text(
                                        'Box width',
                                        style: TextStyle(
                                          fontWeight: FontWeight.w700,
                                        ),
                                      ),
                                      Expanded(
                                        child: Slider(
                                          value: boxWidth,
                                          min: .15,
                                          max: .9,
                                          divisions: 15,
                                          onChanged: (value) => setDialogState(
                                            () => boxWidth = value,
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                  Text(
                                    'Tap outside to apply automatically. Select the box to move, copy, paste, delete, resize, or recolor it.',
                                    style: TextStyle(
                                      fontSize: 11,
                                      color: scheme.onSurfaceVariant,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            );
          },
        );
      },
      transitionBuilder: (_, animation, _, child) {
        final curved = CurvedAnimation(
          parent: animation,
          curve: Curves.easeOutCubic,
          reverseCurve: Curves.easeInCubic,
        );
        return FadeTransition(
          opacity: curved,
          child: SlideTransition(
            position: Tween<Offset>(
              begin: const Offset(0, -.025),
              end: Offset.zero,
            ).animate(curved),
            child: child,
          ),
        );
      },
    );

    focusNode.dispose();
    controller.dispose();
    return result;
  }

  Future<void> _editTextObjectAt(int index) async {
    if (index < 0 || index >= _currentObjects.length) return;
    final object = _currentObjects[index];
    if (object is! InkText) return;

    final result = await _showTextBoxEditor(object, isNew: false);
    if (!mounted || result == null) return;
    _snapshot();
    setState(() {
      if (result.delete || result.text.isEmpty) {
        _currentObjects.removeAt(index);
        _selectionMoveMode = false;
        _selectionLassoPath.clear();
      } else {
        _clearSelection();
        _currentObjects[index] = object.copyWith(
          text: result.text,
          width: result.width,
          isSelected: true,
        );
        _selectionMoveMode = true;
      }
    });
    _scheduleSave();
  }

  Future<void> _editSelectedText() async {
    final index = _currentObjects.indexWhere(
      (object) => object is InkText && object.isSelected,
    );
    if (index >= 0) await _editTextObjectAt(index);
  }

  Future<void> _handleTextTap(InkPoint point, Size canvasSize) async {
    final existingIndex = _findTextIndexAt(point, canvasSize);
    if (existingIndex != null) {
      setState(() {
        _clearSelection();
        final object = _currentObjects[existingIndex] as InkText;
        _currentObjects[existingIndex] = object.copyWith(isSelected: true);
        _selectionMoveMode = true;
      });
      await _editTextObjectAt(existingIndex);
      return;
    }

    final draft = InkText(
      text: '',
      x: point.x,
      y: point.y,
      color: _color,
      fontSize: _textSize,
      width: .35,
      bold: _textBold,
      italic: _textItalic,
      textAlign: _textAlign,
      lineHeight: _textLineHeight,
    );
    final result = await _showTextBoxEditor(draft, isNew: true);
    if (!mounted || result == null || result.text.isEmpty) return;
    _snapshot();
    setState(() {
      _clearSelection();
      _currentObjects.add(
        draft.copyWith(
          text: result.text,
          width: result.width,
          isSelected: true,
        ),
      );
      _selectionMoveMode = true;
    });
    _scheduleSave();
  }

  void _pointerMove(PointerMoveEvent event, Size size) {
    if (_pendingTouchTapPointer == event.pointer) {
      final start = _pendingTouchTapDownPosition;
      if (start != null &&
          !_pendingTouchTapMoved &&
          (event.localPosition - start).distance > 8) {
        _pendingTouchTapMoved = true;
      }
    }
    if (_activePointer != event.pointer) return;
    final point = _point(event, size);
    setState(() {
      if (_activeSelectionResizeHandle != null) {
        _resizeSelection(point, size);
        _draggingSelection = true;
        _interactionChanged = true;
      } else if ((_tool == InkTool.lasso || _tool == InkTool.text) &&
          _lastSelectPosition != null) {
        if (_selectionMoveMode && _hasSelection) {
          final dx = point.x - _lastSelectPosition!.dx;
          final dy = point.y - _lastSelectPosition!.dy;
          _moveSelection(dx, dy);
          _draggingSelection = true;
          _interactionChanged = true;
          _lastSelectPosition = Offset(point.x, point.y);
        } else {
          _lassoPath.add(point);
        }
      } else if (_temporaryEraser) {
        final previous = _eraserCursor;
        final erased = previous == null
            ? _eraseAt(point, size)
            : _eraseAlongPath(previous, point, size);
        _eraserCursor = point;
        _interactionChanged = erased || _interactionChanged;
      } else if (_activeStroke != null) {
        if (_shapeSnapPreview && _activeStroke!.points.length >= 2) {
          _activeStroke = _activeStroke!.copyWith(
            points: [
              _activeStroke!.points.first,
              _shapeSnapTrackedPoint(_point(event, size)),
            ],
          );
          _activeStrokeHasRawTip = false;
        } else {
          _appendSmoothedPoints(event, size);
          _restartLineAssistTimer(_point(event, size), size);
        }
        _interactionChanged = true;
      }
    });
    // A parent setState does not invalidate pdfrx's internal page paint stream.
    // Refresh it for every accepted Pencil sample so the visible endpoint does
    // not trail behind and then jump forward on a later viewer repaint.
    _invalidatePdfrxInkOverlay();
    if (_interactionChanged) _scheduleSave();
  }

  void _pointerUp(PointerEvent event, [Size? size]) {
    if (_draggingSelection) {
      // The selection toolbar is not built while a drag is in flight, so the
      // drag never pays for re-laying it out every frame. Bring it back now
      // that the selection has settled.
      setState(() => _draggingSelection = false);
    }
    if (event.kind == PointerDeviceKind.touch) {
      _touchPointers.remove(event.pointer);
    }
    if (_pendingTouchTapPointer == event.pointer) {
      final tappedOutsideSelection =
          !_pendingTouchTapMoved &&
          size != null &&
          _tool == InkTool.lasso &&
          _hasSelection &&
          !_selectionContainsLocalOffset(event.localPosition, size);
      _pendingTouchTapPointer = null;
      _pendingTouchTapDownPosition = null;
      _pendingTouchTapMoved = false;
      if (tappedOutsideSelection) {
        setState(() {
          _clearSelection();
          _selectionMoveMode = false;
          _lassoPath.clear();
        });
      }
    }
    if (_activePointer != event.pointer) return;
    _cancelLineAssist();
    final finishingStroke = _activeStroke;
    if (finishingStroke != null &&
        size != null &&
        event is! PointerCancelEvent &&
        !_shapeSnapPreview &&
        _usesStrokeStabilizer(finishingStroke)) {
      final raw = _point(event, size);
      final screenSize = _stabilizerScreenSize(size);
      if (_activeStrokeHasRawTip) {
        // Keep the exact endpoint that was already visible during the final
        // live frame. If iOS supplies a slightly newer lift-off position,
        // extend to it without deleting or recalculating any visible point.
        if (_inkPointDistanceInPixels(
              finishingStroke.points.last,
              raw,
              screenSize,
            ) >
            .05) {
          finishingStroke.points.add(raw);
        }
        _activeStrokeHasRawTip = false;
        _strokeStabilizer.reset();
      } else {
        finishingStroke.points.addAll(
          _strokeStabilizer.finish(raw, screenSize),
        );
      }
    } else {
      _activeStrokeHasRawTip = false;
      _strokeStabilizer.reset();
    }
    setState(() {
      if (_tool == InkTool.lasso &&
          !_selectionMoveMode &&
          _lassoPath.length >= 3) {
        _selectInsideLasso();
        _selectionMoveMode = _hasSelection;
        if (_hasSelection) {
          _selectionLassoPath
            ..clear()
            ..addAll(_lassoPath);
        } else {
          _selectionLassoPath.clear();
        }
      }
      if (_activeStroke != null) _currentObjects.add(_activeStroke!);
      final autoReturnToPen = _eraserAutoDeselect && _tool == InkTool.eraser;
      _activeStroke = null;
      _activeStrokeHasRawTip = false;
      _activePointer = null;
      _activePointerKind = null;
      _temporaryEraser = false;
      _eraserCursor = null;
      _lastSelectPosition = null;
      _resetSelectionResize();
      if (_tool == InkTool.lasso) _lassoPath.clear();
      if (autoReturnToPen) _tool = _lastDrawingTool;
      _clearShapeSnapPreview();
      _selectionPointerStartedInside = false;
    });
    _invalidatePdfrxInkOverlay();
    if (_interactionChanged) {
      _scheduleSave();
    } else if (_undo.isNotEmpty) {
      _undo.removeLast();
    }
  }

  bool _eraseAlongPath(InkPoint start, InkPoint end, Size size) {
    final dx = (end.x - start.x) * size.width;
    final dy = (end.y - start.y) * size.height;
    final distance = math.sqrt(dx * dx + dy * dy);
    final spacing = math.max(2.0, _eraserSize * .16);
    final steps = (distance / spacing).ceil().clamp(1, 40).toInt();
    var changed = false;
    for (var step = 1; step <= steps; step++) {
      final amount = step / steps;
      changed =
          _eraseAt(
            InkPoint(
              start.x + (end.x - start.x) * amount,
              start.y + (end.y - start.y) * amount,
              1,
            ),
            size,
          ) ||
          changed;
    }
    return changed;
  }

  double _distanceToSegment(Offset point, Offset start, Offset end) {
    final delta = end - start;
    final lengthSquared = delta.distanceSquared;
    if (lengthSquared <= .00001) return (point - start).distance;
    final projection =
        ((point - start).dx * delta.dx + (point - start).dy * delta.dy) /
        lengthSquared;
    final amount = projection.clamp(0.0, 1.0).toDouble();
    return (point - (start + delta * amount)).distance;
  }

  bool _strokeTouchesEraser(
    InkStroke stroke,
    Offset center,
    Size size,
    double radius,
    double strokeScale,
  ) {
    if (stroke.points.isEmpty) return false;
    final hitRadius = radius + stroke.width * strokeScale / 2;
    final offsets = stroke.points
        .map(
          (candidate) =>
              Offset(candidate.x * size.width, candidate.y * size.height),
        )
        .toList();
    if (offsets.length == 1) {
      return (offsets.first - center).distance <= hitRadius;
    }
    for (var index = 0; index < offsets.length - 1; index++) {
      if (_distanceToSegment(center, offsets[index], offsets[index + 1]) <=
          hitRadius) {
        return true;
      }
    }
    return false;
  }

  List<InkPoint> _densifyStrokeForErasing(InkStroke stroke, Size size) {
    if (stroke.points.length < 2) return List<InkPoint>.of(stroke.points);
    final result = <InkPoint>[];
    for (var index = 0; index < stroke.points.length - 1; index++) {
      final start = stroke.points[index];
      final end = stroke.points[index + 1];
      final dx = (end.x - start.x) * size.width;
      final dy = (end.y - start.y) * size.height;
      final distance = math.sqrt(dx * dx + dy * dy);
      final steps = (distance / 1.8).ceil().clamp(1, 160).toInt();
      for (var step = 0; step < steps; step++) {
        final amount = step / steps;
        result.add(
          InkPoint(
            start.x + (end.x - start.x) * amount,
            start.y + (end.y - start.y) * amount,
            start.pressure + (end.pressure - start.pressure) * amount,
          ),
        );
      }
    }
    result.add(stroke.points.last);
    return result;
  }

  bool _eraseAt(InkPoint point, Size size) {
    final geometry = _eraserGeometry;
    final radius = geometry.hitRadius;
    final strokeScale = geometry.hitTestStrokeScale;
    final center = Offset(point.x * size.width, point.y * size.height);
    final newObjects = <InkObject>[];
    var changed = false;

    for (final object in _currentObjects) {
      // The ink eraser does not delete typed text. Text is removed with the
      // lasso, matching the behavior users expect from note-taking apps.
      if (object is! InkStroke) {
        newObjects.add(object);
        continue;
      }
      if (_eraseHighlighterOnly && object.tool != InkTool.highlighter) {
        newObjects.add(object);
        continue;
      }

      final touches = _strokeTouchesEraser(
        object,
        center,
        size,
        radius,
        strokeScale,
      );
      if (!touches) {
        newObjects.add(object);
        continue;
      }

      changed = true;
      if (_eraserMode == EraserMode.stroke ||
          object.tool == InkTool.shape ||
          object.points.length < 2) {
        continue;
      }

      final hitRadius = radius + object.width * strokeScale / 2;
      final workingPoints = _densifyStrokeForErasing(object, size);
      final hitPoints = List<bool>.filled(workingPoints.length, false);
      final offsets = workingPoints
          .map(
            (candidate) =>
                Offset(candidate.x * size.width, candidate.y * size.height),
          )
          .toList();
      for (var index = 0; index < offsets.length; index++) {
        if ((offsets[index] - center).distance <= hitRadius) {
          hitPoints[index] = true;
        }
      }
      for (var index = 0; index < offsets.length - 1; index++) {
        if (_distanceToSegment(center, offsets[index], offsets[index + 1]) <=
            hitRadius) {
          hitPoints[index] = true;
          hitPoints[index + 1] = true;
        }
      }

      var fragment = <InkPoint>[];
      void finishFragment() {
        if (fragment.length >= 2) {
          newObjects.add(
            object.copyWith(
              points: List<InkPoint>.of(fragment),
              isSelected: false,
            ),
          );
        }
        fragment = <InkPoint>[];
      }

      for (var index = 0; index < workingPoints.length; index++) {
        if (hitPoints[index]) {
          finishFragment();
        } else {
          fragment.add(workingPoints[index]);
        }
      }
      finishFragment();
    }

    if (changed) _pages[_currentPageIndex] = newObjects;
    return changed;
  }

  void _undoAction() {
    if (_undo.isEmpty) return;
    setState(() {
      _redo.add(_copyPages());
      _pages = _undo.removeLast();
      _currentPageIndex = math.min(_currentPageIndex, _pages.length - 1);
      _activeStroke = null;
    });
    _scheduleSave();
  }

  void _redoAction() {
    if (_redo.isEmpty) return;
    setState(() {
      _undo.add(_copyPages());
      _pages = _redo.removeLast();
      _currentPageIndex = math.min(_currentPageIndex, _pages.length - 1);
      _activeStroke = null;
    });
    _scheduleSave();
  }

  void _undoCurrentAction() {
    if (_showNativePdfReader) {
      unawaited(_nativePdfController.undo());
      return;
    }
    _undoAction();
  }

  void _redoCurrentAction() {
    if (_showNativePdfReader) {
      unawaited(_nativePdfController.redo());
      return;
    }
    _redoAction();
  }

  void _nativeDocumentChanged() {
    // Native PDF annotations are persisted by PDFKit/AndroidX directly into
    // the imported PDF. They must not be mirrored into the Flutter object
    // model, otherwise every stroke triggers a second full document save.
  }

  void _selectPage(int index) {
    if (index < 0 || index >= _pages.length) return;
    setState(() {
      _currentPageIndex = index;
      _activeStroke = null;
      _resetZoom();
    });
    if (_usePdfrxViewer) {
      final pageNumber = index - _pdfrxPageStart + 1;
      if (pageNumber >= 1 && _pdfrxController.isReady) {
        unawaited(_pdfrxController.goToPage(pageNumber: pageNumber));
      }
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _scrollContinuousViewToPage(index);
    });
  }

  double _continuousOffsetForPage(int index) {
    if (_continuousPaperWidth <= 0 || index <= 0) return 0;
    var offset = 0.0;
    final last = math.min(index, _pages.length);
    for (var page = 0; page < last; page++) {
      offset += _continuousPaperWidth * _pageAspectRatio(page) + _continuousGap;
    }
    return offset;
  }

  double get _continuousDocumentHeight {
    if (_continuousPaperWidth <= 0) return 0;
    var height = 0.0;
    for (var page = 0; page < _pages.length; page++) {
      height += _continuousPaperWidth * _pageAspectRatio(page);
      if (page < _pages.length - 1) height += _continuousGap;
    }
    return height;
  }

  int _continuousPageForOffset(double offset) {
    if (_pages.isEmpty || _continuousPaperWidth <= 0) return 0;
    var cursor = 0.0;
    for (var page = 0; page < _pages.length; page++) {
      final extent =
          _continuousPaperWidth * _pageAspectRatio(page) +
          (page < _pages.length - 1 ? _continuousGap : 0);
      if (offset < cursor + extent) return page;
      cursor += extent;
    }
    return _pages.length - 1;
  }

  void _scrollContinuousViewToPage(int index) {
    if (!_verticalPageMode ||
        _continuousPaperWidth <= 0 ||
        _continuousViewportHeight <= 0) {
      return;
    }
    final scale = _continuousViewScale;
    final maxOffset = math.max(
      0.0,
      _continuousDocumentHeight - _continuousViewportHeight / scale,
    );
    final target = _continuousOffsetForPage(
      index,
    ).clamp(0.0, maxOffset).toDouble();
    _continuousTransformationController.value = Matrix4.identity()
      ..translateByDouble(0, -target * scale, 0, 1)
      ..scaleByDouble(scale, scale, scale, 1.0);
  }

  void _schedulePdfQualityRefresh() {
    final rawScale = _verticalPageMode
        ? _continuousTransformationController.value
              .getMaxScaleOnAxis()
              .clamp(.1, 4.0)
              .toDouble()
        : _transformationController.value
              .getMaxScaleOnAxis()
              .clamp(.1, 6.0)
              .toDouble();
    final bucket = (rawScale * 4).round() / 4;
    if ((bucket - _pdfRenderScaleBucket).abs() < .01) return;
    _pdfQualityTimer?.cancel();
    _pdfQualityTimer = Timer(const Duration(milliseconds: 220), () {
      if (!mounted) return;
      setState(() => _pdfRenderScaleBucket = bucket);
    });
  }

  void _handlePageTransformChanged() {
    if (!_correctingPageTransform && _pageViewportWidth > 0) {
      _correctingPageTransform = true;
      _clampPageHorizontalTransform();
      _correctingPageTransform = false;
    }
    _schedulePdfQualityRefresh();
    _scheduleViewStateSave();
  }

  void _handleContinuousTransformChanged() {
    if (!_correctingContinuousTransform &&
        _continuousViewportWidth > 0 &&
        _continuousPaperWidth > 0) {
      _correctingContinuousTransform = true;
      _clampContinuousHorizontalTransform();
      _correctingContinuousTransform = false;
    }
    _schedulePdfQualityRefresh();
    _scheduleViewStateSave();
    if (!mounted ||
        !_verticalPageMode ||
        _continuousPaperWidth <= 0 ||
        _continuousViewportHeight <= 0) {
      return;
    }
    final matrix = _continuousTransformationController.value;
    final scale = matrix.getMaxScaleOnAxis().clamp(.1, 4.0).toDouble();
    final translation = matrix.getTranslation();
    final readingPoint =
        (_continuousViewportHeight * .42 - translation.y) / scale;
    final index = _continuousPageForOffset(readingPoint);
    if (index == _currentPageIndex) return;

    setState(() {
      _currentPageIndex = index;
      _activeStroke = null;
      _lassoPath.clear();
      _selectionLassoPath.clear();
      _selectionMoveMode = false;
    });
  }

  // --- pdfrx (pure-PDF notebooks) -----------------------------------------
  //
  // pdfrx's PdfViewer owns one continuously-scrollable, multi-page view
  // internally, unlike the mixed-notebook path where every page gets its
  // own Listener closed over its own pageIndex. There's only one Listener
  // here spanning every page, so incoming pointer positions have to be
  // resolved to "which page, and where on it" using the controller's own
  // Matrix4 (PdfViewerController extends ValueListenable<Matrix4>) and
  // page layout — the same category of transform math _transformationController
  // is already used for elsewhere in this file, not native/platform-view code.

  void _handlePdfrxTransformChanged() {
    if (!_usePdfrxViewer || !_pdfrxController.isReady) return;
    final pageNumber = _pdfrxController.pageNumber;
    if (pageNumber == null) return;
    final index = _pdfrxPageStart + (pageNumber - 1);
    if (index == _currentPageIndex || index < 0 || index >= _pages.length) {
      return;
    }
    setState(() {
      _currentPageIndex = index;
      _activeStroke = null;
      _lassoPath.clear();
      _selectionLassoPath.clear();
      _selectionMoveMode = false;
    });
    _scheduleViewStateSave();
  }

  /// The current on-screen rect (in the pdfrx Listener's local space) of
  /// document page [pageIndex], or null if it isn't part of the active
  /// pdfrx document or the viewer isn't laid out yet.
  Rect? _pdfrxScreenRectForPage(int pageIndex) {
    if (!_pdfrxController.isReady) return null;
    final relativeIndex = pageIndex - _pdfrxPageStart;
    final layouts = _pdfrxController.layout.pageLayouts;
    if (relativeIndex < 0 || relativeIndex >= layouts.length) return null;
    return MatrixUtils.transformRect(
      _pdfrxController.value,
      layouts[relativeIndex],
    );
  }

  ({int pageIndex, Rect rect})? _resolvePdfrxPageAt(Offset localPosition) {
    if (!_pdfrxController.isReady) return null;
    final layouts = _pdfrxController.layout.pageLayouts;
    final matrix = _pdfrxController.value;
    for (var i = 0; i < layouts.length; i++) {
      final screenRect = MatrixUtils.transformRect(matrix, layouts[i]);
      if (screenRect.contains(localPosition)) {
        return (pageIndex: _pdfrxPageStart + i, rect: screenRect);
      }
    }
    return null;
  }

  /// Re-targets a pointer event so it looks like it landed directly on
  /// [pageRect] at local (0, 0) — lets the existing per-page pointer
  /// handlers below (written for one Listener per page) work completely
  /// unchanged for pdfrx's single Listener spanning every page.
  T _transformedForPdfrxPage<T extends PointerEvent>(T event, Rect pageRect) {
    final base = event.transform ?? Matrix4.identity();
    final offset = Matrix4.translationValues(-pageRect.left, -pageRect.top, 0)
      ..multiply(base);
    // .transformed() always returns an instance of the same concrete
    // subclass as `event` (see PointerEvent.transformed's doc comment) —
    // just typed as the PointerEvent base in its signature.
    return event.transformed(offset) as T;
  }

  bool _shouldCapturePdfrxPointer(PointerDownEvent event) {
    if (_isStylus(event) || event.kind == PointerDeviceKind.mouse) return true;
    if (event.kind != PointerDeviceKind.touch || _zoomMode) {
      return false;
    }
    final hit = _resolvePdfrxPageAt(event.localPosition);
    if (hit == null || hit.pageIndex != _currentPageIndex) return false;
    return _touchCanEditAt(
      event.localPosition - hit.rect.topLeft,
      hit.rect.size,
    );
  }

  void _handlePdfrxPointerDown(PointerDownEvent event) {
    final hit = _resolvePdfrxPageAt(event.localPosition);
    if (hit == null) return;
    _activatePageForInput(hit.pageIndex);
    _pointerDown(_transformedForPdfrxPage(event, hit.rect), hit.rect.size);
  }

  void _handlePdfrxPointerMove(PointerMoveEvent event) {
    // Stay on the page the stroke started on for the rest of the gesture,
    // even if the pointer position now resolves just outside its rect
    // (e.g. a fast stroke crossing the page edge mid-move).
    final rect =
        _pdfrxScreenRectForPage(_currentPageIndex) ??
        _resolvePdfrxPageAt(event.localPosition)?.rect;
    if (rect == null) return;
    _pointerMove(_transformedForPdfrxPage(event, rect), rect.size);
  }

  void _handlePdfrxPointerUp(PointerEvent event) {
    final rect =
        _pdfrxScreenRectForPage(_currentPageIndex) ??
        _resolvePdfrxPageAt(event.localPosition)?.rect;
    _pointerUp(
      rect != null ? _transformedForPdfrxPage(event, rect) : event,
      rect?.size,
    );
  }

  void _invalidatePdfrxInkOverlay() {
    if (_usePdfrxViewer && _pdfrxController.isReady) {
      _pdfrxController.invalidate();
    }
  }

  /// Paints one page's ink through pdfrx's own paint pass
  /// (PdfViewerParams.pagePaintCallbacks) instead of a separately
  /// transformed/synced widget layer — validated on-device via the pdfrx
  /// spike to stay pixel-locked to the page under pan/zoom.
  void _paintInkForPdfrxPage(Canvas canvas, Rect pageRect, pdfrx.PdfPage page) {
    final pageIndex = _pdfrxPageStart + (page.pageNumber - 1);
    if (pageIndex < 0 || pageIndex >= _pages.length) return;
    final isCurrent = pageIndex == _currentPageIndex;
    // pdfrx invokes this callback in document space, then its
    // InteractiveViewer transforms the complete CustomPaint. That transform
    // already scales both point coordinates and paint stroke widths. Feeding
    // the viewer zoom into InkPainter would apply zoom to the width twice and
    // make the ink grow quadratically while pinching.
    InkPainter(
      strokes: _pages[pageIndex],
      activeStroke: isCurrent ? _activeStroke : null,
      lassoPath: isCurrent ? _lassoPath : const <InkPoint>[],
      selectionPath: isCurrent ? _selectionLassoPath : const <InkPoint>[],
      template: widget.document.backgroundTemplate,
      selectionOverlayScale: selectionOverlayScaleForCanvas(
        canvasToScreenScale: _selectionCanvasToScreenScale,
      ),
      eraserCursor: isCurrent && _temporaryEraser ? _eraserCursor : null,
      eraserDiameter: _eraserCanvasDiameter,
      eraserBorderWidth: _eraserGeometry.canvasBorderWidth,
      images: _decodedImages,
    ).paintInto(canvas, pageRect);
  }

  Widget _buildPdfrxDocument() {
    final path = _nativePdfPath!;
    _pdfrxPageStart = _nativePdfStartIndex ?? 0;
    return RawGestureDetector(
      behavior: HitTestBehavior.opaque,
      gestures: <Type, GestureRecognizerFactory>{
        _ConditionalEagerGestureRecognizer:
            GestureRecognizerFactoryWithHandlers<
              _ConditionalEagerGestureRecognizer
            >(
              () => _ConditionalEagerGestureRecognizer(
                shouldAccept: _shouldCapturePdfrxPointer,
                supportedDevices: const <PointerDeviceKind>{
                  PointerDeviceKind.touch,
                  PointerDeviceKind.stylus,
                  PointerDeviceKind.invertedStylus,
                  PointerDeviceKind.mouse,
                },
              ),
              (recognizer) {
                recognizer.shouldAccept = _shouldCapturePdfrxPointer;
              },
            ),
      },
      child: Listener(
        behavior: HitTestBehavior.opaque,
        onPointerDown: _handlePdfrxPointerDown,
        onPointerMove: _handlePdfrxPointerMove,
        onPointerUp: _handlePdfrxPointerUp,
        onPointerCancel: _handlePdfrxPointerUp,
        child: pdfrx.PdfViewer.file(
          path,
          key: ValueKey('pdfrx-$path'),
          controller: _pdfrxController,
          initialPageNumber: _nativePdfInitialPage + 1,
          params: pdfrx.PdfViewerParams(
            backgroundColor: _editorWorkspaceColor(context),
            pagePaintCallbacks: [_paintInkForPdfrxPage],
            // Without this a landscape slide bottoms out at fit-to-width and
            // touches every edge, while portrait pages keep side margins.
            sizeDelegateProvider: const PdfZoomOutSizeDelegateProvider(),
          ),
        ),
      ),
    );
  }

  void _activatePageForInput(int pageIndex) {
    if (pageIndex == _currentPageIndex) return;
    setState(() {
      _currentPageIndex = pageIndex;
      _activeStroke = null;
      _lassoPath.clear();
      _selectionLassoPath.clear();
      _selectionMoveMode = false;
    });
  }

  void _togglePageMode() {
    setState(() => _verticalPageMode = !_verticalPageMode);
    if (_verticalPageMode) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _scrollContinuousViewToPage(_currentPageIndex);
      });
    }
  }

  Future<void> _addPage() async {
    if (_addingPage) return;
    _addingPage = true;

    final pageCountBefore = _pages.length;
    final sourcePath = _canExportOriginalPdf ? _pagePdfPaths.first : null;
    final nextAspectRatio = _pageAspectRatio(_currentPageIndex);
    File? revisedPdf;

    try {
      if (sourcePath != null) {
        revisedPdf = await PdfNoteBacking.appendBlankPage(
          source: File(sourcePath),
          documentsDirectory: await getApplicationDocumentsDirectory(),
          documentId: widget.document.id,
          expectedPageCount: pageCountBefore,
          aspectRatio: nextAspectRatio,
        );
        if (!mounted) return;
        if (_pages.length != pageCountBefore ||
            !_canExportOriginalPdf ||
            _pagePdfPaths.first != sourcePath) {
          throw StateError('The note changed while the page was being added.');
        }
      }

      // Page structure is not part of the ink-only undo snapshots. Extend
      // existing history to the new page count so a later ink undo cannot
      // accidentally remove the page and desynchronise its PDF metadata.
      for (final snapshot in _undo) {
        snapshot.add(<InkObject>[]);
      }
      _redo.clear();

      setState(() {
        if (revisedPdf != null) {
          for (var index = 0; index < _pagePdfPaths.length; index++) {
            _pagePdfPaths[index] = revisedPdf.path;
          }
        }
        _pages.add(<InkObject>[]);
        _pageBackgrounds.add(null);
        _pageAspectRatios.add(revisedPdf == null ? null : nextAspectRatio);
        _pagePdfPaths.add(revisedPdf?.path);
        _pagePdfPageNumbers.add(
          revisedPdf == null ? null : pageCountBefore + 1,
        );
        _currentPageIndex = _pages.length - 1;
        _activeStroke = null;
        _resetZoom();
      });
      if (_verticalPageMode && revisedPdf == null) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          _scrollContinuousViewToPage(_currentPageIndex);
        });
      }
      _scheduleSave();
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Could not add page: $error')));
      }
    } finally {
      _addingPage = false;
    }
  }

  Future<void> _addImage() async {
    if (_imagePickerOpen) return;
    final previousTool = _tool;
    _imagePickerOpen = true;
    if (mounted) {
      setState(() {
        _tool = InkTool.image;
        _zoomMode = false;
      });
    }

    File? storedFile;
    ui.ImmutableBuffer? sourceBuffer;
    ui.ImageDescriptor? descriptor;
    ui.Codec? codec;
    ui.Image? decodedImage;
    var retainedImage = false;
    var inserted = false;
    try {
      final source = await showImageSourceSheet(context);
      if (source == null || !mounted) return;

      Uint8List? sourceBytes;
      if (source is GalleryImageSourceResult) {
        sourceBytes = source.bytes;
      } else if (source is CameraImageSourceResult) {
        final photo = await ImagePicker().pickImage(
          source: ImageSource.camera,
          requestFullMetadata: false,
        );
        if (photo != null) sourceBytes = await photo.readAsBytes();
      } else if (source is FilesImageSourceResult) {
        final result = await FilePicker.platform.pickFiles(
          type: FileType.image,
          allowMultiple: false,
          withData: true,
        );
        final picked = result?.files.single;
        sourceBytes = picked?.bytes;
        final sourcePath = picked?.path;
        if (sourceBytes == null && sourcePath != null) {
          sourceBytes = await File(sourcePath).readAsBytes();
        }
      }
      if (sourceBytes == null) return;
      if (sourceBytes.isEmpty) {
        throw StateError('The selected image could not be read.');
      }
      if (!mounted) return;

      sourceBuffer = await ui.ImmutableBuffer.fromUint8List(sourceBytes);
      descriptor = await ui.ImageDescriptor.encoded(sourceBuffer);
      const maximumImageDimension = 2560;
      codec = await descriptor.instantiateCodec(
        targetWidth:
            descriptor.width >= descriptor.height &&
                descriptor.width > maximumImageDimension
            ? maximumImageDimension
            : null,
        targetHeight:
            descriptor.height > descriptor.width &&
                descriptor.height > maximumImageDimension
            ? maximumImageDimension
            : null,
      );
      final frame = await codec.getNextFrame();
      decodedImage = frame.image;
      final pixelWidth = decodedImage.width.toDouble();
      final pixelHeight = decodedImage.height.toDouble();
      final pngData = await decodedImage.toByteData(
        format: ui.ImageByteFormat.png,
      );
      if (pngData == null || !mounted) {
        throw StateError('The selected image could not be converted.');
      }

      final appDirectory = await getApplicationDocumentsDirectory();
      final imageDirectory = Directory(
        '${appDirectory.path}/ink_note_data/${widget.document.id}/images',
      );
      await imageDirectory.create(recursive: true);
      storedFile = File(
        '${imageDirectory.path}/image_${DateTime.now().microsecondsSinceEpoch}.png',
      );
      await storedFile.writeAsBytes(
        pngData.buffer.asUint8List(
          pngData.offsetInBytes,
          pngData.lengthInBytes,
        ),
        flush: true,
      );
      if (!mounted) return;

      final pageRatio = _pageAspectRatio(_currentPageIndex);
      var normalizedWidth = .46;
      var normalizedHeight =
          normalizedWidth * (pixelHeight / pixelWidth) / pageRatio;
      const maxNormalizedHeight = .52;
      if (normalizedHeight > maxNormalizedHeight) {
        final scale = maxNormalizedHeight / normalizedHeight;
        normalizedWidth *= scale;
        normalizedHeight = maxNormalizedHeight;
      }
      final imageObject = InkImage(
        path: storedFile.path,
        x: (1 - normalizedWidth) / 2,
        y: (1 - normalizedHeight) / 2,
        width: normalizedWidth,
        height: normalizedHeight,
        isSelected: true,
      );
      _snapshot();
      setState(() {
        _clearSelection();
        _currentObjects.add(imageObject);
        _decodedImages.remove(storedFile!.path)?.dispose();
        _decodedImages[storedFile.path] = decodedImage!;
        _selectionMoveMode = true;
        _selectionLassoPath.clear();
        _lassoPath.clear();
        _activeStroke = null;
        _tool = InkTool.lasso;
      });
      retainedImage = true;
      inserted = true;
      _scheduleSave();
      if (_pdfrxController.isReady) _pdfrxController.invalidate();
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Image added to this page.')),
      );
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Could not add image: $error')));
      }
    } finally {
      _imagePickerOpen = false;
      codec?.dispose();
      descriptor?.dispose();
      sourceBuffer?.dispose();
      if (!retainedImage) decodedImage?.dispose();
      if (!inserted && storedFile != null && await storedFile.exists()) {
        await storedFile.delete();
      }
      if (mounted && !inserted && _tool == InkTool.image) {
        setState(() => _tool = previousTool);
      }
    }
  }

  Future<void> _importPdf() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: const ['pdf'],
      allowMultiple: false,
    );
    final sourcePath = result?.files.single.path;
    if (sourcePath == null || !mounted) return;

    final messenger = ScaffoldMessenger.of(context);
    messenger.showSnackBar(
      const SnackBar(content: Text('Importing original PDF…')),
    );

    PdfDocument? document;
    Directory? targetDirectory;
    try {
      final appDirectory = await getApplicationDocumentsDirectory();
      final importId = DateTime.now().microsecondsSinceEpoch;
      targetDirectory = Directory(
        '${appDirectory.path}/ink_note_pdf/${widget.document.id}/$importId',
      );
      await targetDirectory.create(recursive: true);
      final storedPdf = await File(
        sourcePath,
      ).copy('${targetDirectory.path}/source.pdf');
      document = await PdfDocument.openFile(storedPdf.path);

      final importedPages = <List<InkObject>>[];
      final importedBackgrounds = <String?>[];
      final importedAspectRatios = <double?>[];
      final importedPdfPaths = <String?>[];
      final importedPdfPageNumbers = <int?>[];
      for (
        var pageNumber = 1;
        pageNumber <= document.pagesCount;
        pageNumber++
      ) {
        final page = await document.getPage(pageNumber);
        try {
          importedPages.add(<InkObject>[]);
          importedBackgrounds.add(null);
          importedPdfPaths.add(storedPdf.path);
          importedPdfPageNumbers.add(pageNumber);
          final ratio = page.width > 0 ? page.height / page.width : 1.35;
          importedAspectRatios.add(
            ratio.isFinite && ratio > .15 ? ratio.toDouble() : 1.35,
          );
        } finally {
          await page.close();
        }
      }

      if (importedPages.isEmpty) {
        throw StateError('The PDF did not contain a readable page.');
      }

      _snapshot();
      setState(() {
        final replaceEmptyStarterPage =
            _pages.length == 1 &&
            _pages.first.isEmpty &&
            (_pageBackgrounds.isEmpty || _pageBackgrounds.first == null) &&
            (_pagePdfPaths.isEmpty || _pagePdfPaths.first == null);
        if (replaceEmptyStarterPage) {
          _pages = importedPages;
          _pageBackgrounds = importedBackgrounds;
          _pageAspectRatios = importedAspectRatios;
          _pagePdfPaths = importedPdfPaths;
          _pagePdfPageNumbers = importedPdfPageNumbers;
          _currentPageIndex = 0;
        } else {
          _pages.addAll(importedPages);
          _pageBackgrounds.addAll(importedBackgrounds);
          _pageAspectRatios.addAll(importedAspectRatios);
          _pagePdfPaths.addAll(importedPdfPaths);
          _pagePdfPageNumbers.addAll(importedPdfPageNumbers);
          _currentPageIndex = _pages.length - importedPages.length;
        }
        _activeStroke = null;
        // Only a notebook that consists entirely of this PDF can be hosted by
        // one native PDF view. When importing into an existing notebook, keep
        // the original pages and append the PDF pages without replacing or
        // hiding them.
        _zoomMode = replaceEmptyStarterPage;
        _resetZoom();
      });
      _scheduleSave();
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            'Imported ${importedPages.length} PDF pages from the original file',
          ),
        ),
      );
    } catch (error) {
      if (targetDirectory != null && await targetDirectory.exists()) {
        await targetDirectory.delete(recursive: true);
      }
      messenger.showSnackBar(
        SnackBar(content: Text('Could not import PDF: $error')),
      );
    } finally {
      await document?.close();
    }
  }

  Future<void> _saveColorPresets() => InkStore.saveColorPresets(_colorPresets);

  Future<void> _saveHighlighterColorPresets() =>
      InkStore.saveHighlighterColorPresets(_highlighterColorPresets);

  Future<Color?> _replaceQuickColorSlot({
    required bool highlighter,
    required int index,
    required Color initialColor,
  }) async {
    final replacement = await _showAdvancedColorPicker(
      initialColor,
      allowPresetActions: false,
    );
    if (!mounted || replacement == null) return null;

    setState(() {
      if (highlighter) {
        if (index < 0 || index >= _highlighterColorPresets.length) return;
        final updated = List<Color>.of(_highlighterColorPresets);
        updated[index] = replacement;
        _highlighterColorPresets = updated;
        _highlighterColor = replacement;
      } else {
        if (index < 0 || index >= _colorPresets.length) return;
        final updated = List<Color>.of(_colorPresets);
        updated[index] = replacement;
        _colorPresets = updated;
        _color = replacement;
      }
    });

    if (highlighter) {
      await _saveHighlighterColorPresets();
    } else {
      await _saveColorPresets();
    }
    return replacement;
  }

  Future<void> _handleQuickColorTap(Color itemColor) async {
    final highlighter = _tool == InkTool.highlighter;
    final currentColor = highlighter ? _highlighterColor : _color;
    final isSelected = itemColor.toARGB32() == currentColor.toARGB32();

    if (!isSelected) {
      setState(() {
        if (highlighter) {
          _highlighterColor = itemColor;
        } else {
          _color = itemColor;
        }
      });
      return;
    }

    final colors = highlighter ? _highlighterColorPresets : _colorPresets;
    final index = colors.indexWhere(
      (color) => color.toARGB32() == itemColor.toARGB32(),
    );
    if (index < 0) return;
    await _replaceQuickColorSlot(
      highlighter: highlighter,
      index: index,
      initialColor: itemColor,
    );
  }

  Future<void> _addColorPreset(Color color) async {
    if (_colorPresets.any((item) => item.toARGB32() == color.toARGB32())) {
      return;
    }
    setState(() => _colorPresets = [..._colorPresets, color]);
    await _saveColorPresets();
  }

  Future<void> _removeColorPreset(Color color) async {
    final index = _colorPresets.indexWhere(
      (item) => item.toARGB32() == color.toARGB32(),
    );
    if (index < _defaultColorPresets.length || index < 0) return;
    final updated = List<Color>.of(_colorPresets)..removeAt(index);
    setState(() => _colorPresets = updated);
    await _saveColorPresets();
  }

  Future<Color?> _pickColorFromCanvas() async {
    return showGeneralDialog<Color>(
      context: context,
      barrierDismissible: true,
      barrierLabel: 'Cancel color picker',
      barrierColor: Colors.black.withValues(alpha: .08),
      pageBuilder: (pickerContext, _, _) {
        var sampling = false;
        return StatefulBuilder(
          builder: (context, setPickerState) {
            return Material(
              color: Colors.transparent,
              child: Stack(
                children: [
                  Positioned.fill(
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTapDown: (details) async {
                        if (sampling) return;
                        final canvasContext = _canvasKey.currentContext;
                        final renderObject = canvasContext?.findRenderObject();
                        if (renderObject is! RenderRepaintBoundary) return;
                        final local = renderObject.globalToLocal(
                          details.globalPosition,
                        );
                        if (local.dx < 0 ||
                            local.dy < 0 ||
                            local.dx >= renderObject.size.width ||
                            local.dy >= renderObject.size.height) {
                          Navigator.of(pickerContext).pop();
                          return;
                        }
                        setPickerState(() => sampling = true);
                        var completed = false;
                        try {
                          final image = await renderObject.toImage(
                            pixelRatio: 1,
                          );
                          final data = await image.toByteData(
                            format: ui.ImageByteFormat.rawRgba,
                          );
                          if (data == null) {
                            image.dispose();
                            return;
                          }
                          final pixelX =
                              (local.dx / renderObject.size.width * image.width)
                                  .floor()
                                  .clamp(0, image.width - 1)
                                  .toInt();
                          final pixelY =
                              (local.dy /
                                      renderObject.size.height *
                                      image.height)
                                  .floor()
                                  .clamp(0, image.height - 1)
                                  .toInt();
                          final offset = (pixelY * image.width + pixelX) * 4;
                          final bytes = data.buffer.asUint8List();
                          final sampled = Color.fromARGB(
                            bytes[offset + 3],
                            bytes[offset],
                            bytes[offset + 1],
                            bytes[offset + 2],
                          );
                          image.dispose();
                          completed = true;
                          if (pickerContext.mounted) {
                            Navigator.of(pickerContext).pop(sampled);
                          }
                        } catch (_) {
                          if (pickerContext.mounted) {
                            ScaffoldMessenger.of(pickerContext).showSnackBar(
                              const SnackBar(
                                content: Text('Could not pick this color.'),
                              ),
                            );
                          }
                        } finally {
                          if (!completed && pickerContext.mounted) {
                            setPickerState(() => sampling = false);
                          }
                        }
                      },
                      child: const SizedBox.expand(),
                    ),
                  ),
                  SafeArea(
                    child: Align(
                      alignment: Alignment.topCenter,
                      child: Padding(
                        padding: const EdgeInsets.only(top: 72),
                        child: Material(
                          elevation: 8,
                          color: Theme.of(context).colorScheme.surface,
                          borderRadius: BorderRadius.circular(999),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 16,
                              vertical: 10,
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                if (sampling)
                                  const SizedBox(
                                    width: 18,
                                    height: 18,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                    ),
                                  )
                                else
                                  const Icon(Icons.colorize_rounded, size: 19),
                                const SizedBox(width: 8),
                                Text(
                                  sampling
                                      ? 'Picking color…'
                                      : 'Tap a color on the page',
                                  style: const TextStyle(
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }

  Future<Color?> _showAdvancedColorPicker(
    Color initialColor, {
    bool canRemove = false,
    bool allowPresetActions = true,
  }) async {
    var hsv = HSVColor.fromColor(initialColor);
    var pickerMode = 0;

    return showGeneralDialog<Color>(
      context: context,
      barrierDismissible: false,
      barrierLabel: 'Close color editor',
      barrierColor: Colors.transparent,
      transitionDuration: const Duration(milliseconds: 160),
      pageBuilder: (dialogContext, _, _) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            final scheme = Theme.of(context).colorScheme;
            final media = MediaQuery.of(context);
            final compact = media.size.width < 650;
            final selected = hsv.toColor();
            final hex = selected
                .toARGB32()
                .toRadixString(16)
                .padLeft(8, '0')
                .substring(2)
                .toUpperCase();

            void closeAndApply() => Navigator.of(dialogContext).pop(selected);

            return Material(
              color: Colors.transparent,
              child: Stack(
                children: [
                  Positioned.fill(
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: closeAndApply,
                      child: const SizedBox.expand(),
                    ),
                  ),
                  SafeArea(
                    child: Align(
                      alignment: Alignment.topCenter,
                      child: Padding(
                        padding: EdgeInsets.only(
                          top: compact ? 112 : 138,
                          left: 12,
                          right: 12,
                        ),
                        child: Material(
                          elevation: 22,
                          shadowColor: Colors.black.withValues(alpha: .24),
                          color: scheme.surface.withValues(alpha: .99),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(24),
                            side: BorderSide(
                              color: scheme.outlineVariant.withValues(
                                alpha: .65,
                              ),
                            ),
                          ),
                          clipBehavior: Clip.antiAlias,
                          child: ConstrainedBox(
                            constraints: BoxConstraints(
                              maxWidth: 470,
                              maxHeight:
                                  media.size.height -
                                  media.padding.vertical -
                                  (compact ? 132 : 158),
                            ),
                            child: SingleChildScrollView(
                              padding: const EdgeInsets.fromLTRB(
                                18,
                                10,
                                18,
                                18,
                              ),
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Row(
                                    children: [
                                      const Expanded(
                                        child: Text(
                                          'Edit color',
                                          style: TextStyle(
                                            fontSize: 19,
                                            fontWeight: FontWeight.w800,
                                          ),
                                        ),
                                      ),
                                      IconButton(
                                        tooltip: 'Pick color from page',
                                        onPressed: () async {
                                          final picked =
                                              await _pickColorFromCanvas();
                                          if (picked != null &&
                                              dialogContext.mounted) {
                                            setDialogState(
                                              () => hsv = HSVColor.fromColor(
                                                picked,
                                              ),
                                            );
                                          }
                                        },
                                        icon: const Icon(
                                          Icons.colorize_rounded,
                                        ),
                                      ),
                                      IconButton(
                                        tooltip: 'Apply and close',
                                        onPressed: closeAndApply,
                                        icon: const Icon(Icons.check_rounded),
                                      ),
                                    ],
                                  ),
                                  const SizedBox(height: 6),
                                  SegmentedButton<int>(
                                    segments: const [
                                      ButtonSegment<int>(
                                        value: 0,
                                        label: Text('Grid'),
                                      ),
                                      ButtonSegment<int>(
                                        value: 1,
                                        label: Text('Spectrum'),
                                      ),
                                    ],
                                    selected: {pickerMode},
                                    showSelectedIcon: false,
                                    onSelectionChanged: (value) =>
                                        setDialogState(
                                          () => pickerMode = value.first,
                                        ),
                                  ),
                                  const SizedBox(height: 12),
                                  AnimatedSwitcher(
                                    duration: const Duration(milliseconds: 160),
                                    child: pickerMode == 0
                                        ? _ColorGridField(
                                            key: const ValueKey('grid'),
                                            hsv: hsv,
                                            onChanged: (value) =>
                                                setDialogState(
                                                  () => hsv = value,
                                                ),
                                          )
                                        : SizedBox(
                                            key: const ValueKey('spectrum'),
                                            height: compact ? 230 : 270,
                                            child: _ColorSpectrumField(
                                              hsv: hsv,
                                              onChanged: (value) =>
                                                  setDialogState(
                                                    () => hsv = value,
                                                  ),
                                            ),
                                          ),
                                  ),
                                  const SizedBox(height: 12),
                                  Align(
                                    alignment: Alignment.centerLeft,
                                    child: Text(
                                      'Opacity ${(hsv.alpha * 100).round()}%',
                                      style: const TextStyle(
                                        fontWeight: FontWeight.w700,
                                      ),
                                    ),
                                  ),
                                  Slider(
                                    value: hsv.alpha,
                                    min: 0,
                                    max: 1,
                                    divisions: 100,
                                    onChanged: (value) => setDialogState(
                                      () => hsv = hsv.withAlpha(value),
                                    ),
                                  ),
                                  const SizedBox(height: 4),
                                  Row(
                                    children: [
                                      Container(
                                        width: 42,
                                        height: 42,
                                        decoration: BoxDecoration(
                                          color: selected,
                                          shape: BoxShape.circle,
                                          border: Border.all(
                                            color: scheme.outlineVariant,
                                          ),
                                        ),
                                      ),
                                      const SizedBox(width: 12),
                                      Expanded(
                                        child: Container(
                                          padding: const EdgeInsets.symmetric(
                                            horizontal: 14,
                                            vertical: 11,
                                          ),
                                          decoration: BoxDecoration(
                                            color:
                                                scheme.surfaceContainerHighest,
                                            borderRadius: BorderRadius.circular(
                                              999,
                                            ),
                                          ),
                                          child: Text(
                                            'HEX $hex',
                                            style: const TextStyle(
                                              fontWeight: FontWeight.w700,
                                            ),
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                  if (allowPresetActions) ...[
                                    const SizedBox(height: 12),
                                    OutlinedButton.icon(
                                      onPressed: () async {
                                        await _addColorPreset(selected);
                                      },
                                      icon: const Icon(
                                        Icons.add_circle_outline_rounded,
                                      ),
                                      label: const Text('Add to presets'),
                                    ),
                                  ],
                                  if (canRemove && allowPresetActions) ...[
                                    const SizedBox(height: 6),
                                    TextButton.icon(
                                      style: TextButton.styleFrom(
                                        foregroundColor: scheme.error,
                                      ),
                                      onPressed: () async {
                                        await _removeColorPreset(initialColor);
                                        if (dialogContext.mounted) {
                                          Navigator.of(dialogContext).pop();
                                        }
                                      },
                                      icon: const Icon(
                                        Icons.delete_outline_rounded,
                                      ),
                                      label: const Text('Remove color'),
                                    ),
                                  ],
                                  const SizedBox(height: 4),
                                  Text(
                                    'Tap outside to apply and close automatically.',
                                    style: TextStyle(
                                      fontSize: 12,
                                      color: scheme.onSurfaceVariant,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            );
          },
        );
      },
      transitionBuilder: (_, animation, _, child) {
        final curved = CurvedAnimation(
          parent: animation,
          curve: Curves.easeOutCubic,
          reverseCurve: Curves.easeInCubic,
        );
        return FadeTransition(
          opacity: curved,
          child: SlideTransition(
            position: Tween<Offset>(
              begin: const Offset(0, -.025),
              end: Offset.zero,
            ).animate(curved),
            child: child,
          ),
        );
      },
    );
  }

  Future<Color?> _showColorPalette(Color initialColor) async {
    final highlighter = _tool == InkTool.highlighter;
    final selection = _tool == InkTool.lasso || _tool == InkTool.text;

    return showGeneralDialog<Color>(
      context: context,
      barrierDismissible: false,
      barrierLabel: 'Close color palette',
      barrierColor: Colors.transparent,
      transitionDuration: const Duration(milliseconds: 160),
      pageBuilder: (dialogContext, _, _) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            final scheme = Theme.of(context).colorScheme;
            final media = MediaQuery.of(context);
            final compact = media.size.width < 650;
            final colors = highlighter
                ? _highlighterColorPresets
                : _colorPresets;

            void closeWithoutChange() =>
                Navigator.of(dialogContext).pop(initialColor);

            return Material(
              color: Colors.transparent,
              child: Stack(
                children: [
                  Positioned.fill(
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: closeWithoutChange,
                      child: const SizedBox.expand(),
                    ),
                  ),
                  SafeArea(
                    child: Align(
                      alignment: Alignment.topCenter,
                      child: Padding(
                        padding: EdgeInsets.only(
                          top: compact ? 112 : 138,
                          left: 12,
                          right: 12,
                        ),
                        child: Material(
                          elevation: 20,
                          shadowColor: Colors.black.withValues(alpha: .22),
                          color: scheme.surface.withValues(alpha: .99),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(22),
                            side: BorderSide(
                              color: scheme.outlineVariant.withValues(
                                alpha: .65,
                              ),
                            ),
                          ),
                          clipBehavior: Clip.antiAlias,
                          child: ConstrainedBox(
                            constraints: const BoxConstraints(maxWidth: 470),
                            child: Padding(
                              padding: const EdgeInsets.fromLTRB(
                                18,
                                10,
                                18,
                                16,
                              ),
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Row(
                                    children: [
                                      Expanded(
                                        child: Text(
                                          selection
                                              ? 'Selection color'
                                              : highlighter
                                              ? 'Highlighter color'
                                              : 'Pen color',
                                          style: const TextStyle(
                                            fontSize: 19,
                                            fontWeight: FontWeight.w800,
                                          ),
                                        ),
                                      ),
                                      IconButton(
                                        tooltip: 'Pick color from page',
                                        onPressed: () async {
                                          final picked =
                                              await _pickColorFromCanvas();
                                          if (picked != null &&
                                              dialogContext.mounted) {
                                            Navigator.of(
                                              dialogContext,
                                            ).pop(picked);
                                          }
                                        },
                                        icon: const Icon(
                                          Icons.colorize_rounded,
                                        ),
                                      ),
                                      IconButton(
                                        tooltip: 'Close',
                                        onPressed: closeWithoutChange,
                                        icon: const Icon(Icons.close_rounded),
                                      ),
                                    ],
                                  ),
                                  const SizedBox(height: 8),
                                  GridView.builder(
                                    shrinkWrap: true,
                                    physics:
                                        const NeverScrollableScrollPhysics(),
                                    gridDelegate:
                                        const SliverGridDelegateWithFixedCrossAxisCount(
                                          crossAxisCount: 8,
                                          crossAxisSpacing: 12,
                                          mainAxisSpacing: 12,
                                        ),
                                    itemCount: colors.length + 1,
                                    itemBuilder: (context, index) {
                                      if (index == colors.length) {
                                        return _AddColorButton(
                                          onTap: () async {
                                            final selected =
                                                await _showAdvancedColorPicker(
                                                  initialColor,
                                                  allowPresetActions:
                                                      !highlighter,
                                                );
                                            if (selected != null &&
                                                dialogContext.mounted) {
                                              Navigator.of(
                                                dialogContext,
                                              ).pop(selected);
                                            }
                                          },
                                        );
                                      }

                                      final color = colors[index];
                                      final custom =
                                          !highlighter &&
                                          index >= _defaultColorPresets.length;
                                      return _PaletteColorButton(
                                        color: color,
                                        selected:
                                            color.toARGB32() ==
                                            initialColor.toARGB32(),
                                        onTap: () => Navigator.of(
                                          dialogContext,
                                        ).pop(color),
                                        onLongPress: custom
                                            ? () async {
                                                final replacement =
                                                    await _showAdvancedColorPicker(
                                                      color,
                                                      canRemove: true,
                                                    );
                                                if (replacement != null &&
                                                    dialogContext.mounted) {
                                                  setDialogState(() {});
                                                }
                                              }
                                            : null,
                                      );
                                    },
                                  ),
                                  const SizedBox(height: 10),
                                  Text(
                                    'Choose a color directly. Tap outside to close.',
                                    style: TextStyle(
                                      fontSize: 12,
                                      color: scheme.onSurfaceVariant,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            );
          },
        );
      },
      transitionBuilder: (_, animation, _, child) {
        final curved = CurvedAnimation(
          parent: animation,
          curve: Curves.easeOutCubic,
          reverseCurve: Curves.easeInCubic,
        );
        return FadeTransition(
          opacity: curved,
          child: SlideTransition(
            position: Tween<Offset>(
              begin: const Offset(0, -.025),
              end: Offset.zero,
            ).animate(curved),
            child: child,
          ),
        );
      },
    );
  }

  Future<void> _chooseDrawingColor() async {
    final isHighlighter = _tool == InkTool.highlighter;
    final selected = await _showColorPalette(
      isHighlighter ? _highlighterColor : _color,
    );
    if (selected != null && mounted) {
      setState(() {
        if (isHighlighter) {
          _highlighterColor = selected;
        } else {
          _color = selected;
        }
      });
    }
  }

  Future<void> _chooseSelectionColor() async {
    if (!_hasSelection) return;
    var initialColor = _color;
    for (final object in _currentObjects) {
      if (!object.isSelected) continue;
      if (object is InkStroke) {
        initialColor = object.color;
        break;
      }
      if (object is InkText) {
        initialColor = object.color;
        break;
      }
    }
    final selected = await _showColorPalette(initialColor);
    if (selected != null && mounted) _recolorSelection(selected);
  }

  bool get _canExportOriginalPdf {
    if (_pages.isEmpty || _pagePdfPaths.length < _pages.length) return false;
    final sourcePath = _pagePdfPaths.first;
    if (sourcePath == null || sourcePath.isEmpty) return false;
    for (var index = 0; index < _pages.length; index++) {
      if (_pagePdfPaths[index] != sourcePath ||
          index >= _pagePdfPageNumbers.length ||
          _pagePdfPageNumbers[index] != index + 1) {
        return false;
      }
    }
    return true;
  }

  Future<File> _exportAnnotatedOriginalPdf() async {
    final sourcePath = _pagePdfPaths.first!;
    final sourceFile = File(sourcePath);
    if (!await sourceFile.exists()) {
      throw StateError('The original PDF file is missing.');
    }

    final safeTitle = widget.document.title
        .replaceAll(RegExp(r'[^a-zA-Z0-9_-]+'), '_')
        .replaceAll(RegExp(r'_+'), '_');
    final tempRoot = Directory(
      '${(await getTemporaryDirectory()).path}/ink_note_pdf_export_${DateTime.now().microsecondsSinceEpoch}',
    );
    await tempRoot.create(recursive: true);
    final finalFile = File(
      '${tempRoot.path}/${safeTitle.isEmpty ? 'ink_note' : safeTitle}.pdf',
    );

    final imageBytesByPath = <String, Uint8List>{};
    for (final image in _pages.expand((page) => page.whereType<InkImage>())) {
      if (imageBytesByPath.containsKey(image.path)) continue;
      final file = File(image.path);
      if (!await file.exists()) {
        throw StateError('An inserted image required for export is missing.');
      }
      imageBytesByPath[image.path] = await file.readAsBytes();
    }

    final exported = PdfVectorExporter.export(
      sourcePdf: await sourceFile.readAsBytes(),
      pages: _pages,
      imageBytesByPath: imageBytesByPath,
    );
    await finalFile.writeAsBytes(exported, flush: true);
    return finalFile;
  }

  Future<void> _shareCurrentPageAsPng() async {
    await Future.wait(
      _currentObjects.whereType<InkImage>().map(
        (image) => _loadStoredImage(image.path),
      ),
    );
    await WidgetsBinding.instance.endOfFrame;
    if (!mounted) throw StateError('Editor is no longer open');
    final canvasContext = _canvasKey.currentContext;
    if (canvasContext == null) throw StateError('Canvas is not ready');
    if (!canvasContext.mounted) throw StateError('Canvas is no longer open');
    final boundary = canvasContext.findRenderObject() as RenderRepaintBoundary;
    final image = await boundary.toImage(pixelRatio: 2);
    final byteData = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    if (byteData == null) throw StateError('Could not encode image');

    final safeTitle = widget.document.title
        .replaceAll(RegExp(r'[^a-zA-Z0-9_-]+'), '_')
        .replaceAll(RegExp(r'_+'), '_');
    final directory = await getTemporaryDirectory();
    final file = File(
      '${directory.path}/${safeTitle.isEmpty ? 'ink_note' : safeTitle}_page_${_currentPageIndex + 1}.png',
    );
    await file.writeAsBytes(byteData.buffer.asUint8List(), flush: true);
    await Share.shareXFiles(
      [XFile(file.path)],
      text: widget.document.title,
      sharePositionOrigin: boundary.localToGlobal(Offset.zero) & boundary.size,
    );
  }

  Future<void> _exportAndShare() async {
    try {
      if (_canExportOriginalPdf) {
        if (_showNativePdfReader) {
          await _nativePdfController.save();
        }
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Exporting annotated PDF…')),
          );
        }
        final file = await _exportAnnotatedOriginalPdf();
        if (!mounted) return;
        final box = context.findRenderObject() as RenderBox?;
        await Share.shareXFiles(
          [XFile(file.path)],
          text: widget.document.title,
          sharePositionOrigin: box == null
              ? null
              : box.localToGlobal(Offset.zero) & box.size,
        );
        return;
      }
      await _shareCurrentPageAsPng();
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not export this note: $error')),
      );
    }
  }

  Future<void> _shareNotenBackup() async {
    _saveTimer?.cancel();
    _viewSaveTimer?.cancel();
    final saved = await _saveDocument();
    if (!saved || !mounted) return;

    try {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Creating editable Noten backup...')),
      );
      final bytes = await NotenArchive.encode(_documentSnapshot());
      final directory = Directory(
        '${(await getTemporaryDirectory()).path}/ink_note_noten_export_${DateTime.now().microsecondsSinceEpoch}',
      );
      await directory.create(recursive: true);
      final file = File(
        '${directory.path}/${NotenArchive.safeFileName(widget.document.title)}.${NotenArchive.extension}',
      );
      await file.writeAsBytes(bytes, flush: true);
      if (!mounted) return;
      final box = context.findRenderObject() as RenderBox?;
      await Share.shareXFiles(
        [XFile(file.path, mimeType: NotenArchive.mimeType)],
        text: widget.document.title,
        sharePositionOrigin: box == null
            ? null
            : box.localToGlobal(Offset.zero) & box.size,
      );
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not create Noten backup: $error')),
      );
    }
  }

  Future<void> _showExportOptions() async {
    final mediaLabel = _canExportOriginalPdf ? 'PDF document' : 'PNG image';
    final choice = await showModalBottomSheet<_ExportChoice>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: Icon(
                _canExportOriginalPdf
                    ? Icons.picture_as_pdf_outlined
                    : Icons.image_outlined,
              ),
              title: Text('Share as $mediaLabel'),
              subtitle: const Text('For viewing, printing, or submitting'),
              onTap: () => Navigator.pop(context, _ExportChoice.pdfOrImage),
            ),
            const Divider(height: 1),
            ListTile(
              leading: const Icon(Icons.inventory_2_outlined),
              title: const Text('Share editable Noten backup'),
              subtitle: const Text(
                'Includes the original PDF, page backgrounds, and editable ink',
              ),
              onTap: () => Navigator.pop(context, _ExportChoice.noten),
            ),
          ],
        ),
      ),
    );
    if (!mounted || choice == null) return;
    switch (choice) {
      case _ExportChoice.pdfOrImage:
        await _exportAndShare();
        return;
      case _ExportChoice.noten:
        await _shareNotenBackup();
        return;
    }
  }

  Widget _buildFloatingToolbar({
    required FloatingToolbarSection section,
    required Axis axis,
    required ToolbarDragCallbacks dragCallbacks,
  }) => FloatingEditorToolbar(
    section: section,
    axis: axis,
    dragCallbacks: dragCallbacks,
    tool: _tool,
    color: _tool == InkTool.highlighter ? _highlighterColor : _color,
    width: _tool == InkTool.eraser
        ? _eraserSize
        : _tool == InkTool.highlighter
        ? _highlighterWidth
        : _width,
    canUndo: _canUndoCurrent,
    canRedo: _canRedoCurrent,
    zoomMode: _zoomMode,
    onTool: (tool) {
      setState(() {
        final comingFromUtility =
            _tool == InkTool.eraser ||
            _tool == InkTool.text ||
            _tool == InkTool.lasso;
        final resolvedTool = tool == InkTool.pen && comingFromUtility
            ? _lastPenTool
            : tool;
        _tool = resolvedTool;
        if (_isDrawingTool(resolvedTool)) _lastDrawingTool = resolvedTool;
        if (_isPenTool(resolvedTool)) _lastPenTool = resolvedTool;
        _zoomMode = false;
      });
    },
    onAddImage: () => unawaited(_addImage()),
    canPaste: _selectionClipboard.isNotEmpty && !_hasSelection,
    onPaste: _pasteSelection,
    onColor: (color) => unawaited(_handleQuickColorTap(color)),
    onOpenColorPalette: _chooseDrawingColor,
    paletteColors: _tool == InkTool.highlighter
        ? _highlighterColorPresets
        : _colorPresets,
    onWidth: (width) => setState(() {
      if (_tool == InkTool.eraser) {
        _eraserSize = width;
      } else if (_tool == InkTool.highlighter) {
        _highlighterWidth = width;
      } else {
        _width = width;
      }
    }),
    eraserMode: _eraserMode,
    onEraserModeChanged: (value) => setState(() => _eraserMode = value),
    eraseHighlighterOnly: _eraseHighlighterOnly,
    onEraseHighlighterOnlyChanged: (value) =>
        setState(() => _eraseHighlighterOnly = value),
    eraserAutoDeselect: _eraserAutoDeselect,
    onEraserAutoDeselectChanged: (value) =>
        setState(() => _eraserAutoDeselect = value),
    onPenTap: _selectOrOpenPenSettings,
    onPenSettings: _showPenSettings,
    onUndo: _undoCurrentAction,
    onRedo: _redoCurrentAction,
    onToggleZoomMode: () => setState(() => _zoomMode = !_zoomMode),
    presets: _presets,
    highlighterPresets: _highlighterPresets,
    onWidthPresetTap: (index) => unawaited(
      _handleSizePresetTap(
        highlighter: _tool == InkTool.highlighter,
        index: index,
      ),
    ),
    onAddWidthPreset: () =>
        unawaited(_addSizePreset(highlighter: _tool == InkTool.highlighter)),
    onZoomIn: () => _zoomEditorBy(1.2),
    onZoomOut: () => _zoomEditorBy(1 / 1.2),
    onResetZoom: _resetEditorZoom,
    dashed: _dashedStroke,
    onDashedChanged: (value) => setState(() => _dashedStroke = value),
    textSize: _textSize,
    onTextSizeChanged: (value) => setState(() => _textSize = value),
    textBold: _textBold,
    onTextBoldChanged: (value) => setState(() => _textBold = value),
    textItalic: _textItalic,
    onTextItalicChanged: (value) => setState(() => _textItalic = value),
    textAlign: _textAlign,
    onTextAlignChanged: (value) => setState(() => _textAlign = value),
    lineHeight: _textLineHeight,
    onLineHeightChanged: (value) => setState(() => _textLineHeight = value),
  );

  void _applyToolbarDocking(ToolbarDockingResult result) {
    final normalized = normalizeToolbarDocking(
      primary: result.primary,
      options: result.options,
    );
    setState(() {
      _primaryToolbarDock = normalized.primary.dock;
      _primaryToolbarOrder = normalized.primary.order;
      _optionsToolbarDock = normalized.options.dock;
      _optionsToolbarOrder = normalized.options.order;
    });
  }

  double _toolbarDepthAt(ToolbarDock dock) {
    var depth = 8.0;
    var count = 0;
    if (_primaryToolbarDock == dock) {
      depth += 58;
      count++;
    }
    if (_optionsToolbarDock == dock) {
      depth += 48;
      count++;
    }
    if (count > 1) depth += 4;
    return count == 0 ? 8 : depth;
  }

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width;
    final wide = width >= 900;
    final scheme = Theme.of(context).colorScheme;
    final workspaceColor = _editorWorkspaceColor(context);

    return Scaffold(
      body: Column(
        children: [
          if (wide)
            _DesktopEditorHeader(
              documents: widget.openDocuments,
              activeId: widget.activeDocumentId,
              onSelect: _selectDocumentTab,
              onClose: _closeDocumentTab,
              onNewTab: _newDocumentTab,
              onHome: _exitEditor,
              onShare: _showExportOptions,
              onImportPdf: _importPdf,
              verticalPageMode: _verticalPageMode,
              onTogglePageMode: _togglePageMode,
            )
          else
            _MobileEditorHeader(
              title: widget.document.title,
              onBack: _exitEditor,
              onShare: _showExportOptions,
              onImportPdf: _importPdf,
              verticalPageMode: _verticalPageMode,
              onTogglePageMode: _togglePageMode,
            ),
          Expanded(
            child: Row(
              children: [
                Expanded(
                  child: Stack(
                    key: _editorViewportKey,
                    children: [
                      if (_usePdfrxViewer)
                        Positioned.fill(child: _buildPdfrxDocument()),
                      if (_showNativePdfReader)
                        Positioned.fill(
                          child: ColoredBox(
                            color: workspaceColor,
                            child: NativePdfDocumentView(
                              key: ValueKey('native-pdf-${_nativePdfPath!}'),
                              path: _nativePdfPath!,
                              controller: _nativePdfController,
                              page: _nativePdfInitialPage,
                              tool: _tool.name,
                              colorValue:
                                  (_tool == InkTool.highlighter
                                          ? _highlighterColor
                                          : _color)
                                      .toARGB32(),
                              strokeWidth: _tool == InkTool.highlighter
                                  ? _highlighterWidth
                                  : _tool == InkTool.eraser
                                  ? _eraserSize
                                  : _width,
                              eraserMode: _eraserMode.name,
                              allowFinger: _settings.allowFinger,
                              smoothing: _smoothing,
                              onDocumentChanged: _nativeDocumentChanged,
                              onPageChanged: (pdfPage) {
                                final start = _nativePdfStartIndex ?? 0;
                                final documentPage = (start + pdfPage)
                                    .clamp(0, _pages.length - 1)
                                    .toInt();
                                if (documentPage == _currentPageIndex ||
                                    !mounted) {
                                  return;
                                }
                                setState(() {
                                  _currentPageIndex = documentPage;
                                });
                                _scheduleViewStateSave();
                              },
                            ),
                          ),
                        ),
                      if (!_showNativePdfReader && !_usePdfrxViewer)
                        ColoredBox(
                          color: workspaceColor,
                          child: LayoutBuilder(
                            builder: (context, viewportConstraints) {
                              _pageViewportWidth = viewportConstraints.maxWidth;
                              _pageViewportHeight =
                                  viewportConstraints.maxHeight;

                              Widget buildPage(
                                int pageIndex, {
                                Size? pageViewport,
                                double contentScale = 1.0,
                              }) {
                                final isCurrent =
                                    pageIndex == _currentPageIndex;
                                final effectiveViewport =
                                    pageViewport ??
                                    Size(
                                      viewportConstraints.maxWidth,
                                      viewportConstraints.maxHeight,
                                    );

                                Widget buildPaper() {
                                  final paperWidth = effectiveViewport.width;
                                  final paperHeight =
                                      paperWidth * _pageAspectRatio(pageIndex);
                                  return Align(
                                    alignment: Alignment.center,
                                    child: SizedBox(
                                      width: paperWidth,
                                      height: paperHeight,
                                      child: ColoredBox(
                                        color: Colors.white,
                                        child: LayoutBuilder(
                                          builder: (context, constraints) {
                                            final size = Size(
                                              constraints.maxWidth,
                                              constraints.maxHeight,
                                            );
                                            final canvas = RepaintBoundary(
                                              key: isCurrent
                                                  ? _canvasKey
                                                  : null,
                                              child: ColoredBox(
                                                color: Colors.white,
                                                child: Stack(
                                                  fit: StackFit.expand,
                                                  children: [
                                                    if (pageIndex <
                                                            _pagePdfPaths
                                                                .length &&
                                                        _pagePdfPaths[pageIndex] !=
                                                            null &&
                                                        pageIndex <
                                                            _pagePdfPageNumbers
                                                                .length &&
                                                        _pagePdfPageNumbers[pageIndex] !=
                                                            null)
                                                      if (isCurrent &&
                                                          !_verticalPageMode &&
                                                          defaultTargetPlatform ==
                                                              TargetPlatform
                                                                  .iOS)
                                                        // Current page, single-page view mode,
                                                        // iOS: swap the raster fallback for a
                                                        // native PDFView resized to match the
                                                        // current zoom bucket. The 1/bucket scale
                                                        // cancels the resize locally (visual
                                                        // footprint stays paperWidth, matching
                                                        // every other layer here), so
                                                        // InteractiveViewer's own live zoom still
                                                        // applies exactly once on top — this only
                                                        // changes what resolution PDFKit renders
                                                        // at, not alignment.
                                                        Align(
                                                          alignment:
                                                              Alignment.topLeft,
                                                          child: Transform.scale(
                                                            scale:
                                                                1 /
                                                                _pdfRenderScaleBucket,
                                                            alignment: Alignment
                                                                .topLeft,
                                                            child: SizedBox(
                                                              width:
                                                                  paperWidth *
                                                                  _pdfRenderScaleBucket,
                                                              height:
                                                                  paperHeight *
                                                                  _pdfRenderScaleBucket,
                                                              child: NativePdfPageDisplay(
                                                                key: ValueKey(
                                                                  'native-${_pagePdfPaths[pageIndex]}#${_pagePdfPageNumbers[pageIndex]}',
                                                                ),
                                                                path:
                                                                    _pagePdfPaths[pageIndex]!,
                                                                pageNumber:
                                                                    _pagePdfPageNumbers[pageIndex]!,
                                                              ),
                                                            ),
                                                          ),
                                                        )
                                                      else
                                                        AdaptivePdfPage(
                                                          key: ValueKey(
                                                            '${_pagePdfPaths[pageIndex]}#${_pagePdfPageNumbers[pageIndex]}',
                                                          ),
                                                          pdfPath:
                                                              _pagePdfPaths[pageIndex]!,
                                                          pageNumber:
                                                              _pagePdfPageNumbers[pageIndex]!,
                                                          enabled:
                                                              (pageIndex -
                                                                      _currentPageIndex)
                                                                  .abs() <=
                                                              4,
                                                          // The Flutter drawing fallback keeps one
                                                          // stable raster size for every nearby page.
                                                          // It never changes page geometry or swaps a
                                                          // page to a smaller preview when focus moves.
                                                          quality: 1,
                                                          renderScale:
                                                              _pdfRenderScaleBucket,
                                                        )
                                                    else if (_pageBackgrounds[pageIndex] !=
                                                        null)
                                                      Image.file(
                                                        File(
                                                          _pageBackgrounds[pageIndex]!,
                                                        ),
                                                        fit: BoxFit.contain,
                                                        errorBuilder:
                                                            (_, _, _) =>
                                                                const SizedBox(),
                                                      ),
                                                    CustomPaint(
                                                      key: ValueKey(
                                                        'ink-canvas-$pageIndex',
                                                      ),
                                                      painter: InkPainter(
                                                        strokes:
                                                            _pages[pageIndex],
                                                        activeStroke: isCurrent
                                                            ? _activeStroke
                                                            : null,
                                                        lassoPath: isCurrent
                                                            ? _lassoPath
                                                            : const <
                                                                InkPoint
                                                              >[],
                                                        selectionPath: isCurrent
                                                            ? _selectionLassoPath
                                                            : const <
                                                                InkPoint
                                                              >[],
                                                        template: widget
                                                            .document
                                                            .backgroundTemplate,
                                                        contentScale:
                                                            contentScale,
                                                        selectionOverlayScale:
                                                            selectionOverlayScaleForCanvas(
                                                              canvasToScreenScale:
                                                                  _selectionCanvasToScreenScale,
                                                              contentScale:
                                                                  contentScale,
                                                            ),
                                                        eraserCursor:
                                                            isCurrent &&
                                                                _temporaryEraser
                                                            ? _eraserCursor
                                                            : null,
                                                        eraserDiameter:
                                                            _eraserCanvasDiameter,
                                                        eraserBorderWidth:
                                                            _eraserGeometry
                                                                .canvasBorderWidth,
                                                        images: _decodedImages,
                                                      ),
                                                      size: Size.infinite,
                                                    ),
                                                  ],
                                                ),
                                              ),
                                            );

                                            return _protectStylusDrawingFromViewportPan(
                                              Listener(
                                                behavior:
                                                    HitTestBehavior.opaque,
                                                onPointerDown: (event) {
                                                  _activatePageForInput(
                                                    pageIndex,
                                                  );
                                                  _pointerDown(event, size);
                                                },
                                                onPointerMove: (event) =>
                                                    _pointerMove(event, size),
                                                onPointerUp: (event) =>
                                                    _pointerUp(event, size),
                                                onPointerCancel: (event) =>
                                                    _pointerUp(event, size),
                                                child: canvas,
                                              ),
                                            );
                                          },
                                        ),
                                      ),
                                    ),
                                  );
                                }

                                if (_verticalPageMode) {
                                  // Keep each page gesture-neutral so the parent ListView
                                  // receives one-finger vertical drags like a blog feed.
                                  return buildPaper();
                                }

                                return InteractiveViewer(
                                  transformationController: isCurrent
                                      ? _transformationController
                                      : null,
                                  minScale: .1,
                                  maxScale: 6,
                                  boundaryMargin: EdgeInsets.symmetric(
                                    horizontal: viewportConstraints.maxWidth,
                                    vertical: viewportConstraints.maxHeight,
                                  ),
                                  clipBehavior: Clip.hardEdge,
                                  constrained: false,
                                  // Keep the transformation origin at the viewport's
                                  // top-left. The custom focal-point calculation then
                                  // uses the same coordinate space as the controller,
                                  // so pinching no longer drifts toward the page top.
                                  alignment: Alignment.topLeft,
                                  panEnabled: isCurrent,
                                  panAxis: PanAxis.free,
                                  scaleEnabled: isCurrent,
                                  trackpadScrollCausesScale: true,
                                  onInteractionStart: isCurrent
                                      ? (details) => _beginZoomGesture(
                                          details,
                                          continuous: false,
                                        )
                                      : null,
                                  onInteractionUpdate: isCurrent
                                      ? (details) => _updateZoomGesture(
                                          details,
                                          continuous: false,
                                        )
                                      : null,
                                  onInteractionEnd: isCurrent
                                      ? (_) =>
                                            _endZoomGesture(continuous: false)
                                      : null,
                                  child: buildPaper(),
                                );
                              }

                              if (_verticalPageMode) {
                                final paperWidth = math.max(
                                  1.0,
                                  viewportConstraints.maxWidth,
                                );
                                const pageGap = 8.0;
                                var totalHeight = 0.0;
                                for (
                                  var index = 0;
                                  index < _pages.length;
                                  index++
                                ) {
                                  totalHeight +=
                                      paperWidth * _pageAspectRatio(index);
                                  if (index < _pages.length - 1) {
                                    totalHeight += pageGap;
                                  }
                                }

                                _continuousPaperWidth = paperWidth;
                                _continuousGap = pageGap;
                                _continuousViewportWidth =
                                    viewportConstraints.maxWidth;
                                _continuousViewportHeight =
                                    viewportConstraints.maxHeight;

                                return InteractiveViewer(
                                  transformationController:
                                      _continuousTransformationController,
                                  minScale: .1,
                                  maxScale: 4,
                                  boundaryMargin: EdgeInsets.symmetric(
                                    horizontal: viewportConstraints.maxWidth,
                                    vertical: viewportConstraints.maxHeight,
                                  ),
                                  clipBehavior: Clip.hardEdge,
                                  constrained: false,
                                  // A top-left transform origin keeps controller
                                  // scene coordinates aligned with the pinch focal
                                  // point. The larger margin also prevents Flutter
                                  // from clamping the page upward while zooming out.
                                  alignment: Alignment.topLeft,
                                  // Touch always navigates with one finger;
                                  // the child gesture barrier keeps Pencil strokes
                                  // from moving the viewport.
                                  panEnabled: true,
                                  panAxis: PanAxis.free,
                                  scaleEnabled: true,
                                  trackpadScrollCausesScale: true,
                                  interactionEndFrictionCoefficient: .00008,
                                  onInteractionStart: (details) =>
                                      _beginZoomGesture(
                                        details,
                                        continuous: true,
                                      ),
                                  onInteractionUpdate: (details) =>
                                      _updateZoomGesture(
                                        details,
                                        continuous: true,
                                      ),
                                  onInteractionEnd: (_) =>
                                      _endZoomGesture(continuous: true),
                                  child: SizedBox(
                                    width: paperWidth,
                                    height: totalHeight,
                                    child: Column(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        for (
                                          var index = 0;
                                          index < _pages.length;
                                          index++
                                        ) ...[
                                          SizedBox(
                                            width: paperWidth,
                                            height:
                                                paperWidth *
                                                _pageAspectRatio(index),
                                            child: buildPage(
                                              index,
                                              pageViewport: Size(
                                                paperWidth,
                                                paperWidth *
                                                    _pageAspectRatio(index),
                                              ),
                                            ),
                                          ),
                                          if (index < _pages.length - 1)
                                            const SizedBox(height: pageGap),
                                        ],
                                      ],
                                    ),
                                  ),
                                );
                              }

                              _continuousPaperWidth = 0;
                              _continuousGap = 8;
                              _continuousViewportWidth = 0;
                              _continuousViewportHeight = 0;
                              return buildPage(_currentPageIndex);
                            },
                          ),
                        ),
                      if (wide)
                        Positioned(
                          top: 8,
                          left: 8,
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              DecoratedBox(
                                decoration: BoxDecoration(
                                  color: scheme.surface.withValues(alpha: .96),
                                  borderRadius: BorderRadius.circular(18),
                                  border: Border.all(
                                    color: Theme.of(context).dividerColor,
                                  ),
                                  boxShadow: [
                                    BoxShadow(
                                      color: Colors.black.withValues(
                                        alpha: .06,
                                      ),
                                      blurRadius: 12,
                                      offset: const Offset(0, 4),
                                    ),
                                  ],
                                ),
                                child: SizedBox(
                                  height: 42,
                                  child: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      IconButton(
                                        tooltip: _pagesPanelCollapsed
                                            ? 'Open pages'
                                            : 'Hide pages',
                                        onPressed: () => setState(
                                          () => _pagesPanelCollapsed =
                                              !_pagesPanelCollapsed,
                                        ),
                                        icon: Icon(
                                          _pagesPanelCollapsed
                                              ? Icons.view_sidebar_outlined
                                              : Icons.view_sidebar_rounded,
                                        ),
                                      ),
                                      const SizedBox(width: 2),
                                      IconButton(
                                        tooltip: 'Undo',
                                        onPressed: _canUndoCurrent
                                            ? _undoCurrentAction
                                            : null,
                                        icon: const Icon(Icons.undo_rounded),
                                      ),
                                      IconButton(
                                        tooltip: 'Redo',
                                        onPressed: _canRedoCurrent
                                            ? _redoCurrentAction
                                            : null,
                                        icon: const Icon(Icons.redo_rounded),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                              if (!_pagesPanelCollapsed) ...[
                                const SizedBox(height: 10),
                                SizedBox(
                                  width: 212,
                                  height: math.min(
                                    MediaQuery.sizeOf(context).height - 150,
                                    360.0,
                                  ),
                                  child: Material(
                                    color: Colors.transparent,
                                    elevation: 0,
                                    child: ClipRRect(
                                      borderRadius: BorderRadius.circular(18),
                                      child: PageStrip(
                                        pages: _pages,
                                        pageBackgrounds: _pageBackgrounds,
                                        pageAspectRatios: _pageAspectRatios,
                                        pagePdfPaths: _pagePdfPaths,
                                        pagePdfPageNumbers: _pagePdfPageNumbers,
                                        currentPageIndex: _currentPageIndex,
                                        onSelectPage: _selectPage,
                                        onAddPage: () => unawaited(_addPage()),
                                        collapsed: false,
                                        onToggleCollapsed: () => setState(
                                          () => _pagesPanelCollapsed = true,
                                        ),
                                        images: _decodedImages,
                                      ),
                                    ),
                                  ),
                                ),
                              ],
                            ],
                          ),
                        ),

                      Positioned.fill(
                        child: DockableEditorToolbars(
                          primary: ToolbarPlacement(
                            dock: _primaryToolbarDock,
                            order: _primaryToolbarOrder,
                          ),
                          options: ToolbarPlacement(
                            dock: _optionsToolbarDock,
                            order: _optionsToolbarOrder,
                          ),
                          reservedInsets: EdgeInsets.only(
                            bottom: wide ? 0 : 54,
                          ),
                          primaryBuilder: (context, axis, dragCallbacks) =>
                              _buildFloatingToolbar(
                                section: FloatingToolbarSection.primary,
                                axis: axis,
                                dragCallbacks: dragCallbacks,
                              ),
                          optionsBuilder: (context, axis, dragCallbacks) =>
                              _buildFloatingToolbar(
                                section: FloatingToolbarSection.options,
                                axis: axis,
                                dragCallbacks: dragCallbacks,
                              ),
                          onChanged: _applyToolbarDocking,
                        ),
                      ),
                      if ((_tool == InkTool.lasso || _tool == InkTool.text) &&
                          _hasSelection &&
                          !_draggingSelection)
                        Positioned.fill(
                          child: AnimatedBuilder(
                            animation: Listenable.merge([
                              _transformationController,
                              _continuousTransformationController,
                              _pdfrxController,
                            ]),
                            builder: (context, _) => LayoutBuilder(
                              builder: (context, _) {
                                final selectionBounds =
                                    _selectionBoundsInViewport();
                                if (selectionBounds == null) {
                                  return const SizedBox.shrink();
                                }
                                return CustomSingleChildLayout(
                                  delegate: SelectionToolbarLayoutDelegate(
                                    anchor: selectionBounds,
                                    leftInset: _toolbarDepthAt(
                                      ToolbarDock.left,
                                    ),
                                    rightInset: _toolbarDepthAt(
                                      ToolbarDock.right,
                                    ),
                                    topInset: _toolbarDepthAt(ToolbarDock.top),
                                    bottomMargin:
                                        (wide ? 8 : 58) +
                                        _toolbarDepthAt(ToolbarDock.bottom),
                                  ),
                                  // Fades in rather than popping back after
                                  // a drag, since the toolbar is removed
                                  // from the tree while dragging.
                                  child: TweenAnimationBuilder<double>(
                                    key: const ValueKey(
                                      'selection-actions-fade',
                                    ),
                                    tween: Tween<double>(begin: 0, end: 1),
                                    duration: const Duration(
                                      milliseconds: 120,
                                    ),
                                    builder: (context, value, child) =>
                                        Opacity(opacity: value, child: child),
                                    child: _SelectionActions(
                                      hasSelection: true,
                                      canPaste:
                                          _selectionClipboard.isNotEmpty,
                                      onCut: _cutSelection,
                                      onCopy: _copySelection,
                                      onPaste: _pasteSelection,
                                      onRemove: _removeSelection,
                                      onSendToBack: _sendSelectionToBack,
                                      onBringToFront: _bringSelectionToFront,
                                      showEdit:
                                          _tool == InkTool.text &&
                                          _currentObjects.any(
                                            (object) =>
                                                object is InkText &&
                                                object.isSelected,
                                          ),
                                      onEdit: () =>
                                          unawaited(_editSelectedText()),
                                      onColorPicker: _chooseSelectionColor,
                                    ),
                                  ),
                                );
                              },
                            ),
                          ),
                        ),
                      if (!wide)
                        Positioned(
                          left: 0,
                          right: 0,
                          bottom: 0,
                          child: CompactPageBar(
                            pageCount: _pages.length,
                            currentPageIndex: _currentPageIndex,
                            onPrevious: _currentPageIndex > 0
                                ? () => _selectPage(_currentPageIndex - 1)
                                : null,
                            onNext: _currentPageIndex < _pages.length - 1
                                ? () => _selectPage(_currentPageIndex + 1)
                                : null,
                            onAddPage: () => unawaited(_addPage()),
                            collapsed: _pagesPanelCollapsed,
                            onToggleCollapsed: () => setState(
                              () =>
                                  _pagesPanelCollapsed = !_pagesPanelCollapsed,
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _ConditionalEagerGestureRecognizer extends OneSequenceGestureRecognizer {
  _ConditionalEagerGestureRecognizer({
    required this.shouldAccept,
    super.supportedDevices,
  });

  bool Function(PointerDownEvent event) shouldAccept;

  @override
  void addAllowedPointer(PointerDownEvent event) {
    if (!shouldAccept(event)) {
      resolve(GestureDisposition.rejected);
      return;
    }
    startTrackingPointer(event.pointer, event.transform);
    resolve(GestureDisposition.accepted);
  }

  @override
  void handleEvent(PointerEvent event) {
    if (event is PointerUpEvent || event is PointerCancelEvent) {
      stopTrackingPointer(event.pointer);
    }
  }

  @override
  void didStopTrackingLastPointer(int pointer) {}

  @override
  String get debugDescription => 'conditional eager';
}

class _PaletteColorButton extends StatelessWidget {
  const _PaletteColorButton({
    required this.color,
    required this.selected,
    required this.onTap,
    this.onLongPress,
  });

  final Color color;
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return GestureDetector(
      onTap: onTap,
      onLongPress: onLongPress,
      child: Container(
        decoration: BoxDecoration(
          color: color,
          shape: BoxShape.circle,
          border: Border.all(
            color: selected ? scheme.primary : scheme.outlineVariant,
            width: selected ? 4 : 1,
          ),
          boxShadow: selected
              ? [
                  BoxShadow(
                    color: scheme.primary.withValues(alpha: .22),
                    blurRadius: 10,
                    spreadRadius: 2,
                  ),
                ]
              : null,
        ),
        child: selected
            ? Icon(
                Icons.check_rounded,
                color:
                    ThemeData.estimateBrightnessForColor(color) ==
                        Brightness.dark
                    ? Colors.white
                    : Colors.black,
              )
            : null,
      ),
    );
  }
}

class _AddColorButton extends StatelessWidget {
  const _AddColorButton({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      customBorder: const CircleBorder(),
      child: Container(
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          border: Border.all(
            color: Theme.of(context).colorScheme.outline,
            width: 2,
          ),
        ),
        child: const Icon(Icons.add_rounded),
      ),
    );
  }
}

class _ColorGridField extends StatelessWidget {
  const _ColorGridField({
    super.key,
    required this.hsv,
    required this.onChanged,
  });

  final HSVColor hsv;
  final ValueChanged<HSVColor> onChanged;

  @override
  Widget build(BuildContext context) {
    const columns = 12;
    const rows = 8;
    return AspectRatio(
      aspectRatio: columns / rows,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(16),
        child: GridView.builder(
          physics: const NeverScrollableScrollPhysics(),
          padding: EdgeInsets.zero,
          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: columns,
            crossAxisSpacing: 1,
            mainAxisSpacing: 1,
          ),
          itemCount: columns * rows,
          itemBuilder: (context, index) {
            final row = index ~/ columns;
            final column = index % columns;
            final Color color;
            if (row == 0) {
              final value = 1 - column / (columns - 1);
              color = HSVColor.fromAHSV(hsv.alpha, 0, 0, value).toColor();
            } else {
              final hue = column * 360 / columns;
              final saturation = .72 + row / (rows - 1) * .28;
              final value = (1.05 - row / (rows - 1) * .72)
                  .clamp(.18, 1.0)
                  .toDouble();
              color = HSVColor.fromAHSV(
                hsv.alpha,
                hue,
                saturation.clamp(0.0, 1.0),
                value,
              ).toColor();
            }
            final selected = _colorDistance(color, hsv.toColor()) < 34;
            return InkWell(
              onTap: () {
                final next = HSVColor.fromColor(color).withAlpha(hsv.alpha);
                onChanged(next);
              },
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: color,
                  border: selected
                      ? Border.all(color: Colors.white, width: 3)
                      : null,
                ),
                child: selected
                    ? const Icon(Icons.check_rounded, size: 16)
                    : null,
              ),
            );
          },
        ),
      ),
    );
  }

  static double _colorDistance(Color a, Color b) {
    final dr = a.r - b.r;
    final dg = a.g - b.g;
    final db = a.b - b.b;
    return math.sqrt(dr * dr + dg * dg + db * db) * 255;
  }
}

class _ColorSpectrumField extends StatelessWidget {
  const _ColorSpectrumField({required this.hsv, required this.onChanged});

  final HSVColor hsv;
  final ValueChanged<HSVColor> onChanged;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final size = Size(constraints.maxWidth, constraints.maxHeight);
        return RawGestureDetector(
          behavior: HitTestBehavior.opaque,
          gestures: <Type, GestureRecognizerFactory>{
            EagerGestureRecognizer:
                GestureRecognizerFactoryWithHandlers<EagerGestureRecognizer>(
                  () => EagerGestureRecognizer(),
                  (_) {},
                ),
          },
          child: Listener(
            behavior: HitTestBehavior.opaque,
            onPointerDown: (event) => _update(event.localPosition, size),
            onPointerMove: (event) => _update(event.localPosition, size),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(16),
              child: CustomPaint(
                painter: _ColorSpectrumPainter(hsv),
                size: Size.infinite,
              ),
            ),
          ),
        );
      },
    );
  }

  void _update(Offset position, Size size) {
    if (size.width <= 0 || size.height <= 0) return;
    final x = (position.dx / size.width).clamp(0.0, 1.0);
    final y = (position.dy / size.height).clamp(0.0, 1.0);
    onChanged(
      HSVColor.fromAHSV(hsv.alpha, x * 360, 1, (1 - y * .92).clamp(.08, 1.0)),
    );
  }
}

class _ColorSpectrumPainter extends CustomPainter {
  const _ColorSpectrumPainter(this.hsv);

  final HSVColor hsv;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final huePaint = Paint()
      ..shader = const LinearGradient(
        colors: [
          Colors.red,
          Colors.yellow,
          Colors.green,
          Colors.cyan,
          Colors.blue,
          Colors.purple,
          Colors.red,
        ],
      ).createShader(rect);
    canvas.drawRect(rect, huePaint);

    final shadePaint = Paint()
      ..shader = const LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [Colors.transparent, Colors.black],
        stops: [0, 1],
      ).createShader(rect);
    canvas.drawRect(rect, shadePaint);

    final selector = Offset(
      (hsv.hue / 360).clamp(0.0, 1.0) * size.width,
      ((1 - hsv.value) / .92).clamp(0.0, 1.0) * size.height,
    );
    canvas.drawCircle(selector, 12, Paint()..color = hsv.toColor());
    canvas.drawCircle(
      selector,
      14,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3
        ..color = Colors.white,
    );
    canvas.drawCircle(
      selector,
      16,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5
        ..color = Colors.black54,
    );
  }

  @override
  bool shouldRepaint(covariant _ColorSpectrumPainter oldDelegate) =>
      oldDelegate.hsv != hsv;
}

class _SelectionActions extends StatelessWidget {
  const _SelectionActions({
    required this.hasSelection,
    required this.canPaste,
    required this.onCut,
    required this.onCopy,
    required this.onPaste,
    required this.onRemove,
    required this.showEdit,
    required this.onEdit,
    required this.onColorPicker,
    required this.onSendToBack,
    required this.onBringToFront,
  });

  final bool hasSelection;
  final bool canPaste;
  final VoidCallback onCut;
  final VoidCallback onCopy;
  final VoidCallback onPaste;
  final VoidCallback onRemove;
  final bool showEdit;
  final VoidCallback onEdit;
  final VoidCallback onColorPicker;
  final VoidCallback onSendToBack;
  final VoidCallback onBringToFront;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return IconButtonTheme(
      data: IconButtonThemeData(
        style: IconButton.styleFrom(
          minimumSize: const Size(38, 38),
          maximumSize: const Size(38, 38),
          padding: EdgeInsets.zero,
          iconSize: 20,
        ),
      ),
      child: Material(
        key: const ValueKey('selection-actions-toolbar'),
        elevation: 10,
        color: scheme.surface.withValues(alpha: .98),
        clipBehavior: Clip.antiAlias,
        shape: StadiumBorder(
          side: BorderSide(color: Theme.of(context).dividerColor),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              IconButton(
                tooltip: 'Change color',
                onPressed: hasSelection ? onColorPicker : null,
                icon: const Icon(Icons.colorize_rounded),
              ),
              if (showEdit)
                IconButton(
                  tooltip: 'Edit text',
                  onPressed: hasSelection ? onEdit : null,
                  icon: const Icon(Icons.edit_note_rounded),
                ),
              IconButton(
                tooltip: 'Send to back',
                onPressed: hasSelection ? onSendToBack : null,
                icon: const Icon(Icons.flip_to_back_rounded),
              ),
              IconButton(
                tooltip: 'Bring to front',
                onPressed: hasSelection ? onBringToFront : null,
                icon: const Icon(Icons.flip_to_front_rounded),
              ),
              IconButton(
                tooltip: 'Cut',
                onPressed: hasSelection ? onCut : null,
                icon: const Icon(Icons.content_cut_rounded),
              ),
              IconButton(
                tooltip: 'Copy',
                onPressed: hasSelection ? onCopy : null,
                icon: const Icon(Icons.copy_rounded),
              ),
              if (canPaste)
                IconButton(
                  tooltip: 'Paste',
                  onPressed: onPaste,
                  icon: const Icon(Icons.content_paste_rounded),
                ),
              IconButton(
                tooltip: 'Delete',
                onPressed: hasSelection ? onRemove : null,
                style: IconButton.styleFrom(foregroundColor: scheme.error),
                icon: const Icon(Icons.delete_outline_rounded),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _TextBoxEditResult {
  const _TextBoxEditResult({
    required this.text,
    required this.width,
    this.delete = false,
  });

  final String text;
  final double width;
  final bool delete;
}

class _PenPreviewPainter extends CustomPainter {
  const _PenPreviewPainter({required this.color, required this.width});

  final Color color;
  final double width;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..strokeWidth = width;
    final path = Path()
      ..moveTo(size.width * .1, size.height * .62)
      ..cubicTo(
        size.width * .28,
        size.height * .88,
        size.width * .52,
        size.height * .2,
        size.width * .85,
        size.height * .58,
      );
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(covariant _PenPreviewPainter oldDelegate) =>
      oldDelegate.color != color || oldDelegate.width != width;
}

class _SettingModeChip extends StatelessWidget {
  const _SettingModeChip({
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
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(13),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 140),
        padding: const EdgeInsets.symmetric(horizontal: 3, vertical: 8),
        decoration: BoxDecoration(
          color: selected ? scheme.primaryContainer : Colors.transparent,
          borderRadius: BorderRadius.circular(13),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              icon,
              size: 20,
              color: selected ? scheme.primary : scheme.onSurfaceVariant,
            ),
            const SizedBox(height: 4),
            Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 10.5,
                fontWeight: selected ? FontWeight.w800 : FontWeight.w600,
                color: selected ? scheme.primary : scheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SettingSection extends StatelessWidget {
  const _SettingSection({
    required this.title,
    required this.trailing,
    required this.child,
  });

  final String title;
  final Widget trailing;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 10),
      decoration: BoxDecoration(
        color: Theme.of(
          context,
        ).colorScheme.surfaceContainerHighest.withValues(alpha: .35),
        borderRadius: BorderRadius.circular(22),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  title.toUpperCase(),
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
              ),
              trailing,
            ],
          ),
          child,
        ],
      ),
    );
  }
}

class _PenWidthChoice extends StatelessWidget {
  const _PenWidthChoice({
    required this.width,
    required this.selected,
    required this.onTap,
  });

  final double width;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final dotSize = (width * 1.45 + 3).clamp(6.0, 18.0).toDouble();
    final label = width == width.roundToDouble()
        ? width.toStringAsFixed(0)
        : width.toStringAsFixed(1);
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 140),
        width: 48,
        height: 46,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: selected
              ? scheme.primaryContainer
              : scheme.surfaceContainerHighest.withValues(alpha: .4),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: selected ? scheme.primary : Colors.transparent,
          ),
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              width: dotSize,
              height: dotSize,
              decoration: BoxDecoration(
                color: scheme.onSurface,
                shape: BoxShape.circle,
              ),
            ),
            const SizedBox(height: 3),
            Text(
              label,
              style: TextStyle(
                fontSize: 10,
                fontWeight: FontWeight.w700,
                color: selected ? scheme.primary : scheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _FloatingColorButton extends StatelessWidget {
  const _FloatingColorButton({
    required this.color,
    required this.selected,
    required this.onTap,
  });

  final Color color;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return InkWell(
      onTap: onTap,
      customBorder: const CircleBorder(),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 140),
        width: 31,
        height: 31,
        padding: const EdgeInsets.all(3),
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: selected ? scheme.primaryContainer : Colors.transparent,
          border: Border.all(
            color: selected ? scheme.primary : scheme.outlineVariant,
            width: selected ? 2 : 1,
          ),
        ),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: color,
            shape: BoxShape.circle,
            border: Border.all(
              color: color.computeLuminance() > .88
                  ? scheme.outlineVariant
                  : Colors.transparent,
            ),
          ),
        ),
      ),
    );
  }
}

class _MobileEditorHeader extends StatelessWidget {
  const _MobileEditorHeader({
    required this.title,
    required this.onBack,
    required this.onShare,
    required this.onImportPdf,
    required this.verticalPageMode,
    required this.onTogglePageMode,
  });

  final String title;
  final VoidCallback onBack;
  final VoidCallback onShare;
  final VoidCallback onImportPdf;
  final bool verticalPageMode;
  final VoidCallback onTogglePageMode;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      bottom: false,
      child: Container(
        height: 50,
        decoration: BoxDecoration(
          color: const Color(0xFF2F5EA7),
          border: Border(
            bottom: BorderSide(color: Theme.of(context).dividerColor),
          ),
        ),
        child: Row(
          children: [
            IconButton(
              tooltip: 'Back to notes',
              onPressed: onBack,
              color: Colors.white,
              icon: const BackButtonIcon(),
            ),
            Expanded(
              child: Text(
                title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 17,
                  fontWeight: FontWeight.w800,
                  color: Colors.white,
                ),
              ),
            ),
            IconButton(
              tooltip: verticalPageMode
                  ? 'Switch to page-by-page mode'
                  : 'Switch to continuous page scroll',
              onPressed: onTogglePageMode,
              color: Colors.white,
              icon: Icon(
                verticalPageMode
                    ? Icons.view_agenda_rounded
                    : Icons.filter_none_rounded,
              ),
            ),
            IconButton(
              tooltip: 'Import PDF',
              onPressed: onImportPdf,
              color: Colors.white,
              icon: const Icon(Icons.picture_as_pdf_outlined),
            ),
            IconButton(
              tooltip: 'Share page',
              onPressed: onShare,
              color: Colors.white,
              icon: const Icon(Icons.share_outlined),
            ),
            const SizedBox(width: 4),
          ],
        ),
      ),
    );
  }
}

class _DesktopEditorHeader extends StatelessWidget {
  const _DesktopEditorHeader({
    required this.documents,
    required this.activeId,
    required this.onSelect,
    required this.onClose,
    required this.onNewTab,
    required this.onHome,
    required this.onShare,
    required this.onImportPdf,
    required this.verticalPageMode,
    required this.onTogglePageMode,
  });

  final List<InkDocument> documents;
  final String activeId;
  final ValueChanged<String> onSelect;
  final ValueChanged<String> onClose;
  final VoidCallback onNewTab;
  final VoidCallback onHome;
  final VoidCallback onShare;
  final VoidCallback onImportPdf;
  final bool verticalPageMode;
  final VoidCallback onTogglePageMode;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      bottom: false,
      child: Container(
        height: 50,
        decoration: BoxDecoration(
          color: const Color(0xFF2F5EA7),
          border: Border(
            bottom: BorderSide(color: Theme.of(context).dividerColor),
          ),
        ),
        child: Row(
          children: [
            IconButton(
              tooltip: 'Back to notes',
              onPressed: onHome,
              color: Colors.white,
              icon: const BackButtonIcon(),
            ),
            Expanded(
              child: _DocumentTabStrip(
                documents: documents,
                activeId: activeId,
                onSelect: onSelect,
                onClose: onClose,
                onNewTab: onNewTab,
              ),
            ),
            IconButton(
              tooltip: verticalPageMode
                  ? 'Switch to page-by-page mode'
                  : 'Switch to continuous page scroll',
              onPressed: onTogglePageMode,
              color: Colors.white,
              icon: Icon(
                verticalPageMode
                    ? Icons.view_agenda_rounded
                    : Icons.filter_none_rounded,
              ),
            ),
            IconButton(
              tooltip: 'Import PDF',
              onPressed: onImportPdf,
              color: Colors.white,
              icon: const Icon(Icons.picture_as_pdf_outlined),
            ),
            IconButton(
              tooltip: 'Share page',
              onPressed: onShare,
              color: Colors.white,
              icon: const Icon(Icons.share_outlined),
            ),
            const SizedBox(width: 6),
          ],
        ),
      ),
    );
  }
}

class _DocumentTabStrip extends StatelessWidget {
  const _DocumentTabStrip({
    required this.documents,
    required this.activeId,
    required this.onSelect,
    required this.onClose,
    required this.onNewTab,
  });

  final List<InkDocument> documents;
  final String activeId;
  final ValueChanged<String> onSelect;
  final ValueChanged<String> onClose;
  final VoidCallback onNewTab;

  @override
  Widget build(BuildContext context) {
    return ListView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 5),
      children: [
        for (final document in documents)
          Padding(
            padding: const EdgeInsets.only(right: 4),
            child: Material(
              color: document.id == activeId
                  ? const Color(0xFF3E6CB8)
                  : const Color(0xFF2B4F8B),
              borderRadius: BorderRadius.circular(10),
              child: InkWell(
                onTap: () => onSelect(document.id),
                borderRadius: BorderRadius.circular(10),
                child: Padding(
                  padding: const EdgeInsets.only(left: 9),
                  child: Row(
                    children: [
                      Icon(
                        Icons.description_outlined,
                        size: 15,
                        color: Colors.white.withValues(
                          alpha: document.id == activeId ? 1 : .85,
                        ),
                      ),
                      const SizedBox(width: 5),
                      ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 125),
                        child: Text(
                          document.title,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 14,
                            fontWeight: document.id == activeId
                                ? FontWeight.w800
                                : FontWeight.w600,
                          ),
                        ),
                      ),
                      IconButton(
                        visualDensity: VisualDensity.compact,
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints.tightFor(
                          width: 32,
                          height: 32,
                        ),
                        tooltip: 'Close tab',
                        onPressed: () => onClose(document.id),
                        icon: const Icon(
                          Icons.close_rounded,
                          size: 15,
                          color: Colors.white,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        IconButton(
          tooltip: 'Open a new note',
          onPressed: onNewTab,
          color: Colors.white,
          icon: const Icon(Icons.add_rounded),
        ),
      ],
    );
  }
}
