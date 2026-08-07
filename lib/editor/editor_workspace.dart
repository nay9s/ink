import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../models.dart';
import '../store.dart';
import 'editor_screen.dart';

class EditorWorkspace extends StatefulWidget {
  const EditorWorkspace({
    super.key,
    required this.initialDocument,
    this.initialDocuments,
    this.initialActiveId,
  });

  final InkDocument initialDocument;
  final List<InkDocument>? initialDocuments;
  final String? initialActiveId;

  @override
  State<EditorWorkspace> createState() => _EditorWorkspaceState();
}

class _EditorWorkspaceState extends State<EditorWorkspace>
    with WidgetsBindingObserver {
  late final List<InkDocument> _openDocuments;
  late String _activeId;
  bool _navigationPromptOpen = false;

  InkDocument get _activeDocument =>
      _openDocuments.firstWhere((document) => document.id == _activeId);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    final candidates = widget.initialDocuments == null ||
            widget.initialDocuments!.isEmpty
        ? <InkDocument>[widget.initialDocument]
        : widget.initialDocuments!;
    final seenIds = <String>{};
    _openDocuments = <InkDocument>[
      for (final document in candidates)
        if (seenIds.add(document.id)) document,
    ];
    _activeId = _openDocuments.any(
      (document) => document.id == widget.initialActiveId,
    )
        ? widget.initialActiveId!
        : _openDocuments.first.id;
    unawaited(_persistWorkspace(editorOpen: true));
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached ||
        state == AppLifecycleState.hidden) {
      unawaited(_persistWorkspace(editorOpen: true));
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  Future<void> _persistWorkspace({required bool editorOpen}) {
    return AppSessionStore.saveWorkspace(
      WorkspaceSession(
        editorOpen: editorOpen,
        openDocumentIds:
            _openDocuments.map((document) => document.id).toList(),
        activeDocumentId: editorOpen ? _activeId : null,
      ),
    );
  }

  void _documentSaved(InkDocument saved) {
    if (!mounted) return;
    final index = _openDocuments.indexWhere((item) => item.id == saved.id);
    if (index >= 0) {
      setState(() => _openDocuments[index] = saved);
      unawaited(_persistWorkspace(editorOpen: true));
    }
  }

  Future<String?> _requestNameBeforeLeaving(
    InkDocument document, {
    required String action,
  }) async {
    if (_navigationPromptOpen || !mounted) return null;
    _navigationPromptOpen = true;
    final controller = TextEditingController(text: document.title);
    controller.selection = TextSelection(
      baseOffset: 0,
      extentOffset: controller.text.length,
    );
    String? validationMessage;

    String? validateName(String value) {
      if (value.isEmpty) return 'Please enter a document name.';
      if (RegExp(r'^Document \d+$').hasMatch(value)) {
        return 'Replace the automatic name with your own file name.';
      }
      return null;
    }

    final result = await showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('Name this document'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Set a file name before $action so the document is easy to find.',
              ),
              const SizedBox(height: 14),
              TextField(
                controller: controller,
                autofocus: true,
                maxLength: 80,
                textInputAction: TextInputAction.done,
                decoration: InputDecoration(
                  labelText: 'Document name',
                  errorText: validationMessage,
                ),
                onSubmitted: (_) {
                  final value = controller.text.trim();
                  final error = validateName(value);
                  if (error != null) {
                    setDialogState(() => validationMessage = error);
                    return;
                  }
                  Navigator.pop(dialogContext, value);
                },
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('Keep editing'),
            ),
            FilledButton(
              onPressed: () {
                final value = controller.text.trim();
                final error = validateName(value);
                if (error != null) {
                  setDialogState(() => validationMessage = error);
                  return;
                }
                Navigator.pop(dialogContext, value);
              },
              child: const Text('Save name'),
            ),
          ],
        ),
      ),
    );

    controller.dispose();
    _navigationPromptOpen = false;
    return result;
  }

  Future<InkDocument?> _renameBeforeLeaving(
    InkDocument document, {
    required String action,
  }) async {
    if (!document.requiresNaming) return document;

    final name = await _requestNameBeforeLeaving(document, action: action);
    if (name == null || !mounted) return null;
    final renamed = document.copyWith(
      title: name,
      updatedAt: DateTime.now(),
      requiresNaming: false,
    );
    await InkDocumentStore.save(renamed);
    if (!mounted) return null;
    final index = _openDocuments.indexWhere((item) => item.id == renamed.id);
    if (index >= 0) setState(() => _openDocuments[index] = renamed);
    return renamed;
  }

  Future<void> _newTab() async {
    final document = await InkDocumentStore.createAutomatic();
    if (!mounted) return;
    setState(() {
      _openDocuments.add(document);
      _activeId = document.id;
    });
    await _persistWorkspace(editorOpen: true);
  }

  Future<void> _closeTab(String id) async {
    final index = _openDocuments.indexWhere((document) => document.id == id);
    if (index < 0) return;
    final renamed = await _renameBeforeLeaving(
      _openDocuments[index],
      action: 'closing this tab',
    );
    if (renamed == null || !mounted) return;

    if (_openDocuments.length == 1) {
      await _persistWorkspace(editorOpen: false);
      if (mounted) Navigator.pop(context);
      return;
    }

    setState(() {
      _openDocuments.removeAt(index);
      if (_activeId == id) {
        _activeId =
            _openDocuments[math.min(index, _openDocuments.length - 1)].id;
      }
    });
    await _persistWorkspace(editorOpen: true);
  }

  Future<void> _exitToLibrary() async {
    final renamed = await _renameBeforeLeaving(
      _activeDocument,
      action: 'opening the library',
    );
    if (renamed == null || !mounted) return;
    await _persistWorkspace(editorOpen: false);
    if (mounted) Navigator.pop(context);
  }

  void _selectTab(String id) {
    if (id == _activeId || !_openDocuments.any((item) => item.id == id)) return;
    setState(() => _activeId = id);
    unawaited(_persistWorkspace(editorOpen: true));
  }

  @override
  Widget build(BuildContext context) => PopScope(
        canPop: false,
        onPopInvokedWithResult: (didPop, _) {
          if (!didPop) unawaited(_exitToLibrary());
        },
        child: EditorScreen(
          key: ValueKey(_activeId),
          document: _activeDocument,
          openDocuments: List.unmodifiable(_openDocuments),
          activeDocumentId: _activeId,
          onSelectTab: _selectTab,
          onCloseTab: (id) => unawaited(_closeTab(id)),
          onNewTab: () => unawaited(_newTab()),
          onExit: () => unawaited(_exitToLibrary()),
          onDocumentSaved: _documentSaved,
        ),
      );
}
