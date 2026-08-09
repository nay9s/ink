import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ink_note/editor/pdf_zoom_out_size_delegate.dart';
import 'package:pdfrx/pdfrx.dart';

void main() {
  // A landscape viewport, as an iPad in the editor.
  const viewSize = Size(1000, 700);

  PdfViewerLayoutMetrics metricsFor(Size pageSize, {double factor = .8}) {
    final page = Rect.fromLTWH(0, 0, pageSize.width, pageSize.height);
    return PdfZoomOutSizeDelegate(minScaleFactor: factor).calculateMetrics(
      viewSize: viewSize,
      layout: PdfPageLayout(
        pageLayouts: <Rect>[page],
        documentSize: pageSize,
      ),
      pageNumber: 1,
      pageMargin: 8,
      boundaryMargin: null,
    );
  }

  test('a landscape page can zoom out below fit', () {
    // Wider than the viewport's aspect, so fit is width-limited and the page
    // would otherwise touch both edges at minimum zoom.
    final metrics = metricsFor(const Size(1600, 900));
    final fit = metrics.alternativeFitScale!;

    expect(metrics.minScale, lessThan(fit));
    expect(metrics.minScale, closeTo(fit * .8, 1e-9));

    // At minimum zoom the page leaves background on the limiting axis.
    expect(1600 * metrics.minScale, lessThan(viewSize.width));
  });

  test('a portrait page keeps its fit scale as the opening zoom', () {
    final metrics = metricsFor(const Size(595, 842));

    // Only the floor moves; the scales the viewer opens at are untouched.
    expect(metrics.alternativeFitScale, closeTo(700 / (842 + 16), 1e-9));
    expect(metrics.minScale, closeTo(metrics.alternativeFitScale! * .8, 1e-9));
    expect(metrics.maxScale, 8);
  });

  test('a factor of one leaves the default fit floor untouched', () {
    final metrics = metricsFor(const Size(1600, 900), factor: 1);

    expect(metrics.minScale, closeTo(metrics.alternativeFitScale!, 1e-9));
  });

  test('providers with the same factor compare equal', () {
    const a = PdfZoomOutSizeDelegateProvider();
    const b = PdfZoomOutSizeDelegateProvider();
    const c = PdfZoomOutSizeDelegateProvider(minScaleFactor: .5);

    // PdfViewerParams uses equality to decide whether to rebuild the delegate.
    expect(a, b);
    expect(a.hashCode, b.hashCode);
    expect(a, isNot(c));
  });
}
