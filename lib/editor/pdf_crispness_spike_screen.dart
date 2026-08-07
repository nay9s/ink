import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:pdfx/pdfx.dart';

import 'adaptive_pdf_page.dart';
import 'pdf_crispness_spike_view.dart';

/// Temporary — throwaway side-by-side comparison to answer one question:
/// does resizing a native PDFView's frame keep it sharp under zoom, where
/// the current raster fallback (AdaptivePdfPage) visibly softens? Not part
/// of the normal note-taking flow. Delete this screen, its settings entry
/// point, pdf_crispness_spike_view.dart, and the matching native code in
/// AppDelegate.swift once the question is answered.
class PdfCrispnessSpikeScreen extends StatefulWidget {
  const PdfCrispnessSpikeScreen({super.key});

  @override
  State<PdfCrispnessSpikeScreen> createState() =>
      _PdfCrispnessSpikeScreenState();
}

class _PdfCrispnessSpikeScreenState extends State<PdfCrispnessSpikeScreen> {
  static const double _baseWidth = 320;

  String? _pdfPath;
  double _pageAspectRatio = 1.4142; // A4 portrait fallback until measured.
  double _zoom = 1;
  bool _loading = false;

  Future<void> _pickPdf() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: const ['pdf'],
      allowMultiple: false,
    );
    final path = result?.files.single.path;
    if (path == null || !mounted) return;

    setState(() => _loading = true);
    var aspectRatio = _pageAspectRatio;
    try {
      final document = await PdfDocument.openFile(path);
      try {
        final page = await document.getPage(1);
        if (page.width > 0) aspectRatio = page.height / page.width;
        await page.close();
      } finally {
        await document.close();
      }
    } catch (_) {
      // Keep the fallback aspect ratio if the page couldn't be measured.
    }
    if (!mounted) return;
    setState(() {
      _pdfPath = path;
      _pageAspectRatio = aspectRatio;
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final baseHeight = _baseWidth * _pageAspectRatio;
    final path = _pdfPath;

    return Scaffold(
      appBar: AppBar(
        title: const Text('PDF crispness spike (temporary)'),
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            children: [
              FilledButton.icon(
                onPressed: _loading ? null : _pickPdf,
                icon: const Icon(Icons.picture_as_pdf_outlined),
                label: Text(path == null ? 'Pick a PDF' : 'Pick a different PDF'),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  const Text('Zoom'),
                  Expanded(
                    child: Slider(
                      value: _zoom,
                      min: 1,
                      max: 4,
                      divisions: 30,
                      label: '${_zoom.toStringAsFixed(2)}x',
                      onChanged: path == null
                          ? null
                          : (value) => setState(() => _zoom = value),
                    ),
                  ),
                  SizedBox(
                    width: 48,
                    child: Text('${_zoom.toStringAsFixed(2)}x'),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              if (path == null)
                const Expanded(
                  child: Center(child: Text('Pick a PDF to compare.')),
                )
              else
                Expanded(
                  child: SingleChildScrollView(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        const Text(
                          'Panel A — today (fixed-resolution raster, '
                          'GPU-stretched by the zoom slider)',
                          style: TextStyle(fontWeight: FontWeight.bold),
                        ),
                        const SizedBox(height: 8),
                        Center(
                          child: ClipRect(
                            child: Transform.scale(
                              scale: _zoom,
                              alignment: Alignment.topCenter,
                              child: SizedBox(
                                width: _baseWidth,
                                height: baseHeight,
                                child: AdaptivePdfPage(
                                  pdfPath: path,
                                  pageNumber: 1,
                                  enabled: true,
                                  quality: 1,
                                  renderScale: 1,
                                ),
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(height: 24),
                        const Text(
                          'Panel B — candidate (native PDFView, actually '
                          'resized as the zoom slider moves)',
                          style: TextStyle(fontWeight: FontWeight.bold),
                        ),
                        const SizedBox(height: 8),
                        Center(
                          child: SizedBox(
                            width: _baseWidth * _zoom,
                            height: baseHeight * _zoom,
                            child: PdfCrispnessSpikeView(
                              path: path,
                              pageNumber: 1,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
