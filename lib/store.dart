import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'app_file_paths.dart';
import 'models.dart';

class InkDocumentStore {
  static const _indexKey = 'ink_note_document_index_v1';
  static const _documentPrefix = 'ink_note_document_v1_';
  static const _legacyStrokeKey = 'ink_note_strokes_v1';
  static const _initializedKey = 'ink_note_initialized_v2';
  static const _documentCounterKey = 'ink_note_document_counter_v1';

  static Future<List<InkDocument>> loadAll() async {
    final preferences = await SharedPreferences.getInstance();
    var ids = preferences.getStringList(_indexKey);

    if (ids == null) {
      final hasInitialized = preferences.getBool(_initializedKey) ?? false;
      if (hasInitialized) {
        ids = <String>[];
        await preferences.setStringList(_indexKey, ids);
      } else {
        final migrated = _decodeLegacy(preferences.getString(_legacyStrokeKey));
        final now = DateTime.now();
        final seeded = [
          InkDocument(
            id: 'study_notes',
            title: 'Study Notes',
            colorValue: 0xFFA9D7B5,
            createdAt: now,
            updatedAt: now,
            pages: [migrated],
          ),
          InkDocument(
            id: 'biology',
            title: 'Biology',
            colorValue: 0xFFF29A7C,
            createdAt: now.subtract(const Duration(minutes: 1)),
            updatedAt: now.subtract(const Duration(minutes: 1)),
            pages: [<InkObject>[]],
          ),
          InkDocument(
            id: 'journal',
            title: 'Journal',
            colorValue: 0xFFB9AFE7,
            createdAt: now.subtract(const Duration(minutes: 2)),
            updatedAt: now.subtract(const Duration(minutes: 2)),
            pages: [<InkObject>[]],
          ),
          InkDocument(
            id: 'ideas',
            title: 'Ideas',
            colorValue: 0xFFF3CD68,
            createdAt: now.subtract(const Duration(minutes: 3)),
            updatedAt: now.subtract(const Duration(minutes: 3)),
            pages: [<InkObject>[]],
          ),
        ];
        for (final document in seeded) {
          await _write(preferences, document);
        }
        ids = seeded.map((document) => document.id).toList();
        await preferences.setStringList(_indexKey, ids);
        await preferences.setBool(_initializedKey, true);
      }
    }

    final documents = <InkDocument>[];
    for (final id in ids) {
      final raw = preferences.getString('$_documentPrefix$id');
      if (raw == null) continue;
      try {
        final decoded = InkDocument.fromJson(
          Map<String, dynamic>.from(jsonDecode(raw) as Map),
        );
        final resolved = await _resolveFilePaths(decoded);
        documents.add(resolved.document);
        if (resolved.changed) {
          await _write(preferences, resolved.document);
        }
      } catch (_) {
        // Skip one corrupt document without blocking the rest of the library.
      }
    }
    return documents;
  }

  static List<InkObject> _decodeLegacy(String? raw) {
    if (raw == null) return [];
    try {
      return (jsonDecode(raw) as List)
          .map(
            (stroke) =>
                InkObject.fromJson(Map<String, dynamic>.from(stroke as Map)),
          )
          .toList();
    } catch (_) {
      return [];
    }
  }

  static Future<InkDocument> create(
    String title, {
    String? folderId,
    bool requiresNaming = false,
  }) async {
    final preferences = await SharedPreferences.getInstance();
    final now = DateTime.now();
    final id = 'note_${now.microsecondsSinceEpoch}';
    const palette = [
      0xFFA9D7B5,
      0xFFF29A7C,
      0xFFB9AFE7,
      0xFFF3CD68,
      0xFF9CC2E5,
      0xFFE59C9C,
    ];
    final document = InkDocument(
      id: id,
      title: title.trim().isEmpty ? 'Untitled note' : title.trim(),
      colorValue: palette[id.hashCode.abs() % palette.length],
      createdAt: now,
      updatedAt: now,
      pages: [[]],
      folderId: folderId,
      requiresNaming: requiresNaming,
    );
    await _write(preferences, document);
    final ids = preferences.getStringList(_indexKey) ?? [];
    await preferences.setStringList(_indexKey, [id, ...ids]);
    await preferences.setBool(_initializedKey, true);
    return document;
  }

  static Future<String> nextAutomaticTitle() async {
    final preferences = await SharedPreferences.getInstance();
    final documents = await loadAll();
    final used = documents.map((document) => document.title.trim()).toSet();
    final pattern = RegExp(r'^Document (\d+)$');
    var highestExisting = 0;
    for (final title in used) {
      final match = pattern.firstMatch(title);
      final number = match == null ? null : int.tryParse(match.group(1)!);
      if (number != null && number > highestExisting) highestExisting = number;
    }

    var number =
        math
            .max(preferences.getInt(_documentCounterKey) ?? 0, highestExisting)
            .toInt() +
        1;
    while (used.contains('Document $number')) {
      number++;
    }
    await preferences.setInt(_documentCounterKey, number);
    return 'Document $number';
  }

  static Future<InkDocument> createAutomatic({String? folderId}) async {
    return create(
      await nextAutomaticTitle(),
      folderId: folderId,
      requiresNaming: true,
    );
  }

  static Future<void> save(InkDocument document) async {
    final preferences = await SharedPreferences.getInstance();
    await _write(preferences, document);
    final ids = preferences.getStringList(_indexKey) ?? [];
    if (!ids.contains(document.id)) {
      await preferences.setStringList(_indexKey, [document.id, ...ids]);
    }
    await preferences.setBool(_initializedKey, true);
  }

  static Future<void> delete(String id) async {
    final preferences = await SharedPreferences.getInstance();
    await preferences.remove('$_documentPrefix$id');
    await preferences.remove('ink_note_editor_state_v1_$id');
    final ids = preferences.getStringList(_indexKey) ?? [];
    await preferences.setStringList(
      _indexKey,
      ids.where((item) => item != id).toList(),
    );
  }

  static Future<void> deleteAll() async {
    final preferences = await SharedPreferences.getInstance();
    final ids = preferences.getStringList(_indexKey) ?? [];
    for (final id in ids) {
      await preferences.remove('$_documentPrefix$id');
      await preferences.remove('ink_note_editor_state_v1_$id');
    }
    await preferences.remove('ink_note_workspace_session_v1');
    await preferences.setStringList(_indexKey, []);
    await preferences.setBool(_initializedKey, true);
  }

  static Future<void> _write(
    SharedPreferences preferences,
    InkDocument document,
  ) async {
    final json = document.toJson();
    if (_hasFilePaths(document)) {
      final documentsDirectory = await getApplicationDocumentsDirectory();
      json['pageBackgrounds'] = document.pageBackgrounds
          .map(
            (path) => path == null
                ? null
                : AppFilePaths.forStorage(path, documentsDirectory.path),
          )
          .toList();
      json['pagePdfPaths'] = document.pagePdfPaths
          .map(
            (path) => path == null
                ? null
                : AppFilePaths.forStorage(path, documentsDirectory.path),
          )
          .toList();
    }
    await preferences.setString(
      '$_documentPrefix${document.id}',
      jsonEncode(json),
    );
  }

  static bool _hasFilePaths(InkDocument document) =>
      document.pageBackgrounds.any((path) => path != null && path.isNotEmpty) ||
      document.pagePdfPaths.any((path) => path != null && path.isNotEmpty);

  static Future<_ResolvedDocumentPaths> _resolveFilePaths(
    InkDocument document,
  ) async {
    if (!_hasFilePaths(document)) {
      return _ResolvedDocumentPaths(document, false);
    }
    final documentsDirectory = await getApplicationDocumentsDirectory();
    var changed = false;

    String? resolve(String? value) {
      if (value == null || value.isEmpty) return value;
      final resolved = AppFilePaths.resolve(value, documentsDirectory.path);
      if (resolved != value &&
          !value.startsWith(AppFilePaths.referencePrefix)) {
        changed = true;
      }
      return resolved;
    }

    final resolved = document.copyWith(
      pageBackgrounds: document.pageBackgrounds.map(resolve).toList(),
      pagePdfPaths: document.pagePdfPaths.map(resolve).toList(),
    );
    return _ResolvedDocumentPaths(resolved, changed);
  }
}

class _ResolvedDocumentPaths {
  const _ResolvedDocumentPaths(this.document, this.changed);

  final InkDocument document;
  final bool changed;
}

class InkFolderStore {
  static const _key = 'ink_note_folders_v1';

  static Future<List<InkFolder>> loadAll() async {
    final raw = (await SharedPreferences.getInstance()).getString(_key);
    if (raw == null) return [];
    try {
      return (jsonDecode(raw) as List)
          .map(
            (folder) =>
                InkFolder.fromJson(Map<String, dynamic>.from(folder as Map)),
          )
          .toList();
    } catch (_) {
      return [];
    }
  }

  static Future<InkFolder> create(String name, {String? parentId}) async {
    final folders = await loadAll();
    final folder = InkFolder(
      id: 'folder_${DateTime.now().microsecondsSinceEpoch}',
      name: name.trim(),
      parentId: parentId,
    );
    await _save([...folders, folder]);
    return folder;
  }

  static Future<void> rename(InkFolder folder, String name) async {
    final folders = await loadAll();
    await _save([
      for (final item in folders)
        if (item.id == folder.id) item.copyWith(name: name.trim()) else item,
    ]);
  }

  static Future<void> delete(String id) async {
    final folders = await loadAll();
    final toDelete = <String>{id};
    var changed = true;
    while (changed) {
      changed = false;
      for (final folder in folders) {
        if (folder.parentId != null &&
            toDelete.contains(folder.parentId) &&
            toDelete.add(folder.id)) {
          changed = true;
        }
      }
    }

    await _save(
      folders.where((folder) => !toDelete.contains(folder.id)).toList(),
    );

    final documents = await InkDocumentStore.loadAll();
    for (final document in documents) {
      if (document.folderId != null && toDelete.contains(document.folderId)) {
        await InkDocumentStore.save(
          document.copyWith(clearFolder: true, updatedAt: DateTime.now()),
        );
      }
    }
  }

  static Future<void> deleteAll() async {
    await (await SharedPreferences.getInstance()).remove(_key);
  }

  static Future<void> _save(List<InkFolder> folders) async {
    await (await SharedPreferences.getInstance()).setString(
      _key,
      jsonEncode(folders.map((folder) => folder.toJson()).toList()),
    );
  }
}

class AppSessionStore {
  static const _workspaceKey = 'ink_note_workspace_session_v1';
  static const _editorStatePrefix = 'ink_note_editor_state_v1_';

  static Future<WorkspaceSession> loadWorkspace() async {
    final raw = (await SharedPreferences.getInstance()).getString(
      _workspaceKey,
    );
    if (raw == null) return const WorkspaceSession();
    try {
      return WorkspaceSession.fromJson(
        Map<String, dynamic>.from(jsonDecode(raw) as Map),
      );
    } catch (_) {
      return const WorkspaceSession();
    }
  }

  static Future<void> saveWorkspace(WorkspaceSession session) async {
    await (await SharedPreferences.getInstance()).setString(
      _workspaceKey,
      jsonEncode(session.toJson()),
    );
  }

  static Future<EditorViewState?> loadEditorState(String documentId) async {
    final raw = (await SharedPreferences.getInstance()).getString(
      '$_editorStatePrefix$documentId',
    );
    if (raw == null) return null;
    try {
      return EditorViewState.fromJson(
        Map<String, dynamic>.from(jsonDecode(raw) as Map),
      );
    } catch (_) {
      return null;
    }
  }

  static Future<void> saveEditorState(
    String documentId,
    EditorViewState state,
  ) async {
    await (await SharedPreferences.getInstance()).setString(
      '$_editorStatePrefix$documentId',
      jsonEncode(state.toJson()),
    );
  }

  static Future<void> deleteEditorState(String documentId) async {
    await (await SharedPreferences.getInstance()).remove(
      '$_editorStatePrefix$documentId',
    );
  }
}

class InkStore {
  static const _presetsKey = 'ink_note_pen_presets_v1';
  static const _colorPresetsKey = 'ink_note_color_presets_v1';
  static const _highlighterColorPresetsKey =
      'ink_note_highlighter_color_presets_v1';
  static const _highlighterPresetsKey = 'ink_note_highlighter_size_presets_v1';

  static Future<List<PenPreset>> loadPresets() async {
    final raw = (await SharedPreferences.getInstance()).getString(_presetsKey);
    if (raw == null) return [];
    try {
      return (jsonDecode(raw) as List)
          .map(
            (preset) =>
                PenPreset.fromJson(Map<String, dynamic>.from(preset as Map)),
          )
          .toList();
    } catch (_) {
      return [];
    }
  }

  static Future<void> savePresets(List<PenPreset> presets) async {
    await (await SharedPreferences.getInstance()).setString(
      _presetsKey,
      jsonEncode(presets.map((preset) => preset.toJson()).toList()),
    );
  }

  static Future<List<PenPreset>> loadHighlighterPresets() async {
    final raw = (await SharedPreferences.getInstance()).getString(
      _highlighterPresetsKey,
    );
    if (raw == null) return [];
    try {
      return (jsonDecode(raw) as List)
          .map(
            (preset) =>
                PenPreset.fromJson(Map<String, dynamic>.from(preset as Map)),
          )
          .toList();
    } catch (_) {
      return [];
    }
  }

  static Future<void> saveHighlighterPresets(List<PenPreset> presets) async {
    await (await SharedPreferences.getInstance()).setString(
      _highlighterPresetsKey,
      jsonEncode(presets.map((preset) => preset.toJson()).toList()),
    );
  }

  static Future<List<Color>> loadColorPresets() async {
    final raw = (await SharedPreferences.getInstance()).getString(
      _colorPresetsKey,
    );
    if (raw == null) return [];
    try {
      return (jsonDecode(raw) as List)
          .map((value) => Color((value as num).toInt()))
          .toList();
    } catch (_) {
      return [];
    }
  }

  static Future<void> saveColorPresets(List<Color> colors) async {
    await (await SharedPreferences.getInstance()).setString(
      _colorPresetsKey,
      jsonEncode(colors.map((color) => color.toARGB32()).toList()),
    );
  }

  static Future<List<Color>> loadHighlighterColorPresets() async {
    final raw = (await SharedPreferences.getInstance()).getString(
      _highlighterColorPresetsKey,
    );
    if (raw == null) return [];
    try {
      return (jsonDecode(raw) as List)
          .map((value) => Color((value as num).toInt()))
          .toList();
    } catch (_) {
      return [];
    }
  }

  static Future<void> saveHighlighterColorPresets(List<Color> colors) async {
    await (await SharedPreferences.getInstance()).setString(
      _highlighterColorPresetsKey,
      jsonEncode(colors.map((color) => color.toARGB32()).toList()),
    );
  }
}

class AppSettingsStore {
  static const _settingsKey = 'ink_note_settings_v1';

  static Future<AppSettings> load() async {
    final raw = (await SharedPreferences.getInstance()).getString(_settingsKey);
    if (raw == null) return const AppSettings();
    try {
      return AppSettings.fromJson(
        Map<String, dynamic>.from(jsonDecode(raw) as Map),
      );
    } catch (_) {
      return const AppSettings();
    }
  }

  static Future<void> save(AppSettings settings) async {
    await (await SharedPreferences.getInstance()).setString(
      _settingsKey,
      jsonEncode(settings.toJson()),
    );
  }
}
