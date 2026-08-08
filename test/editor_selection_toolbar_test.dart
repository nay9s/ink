import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ink_note/editor/editor_screen.dart';
import 'package:ink_note/models.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets('selection actions appear near the selected content', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    await tester.binding.setSurfaceSize(const Size(1024, 768));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final now = DateTime(2026, 8, 9);
    final document = InkDocument(
      id: 'selection-toolbar-test',
      title: 'Selection toolbar test',
      colorValue: Colors.blue.toARGB32(),
      createdAt: now,
      updatedAt: now,
      pages: [
        <InkObject>[
          InkStroke(
            tool: InkTool.pen,
            color: Colors.blue,
            width: 4,
            pressureSensitivity: 0,
            isSelected: true,
            points: const [InkPoint(.35, .3, 1), InkPoint(.65, .3, 1)],
          ),
        ],
      ],
    );

    await tester.pumpWidget(
      MaterialApp(
        home: EditorScreen(
          document: document,
          openDocuments: [document],
          activeDocumentId: document.id,
          onSelectTab: (_) {},
          onCloseTab: (_) {},
          onNewTab: () {},
          onExit: () {},
          onDocumentSaved: (_) {},
        ),
      ),
    );
    await tester.pumpAndSettle();

    final lasso = find.byTooltip('Lasso');
    expect(lasso, findsOneWidget);
    final primaryToolbarY = tester.getCenter(lasso).dy;
    await tester.tap(lasso);
    await tester.pumpAndSettle();

    final cut = find.byTooltip('Cut');
    expect(cut, findsOneWidget);
    expect(tester.getCenter(cut).dy, greaterThan(primaryToolbarY + 100));
    final actionsSize = tester.getSize(
      find.byKey(const ValueKey('selection-actions-toolbar')),
    );
    expect(actionsSize.width, lessThan(260));
    expect(actionsSize.height, lessThan(60));

    await tester.tap(cut);
    await tester.pumpAndSettle();
    expect(find.byTooltip('Cut'), findsNothing);
    expect(find.byTooltip('Paste'), findsOneWidget);
  });
}
