import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ink_note/editor/image_source_sheet.dart';

class _FakePhotoLibrary implements PhotoLibraryGateway {
  _FakePhotoLibrary({
    this.access = PhotoLibraryAccess.authorized,
    this.assets = const [],
  });

  PhotoLibraryAccess access;
  List<PhotoLibraryAsset> assets;
  int manageCalls = 0;
  int settingsCalls = 0;

  @override
  Future<PhotoLibraryAccess> requestAccess() async => access;

  @override
  Future<PhotoLibraryPage> loadPage({
    required int page,
    required int size,
  }) async {
    if (page > 0) {
      return const PhotoLibraryPage(assets: [], hasMore: false);
    }
    return PhotoLibraryPage(assets: assets, hasMore: false);
  }

  @override
  Future<Uint8List?> loadOriginal(PhotoLibraryAsset asset) async {
    return Uint8List.fromList([1, 2, 3, 4]);
  }

  @override
  Future<Uint8List?> loadThumbnail(PhotoLibraryAsset asset, int size) async {
    return null;
  }

  @override
  Future<void> manageLimitedAccess() async {
    manageCalls++;
  }

  @override
  Future<void> openSettings() async {
    settingsCalls++;
  }
}

void main() {
  Future<void> setTestSurface(WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(1024, 768));
    addTearDown(() => tester.binding.setSurfaceSize(null));
  }

  Future<InsertImageSourceResult?> openSheet(
    WidgetTester tester,
    PhotoLibraryGateway library,
  ) async {
    InsertImageSourceResult? result;
    await setTestSurface(tester);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => Center(
              child: FilledButton(
                onPressed: () async {
                  result = await showImageSourceSheet(
                    context,
                    library: library,
                  );
                },
                child: const Text('Open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    expect(find.text('Images'), findsOneWidget);
    return result;
  }

  testWidgets('shows recent images and returns the selected image bytes', (
    tester,
  ) async {
    final library = _FakePhotoLibrary(
      assets: const [
        PhotoLibraryAsset(id: 'recent-1', source: 'one', name: 'one.jpg'),
        PhotoLibraryAsset(id: 'recent-2', source: 'two', name: 'two.jpg'),
      ],
    );
    InsertImageSourceResult? result;

    await setTestSurface(tester);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => FilledButton(
              onPressed: () async {
                result = await showImageSourceSheet(context, library: library);
              },
              child: const Text('Open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('gallery-recent-1')), findsOneWidget);
    expect(find.byKey(const ValueKey('gallery-recent-2')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('gallery-recent-1')));
    await tester.pumpAndSettle();

    expect(result, isA<GalleryImageSourceResult>());
    final gallery = result! as GalleryImageSourceResult;
    expect(gallery.bytes, [1, 2, 3, 4]);
    expect(gallery.name, 'one.jpg');
  });

  testWidgets('More closes the gallery with a Files request', (tester) async {
    final library = _FakePhotoLibrary();
    InsertImageSourceResult? result;

    await setTestSurface(tester);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => FilledButton(
              onPressed: () async {
                result = await showImageSourceSheet(context, library: library);
              },
              child: const Text('Open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('image-source-files')));
    await tester.pumpAndSettle();

    expect(result, isA<FilesImageSourceResult>());
  });

  testWidgets('denied photo access keeps Files available and links Settings', (
    tester,
  ) async {
    final library = _FakePhotoLibrary(access: PhotoLibraryAccess.denied);
    await openSheet(tester, library);

    expect(find.text('Allow access to photos'), findsOneWidget);
    expect(find.byKey(const ValueKey('image-source-files')), findsOneWidget);
    final settings = find.byKey(const ValueKey('image-source-settings'));
    await tester.ensureVisible(settings);
    await tester.tap(settings);
    await tester.pump();

    expect(library.settingsCalls, 1);
  });

  testWidgets('limited photo access can open the system management picker', (
    tester,
  ) async {
    final library = _FakePhotoLibrary(access: PhotoLibraryAccess.limited);
    await openSheet(tester, library);

    expect(find.text('No selected photos are available.'), findsOneWidget);
    final choosePhotos = find.text('Choose Photos');
    await tester.ensureVisible(choosePhotos);
    await tester.tap(choosePhotos);
    await tester.pumpAndSettle();

    expect(library.manageCalls, 1);
  });
}
