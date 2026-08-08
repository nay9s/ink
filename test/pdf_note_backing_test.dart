import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ink_note/pdf_note_backing.dart';
import 'package:pdf_document/pdf_document.dart' as pdf;

void main() {
  late Directory temporaryDirectory;

  setUp(() async {
    temporaryDirectory = await Directory.systemTemp.createTemp(
      'ink_note_pdf_backing_test_',
    );
  });

  tearDown(() async {
    if (await temporaryDirectory.exists()) {
      await temporaryDirectory.delete(recursive: true);
    }
  });

  test('creates a one-page PDF backing for a new note', () async {
    final file = await PdfNoteBacking.createBlank(
      documentsDirectory: temporaryDirectory,
      documentId: 'note_1',
    );
    final document = pdf.PdfDocument.open(await file.readAsBytes());
    final page = document.page(0);

    expect(await file.exists(), isTrue);
    expect(document.pageCount, 1);
    expect(
      page.mediaBox.height / page.mediaBox.width,
      closeTo(PdfNoteBacking.defaultAspectRatio, .0001),
    );
    expect(file.path, contains('ink_note_pdf'));
  });

  test('appends a real blank PDF page and keeps the previous pages', () async {
    final source = await PdfNoteBacking.createBlank(
      documentsDirectory: temporaryDirectory,
      documentId: 'note_2',
    );
    final firstRevision = await PdfNoteBacking.appendBlankPage(
      source: source,
      documentsDirectory: temporaryDirectory,
      documentId: 'note_2',
      expectedPageCount: 1,
      aspectRatio: 1.5,
    );
    final secondRevision = await PdfNoteBacking.appendBlankPage(
      source: firstRevision,
      documentsDirectory: temporaryDirectory,
      documentId: 'note_2',
      expectedPageCount: 2,
      aspectRatio: 1.2,
    );
    final document = pdf.PdfDocument.open(await secondRevision.readAsBytes());

    expect(firstRevision.path, isNot(secondRevision.path));
    expect(document.pageCount, 3);
    expect(
      document.page(0).mediaBox.height / document.page(0).mediaBox.width,
      closeTo(PdfNoteBacking.defaultAspectRatio, .0001),
    );
    expect(
      document.page(1).mediaBox.height / document.page(1).mediaBox.width,
      closeTo(1.5, .0001),
    );
    expect(
      document.page(2).mediaBox.height / document.page(2).mediaBox.width,
      closeTo(1.2, .0001),
    );
  });
}
