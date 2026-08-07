import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Displays exactly one PDF page via a native, non-interactive PDFView.
/// Resizing this widget's logical width/height makes PDFKit lay out and
/// rasterize fresh at that resolution, instead of stretching a fixed-size
/// texture the way AdaptivePdfPage's raster fallback does — see
/// editor_screen.dart's usage for how the size is driven without
/// double-applying InteractiveViewer's own zoom.
///
/// Display only: no touch handling, no ink, no annotations. Ink stays
/// entirely in the Flutter InkPainter layer drawn on top by the caller.
class NativePdfPageDisplay extends StatelessWidget {
  const NativePdfPageDisplay({
    super.key,
    required this.path,
    required this.pageNumber,
  });

  static const String viewType = 'ink_note/native_pdf_page_display';

  final String path;
  final int pageNumber;

  @override
  Widget build(BuildContext context) {
    return UiKitView(
      viewType: viewType,
      creationParams: <String, Object>{
        'path': path,
        'pageNumber': pageNumber,
      },
      creationParamsCodec: const StandardMessageCodec(),
    );
  }
}
