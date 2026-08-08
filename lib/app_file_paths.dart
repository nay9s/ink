import 'dart:io';

/// Stable references for files owned by Ink Note.
///
/// iOS can assign a different absolute sandbox path after a sideload refresh.
/// Persisting only the path relative to Documents lets the app rebuild the
/// correct absolute path every time it launches.
class AppFilePaths {
  const AppFilePaths._();

  static const referencePrefix = 'noten-app://';
  static const _managedRoots = <String>['ink_note_pdf/', 'ink_note_data/'];

  static String forStorage(String path, String documentsDirectory) {
    final relative = _managedRelative(path, documentsDirectory);
    return relative == null ? path : '$referencePrefix$relative';
  }

  static String resolve(String reference, String documentsDirectory) {
    final relative = _managedRelative(reference, documentsDirectory);
    if (relative == null) return reference;
    final segments = relative.split('/');
    return <String>[
      _trimTrailingSeparators(documentsDirectory),
      ...segments,
    ].join(Platform.pathSeparator);
  }

  static bool isManaged(String? value) {
    if (value == null || value.isEmpty) return false;
    if (value.startsWith(referencePrefix)) return true;
    final normalized = _normalize(value).toLowerCase();
    return _managedRoots.any((root) => normalized.contains('/$root'));
  }

  static String? _managedRelative(String value, String documentsDirectory) {
    if (value.isEmpty) return null;
    if (value.startsWith(referencePrefix)) {
      return _safeRelative(value.substring(referencePrefix.length));
    }

    final normalizedValue = _normalize(value);
    final normalizedRoot = _normalize(
      _trimTrailingSeparators(documentsDirectory),
    );
    final valueLower = normalizedValue.toLowerCase();
    final rootLower = normalizedRoot.toLowerCase();
    if (valueLower.startsWith('$rootLower/')) {
      return _safeRelative(
        normalizedValue.substring(normalizedRoot.length + 1),
      );
    }

    // Migration for versions that persisted the full iOS container path.
    // Keep the stable suffix and replace only the obsolete sandbox prefix.
    for (final root in _managedRoots) {
      final marker = '/$root';
      final index = valueLower.indexOf(marker);
      if (index >= 0) {
        return _safeRelative(normalizedValue.substring(index + 1));
      }
    }
    return null;
  }

  static String? _safeRelative(String value) {
    final normalized = _normalize(value).replaceFirst(RegExp(r'^/+'), '');
    final segments = normalized.split('/');
    if (segments.isEmpty ||
        segments.any(
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

  static String _normalize(String value) =>
      value.replaceAll('\\', '/').replaceAll(RegExp(r'/+'), '/');

  static String _trimTrailingSeparators(String value) =>
      value.replaceFirst(RegExp(r'[\\/]+$'), '');
}
