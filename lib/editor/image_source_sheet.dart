import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:photo_manager/photo_manager.dart';

sealed class InsertImageSourceResult {
  const InsertImageSourceResult();
}

final class GalleryImageSourceResult extends InsertImageSourceResult {
  const GalleryImageSourceResult({required this.bytes, this.name});

  final Uint8List bytes;
  final String? name;
}

final class CameraImageSourceResult extends InsertImageSourceResult {
  const CameraImageSourceResult();
}

final class FilesImageSourceResult extends InsertImageSourceResult {
  const FilesImageSourceResult();
}

enum PhotoLibraryAccess { authorized, limited, denied }

@immutable
class PhotoLibraryAsset {
  const PhotoLibraryAsset({required this.id, required this.source, this.name});

  final String id;
  final Object source;
  final String? name;
}

@immutable
class PhotoLibraryPage {
  const PhotoLibraryPage({required this.assets, required this.hasMore});

  final List<PhotoLibraryAsset> assets;
  final bool hasMore;
}

abstract interface class PhotoLibraryGateway {
  Future<PhotoLibraryAccess> requestAccess();

  Future<PhotoLibraryPage> loadPage({required int page, required int size});

  Future<Uint8List?> loadThumbnail(PhotoLibraryAsset asset, int size);

  Future<Uint8List?> loadOriginal(PhotoLibraryAsset asset);

  Future<void> manageLimitedAccess();

  Future<void> openSettings();
}

class PhotoManagerLibraryGateway implements PhotoLibraryGateway {
  static const _permissionRequest = PermissionRequestOption(
    iosAccessLevel: IosAccessLevel.readWrite,
    androidPermission: AndroidPermission(
      type: RequestType.image,
      mediaLocation: false,
    ),
  );

  AssetPathEntity? _allPhotos;

  @override
  Future<PhotoLibraryAccess> requestAccess() async {
    final state = await PhotoManager.requestPermissionExtend(
      requestOption: _permissionRequest,
    );
    if (state.isAuth) return PhotoLibraryAccess.authorized;
    if (state.hasAccess) return PhotoLibraryAccess.limited;
    return PhotoLibraryAccess.denied;
  }

  Future<AssetPathEntity?> _photoPath() async {
    final existing = _allPhotos;
    if (existing != null) return existing;
    final paths = await PhotoManager.getAssetPathList(
      onlyAll: true,
      type: RequestType.image,
    );
    if (paths.isEmpty) return null;
    return _allPhotos = paths.first;
  }

  @override
  Future<PhotoLibraryPage> loadPage({
    required int page,
    required int size,
  }) async {
    final path = await _photoPath();
    if (path == null) {
      return const PhotoLibraryPage(assets: [], hasMore: false);
    }
    final total = await path.assetCountAsync;
    final entities = await path.getAssetListPaged(
      page: page,
      size: size,
      type: RequestType.image,
    );
    return PhotoLibraryPage(
      assets: entities
          .map(
            (asset) => PhotoLibraryAsset(
              id: asset.id,
              source: asset,
              name: asset.title,
            ),
          )
          .toList(growable: false),
      hasMore: (page + 1) * size < total && entities.isNotEmpty,
    );
  }

  AssetEntity _entity(PhotoLibraryAsset asset) => asset.source as AssetEntity;

  @override
  Future<Uint8List?> loadThumbnail(PhotoLibraryAsset asset, int size) {
    return _entity(
      asset,
    ).thumbnailDataWithSize(ThumbnailSize.square(size), quality: 84);
  }

  @override
  Future<Uint8List?> loadOriginal(PhotoLibraryAsset asset) {
    return _entity(asset).originBytes;
  }

  @override
  Future<void> manageLimitedAccess() async {
    await PhotoManager.presentLimited(type: RequestType.image);
    _allPhotos = null;
  }

  @override
  Future<void> openSettings() => PhotoManager.openSetting();
}

Future<InsertImageSourceResult?> showImageSourceSheet(
  BuildContext context, {
  PhotoLibraryGateway? library,
}) {
  final screen = MediaQuery.sizeOf(context);
  final topInset = math.min(112.0, math.max(72.0, screen.height * .13));
  final maximumHeight = math.max(320.0, screen.height - topInset - 24);
  // Sized to show a 3x3 grid of thumbnails, like an iOS popover: big enough
  // to browse, small enough that the page stays visible behind it.
  const width = 360.0;
  const height = 476.0;
  return showGeneralDialog<InsertImageSourceResult>(
    context: context,
    barrierDismissible: true,
    barrierLabel: 'Close image picker',
    barrierColor: Colors.black.withValues(alpha: .12),
    transitionDuration: const Duration(milliseconds: 180),
    pageBuilder: (context, _, _) => SafeArea(
      child: Align(
        alignment: Alignment.topCenter,
        child: Padding(
          padding: EdgeInsets.fromLTRB(16, topInset, 16, 16),
          child: SizedBox(
            width: math.min(width, math.max(280, screen.width - 32)),
            height: math.min(height, maximumHeight),
            child: ImageSourceSheet(
              library: library ?? PhotoManagerLibraryGateway(),
            ),
          ),
        ),
      ),
    ),
    transitionBuilder: (context, animation, _, child) {
      final curved = CurvedAnimation(
        parent: animation,
        curve: Curves.easeOutCubic,
        reverseCurve: Curves.easeInCubic,
      );
      return FadeTransition(
        opacity: curved,
        child: ScaleTransition(
          scale: Tween(begin: .97, end: 1.0).animate(curved),
          alignment: Alignment.topCenter,
          child: child,
        ),
      );
    },
  );
}

class ImageSourceSheet extends StatefulWidget {
  const ImageSourceSheet({super.key, required this.library});

  final PhotoLibraryGateway library;

  @override
  State<ImageSourceSheet> createState() => _ImageSourceSheetState();
}

class _ImageSourceSheetState extends State<ImageSourceSheet>
    with WidgetsBindingObserver {
  static const _pageSize = 80;

  final ScrollController _scrollController = ScrollController();
  final List<PhotoLibraryAsset> _assets = [];
  PhotoLibraryAccess? _access;
  bool _initializing = false;
  bool _loadingMore = false;
  bool _hasMore = true;
  int _nextPage = 0;
  String? _error;
  String? _loadingAssetId;

  bool get _hasAccess =>
      _access == PhotoLibraryAccess.authorized ||
      _access == PhotoLibraryAccess.limited;

  bool get _cameraAvailable =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.iOS ||
          defaultTargetPlatform == TargetPlatform.android);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _scrollController.addListener(_handleScroll);
    unawaited(_initialize());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed &&
        _access == PhotoLibraryAccess.denied &&
        !_initializing) {
      unawaited(_initialize());
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _scrollController
      ..removeListener(_handleScroll)
      ..dispose();
    super.dispose();
  }

  void _handleScroll() {
    if (_scrollController.position.extentAfter < 360) {
      unawaited(_loadMore());
    }
  }

  Future<void> _initialize() async {
    if (_initializing) return;
    setState(() {
      _initializing = true;
      _error = null;
      _assets.clear();
      _nextPage = 0;
      _hasMore = true;
    });
    try {
      final access = await widget.library.requestAccess();
      if (!mounted) return;
      setState(() => _access = access);
      if (access == PhotoLibraryAccess.authorized ||
          access == PhotoLibraryAccess.limited) {
        await _loadMore();
      }
    } catch (_) {
      if (mounted) {
        setState(() => _error = 'Could not open the photo library.');
      }
    } finally {
      if (mounted) setState(() => _initializing = false);
    }
  }

  Future<void> _loadMore() async {
    if (!_hasAccess || _loadingMore || !_hasMore) return;
    setState(() => _loadingMore = true);
    try {
      final page = await widget.library.loadPage(
        page: _nextPage,
        size: _pageSize,
      );
      if (!mounted) return;
      setState(() {
        final knownIds = _assets.map((asset) => asset.id).toSet();
        _assets.addAll(
          page.assets.where((asset) => !knownIds.contains(asset.id)),
        );
        _nextPage++;
        _hasMore = page.hasMore;
        _error = null;
      });
    } catch (_) {
      if (mounted) {
        setState(() {
          _error = 'Could not load photos.';
          _hasMore = false;
        });
      }
    } finally {
      if (mounted) setState(() => _loadingMore = false);
    }
  }

  Future<void> _selectAsset(PhotoLibraryAsset asset) async {
    if (_loadingAssetId != null) return;
    setState(() {
      _loadingAssetId = asset.id;
      _error = null;
    });
    try {
      final bytes = await widget.library.loadOriginal(asset);
      if (!mounted) return;
      if (bytes == null || bytes.isEmpty) {
        setState(() {
          _loadingAssetId = null;
          _error = 'This photo could not be downloaded.';
        });
        return;
      }
      Navigator.of(
        context,
      ).pop(GalleryImageSourceResult(bytes: bytes, name: asset.name));
    } catch (_) {
      if (mounted) {
        setState(() {
          _loadingAssetId = null;
          _error = 'This photo could not be opened.';
        });
      }
    }
  }

  Future<void> _manageLimitedAccess() async {
    try {
      await widget.library.manageLimitedAccess();
      if (mounted) await _initialize();
    } catch (_) {
      if (mounted) {
        setState(() => _error = 'Could not update photo access.');
      }
    }
  }

  Future<void> _openSettings() async {
    try {
      await widget.library.openSettings();
    } catch (_) {
      if (mounted) {
        setState(() => _error = 'Could not open Settings.');
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Stack(
      fit: StackFit.expand,
      clipBehavior: Clip.none,
      children: [
        Positioned(
          top: 1,
          left: 0,
          right: 0,
          child: Center(
            child: Transform.rotate(
              angle: math.pi / 4,
              child: Container(
                width: 22,
                height: 22,
                decoration: BoxDecoration(
                  color: scheme.surface,
                  border: Border.all(color: Theme.of(context).dividerColor),
                ),
              ),
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.only(top: 10),
          // Material both supplies the surface styling and gives descendant
          // Text widgets a DefaultTextStyle. showGeneralDialog does not add
          // one, and without it plain Text renders in the red-on-yellow
          // "missing style" debug form.
          child: Material(
            color: scheme.surface,
            elevation: 12,
            shadowColor: Colors.black.withValues(alpha: .28),
            clipBehavior: Clip.antiAlias,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(22),
              side: BorderSide(color: Theme.of(context).dividerColor),
            ),
            child: Column(
              children: [
                _SheetHeader(
                  onCamera: _cameraAvailable
                      ? () => Navigator.of(
                          context,
                        ).pop(const CameraImageSourceResult())
                      : null,
                ),
                Divider(height: 1, color: Theme.of(context).dividerColor),
                Expanded(child: _buildBody(context)),
                Divider(height: 1, color: Theme.of(context).dividerColor),
                _SheetFooterAction(
                  onPressed: () => Navigator.of(
                    context,
                  ).pop(const FilesImageSourceResult()),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildBody(BuildContext context) {
    if (_initializing && _assets.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_access == PhotoLibraryAccess.denied) {
      return _PhotoAccessMessage(error: _error, onOpenSettings: _openSettings);
    }
    if (_error != null && _assets.isEmpty) {
      return _PhotoLoadError(error: _error!, onRetry: _initialize);
    }
    if (_assets.isEmpty) {
      return _EmptyPhotoLibrary(
        limited: _access == PhotoLibraryAccess.limited,
        onManage: _manageLimitedAccess,
      );
    }

    return Column(
      children: [
        if (_access == PhotoLibraryAccess.limited)
          _LimitedAccessBanner(onManage: _manageLimitedAccess),
        if (_error != null)
          _InlinePhotoError(message: _error!, onRetry: _initialize),
        Expanded(
          child: GridView.builder(
            controller: _scrollController,
            padding: const EdgeInsets.all(14),
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 3,
              crossAxisSpacing: 8,
              mainAxisSpacing: 8,
            ),
            itemCount: _assets.length + (_loadingMore ? 1 : 0),
            itemBuilder: (context, index) {
              if (index >= _assets.length) {
                return const Center(
                  child: SizedBox(
                    width: 22,
                    height: 22,
                    child: CircularProgressIndicator(strokeWidth: 2.5),
                  ),
                );
              }
              final asset = _assets[index];
              return _PhotoTile(
                key: ValueKey('gallery-${asset.id}'),
                asset: asset,
                library: widget.library,
                loading: _loadingAssetId == asset.id,
                onTap: () => unawaited(_selectAsset(asset)),
              );
            },
          ),
        ),
      ],
    );
  }
}

/// Compact iOS-style header: the title stays optically centred because the
/// leading spacer matches the trailing action's width, and the row is forced
/// to full width so the action cannot drift inward over the title.
class _SheetHeader extends StatelessWidget {
  const _SheetHeader({required this.onCamera});

  final VoidCallback? onCamera;

  static const double _actionExtent = 48;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: double.infinity,
      height: 50,
      child: Row(
        children: [
          const SizedBox(width: _actionExtent),
          const Expanded(
            child: Text(
              'Images',
              textAlign: TextAlign.center,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 17,
                fontWeight: FontWeight.w600,
                letterSpacing: -.2,
              ),
            ),
          ),
          SizedBox(
            width: _actionExtent,
            child: onCamera == null
                ? null
                : IconButton(
                    key: const ValueKey('image-source-camera'),
                    tooltip: 'Take photo',
                    onPressed: onCamera,
                    iconSize: 21,
                    icon: const Icon(Icons.photo_camera_outlined),
                  ),
          ),
        ],
      ),
    );
  }
}

/// Full-width tappable row in place of a floating button, matching how iOS
/// action sheets present a trailing choice.
class _SheetFooterAction extends StatelessWidget {
  const _SheetFooterAction({required this.onPressed});

  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return InkWell(
      key: const ValueKey('image-source-files'),
      onTap: onPressed,
      child: SizedBox(
        height: 52,
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.folder_open_rounded, size: 20, color: scheme.primary),
            const SizedBox(width: 8),
            Text(
              'More…',
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w600,
                color: scheme.primary,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _PhotoTile extends StatefulWidget {
  const _PhotoTile({
    super.key,
    required this.asset,
    required this.library,
    required this.loading,
    required this.onTap,
  });

  final PhotoLibraryAsset asset;
  final PhotoLibraryGateway library;
  final bool loading;
  final VoidCallback onTap;

  @override
  State<_PhotoTile> createState() => _PhotoTileState();
}

class _PhotoTileState extends State<_PhotoTile> {
  late Future<Uint8List?> _thumbnail;

  @override
  void initState() {
    super.initState();
    _thumbnail = widget.library.loadThumbnail(widget.asset, 320);
  }

  @override
  void didUpdateWidget(covariant _PhotoTile oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.asset.id != widget.asset.id ||
        oldWidget.library != widget.library) {
      _thumbnail = widget.library.loadThumbnail(widget.asset, 320);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.surfaceContainerHighest,
      borderRadius: BorderRadius.circular(12),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: widget.loading ? null : widget.onTap,
        child: Stack(
          fit: StackFit.expand,
          children: [
            FutureBuilder<Uint8List?>(
              future: _thumbnail,
              builder: (context, snapshot) {
                final bytes = snapshot.data;
                if (bytes == null || bytes.isEmpty) {
                  return Icon(
                    Icons.image_outlined,
                    size: 34,
                    color: scheme.onSurfaceVariant,
                  );
                }
                return Image.memory(
                  bytes,
                  fit: BoxFit.cover,
                  gaplessPlayback: true,
                  filterQuality: FilterQuality.low,
                  errorBuilder: (_, _, _) => Icon(
                    Icons.broken_image_outlined,
                    color: scheme.onSurfaceVariant,
                  ),
                );
              },
            ),
            if (widget.loading)
              ColoredBox(
                color: Colors.black.withValues(alpha: .34),
                child: const Center(
                  child: CircularProgressIndicator(color: Colors.white),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _LimitedAccessBanner extends StatelessWidget {
  const _LimitedAccessBanner({required this.onManage});

  final VoidCallback onManage;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      margin: const EdgeInsets.fromLTRB(18, 12, 18, 0),
      padding: const EdgeInsets.fromLTRB(14, 8, 8, 8),
      decoration: BoxDecoration(
        color: scheme.secondaryContainer.withValues(alpha: .65),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        children: [
          Icon(
            Icons.photo_library_outlined,
            color: scheme.onSecondaryContainer,
          ),
          const SizedBox(width: 10),
          const Expanded(child: Text('Showing selected photos only')),
          TextButton(onPressed: onManage, child: const Text('Manage')),
        ],
      ),
    );
  }
}

class _InlinePhotoError extends StatelessWidget {
  const _InlinePhotoError({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      margin: const EdgeInsets.fromLTRB(18, 10, 18, 0),
      padding: const EdgeInsets.fromLTRB(14, 8, 8, 8),
      decoration: BoxDecoration(
        color: scheme.errorContainer,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        children: [
          Icon(Icons.error_outline_rounded, color: scheme.onErrorContainer),
          const SizedBox(width: 10),
          Expanded(child: Text(message)),
          TextButton(onPressed: onRetry, child: const Text('Retry')),
        ],
      ),
    );
  }
}

class _PhotoAccessMessage extends StatelessWidget {
  const _PhotoAccessMessage({
    required this.error,
    required this.onOpenSettings,
  });

  final String? error;
  final VoidCallback onOpenSettings;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) => SingleChildScrollView(
        padding: const EdgeInsets.all(28),
        child: ConstrainedBox(
          constraints: BoxConstraints(
            minHeight: math.max(0, constraints.maxHeight - 56),
          ),
          child: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.photo_library_outlined, size: 52),
                const SizedBox(height: 14),
                const Text(
                  'Allow access to photos',
                  style: TextStyle(fontSize: 19, fontWeight: FontWeight.w800),
                ),
                const SizedBox(height: 8),
                Text(
                  error ??
                      'Photo access is needed to show your recent images here. You can still use More… to choose an image from Files.',
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 18),
                FilledButton.icon(
                  key: const ValueKey('image-source-settings'),
                  onPressed: onOpenSettings,
                  icon: const Icon(Icons.settings_outlined),
                  label: const Text('Open Settings'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _PhotoLoadError extends StatelessWidget {
  const _PhotoLoadError({required this.error, required this.onRetry});

  final String error;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) => SingleChildScrollView(
        padding: const EdgeInsets.all(28),
        child: ConstrainedBox(
          constraints: BoxConstraints(
            minHeight: math.max(0, constraints.maxHeight - 56),
          ),
          child: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.broken_image_outlined, size: 48),
                const SizedBox(height: 12),
                Text(error, textAlign: TextAlign.center),
                const SizedBox(height: 16),
                OutlinedButton.icon(
                  onPressed: onRetry,
                  icon: const Icon(Icons.refresh_rounded),
                  label: const Text('Try again'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _EmptyPhotoLibrary extends StatelessWidget {
  const _EmptyPhotoLibrary({required this.limited, required this.onManage});

  final bool limited;
  final VoidCallback onManage;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) => SingleChildScrollView(
        padding: const EdgeInsets.all(28),
        child: ConstrainedBox(
          constraints: BoxConstraints(
            minHeight: math.max(0, constraints.maxHeight - 56),
          ),
          child: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.photo_outlined, size: 48),
                const SizedBox(height: 12),
                Text(
                  limited
                      ? 'No selected photos are available.'
                      : 'No photos found.',
                  textAlign: TextAlign.center,
                ),
                if (limited) ...[
                  const SizedBox(height: 14),
                  OutlinedButton(
                    onPressed: onManage,
                    child: const Text('Choose Photos'),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
