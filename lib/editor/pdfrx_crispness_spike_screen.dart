import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:pdfrx/pdfrx.dart';

/// Temporary — throwaway test of whether `pdfrx` solves, together, the two
/// things the earlier native-PDFView spike didn't fully answer: does the
/// page actually sharpen under pinch-zoom (not just stretch), and can a
/// custom-painted overlay stay pixel-aligned with the page throughout a
/// pan/zoom gesture?
///
/// `PdfViewerParams.pagePaintCallbacks` calls back with `(canvas, pageRect,
/// page)` from inside the viewer's own paint pass (confirmed by reading
/// pdfrx's source, pdf_viewer.dart) — the test overlay below is painted
/// through that same callback, standing in for what the real ink layer
/// would do. If both hold up on-device, this is worth migrating the real
/// editor to. Delete this screen, its settings entry, and the `pdfrx`
/// dependency if it doesn't pan out.
class PdfrxCrispnessSpikeScreen extends StatefulWidget {
  const PdfrxCrispnessSpikeScreen({super.key});

  @override
  State<PdfrxCrispnessSpikeScreen> createState() =>
      _PdfrxCrispnessSpikeScreenState();
}

class _PdfrxCrispnessSpikeScreenState
    extends State<PdfrxCrispnessSpikeScreen> {
  String? _pdfPath;

  Future<void> _pickPdf() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: const ['pdf'],
      allowMultiple: false,
    );
    final path = result?.files.single.path;
    if (path == null || !mounted) return;
    setState(() => _pdfPath = path);
  }

  void _paintTestOverlay(Canvas canvas, Rect pageRect, PdfPage page) {
    final border = Paint()
      ..color = Colors.redAccent
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3;
    canvas.drawRect(pageRect.deflate(1.5), border);

    final diagonal = Paint()
      ..color = Colors.blueAccent
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2;
    canvas.drawLine(pageRect.topLeft, pageRect.bottomRight, diagonal);
    canvas.drawLine(pageRect.topRight, pageRect.bottomLeft, diagonal);

    // A tick mark near each corner makes a lagging/drifting overlay far
    // more obvious under zoom than the border/diagonal alone.
    const tick = 16.0;
    final tickPaint = Paint()
      ..color = Colors.greenAccent
      ..style = PaintingStyle.stroke
      ..strokeWidth = 4;
    for (final corner in [
      pageRect.topLeft,
      pageRect.topRight,
      pageRect.bottomLeft,
      pageRect.bottomRight,
    ]) {
      canvas.drawCircle(corner, tick, tickPaint);
    }
  }

  @override
  Widget build(BuildContext context) {
    final path = _pdfPath;
    return Scaffold(
      appBar: AppBar(
        title: const Text('pdfrx crispness + overlay spike (temporary)'),
        actions: [
          IconButton(
            onPressed: _pickPdf,
            icon: const Icon(Icons.picture_as_pdf_outlined),
            tooltip: 'Pick a PDF',
          ),
        ],
      ),
      body: path == null
          ? Center(
              child: FilledButton.icon(
                onPressed: _pickPdf,
                icon: const Icon(Icons.picture_as_pdf_outlined),
                label: const Text('Pick a PDF'),
              ),
            )
          : PdfViewer.file(
              path,
              params: PdfViewerParams(
                pagePaintCallbacks: [_paintTestOverlay],
              ),
            ),
    );
  }
}
