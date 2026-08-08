import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pdf_document/pdf_document.dart' as pdf;
import 'package:shared_preferences/shared_preferences.dart';

import 'package:ink_note/store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const pathProviderChannel = MethodChannel('plugins.flutter.io/path_provider');
  late Directory documentsDirectory;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    documentsDirectory = await Directory.systemTemp.createTemp(
      'ink_note_store_test_',
    );
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(pathProviderChannel, (call) async {
          if (call.method == 'getApplicationDocumentsDirectory') {
            return documentsDirectory.path;
          }
          return null;
        });
  });

  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(pathProviderChannel, null);
    if (await documentsDirectory.exists()) {
      await documentsDirectory.delete(recursive: true);
    }
  });

  test('clearing all notes does not recreate sample notes', () async {
    final initial = await InkDocumentStore.loadAll();
    expect(initial, isNotEmpty);

    await InkDocumentStore.deleteAll();
    final afterClear = await InkDocumentStore.loadAll();

    expect(afterClear, isEmpty);
  });

  test('deleting a folder moves its notes back to the root', () async {
    await InkDocumentStore.loadAll();
    final folder = await InkFolderStore.create('Archive');
    final note = await InkDocumentStore.create(
      'Moved note',
      folderId: folder.id,
    );

    await InkFolderStore.delete(folder.id);
    final documents = await InkDocumentStore.loadAll();
    final saved = documents.firstWhere((item) => item.id == note.id);

    expect(saved.folderId, isNull);
  });

  test('a New Note is created with a real one-page PDF backing', () async {
    await InkDocumentStore.deleteAll();

    final note = await InkDocumentStore.createAutomatic();
    final pdfPath = note.pagePdfPaths.single;
    final source = File(pdfPath!);
    final document = pdf.PdfDocument.open(await source.readAsBytes());

    expect(await source.exists(), isTrue);
    expect(note.pagePdfPageNumbers, const [1]);
    expect(note.pageAspectRatios.single, isNotNull);
    expect(document.pageCount, 1);

    final restored = (await InkDocumentStore.loadAll()).single;
    expect(restored.pagePdfPaths.single, pdfPath);
  });
}
