import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ink_note/app_metadata.dart';
import 'package:ink_note/screens/settings_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  test('app metadata stays synchronized with pubspec version', () async {
    final pubspec = await File('pubspec.yaml').readAsString();

    expect(
      pubspec,
      contains('version: ${AppMetadata.version}+${AppMetadata.buildNumber}'),
    );
  });

  testWidgets('settings shows the app version and build number', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    await tester.binding.setSurfaceSize(const Size(1024, 1400));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(const MaterialApp(home: SettingsScreen()));
    await tester.pumpAndSettle();

    expect(find.text('Version'), findsOneWidget);
    expect(find.text(AppMetadata.versionWithBuild), findsOneWidget);
  });
}
