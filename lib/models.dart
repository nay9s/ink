import 'package:flutter/material.dart';

enum InkTool {
  pen,
  fountainPen,
  brushPen,
  highlighter,
  eraser,
  lasso,
  shape,
  text,
  image,
}

enum EraserMode { precision, stroke }

enum BackgroundTemplate { blank, ruled, grid, dotted, cornell }

enum CoverStyle { solid, spiral, leather, pattern }

enum ThemePreference { system, light, dark }

enum ToolbarDock { top, left, right, bottom }

class InkPoint {
  const InkPoint(this.x, this.y, this.pressure);

  final double x;
  final double y;
  final double pressure;

  Map<String, Object> toJson() => {'x': x, 'y': y, 'p': pressure};

  factory InkPoint.fromJson(Map<String, dynamic> value) => InkPoint(
    (value['x'] as num).toDouble(),
    (value['y'] as num).toDouble(),
    (value['p'] as num).toDouble(),
  );
}

abstract class InkObject {
  String get type;
  bool get isSelected;
  InkObject copyWith({bool? isSelected});
  Map<String, Object> toJson();

  static InkObject fromJson(Map<String, dynamic> json) {
    final type = json['type'] as String?;
    if (type == null || type == 'stroke') return InkStroke.fromJson(json);

    switch (type) {
      case 'text':
        return InkText.fromJson(json);
      case 'image':
        return InkImage.fromJson(json);
      default:
        return InkStroke.fromJson(json);
    }
  }
}

class InkText extends InkObject {
  InkText({
    required this.text,
    required this.x,
    required this.y,
    required this.color,
    required this.fontSize,
    this.width = .35,
    this.bold = false,
    this.italic = false,
    this.fontFamily = 'Modern',
    this.textAlign = TextAlign.left,
    this.lineHeight = 1.2,
    this.isSelected = false,
  });

  final String text;
  final double x;
  final double y;
  final Color color;
  final double fontSize;
  final double width;
  final bool bold;
  final bool italic;
  final String fontFamily;
  final TextAlign textAlign;
  final double lineHeight;

  @override
  final bool isSelected;

  @override
  String get type => 'text';

  @override
  InkText copyWith({
    bool? isSelected,
    String? text,
    double? x,
    double? y,
    Color? color,
    double? fontSize,
    double? width,
    bool? bold,
    bool? italic,
    String? fontFamily,
    TextAlign? textAlign,
    double? lineHeight,
  }) {
    return InkText(
      text: text ?? this.text,
      x: x ?? this.x,
      y: y ?? this.y,
      color: color ?? this.color,
      fontSize: fontSize ?? this.fontSize,
      width: width ?? this.width,
      bold: bold ?? this.bold,
      italic: italic ?? this.italic,
      fontFamily: fontFamily ?? this.fontFamily,
      textAlign: textAlign ?? this.textAlign,
      lineHeight: lineHeight ?? this.lineHeight,
      isSelected: isSelected ?? this.isSelected,
    );
  }

  @override
  Map<String, Object> toJson() => {
    'type': type,
    'text': text,
    'x': x,
    'y': y,
    'color': color.toARGB32(),
    'fontSize': fontSize,
    'width': width,
    'bold': bold,
    'italic': italic,
    'fontFamily': fontFamily,
    'textAlign': textAlign.name,
    'lineHeight': lineHeight,
  };

  factory InkText.fromJson(Map<String, dynamic> value) => InkText(
    text: value['text'] as String,
    x: (value['x'] as num).toDouble(),
    y: (value['y'] as num).toDouble(),
    color: Color(value['color'] as int),
    fontSize: (value['fontSize'] as num).toDouble(),
    width: (value['width'] as num?)?.toDouble() ?? .35,
    bold: value['bold'] as bool? ?? false,
    italic: value['italic'] as bool? ?? false,
    fontFamily: value['fontFamily'] as String? ?? 'Modern',
    textAlign: TextAlign.values.byName(value['textAlign'] as String? ?? 'left'),
    lineHeight: (value['lineHeight'] as num?)?.toDouble() ?? 1.2,
  );
}

class InkImage extends InkObject {
  InkImage({
    required this.path,
    required this.x,
    required this.y,
    required this.width,
    required this.height,
    this.isSelected = false,
  });

  final String path;
  final double x;
  final double y;
  final double width;
  final double height;

  @override
  final bool isSelected;

  @override
  String get type => 'image';

  @override
  InkImage copyWith({
    bool? isSelected,
    String? path,
    double? x,
    double? y,
    double? width,
    double? height,
  }) {
    return InkImage(
      path: path ?? this.path,
      x: x ?? this.x,
      y: y ?? this.y,
      width: width ?? this.width,
      height: height ?? this.height,
      isSelected: isSelected ?? this.isSelected,
    );
  }

  @override
  Map<String, Object> toJson() => {
    'type': type,
    'path': path,
    'x': x,
    'y': y,
    'width': width,
    'height': height,
  };

  factory InkImage.fromJson(Map<String, dynamic> value) => InkImage(
    path: value['path'] as String,
    x: (value['x'] as num).toDouble(),
    y: (value['y'] as num).toDouble(),
    width: (value['width'] as num).toDouble(),
    height: (value['height'] as num).toDouble(),
  );
}

class InkStroke extends InkObject {
  InkStroke({
    required this.tool,
    required this.color,
    required this.width,
    required this.points,
    this.dashed = false,
    this.pressureSensitivity = .7,
    this.isSelected = false,
  });

  final InkTool tool;
  final Color color;
  final double width;
  final List<InkPoint> points;
  final bool dashed;
  final double pressureSensitivity;

  @override
  final bool isSelected;

  @override
  String get type => 'stroke';

  @override
  InkStroke copyWith({
    bool? isSelected,
    InkTool? tool,
    Color? color,
    double? width,
    List<InkPoint>? points,
    bool? dashed,
    double? pressureSensitivity,
  }) {
    return InkStroke(
      tool: tool ?? this.tool,
      color: color ?? this.color,
      width: width ?? this.width,
      points: points ?? this.points,
      dashed: dashed ?? this.dashed,
      pressureSensitivity: pressureSensitivity ?? this.pressureSensitivity,
      isSelected: isSelected ?? this.isSelected,
    );
  }

  @override
  Map<String, Object> toJson() => {
    'type': type,
    'tool': tool.name,
    'color': color.toARGB32(),
    'width': width,
    'dashed': dashed,
    'pressureSensitivity': pressureSensitivity,
    'points': points.map((point) => point.toJson()).toList(),
  };

  factory InkStroke.fromJson(Map<String, dynamic> value) => InkStroke(
    tool: InkTool.values.byName(value['tool'] as String),
    color: Color(value['color'] as int),
    width: (value['width'] as num).toDouble(),
    dashed: value['dashed'] as bool? ?? false,
    pressureSensitivity:
        (value['pressureSensitivity'] as num?)?.toDouble() ?? .7,
    points: (value['points'] as List)
        .map(
          (point) => InkPoint.fromJson(Map<String, dynamic>.from(point as Map)),
        )
        .toList(),
  );
}

class InkFolder {
  const InkFolder({required this.id, required this.name, this.parentId});

  final String id;
  final String name;
  final String? parentId;

  InkFolder copyWith({
    String? name,
    String? parentId,
    bool clearParent = false,
  }) {
    return InkFolder(
      id: id,
      name: name ?? this.name,
      parentId: clearParent ? null : parentId ?? this.parentId,
    );
  }

  Map<String, Object?> toJson() => {
    'id': id,
    'name': name,
    'parentId': parentId,
  };

  factory InkFolder.fromJson(Map<String, dynamic> value) => InkFolder(
    id: value['id'] as String,
    name: value['name'] as String,
    parentId: value['parentId'] as String?,
  );
}

class InkDocument {
  InkDocument({
    required this.id,
    required this.title,
    required this.colorValue,
    required this.createdAt,
    required this.updatedAt,
    required this.pages,
    List<String?>? pageBackgrounds,
    List<double?>? pageAspectRatios,
    List<String?>? pagePdfPaths,
    List<int?>? pagePdfPageNumbers,
    this.folderId,
    this.isFavorite = false,
    this.iconKey = 'description',
    this.coverStyle = CoverStyle.solid,
    this.backgroundTemplate = BackgroundTemplate.blank,
    this.requiresNaming = false,
  }) : pageBackgrounds =
           pageBackgrounds ??
           List<String?>.filled(pages.length, null, growable: true),
       pageAspectRatios =
           pageAspectRatios ??
           List<double?>.filled(pages.length, null, growable: true),
       pagePdfPaths =
           pagePdfPaths ??
           List<String?>.filled(pages.length, null, growable: true),
       pagePdfPageNumbers =
           pagePdfPageNumbers ??
           List<int?>.filled(pages.length, null, growable: true);

  final String id;
  final String title;
  final int colorValue;
  final DateTime createdAt;
  final DateTime updatedAt;
  final List<List<InkObject>> pages;
  final List<String?> pageBackgrounds;
  final List<double?> pageAspectRatios;
  final List<String?> pagePdfPaths;
  final List<int?> pagePdfPageNumbers;
  final String? folderId;
  final bool isFavorite;
  final String iconKey;
  final CoverStyle coverStyle;
  final BackgroundTemplate backgroundTemplate;
  final bool requiresNaming;

  InkDocument copyWith({
    String? title,
    int? colorValue,
    DateTime? createdAt,
    DateTime? updatedAt,
    List<List<InkObject>>? pages,
    List<String?>? pageBackgrounds,
    List<double?>? pageAspectRatios,
    List<String?>? pagePdfPaths,
    List<int?>? pagePdfPageNumbers,
    String? folderId,
    bool clearFolder = false,
    bool? isFavorite,
    String? iconKey,
    CoverStyle? coverStyle,
    BackgroundTemplate? backgroundTemplate,
    bool? requiresNaming,
  }) {
    return InkDocument(
      id: id,
      title: title ?? this.title,
      colorValue: colorValue ?? this.colorValue,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      pages: pages ?? this.pages,
      pageBackgrounds: pageBackgrounds ?? this.pageBackgrounds,
      pageAspectRatios: pageAspectRatios ?? this.pageAspectRatios,
      pagePdfPaths: pagePdfPaths ?? this.pagePdfPaths,
      pagePdfPageNumbers: pagePdfPageNumbers ?? this.pagePdfPageNumbers,
      folderId: clearFolder ? null : folderId ?? this.folderId,
      isFavorite: isFavorite ?? this.isFavorite,
      iconKey: iconKey ?? this.iconKey,
      coverStyle: coverStyle ?? this.coverStyle,
      backgroundTemplate: backgroundTemplate ?? this.backgroundTemplate,
      requiresNaming: requiresNaming ?? this.requiresNaming,
    );
  }

  Map<String, Object?> toJson() => {
    'id': id,
    'title': title,
    'color': colorValue,
    'createdAt': createdAt.toIso8601String(),
    'updatedAt': updatedAt.toIso8601String(),
    'pages': pages
        .map((page) => page.map((obj) => obj.toJson()).toList())
        .toList(),
    'pageBackgrounds': pageBackgrounds,
    'pageAspectRatios': pageAspectRatios,
    'pagePdfPaths': pagePdfPaths,
    'pagePdfPageNumbers': pagePdfPageNumbers,
    'folderId': folderId,
    'isFavorite': isFavorite,
    'iconKey': iconKey,
    'coverStyle': coverStyle.name,
    'backgroundTemplate': backgroundTemplate.name,
    'requiresNaming': requiresNaming,
  };

  factory InkDocument.fromJson(Map<String, dynamic> value) {
    List<List<InkObject>> documentPages;
    if (value.containsKey('pages')) {
      documentPages = (value['pages'] as List).map((page) {
        return (page as List).map((obj) {
          return InkObject.fromJson(Map<String, dynamic>.from(obj as Map));
        }).toList();
      }).toList();
    } else if (value.containsKey('strokes')) {
      final oldStrokes = (value['strokes'] as List).map((stroke) {
        return InkObject.fromJson(Map<String, dynamic>.from(stroke as Map));
      }).toList();
      documentPages = [oldStrokes];
    } else {
      documentPages = [[]];
    }

    if (documentPages.isEmpty) documentPages = [[]];
    final updatedAt = DateTime.parse(value['updatedAt'] as String);
    final title = value['title'] as String;

    return InkDocument(
      id: value['id'] as String,
      title: title,
      colorValue: value['color'] as int,
      createdAt: value['createdAt'] is String
          ? DateTime.parse(value['createdAt'] as String)
          : updatedAt,
      updatedAt: updatedAt,
      pages: documentPages,
      pageBackgrounds: value['pageBackgrounds'] is List
          ? (value['pageBackgrounds'] as List)
                .map((item) => item as String?)
                .toList()
          : List<String?>.filled(documentPages.length, null, growable: true),
      pageAspectRatios: value['pageAspectRatios'] is List
          ? (value['pageAspectRatios'] as List)
                .map((item) => item == null ? null : (item as num).toDouble())
                .toList()
          : List<double?>.filled(documentPages.length, null, growable: true),
      pagePdfPaths: value['pagePdfPaths'] is List
          ? (value['pagePdfPaths'] as List)
                .map((item) => item as String?)
                .toList()
          : List<String?>.filled(documentPages.length, null, growable: true),
      pagePdfPageNumbers: value['pagePdfPageNumbers'] is List
          ? (value['pagePdfPageNumbers'] as List)
                .map((item) => item == null ? null : (item as num).toInt())
                .toList()
          : List<int?>.filled(documentPages.length, null, growable: true),
      folderId: value['folderId'] as String?,
      isFavorite: value['isFavorite'] as bool? ?? false,
      iconKey: value['iconKey'] as String? ?? 'description',
      coverStyle: value['coverStyle'] is String
          ? CoverStyle.values.byName(value['coverStyle'] as String)
          : CoverStyle.solid,
      backgroundTemplate: value['backgroundTemplate'] is String
          ? BackgroundTemplate.values.byName(
              value['backgroundTemplate'] as String,
            )
          : BackgroundTemplate.blank,
      requiresNaming:
          value['requiresNaming'] as bool? ??
          RegExp(r'^Document \d+$').hasMatch(title),
    );
  }
}

class PenPreset {
  const PenPreset({required this.size, required this.smoothing});

  final double size;
  final double smoothing;

  bool matches(double otherSize, double otherSmoothing) =>
      (size - otherSize).abs() < .01 &&
      (smoothing - otherSmoothing).abs() < .01;

  Map<String, Object> toJson() => {'size': size, 'smoothing': smoothing};

  factory PenPreset.fromJson(Map<String, dynamic> value) => PenPreset(
    size: (value['size'] as num).toDouble(),
    smoothing: (value['smoothing'] as num).toDouble(),
  );
}

class WorkspaceSession {
  const WorkspaceSession({
    this.editorOpen = false,
    this.openDocumentIds = const <String>[],
    this.activeDocumentId,
  });

  final bool editorOpen;
  final List<String> openDocumentIds;
  final String? activeDocumentId;

  Map<String, Object?> toJson() => {
    'editorOpen': editorOpen,
    'openDocumentIds': openDocumentIds,
    'activeDocumentId': activeDocumentId,
  };

  factory WorkspaceSession.fromJson(Map<String, dynamic> value) {
    final ids =
        (value['openDocumentIds'] as List?)?.whereType<String>().toList() ??
        const <String>[];
    return WorkspaceSession(
      editorOpen: value['editorOpen'] as bool? ?? false,
      openDocumentIds: ids,
      activeDocumentId: value['activeDocumentId'] as String?,
    );
  }
}

class EditorViewState {
  const EditorViewState({
    this.currentPageIndex = 0,
    this.tool = InkTool.pen,
    this.colorValue = 0xFF17233C,
    this.highlighterColorValue = 0xFFFFFF73,
    this.width = 2,
    this.highlighterWidth = 14,
    this.smoothing = .45,
    this.pressureSensitivity = .7,
    this.eraserSize = 28,
    this.eraserMode = EraserMode.precision,
    this.eraseHighlighterOnly = false,
    this.eraserAutoDeselect = false,
    this.lastDrawingTool = InkTool.pen,
    this.lastPenTool = InkTool.pen,
    this.zoomMode = false,
    this.verticalPageMode = true,
    this.pagesPanelCollapsed = true,
    this.dashedStroke = false,
    this.textSize = 24,
    this.textBold = false,
    this.textItalic = false,
    this.textAlign = TextAlign.left,
    this.textLineHeight = 1.2,
    this.primaryToolbarDock = ToolbarDock.top,
    this.primaryToolbarOrder = 0,
    this.optionsToolbarDock = ToolbarDock.top,
    this.optionsToolbarOrder = 1,
    this.pageTransform = const <double>[],
    this.continuousTransform = const <double>[],
  });

  final int currentPageIndex;
  final InkTool tool;
  final int colorValue;
  final int highlighterColorValue;
  final double width;
  final double highlighterWidth;
  final double smoothing;
  final double pressureSensitivity;
  final double eraserSize;
  final EraserMode eraserMode;
  final bool eraseHighlighterOnly;
  final bool eraserAutoDeselect;
  final InkTool lastDrawingTool;
  final InkTool lastPenTool;
  final bool zoomMode;
  final bool verticalPageMode;
  final bool pagesPanelCollapsed;
  final bool dashedStroke;
  final double textSize;
  final bool textBold;
  final bool textItalic;
  final TextAlign textAlign;
  final double textLineHeight;
  final ToolbarDock primaryToolbarDock;
  final int primaryToolbarOrder;
  final ToolbarDock optionsToolbarDock;
  final int optionsToolbarOrder;
  final List<double> pageTransform;
  final List<double> continuousTransform;

  static T _enumByName<T extends Enum>(
    List<T> values,
    Object? saved,
    T fallback,
  ) {
    final name = saved as String?;
    if (name == null) return fallback;
    for (final value in values) {
      if (value.name == name) return value;
    }
    return fallback;
  }

  static List<double> _doubleList(Object? value) =>
      (value as List?)
          ?.whereType<num>()
          .map((item) => item.toDouble())
          .toList() ??
      const <double>[];

  Map<String, Object?> toJson() => {
    'currentPageIndex': currentPageIndex,
    'tool': tool.name,
    'colorValue': colorValue,
    'highlighterColorValue': highlighterColorValue,
    'width': width,
    'highlighterWidth': highlighterWidth,
    'smoothing': smoothing,
    'pressureSensitivity': pressureSensitivity,
    'eraserSize': eraserSize,
    'eraserMode': eraserMode.name,
    'eraseHighlighterOnly': eraseHighlighterOnly,
    'eraserAutoDeselect': eraserAutoDeselect,
    'lastDrawingTool': lastDrawingTool.name,
    'lastPenTool': lastPenTool.name,
    'zoomMode': zoomMode,
    'verticalPageMode': verticalPageMode,
    'pagesPanelCollapsed': pagesPanelCollapsed,
    'dashedStroke': dashedStroke,
    'textSize': textSize,
    'textBold': textBold,
    'textItalic': textItalic,
    'textAlign': textAlign.name,
    'textLineHeight': textLineHeight,
    'primaryToolbarDock': primaryToolbarDock.name,
    'primaryToolbarOrder': primaryToolbarOrder,
    'optionsToolbarDock': optionsToolbarDock.name,
    'optionsToolbarOrder': optionsToolbarOrder,
    'pageTransform': pageTransform,
    'continuousTransform': continuousTransform,
  };

  factory EditorViewState.fromJson(
    Map<String, dynamic> value,
  ) => EditorViewState(
    currentPageIndex: value['currentPageIndex'] as int? ?? 0,
    tool: _enumByName(InkTool.values, value['tool'], InkTool.pen),
    colorValue: value['colorValue'] as int? ?? 0xFF17233C,
    highlighterColorValue: value['highlighterColorValue'] as int? ?? 0xFFFFFF73,
    width: (value['width'] as num?)?.toDouble() ?? 2,
    highlighterWidth: (value['highlighterWidth'] as num?)?.toDouble() ?? 14,
    smoothing: (value['smoothing'] as num?)?.toDouble() ?? .45,
    pressureSensitivity:
        (value['pressureSensitivity'] as num?)?.toDouble() ?? .7,
    eraserSize: (value['eraserSize'] as num?)?.toDouble() ?? 28,
    eraserMode: _enumByName(
      EraserMode.values,
      value['eraserMode'],
      EraserMode.precision,
    ),
    eraseHighlighterOnly: value['eraseHighlighterOnly'] as bool? ?? false,
    eraserAutoDeselect: value['eraserAutoDeselect'] as bool? ?? false,
    lastDrawingTool: _enumByName(
      InkTool.values,
      value['lastDrawingTool'],
      InkTool.pen,
    ),
    lastPenTool: _enumByName(InkTool.values, value['lastPenTool'], InkTool.pen),
    zoomMode: value['zoomMode'] as bool? ?? false,
    verticalPageMode: value['verticalPageMode'] as bool? ?? true,
    pagesPanelCollapsed: value['pagesPanelCollapsed'] as bool? ?? true,
    dashedStroke: value['dashedStroke'] as bool? ?? false,
    textSize: (value['textSize'] as num?)?.toDouble() ?? 24,
    textBold: value['textBold'] as bool? ?? false,
    textItalic: value['textItalic'] as bool? ?? false,
    textAlign: _enumByName(
      TextAlign.values,
      value['textAlign'],
      TextAlign.left,
    ),
    textLineHeight: (value['textLineHeight'] as num?)?.toDouble() ?? 1.2,
    primaryToolbarDock: _enumByName(
      ToolbarDock.values,
      value['primaryToolbarDock'],
      ToolbarDock.top,
    ),
    primaryToolbarOrder: ((value['primaryToolbarOrder'] as num?)?.toInt() ?? 0)
        .clamp(0, 1),
    optionsToolbarDock: _enumByName(
      ToolbarDock.values,
      value['optionsToolbarDock'],
      ToolbarDock.top,
    ),
    optionsToolbarOrder: ((value['optionsToolbarOrder'] as num?)?.toInt() ?? 1)
        .clamp(0, 1),
    pageTransform: _doubleList(value['pageTransform']),
    continuousTransform: _doubleList(value['continuousTransform']),
  );
}

class AppSettings {
  const AppSettings({
    this.themePreference = ThemePreference.system,
    this.defaultSmoothing = 0.45,
    this.defaultWidth = 2.0,
    this.sortBy = 'date_modified',
    this.allowFinger = false,
  });

  final ThemePreference themePreference;
  final double defaultSmoothing;
  final double defaultWidth;
  final String sortBy;
  final bool allowFinger;

  AppSettings copyWith({
    ThemePreference? themePreference,
    double? defaultSmoothing,
    double? defaultWidth,
    String? sortBy,
    bool? allowFinger,
  }) {
    return AppSettings(
      themePreference: themePreference ?? this.themePreference,
      defaultSmoothing: defaultSmoothing ?? this.defaultSmoothing,
      defaultWidth: defaultWidth ?? this.defaultWidth,
      sortBy: sortBy ?? this.sortBy,
      allowFinger: allowFinger ?? this.allowFinger,
    );
  }

  Map<String, Object> toJson() => {
    'themePreference': themePreference.name,
    'defaultSmoothing': defaultSmoothing,
    'defaultWidth': defaultWidth,
    'sortBy': sortBy,
    'allowFinger': allowFinger,
  };

  factory AppSettings.fromJson(Map<String, dynamic> value) {
    final savedTheme = value['themePreference'] as String?;
    final legacyDarkMode = value['isDarkMode'] as bool? ?? false;

    return AppSettings(
      themePreference: savedTheme == null
          ? (legacyDarkMode ? ThemePreference.dark : ThemePreference.system)
          : ThemePreference.values.byName(savedTheme),
      defaultSmoothing: (value['defaultSmoothing'] as num?)?.toDouble() ?? 0.45,
      defaultWidth: (value['defaultWidth'] as num?)?.toDouble() ?? 2.0,
      sortBy: value['sortBy'] as String? ?? 'date_modified',
      allowFinger: value['allowFinger'] as bool? ?? false,
    );
  }
}
