import 'dart:async';
import 'dart:collection';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:pdfx/pdfx.dart';

/// Displays a page from the original PDF while keeping only a small adaptive
/// raster cache in memory. The original PDF remains the source of truth; the
/// bitmap is only a screen texture and is recreated at a higher resolution
/// after zooming.
class AdaptivePdfPage extends StatefulWidget {
  const AdaptivePdfPage({
    super.key,
    required this.pdfPath,
    required this.pageNumber,
    required this.enabled,
    this.quality = 1,
    this.renderScale = 1,
    this.fit = BoxFit.contain,
  });

  final String pdfPath;
  final int pageNumber;
  final bool enabled;
  final double quality;
  final double renderScale;
  final BoxFit fit;

  @override
  State<AdaptivePdfPage> createState() => _AdaptivePdfPageState();
}

class _AdaptivePdfPageState extends State<AdaptivePdfPage> {
  Uint8List? _bytes;
  String? _requestKey;
  int _requestId = 0;

  void _request({
    required int width,
    required int height,
  }) {
    final key = '${widget.pdfPath}|${widget.pageNumber}|$width|$height';
    if (_requestKey == key) return;
    _requestKey = key;
    final requestId = ++_requestId;
    unawaited(
      PdfRasterCache.instance
          .render(
            path: widget.pdfPath,
            pageNumber: widget.pageNumber,
            width: width,
            height: height,
          )
          .then((value) {
        if (!mounted || requestId != _requestId || value == null) return;
        setState(() => _bytes = value);
      }),
    );
  }


  @override
  void didUpdateWidget(covariant AdaptivePdfPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    final sourceChanged = oldWidget.pdfPath != widget.pdfPath ||
        oldWidget.pageNumber != widget.pageNumber;
    if (sourceChanged) {
      _requestId++;
      _requestKey = null;
      _bytes = null;
    }
    // When a page leaves the preload window, keep its last texture. Clearing
    // it here produces a white flash when the page becomes visible again.
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        if (widget.enabled &&
            constraints.maxWidth.isFinite &&
            constraints.maxHeight.isFinite &&
            constraints.maxWidth > 0 &&
            constraints.maxHeight > 0) {
          final pixelRatio = MediaQuery.devicePixelRatioOf(context);
          final scale = widget.renderScale.clamp(.25, 4.0).toDouble();
          final quality = widget.quality.clamp(.15, 1.25).toDouble();
          final rawWidth = constraints.maxWidth * pixelRatio * scale * quality;
          final rawHeight = constraints.maxHeight * pixelRatio * scale * quality;
          final longest = rawWidth > rawHeight ? rawWidth : rawHeight;
          final capScale = longest > 4600 ? 4600 / longest : 1.0;
          final width = (rawWidth * capScale)
              .round()
              .clamp(96, 4600)
              .toInt();
          final height = (rawHeight * capScale)
              .round()
              .clamp(96, 4600)
              .toInt();
          _request(width: width, height: height);
        }

        final bytes = _bytes;
        if (bytes == null) {
          return const ColoredBox(color: Colors.white);
        }
        return Image.memory(
          bytes,
          fit: widget.fit,
          gaplessPlayback: true,
          filterQuality: FilterQuality.high,
          errorBuilder: (_, _, _) => const ColoredBox(color: Colors.white),
        );
      },
    );
  }
}

class PdfRasterCache {
  PdfRasterCache._();

  static final PdfRasterCache instance = PdfRasterCache._();

  static const int _maximumBytes = 64 * 1024 * 1024;
  static const int _dimensionStep = 128;

  final Map<String, Future<PdfDocument>> _documents = {};
  final Map<String, Future<Uint8List?>> _pending = {};
  final Map<String, Future<void>> _documentQueues = {};
  final LinkedHashMap<String, Uint8List> _cache = LinkedHashMap();
  int _cachedBytes = 0;

  int _bucket(int value) {
    final safe = value.clamp(96, 4600).toInt();
    return ((safe + _dimensionStep - 1) ~/ _dimensionStep) * _dimensionStep;
  }

  Future<Uint8List?> render({
    required String path,
    required int pageNumber,
    required int width,
    required int height,
  }) {
    final bucketWidth = _bucket(width);
    final bucketHeight = _bucket(height);
    final key = '$path|$pageNumber|$bucketWidth|$bucketHeight';
    final cached = _cache.remove(key);
    if (cached != null) {
      _cache[key] = cached;
      return Future.value(cached);
    }
    final existing = _pending[key];
    if (existing != null) return existing;

    final completer = Completer<Uint8List?>();
    final previous = _documentQueues[path] ?? Future<void>.value();
    final queued = previous.catchError((Object _) {}).then<void>((_) async {
      try {
        final document = await (_documents[path] ??=
            PdfDocument.openFile(path));
        if (pageNumber < 1 || pageNumber > document.pagesCount) {
          completer.complete(null);
          return;
        }
        final page = await document.getPage(pageNumber);
        try {
          final rendered = await page.render(
            width: bucketWidth.toDouble(),
            height: bucketHeight.toDouble(),
            format: PdfPageImageFormat.png,
            backgroundColor: '#FFFFFF',
          );
          final bytes = rendered?.bytes;
          if (bytes == null) {
            completer.complete(null);
            return;
          }
          _insert(key, bytes);
          completer.complete(bytes);
        } finally {
          await page.close();
        }
      } catch (_) {
        _documents.remove(path);
        completer.complete(null);
      }
    });
    late final Future<void> queueFuture;
    queueFuture = queued.whenComplete(() {
      if (identical(_documentQueues[path], queueFuture)) {
        _documentQueues.remove(path);
      }
    });
    _documentQueues[path] = queueFuture;
    final future = completer.future;
    _pending[key] = future;
    unawaited(future.whenComplete(() => _pending.remove(key)));
    return future;
  }

  void _insert(String key, Uint8List bytes) {
    final previous = _cache.remove(key);
    if (previous != null) _cachedBytes -= previous.lengthInBytes;
    _cache[key] = bytes;
    _cachedBytes += bytes.lengthInBytes;
    while (_cachedBytes > _maximumBytes && _cache.isNotEmpty) {
      final oldestKey = _cache.keys.first;
      final removed = _cache.remove(oldestKey);
      if (removed != null) _cachedBytes -= removed.lengthInBytes;
    }
  }
}
