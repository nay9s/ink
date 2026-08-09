import 'package:flutter/rendering.dart';
import 'package:pdfrx/pdfrx.dart';

/// Lets the viewer zoom out past "fit page" so a page never has to sit edge
/// to edge against the viewport.
///
/// pdfrx's default minimum zoom is the fit-page scale,
/// `min(viewWidth / pageWidth, viewHeight / pageHeight)`. Which term wins
/// decides whether any background is visible at minimum zoom: a portrait page
/// in a landscape viewport is height-limited, so the leftover width shows as
/// background, while a landscape slide is width-limited and fills the
/// viewport exactly with nothing around it. Allowing a little zoom-out below
/// fit gives every page the same framed look and matches how PDF readers
/// normally behave.
class PdfZoomOutSizeDelegateProvider extends PdfViewerSizeDelegateProvider {
  const PdfZoomOutSizeDelegateProvider({this.minScaleFactor = .8});

  /// Fraction of the fit-page scale allowed as the minimum zoom. At .8 the
  /// page can shrink to 80% of the viewport's limiting dimension, leaving
  /// roughly a tenth of it as background on each side.
  final double minScaleFactor;

  @override
  PdfViewerSizeDelegate create() =>
      PdfZoomOutSizeDelegate(minScaleFactor: minScaleFactor);

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is PdfZoomOutSizeDelegateProvider &&
          other.minScaleFactor == minScaleFactor;

  @override
  int get hashCode => minScaleFactor.hashCode;
}

class PdfZoomOutSizeDelegate extends PdfViewerSizeDelegateLegacy {
  PdfZoomOutSizeDelegate({required this.minScaleFactor})
    : super(
        maxScale: 8,
        minScale: .1,
        useAlternativeFitScaleAsMinScale: true,
        onePassRenderingScaleThreshold: 200 / 72,
        calculateInitialZoom: null,
      );

  final double minScaleFactor;

  @override
  PdfViewerLayoutMetrics calculateMetrics({
    required Size viewSize,
    required PdfPageLayout? layout,
    required int? pageNumber,
    required double pageMargin,
    required EdgeInsets? boundaryMargin,
  }) {
    final metrics = super.calculateMetrics(
      viewSize: viewSize,
      layout: layout,
      pageNumber: pageNumber,
      pageMargin: pageMargin,
      boundaryMargin: boundaryMargin,
    );
    final factor = minScaleFactor.isFinite && minScaleFactor > 0
        ? minScaleFactor.clamp(.1, 1.0).toDouble()
        : 1.0;
    // coverScale and alternativeFitScale are left untouched, so the document
    // still opens at fit and only the floor moves.
    return PdfViewerLayoutMetrics(
      minScale: metrics.minScale * factor,
      maxScale: metrics.maxScale,
      coverScale: metrics.coverScale,
      alternativeFitScale: metrics.alternativeFitScale,
    );
  }
}
