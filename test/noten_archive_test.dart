import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ink_note/models.dart';
import 'package:ink_note/noten_archive.dart';

void main() {
  test('round-trips editable ink and bundles referenced PDF assets', () async {
    final sourceRoot = await Directory.systemTemp.createTemp(
      'ink_note_noten_source_',
    );
    final destinationRoot = await Directory.systemTemp.createTemp(
      'ink_note_noten_destination_',
    );
    addTearDown(() async {
      if (await sourceRoot.exists()) await sourceRoot.delete(recursive: true);
      if (await destinationRoot.exists()) {
        await destinationRoot.delete(recursive: true);
      }
    });

    final pdf = File('${sourceRoot.path}${Platform.pathSeparator}source.pdf');
    final background = File(
      '${sourceRoot.path}${Platform.pathSeparator}paper.png',
    );
    final pdfBytes = utf8.encode('%PDF-1.4\n% test PDF bytes\n%%EOF');
    final backgroundBytes = <int>[137, 80, 78, 71, 13, 10, 26, 10];
    await pdf.writeAsBytes(pdfBytes);
    await background.writeAsBytes(backgroundBytes);

    final original = InkDocument(
      id: 'original',
      title: 'Calculus notes',
      colorValue: 0xFFA9D7B5,
      createdAt: DateTime.utc(2026, 1, 2),
      updatedAt: DateTime.utc(2026, 1, 3),
      pages: [
        [
          InkStroke(
            tool: InkTool.pen,
            color: const Color(0xFF123456),
            width: 2.5,
            pressureSensitivity: .8,
            dashed: true,
            points: const [InkPoint(.1, .2, .4), InkPoint(.3, .4, .9)],
          ),
        ],
        <InkObject>[],
      ],
      pageBackgrounds: [background.path, null],
      pageAspectRatios: const [1.4, 1.5],
      pagePdfPaths: [pdf.path, pdf.path],
      pagePdfPageNumbers: const [1, 2],
      folderId: 'old-folder',
    );

    final encoded = await NotenArchive.encode(original);
    final zip = ZipDecoder().decodeBytes(encoded);
    final names = zip.files.map((entry) => entry.name).toSet();
    expect(
      names,
      containsAll(<String>[
        'manifest.json',
        'document.json',
        'assets/pdfs/0000.pdf',
        'assets/backgrounds/0000.png',
      ]),
    );
    expect(
      names.where((name) => name.startsWith('assets/pdfs/')),
      hasLength(1),
    );
    final archivedDocument = Map<String, dynamic>.from(
      jsonDecode(
            utf8.decode(
              zip.files
                  .firstWhere((entry) => entry.name == 'document.json')
                  .content,
            ),
          )
          as Map,
    );
    expect(jsonEncode(archivedDocument), isNot(contains(sourceRoot.path)));
    expect(archivedDocument['pagePdfPaths'], const [
      'assets/pdfs/0000.pdf',
      'assets/pdfs/0000.pdf',
    ]);

    final importedAt = DateTime.utc(2026, 2, 3, 4, 5);
    final result = await NotenArchive.decode(
      encoded,
      documentsDirectory: destinationRoot,
      documentId: 'imported-note',
      folderId: 'new-folder',
      importedAt: importedAt,
    );

    expect(result.document.id, 'imported-note');
    expect(result.document.title, original.title);
    expect(result.document.createdAt, original.createdAt);
    expect(result.document.updatedAt, importedAt);
    expect(result.document.folderId, 'new-folder');
    expect(result.document.pages, hasLength(2));
    final stroke = result.document.pages.first.single as InkStroke;
    expect(stroke.tool, InkTool.pen);
    expect(stroke.color.toARGB32(), 0xFF123456);
    expect(stroke.dashed, isTrue);
    expect(stroke.points, hasLength(2));
    expect(result.document.pagePdfPaths[0], result.document.pagePdfPaths[1]);
    expect(
      await File(result.document.pagePdfPaths.first!).readAsBytes(),
      pdfBytes,
    );
    expect(
      await File(result.document.pageBackgrounds.first!).readAsBytes(),
      backgroundBytes,
    );
  });

  test('rejects unsafe archive paths before extracting files', () async {
    final destinationRoot = await Directory.systemTemp.createTemp(
      'ink_note_noten_unsafe_',
    );
    addTearDown(() async {
      if (await destinationRoot.exists()) {
        await destinationRoot.delete(recursive: true);
      }
    });

    final now = DateTime.utc(2026, 1, 1);
    final document = InkDocument(
      id: 'unsafe',
      title: 'Unsafe',
      colorValue: 0xFF000000,
      createdAt: now,
      updatedAt: now,
      pages: [<InkObject>[]],
    );
    final archive = Archive()
      ..add(
        ArchiveFile.string(
          'manifest.json',
          jsonEncode(<String, Object>{
            'format': 'noten',
            'schemaVersion': NotenArchive.schemaVersion,
            'document': 'document.json',
          }),
        ),
      )
      ..add(ArchiveFile.string('document.json', jsonEncode(document.toJson())))
      ..add(ArchiveFile.string('../escape.pdf', 'unsafe'));

    await expectLater(
      NotenArchive.decode(
        ZipEncoder().encodeBytes(archive),
        documentsDirectory: destinationRoot,
        documentId: 'rejected',
        importedAt: now,
      ),
      throwsA(isA<NotenArchiveException>()),
    );
    expect(
      await File(
        '${destinationRoot.parent.path}${Platform.pathSeparator}escape.pdf',
      ).exists(),
      isFalse,
    );
  });

  test('does not create a backup when a referenced PDF is missing', () async {
    final now = DateTime.utc(2026, 1, 1);
    final document = InkDocument(
      id: 'missing',
      title: 'Missing PDF',
      colorValue: 0xFF000000,
      createdAt: now,
      updatedAt: now,
      pages: [<InkObject>[]],
      pagePdfPaths: [
        '${Directory.systemTemp.path}${Platform.pathSeparator}'
            'does-not-exist-${now.microsecondsSinceEpoch}.pdf',
      ],
    );

    await expectLater(
      NotenArchive.encode(document),
      throwsA(isA<NotenArchiveException>()),
    );
  });
}
