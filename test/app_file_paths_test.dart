import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ink_note/app_file_paths.dart';

void main() {
  const documentsDirectory = r'C:\Containers\Current\Documents';

  test('stores managed files relative to the current Documents directory', () {
    final stored = AppFilePaths.forStorage(
      r'C:\Containers\Current\Documents\ink_note_pdf\note_1\source.pdf',
      documentsDirectory,
    );

    expect(stored, 'noten-app://ink_note_pdf/note_1/source.pdf');
  });

  test('migrates an absolute path from an obsolete iOS sandbox', () {
    const stale =
        '/var/mobile/Containers/Data/Application/OLD/Documents/'
        'ink_note_pdf/note_1/source.pdf';

    final stored = AppFilePaths.forStorage(stale, documentsDirectory);
    final resolved = AppFilePaths.resolve(stored, documentsDirectory);

    expect(stored, 'noten-app://ink_note_pdf/note_1/source.pdf');
    expect(
      resolved,
      <String>[
        documentsDirectory,
        'ink_note_pdf',
        'note_1',
        'source.pdf',
      ].join(Platform.pathSeparator),
    );
  });

  test('does not resolve unsafe or unmanaged references', () {
    const unsafe = 'noten-app://../outside.pdf';
    const unmanaged = r'C:\Users\someone\Downloads\source.pdf';

    expect(AppFilePaths.resolve(unsafe, documentsDirectory), unsafe);
    expect(AppFilePaths.forStorage(unmanaged, documentsDirectory), unmanaged);
  });
}
