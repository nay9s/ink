import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ink_note/editor/page_strip.dart';
import 'package:ink_note/models.dart';

void main() {
  Future<void> pumpStrip(WidgetTester tester, List<double?> ratios) async {
    await tester.binding.setSurfaceSize(const Size(1024, 768));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Row(
            children: [
              SizedBox(
                width: 220,
                child: PageStrip(
                  pages: List<List<InkObject>>.generate(
                    ratios.length,
                    (_) => <InkObject>[],
                  ),
                  pageBackgrounds: List<String?>.filled(ratios.length, null),
                  pageAspectRatios: ratios,
                  pagePdfPaths: List<String?>.filled(ratios.length, null),
                  pagePdfPageNumbers: List<int?>.filled(ratios.length, null),
                  currentPageIndex: 0,
                  onSelectPage: (_) {},
                  onAddPage: () {},
                  collapsed: false,
                  onToggleCollapsed: () {},
                  images: const <String, ui.Image>{},
                ),
              ),
              const Expanded(child: SizedBox()),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  /// Vertical distance between the bottom of page 1's thumbnail and its
  /// number label. A fixed portrait tile ratio used to leave a large void
  /// here for landscape pages.
  double gapUnderFirstThumbnail(WidgetTester tester) {
    final thumbnail = tester.getRect(find.byType(AspectRatio).first);
    final label = tester.getRect(find.text('1'));
    return label.top - thumbnail.bottom;
  }

  testWidgets('landscape pages do not leave a void above the page number', (
    tester,
  ) async {
    // 16:9 slides.
    await pumpStrip(tester, List<double?>.filled(4, 9 / 16));

    expect(gapUnderFirstThumbnail(tester), lessThan(12));
  });

  testWidgets('portrait pages stay tightly laid out too', (tester) async {
    await pumpStrip(tester, List<double?>.filled(4, 842 / 595));

    expect(gapUnderFirstThumbnail(tester), lessThan(12));
  });

  testWidgets('a mixed document sizes tiles to its tallest page', (
    tester,
  ) async {
    // One portrait page among landscape ones: every tile has to clear the
    // tallest thumbnail, so only the shorter ones can have slack.
    await pumpStrip(tester, <double?>[9 / 16, 842 / 595, 9 / 16]);

    final tallestThumbnail = tester.getRect(find.byType(AspectRatio).at(1));
    final tallestLabel = tester.getRect(find.text('2'));
    expect(tallestLabel.top - tallestThumbnail.bottom, lessThan(12));
  });
}
