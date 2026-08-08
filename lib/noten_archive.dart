import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';

import 'models.dart';

class NotenArchiveException implements Exception {
  const NotenArchiveException(this.message);

  final String message;

  @override
  String toString() => message;
}

class NotenImportResult {
  const NotenImportResult({
    required this.document,
    required this.assetDirectory,
  });

  final InkDocument document;
  final Directory assetDirectory;
}

enum _NotenAssetKind { pdf, background, image }

/// Portable, editable Ink Note document.
///
/// A `.noten` file is a validated ZIP container with JSON metadata and every
/// referenced PDF/background/image bundled below `assets/`. Archive references are
/// relative, so moving the file between devices never preserves stale iOS
/// sandbox paths.
class NotenArchive {
  const NotenArchive._();

  static const extension = 'noten';
  static const mimeType = 'application/x-noten';
  static const schemaVersion = 1;
  static const _manifestName = 'manifest.json';
  static const _documentName = 'document.json';
  static const _maxArchiveBytes = 1024 * 1024 * 1024;
  // Long handwritten notebooks can contain millions of vector points. Keep a
  // separate metadata cap for malformed archives without rejecting legitimate
  // notebooks whose editable stroke JSON is larger than a few megabytes.
  static const _maxMetadataBytes = 256 * 1024 * 1024;
  static const _maxEntries = 10000;

  static Future<Uint8List> encode(InkDocument document) async {
    final archive = Archive();
    final documentJson = Map<String, Object?>.from(document.toJson());
    final archivedPaths = <String, String>{};
    var pdfIndex = 0;
    var backgroundIndex = 0;
    var imageIndex = 0;

    Future<String?> bundle(
      String? localPath, {
      required _NotenAssetKind kind,
    }) async {
      if (localPath == null || localPath.isEmpty) return null;
      final existing = archivedPaths[localPath];
      if (existing != null) return existing;

      final source = File(localPath);
      if (!await source.exists()) {
        throw NotenArchiveException(
          switch (kind) {
            _NotenAssetKind.pdf =>
              'The original PDF is missing and cannot be added to this '
                  'Noten backup.',
            _NotenAssetKind.background =>
              'A page background is missing and cannot be added to this '
                  'Noten backup.',
            _NotenAssetKind.image =>
              'An inserted image is missing and cannot be added to this '
                  'Noten backup.',
          },
        );
      }
      final bytes = await source.readAsBytes();
      if (bytes.length > _maxArchiveBytes) {
        throw const NotenArchiveException('A bundled file is too large.');
      }
      final archivePath = switch (kind) {
        _NotenAssetKind.pdf =>
          'assets/pdfs/${pdfIndex.toString().padLeft(4, '0')}.pdf',
        _NotenAssetKind.background =>
          'assets/backgrounds/'
              '${backgroundIndex.toString().padLeft(4, '0')}'
              '${_safeExtension(localPath)}',
        _NotenAssetKind.image =>
          'assets/images/${imageIndex.toString().padLeft(4, '0')}'
              '${_safeExtension(localPath)}',
      };
      switch (kind) {
        case _NotenAssetKind.pdf:
          pdfIndex++;
        case _NotenAssetKind.background:
          backgroundIndex++;
        case _NotenAssetKind.image:
          imageIndex++;
      }
      archivedPaths[localPath] = archivePath;
      archive.add(ArchiveFile.noCompress(archivePath, bytes.length, bytes));
      return archivePath;
    }

    final pdfPaths = <String?>[];
    for (final path in document.pagePdfPaths) {
      pdfPaths.add(await bundle(path, kind: _NotenAssetKind.pdf));
    }
    final backgroundPaths = <String?>[];
    for (final path in document.pageBackgrounds) {
      backgroundPaths.add(
        await bundle(path, kind: _NotenAssetKind.background),
      );
    }
    final pages = <List<Map<String, Object?>>>[];
    for (final page in document.pages) {
      final archivedPage = <Map<String, Object?>>[];
      for (final object in page) {
        final value = Map<String, Object?>.from(object.toJson());
        if (object is InkImage) {
          value['path'] = await bundle(
            object.path,
            kind: _NotenAssetKind.image,
          );
        }
        archivedPage.add(value);
      }
      pages.add(archivedPage);
    }
    documentJson['pagePdfPaths'] = pdfPaths;
    documentJson['pageBackgrounds'] = backgroundPaths;
    documentJson['pages'] = pages;

    final manifest = <String, Object?>{
      'format': 'noten',
      'schemaVersion': schemaVersion,
      'document': _documentName,
      'createdAt': DateTime.now().toUtc().toIso8601String(),
      'app': 'Ink Note',
    };
    archive
      ..add(ArchiveFile.string(_manifestName, jsonEncode(manifest)))
      ..add(ArchiveFile.string(_documentName, jsonEncode(documentJson)));
    return ZipEncoder().encodeBytes(archive, level: DeflateLevel.bestSpeed);
  }

  static Future<NotenImportResult> decode(
    Uint8List bytes, {
    required Directory documentsDirectory,
    String? folderId,
    String? documentId,
    DateTime? importedAt,
  }) async {
    if (bytes.isEmpty || bytes.length > _maxArchiveBytes) {
      throw const NotenArchiveException(
        'This Noten file is empty or too large.',
      );
    }

    final Archive archive;
    try {
      archive = ZipDecoder().decodeBytes(bytes, verify: true);
    } catch (_) {
      throw const NotenArchiveException('This is not a valid Noten file.');
    }
    if (archive.length > _maxEntries) {
      throw const NotenArchiveException(
        'This Noten file has too many entries.',
      );
    }
    var totalSize = 0;
    final entries = <String, ArchiveFile>{};
    for (final entry in archive) {
      if (entry.isDirectory) continue;
      final name = _safeArchiveReference(entry.name);
      if (name == null || entries.containsKey(name)) {
        throw const NotenArchiveException(
          'This Noten file contains unsafe or duplicate paths.',
        );
      }
      totalSize += entry.size;
      if (totalSize > _maxArchiveBytes) {
        throw const NotenArchiveException(
          'The expanded Noten file is too large.',
        );
      }
      entries[name] = entry;
    }

    Map<String, dynamic> readJson(String name) {
      final entry = entries[name];
      if (entry == null || entry.size > _maxMetadataBytes) {
        throw const NotenArchiveException(
          'Noten metadata is missing or invalid.',
        );
      }
      try {
        return Map<String, dynamic>.from(
          jsonDecode(utf8.decode(entry.content)) as Map,
        );
      } catch (_) {
        throw const NotenArchiveException('Noten metadata is not readable.');
      }
    }

    final manifest = readJson(_manifestName);
    if (manifest['format'] != 'noten' ||
        manifest['schemaVersion'] != schemaVersion ||
        manifest['document'] != _documentName) {
      throw const NotenArchiveException(
        'This Noten file uses an unsupported format version.',
      );
    }
    final documentJson = readJson(_documentName);
    final now = importedAt ?? DateTime.now();
    final newId = documentId ?? 'note_${now.microsecondsSinceEpoch}';
    final importDirectory = Directory(
      '${documentsDirectory.path}${Platform.pathSeparator}ink_note_data'
      '${Platform.pathSeparator}$newId${Platform.pathSeparator}'
      '${now.microsecondsSinceEpoch}',
    );

    try {
      await importDirectory.create(recursive: true);
      final extracted = <String, String>{};
      var pdfIndex = 0;
      var backgroundIndex = 0;
      var imageIndex = 0;

      Future<String?> extract(
        Object? rawReference, {
        required _NotenAssetKind kind,
      }) async {
        if (rawReference == null) return null;
        if (rawReference is! String) {
          throw const NotenArchiveException(
            'Noten contains an invalid asset reference.',
          );
        }
        final reference = _safeArchiveReference(rawReference);
        if (reference == null || !reference.startsWith('assets/')) {
          throw const NotenArchiveException(
            'Noten contains an unsafe asset reference.',
          );
        }
        final previous = extracted[reference];
        if (previous != null) return previous;
        final entry = entries[reference];
        if (entry == null || entry.isDirectory) {
          throw const NotenArchiveException(
            'A file required by this Noten document is missing.',
          );
        }
        final outputName = switch (kind) {
          _NotenAssetKind.pdf =>
            'pdf_${pdfIndex.toString().padLeft(4, '0')}.pdf',
          _NotenAssetKind.background =>
            'background_${backgroundIndex.toString().padLeft(4, '0')}'
                '${_safeExtension(reference)}',
          _NotenAssetKind.image =>
            'image_${imageIndex.toString().padLeft(4, '0')}'
                '${_safeExtension(reference)}',
        };
        switch (kind) {
          case _NotenAssetKind.pdf:
            pdfIndex++;
          case _NotenAssetKind.background:
            backgroundIndex++;
          case _NotenAssetKind.image:
            imageIndex++;
        }
        final output = File(
          '${importDirectory.path}${Platform.pathSeparator}$outputName',
        );
        await output.writeAsBytes(entry.content, flush: true);
        extracted[reference] = output.path;
        return output.path;
      }

      final pagePdfPaths = <String?>[];
      for (final value in _nullableList(documentJson['pagePdfPaths'])) {
        pagePdfPaths.add(await extract(value, kind: _NotenAssetKind.pdf));
      }
      final pageBackgrounds = <String?>[];
      for (final value in _nullableList(documentJson['pageBackgrounds'])) {
        pageBackgrounds.add(
          await extract(value, kind: _NotenAssetKind.background),
        );
      }
      final rawPages = documentJson['pages'];
      if (rawPages is List) {
        for (var pageIndex = 0; pageIndex < rawPages.length; pageIndex++) {
          final rawPage = rawPages[pageIndex];
          if (rawPage is! List) continue;
          for (var objectIndex = 0;
              objectIndex < rawPage.length;
              objectIndex++) {
            final rawObject = rawPage[objectIndex];
            if (rawObject is! Map || rawObject['type'] != 'image') continue;
            final object = Map<String, dynamic>.from(rawObject);
            final imagePath = await extract(
              object['path'],
              kind: _NotenAssetKind.image,
            );
            if (imagePath == null) {
              throw const NotenArchiveException(
                'Noten contains an invalid image reference.',
              );
            }
            object['path'] = imagePath;
            rawPage[objectIndex] = object;
          }
        }
      }

      documentJson
        ..['id'] = newId
        ..['updatedAt'] = now.toIso8601String()
        ..['pagePdfPaths'] = pagePdfPaths
        ..['pageBackgrounds'] = pageBackgrounds
        ..['folderId'] = folderId
        ..['requiresNaming'] = false;
      final document = InkDocument.fromJson(documentJson);
      return NotenImportResult(
        document: document,
        assetDirectory: importDirectory,
      );
    } catch (_) {
      if (await importDirectory.exists()) {
        await importDirectory.delete(recursive: true);
      }
      rethrow;
    }
  }

  static String safeFileName(String title) {
    final value = title
        .replaceAll(RegExp(r'[\\/:*?"<>|\x00-\x1F]+'), '_')
        .replaceAll(RegExp(r'_+'), '_')
        .trim();
    return value.isEmpty ? 'Ink_Note' : value;
  }

  static List<Object?> _nullableList(Object? value) {
    if (value == null) return const <Object?>[];
    if (value is! List) {
      throw const NotenArchiveException('Noten contains an invalid page list.');
    }
    return List<Object?>.from(value);
  }

  static String? _safeArchiveReference(String value) {
    final normalized = value.replaceAll('\\', '/');
    if (normalized.isEmpty || normalized.startsWith('/')) return null;
    final segments = normalized.split('/');
    if (segments.any(
      (segment) =>
          segment.isEmpty ||
          segment == '.' ||
          segment == '..' ||
          segment.contains(':'),
    )) {
      return null;
    }
    return segments.join('/');
  }

  static String _safeExtension(String path) {
    final name = path.replaceAll('\\', '/').split('/').last;
    final dot = name.lastIndexOf('.');
    if (dot <= 0 || dot == name.length - 1) return '.bin';
    final extension = name.substring(dot).toLowerCase();
    return RegExp(r'^\.[a-z0-9]{1,8}$').hasMatch(extension)
        ? extension
        : '.bin';
  }
}
