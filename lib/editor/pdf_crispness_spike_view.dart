import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Temporary — thin wrapper around the throwaway `PdfCrispnessSpikeView`
/// native platform view (see AppDelegate.swift). Display only, no touch
/// handling, no ink. Delete alongside the rest of the spike once the
/// crispness question it exists to answer is resolved.
class PdfCrispnessSpikeView extends StatelessWidget {
  const PdfCrispnessSpikeView({
    super.key,
    required this.path,
    required this.pageNumber,
  });

  static const String viewType = 'ink_note/pdf_crispness_spike';

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
