// The purpose of this file is to create the main menu screen (this is part of the list of screens in the bottom navigation bar)
import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:jellybook/models/folder.dart';
import 'package:jellybook/providers/fetchCategories.dart';
import 'package:jellybook/screens/collectionScreen.dart';
import 'package:jellybook/screens/infoScreen.dart';
import 'package:isar/isar.dart';
import 'package:isar_flutter_libs/isar_flutter_libs.dart';
import 'package:jellybook/models/entry.dart';
import 'package:auto_size_text/auto_size_text.dart';
import 'package:jellybook/l10n/app_localizations.dart';
import 'package:jellybook/variables.dart';
import 'package:jellybook/widgets/jellybookImageCache.dart';
import 'package:infinite_scroll_pagination/infinite_scroll_pagination.dart';
import 'package:provider/provider.dart';
import 'package:jellybook/providers/connectionManager.dart';

class MainMenu extends StatefulWidget {
  @override
  _MainMenuState createState() => _MainMenuState();
}

class _MainMenuState extends State<MainMenu> with WidgetsBindingObserver {
  static const _pageSize = 20;
  late final PagingController<int, Entry> _pagingController =
      PagingController<int, Entry>(
    getNextPageKey: (state) {
      if (state.pages == null) return 0;
      final lastPage = state.pages!.last;
      if (lastPage.length < _pageSize) return null;
      return state.keys!.last + lastPage.length;
    },
    fetchPage: _fetchPage,
  );

  bool force = false;

  ConnectionManager? _connectionManager;
  bool _wasOffline = false;

  bool _errorModalShowing = false;
  List<Folder>? _lastFolders;
  final ScrollController _libraryScrollController = ScrollController();
  bool _inForeground = true;
  bool _warmScheduled = false;
  bool _warming = false;
  bool _warmAgain = false;
  String? _coverSignature;

  // Tell visible cards to recalculate progress after leaving a collection.
  final ValueNotifier<int> _progressRevision = ValueNotifier<int>(0);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _inForeground = state == AppLifecycleState.resumed;
    if (_inForeground) {
      // Decoded images can be reclaimed while Android has us backgrounded.
      // This also runs when Library is not the selected bottom tab.
      _scheduleCoverWarming();
    }
  }

  bool get _canWarm => mounted && _inForeground &&
      (ModalRoute.of(context)?.isCurrent ?? true);

  void _scheduleCoverWarming() {
    if (!mounted || !_inForeground || _lastFolders == null) return;
    if (_warming) {
      _warmAgain = true;
      return;
    }
    if (_warmScheduled) return;
    _warmScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _warmScheduled = false;
      if (_canWarm && _lastFolders != null) {
        unawaited(_warmVisibleCovers());
      }
    });
    // Ensure a callback is delivered even when resuming to an idle tab.
    WidgetsBinding.instance.scheduleFrame();
  }

  // Two-column grid: 8px outer padding, 6px gutters, 0.63 aspect ratio.
  // Prepare the onscreen rows and one adjacent row, not the entire library.
  ({int first, int end}) _visibleCoverRange(int count) {
    if (count == 0) return (first: 0, end: 0);
    if (!_libraryScrollController.hasClients) {
      return (first: 0, end: math.min(count, 10));
    }
    final viewport = _libraryScrollController.position.viewportDimension;
    final offset = _libraryScrollController.offset;
    final width = math.max(1.0, MediaQuery.sizeOf(context).width - 16);
    final tileWidth = (width - 6) / 2;
    final rowHeight = tileWidth / 0.63 + 6;
    final gridTop = MediaQuery.paddingOf(context).top + 48;
    final firstRow = math.max(0, ((offset - gridTop) / rowHeight).floor() - 1);
    final lastRow = math.max(firstRow + 1,
        ((offset + viewport - gridTop) / rowHeight).ceil() + 1);
    return (
      first: math.min(count, firstRow * 2),
      end: math.min(count, lastRow * 2),
    );
  }

  Future<void> _warmVisibleCovers() async {
    if (_warming || !_canWarm) return;
    _warmAgain = false;
    _warming = true;
    try {
      final folders = _lastFolders;
      if (folders == null) return;
      final range = _visibleCoverRange(folders.length);
      // At most two concurrent decodes, joining the exact same providers
      // used by SeriesCard. Avoid competing with navigation/reader work.
      for (var i = range.first; i < range.end && _canWarm; i += 2) {
        await Future.wait([
          for (var j = i; j < math.min(range.end, i + 2); j++)
            _warmCover(folders[j].image),
        ]);
      }
    } finally {
      _warming = false;
      if (_warmAgain && _canWarm) {
        _warmAgain = false;
        _scheduleCoverWarming();
      }
    }
  }

  Future<void> _warmCover(String path) async {
    if (!_canWarm) return;
    final provider = _libraryCoverProvider(path);
    if (provider == null) return;
    try {
      await precacheImage(provider, context, onError: (_, __) {});
    } catch (_) {
      // Offline, unreadable, or missing covers should not block others.
    }
  }

  void _onFoldersLoaded(List<Folder> folders) {
    // Don't prewarm again on progress-notifier rebuilds or tab switches.
    final signature = folders.map((f) => '${f.id}\u0000${f.image}').join('\u0001');
    if (signature == _coverSignature) return;
    _coverSignature = signature;
    _scheduleCoverWarming();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final manager = context.read<ConnectionManager>();
    if (_connectionManager != manager) {
      _connectionManager?.removeListener(_onConnectionChanged);
      _connectionManager = manager;
      _wasOffline = manager.status == ConnectionStatus.offline;
      manager.addListener(_onConnectionChanged);
    }
  }

  String _friendlyError(String error) {
    final e = error.toLowerCase();
    if (e.contains("socketexception") ||
        e.contains("connection") ||
        e.contains("timed out") ||
        e.contains("timeout") ||
        e.contains("host lookup")) {
      return AppLocalizations.of(context)?.serverNotFound ??
          "Could not reach the server. Please check your connection and try again.";
    }
    if (e.contains("401") || e.contains("unauthorized")) {
      return AppLocalizations.of(context)?.invalidCredentials ??
          "Your session has expired. Please log in again.";
    }
    return "Couldn't refresh the library. Please try again.";
  }

  void _onConnectionChanged() {
    final status = _connectionManager!.status;

    if (status == ConnectionStatus.offline) {
      _wasOffline = true;
    } else if (status == ConnectionStatus.online && _wasOffline) {
      // only refresh when we are coming back from being offline
      _wasOffline = false;
      if (mounted) {
        logger.d('MainMenu: connection restored, refreshing library');
        _pagingController.refresh();
        setState(() {
          force = true;
        });
      }
    }
  }

  Widget _buildGrid(List<Folder> folders) {
    return CustomScrollView(
      controller: _libraryScrollController,
      slivers: <Widget>[
        SliverToBoxAdapter(
          child: SizedBox(
            // match custom app bar: status/notch inset + compact bar content
            height: MediaQuery.of(context).padding.top + 40 + 8,
          ),
        ),
        SliverPadding(
          padding: const EdgeInsets.symmetric(horizontal: 8.0),
          sliver: SliverGrid(
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 2,
              childAspectRatio: 0.63,
              crossAxisSpacing: 6,
              mainAxisSpacing: 6,
            ),
            delegate: SliverChildBuilderDelegate(
              (context, index) {
                final folder = folders[index];
                return ValueListenableBuilder<int>(
                  valueListenable: _progressRevision,
                  builder: (context, _, __) => SeriesCard(
                    folder: folder,
                    onTap: () async {
                      await Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (context) => collectionScreen(
                            folderId: folder.id,
                            name: folder.name,
                            image: folder.image,
                            bookIds: folder.bookIds,
                          ),
                        ),
                      );
                      // Read saved progress from Isar, not from the server.
                      if (mounted) _progressRevision.value++;
                    },
                  ),
                );
              },
              childCount: folders.length,
            ),
          ),
        ),
        const SliverToBoxAdapter(child: SizedBox(height: 80)),
      ],
    );
  }

  Future<List<Entry>> _fetchPage(int pageKey) async {
    logger.i('pageKey: $pageKey');
    final result = await fetchEntries(pageKey, _pageSize);
    logger.i("result.\$1: ${result.$1}");
    return result.$2;
  }

  @override
  void dispose() {
    _inForeground = false;
    WidgetsBinding.instance.removeObserver(this);
    _libraryScrollController.dispose();
    _connectionManager?.removeListener(_onConnectionChanged);
    _progressRevision.dispose();
    _pagingController.dispose();
    super.dispose();
  }

  void _showErrorModal(BuildContext context, String error) {
    if (!mounted || _errorModalShowing) return;
    _errorModalShowing = true;

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (BuildContext dialogContext) {
        return AlertDialog(
          title: Text(
            AppLocalizations.of(context)?.error ?? "Error",
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.cloud_off,
                size: 48,
                color: Theme.of(context).colorScheme.error,
              ),
              const SizedBox(height: 16),
              Text(_friendlyError(error)),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () {
                Navigator.of(dialogContext).pop();
              },
              child: const Text("Dismiss"),
            ),
            ElevatedButton(
              onPressed: () {
                Navigator.of(dialogContext).pop();
                _pagingController.refresh();
                setState(() {
                  force = true;
                });
              },
              child: const Text("Retry"),
            ),
          ],
        );
      },
    ).then((_) => _errorModalShowing = false);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: PreferredSize(
        // Compact bar: only status/notch inset + 40px content (default AppBar is 56).
        preferredSize: Size.fromHeight(MediaQuery.of(context).padding.top + 36),
        child: Container(
          color: Colors.black.withOpacity(0.90),
          padding: EdgeInsets.only(top: MediaQuery.of(context).padding.top),
          child: SizedBox(
            height: 36,
            child: Stack(
              alignment: Alignment.center,
              children: [
                // On notched devices, pin title near the top (under the notch).
                // On flat status bars / tablets, keep equal top & bottom padding.
                Align(
                  alignment: MediaQuery.of(context).padding.top > 30
                      ? const Alignment(0, -0.7)
                      : Alignment.center,
                  child: Text(
                    AppLocalizations.of(context)?.library ?? "Library",
                    style: const TextStyle(
                      fontSize: 22,
                      fontWeight: FontWeight.bold,
                      color: Colors.white,
                    ),
                  ),
                ),
                // Connection status icon (right)
                Positioned(
                  right: 4,
                  child: Consumer<ConnectionManager>(
                    builder: (context, connectionManager, _) {
                      final status = connectionManager.status;

                      if (status == ConnectionStatus.offline) {
                        return IconButton(
                          icon: const Icon(Icons.cloud_off, color: Colors.white),
                          tooltip: 'Offline - tap to retry',
                          onPressed: () {
                            connectionManager.retry();
                          },
                        );
                      } else if (status == ConnectionStatus.validating) {
                        return const Padding(
                          padding: EdgeInsets.symmetric(horizontal: 16.0),
                          child: SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: Colors.white,
                            ),
                          ),
                        );
                      }

                      return const SizedBox.shrink();
                    },
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
      body: RefreshIndicator(
        onRefresh: () async {
          _pagingController.refresh();
          setState(() {
            force = true;
          });
        },
        child: FutureBuilder<(List<Entry>, List<Folder>)>(
          future: getServerCategories(force: force),
          builder: (context, AsyncSnapshot snapshot) {
            // while loading/refreshing, keep showing the last grid if we have one
            if (snapshot.connectionState != ConnectionState.done) {
              final cached = _lastFolders;
              return cached != null
                  ? _buildGrid(cached)
                  : const Center(child: CircularProgressIndicator());
            }

            if (snapshot.hasData && snapshot.data != null) {
              final List<Folder> folders = snapshot.data.$2 ?? <Folder>[];
              _lastFolders = folders;
              _onFoldersLoaded(folders);
              return _buildGrid(folders);
            }

            if (snapshot.hasError) {
              WidgetsBinding.instance.addPostFrameCallback((_) {
                _showErrorModal(context, snapshot.error.toString());
              });
              // fall back to the last grid, or whatever is cached in Isar
              final cached = _lastFolders ??
                  Isar.getInstance()?.folders.where().findAllSync();
              if (cached != null && cached.isNotEmpty) {
                _lastFolders = cached;
                _onFoldersLoaded(cached);
                return _buildGrid(cached);
              }
              return const Center(child: Icon(Icons.cloud_off, size: 48));
            }

            return const Center(child: Text("No data found"));
          },
        ),
      ),
    );
  }
}

class SeriesCard extends StatefulWidget {
  final Folder folder;
  final VoidCallback onTap;

  const SeriesCard({super.key, required this.folder, required this.onTap});

  @override
  State<SeriesCard> createState() => _SeriesCardState();
}

class _SeriesCardState extends State<SeriesCard> {
  static const double _imageRadius = 12;
  static const double _cardRadius = _imageRadius + 4 + 1.5;

  // Average progress across all books in the series
  double _calcProgress() {
    final isar = Isar.getInstance();
    if (isar == null || widget.folder.bookIds.isEmpty) return 0.0;
    final entries = isar.entrys
        .where()
        .filter()
        .anyOf(widget.folder.bookIds, (q, String id) => q.idEqualTo(id))
        .findAllSync();
    if (entries.isEmpty) return 0.0;
    // entry.progress is a percentage (0-100); return a 0-1 fraction
    final total = entries.fold<double>(0.0, (sum, e) => sum + e.progress);
    return (total / entries.length / 100).clamp(0.0, 1.0);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final folder = widget.folder; // added
    final progress = _calcProgress(); // added

    return GestureDetector(
      onTap: widget.onTap,
      child: Container(
        padding: const EdgeInsets.all(4),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(_cardRadius),
          border: Border.all(color: scheme.outlineVariant, width: 1.5),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Title lives in the card header, not on the image
            Padding(
              padding: const EdgeInsets.fromLTRB(4, 2, 4, 6),
              child: Row(
                children: [
                  Icon(Icons.chrome_reader_mode_outlined,
                      size: 22, color: scheme.primary),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      folder.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            // Clean cover with just a book-count pill
            Expanded(
              child: ClipRRect(
                borderRadius: BorderRadius.circular(_imageRadius),
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    _LibraryCover(path: folder.image),
                    Positioned(
                      bottom: 8,
                      right: 8,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 10, vertical: 5),
                        decoration: BoxDecoration(
                          color: Colors.black.withOpacity(0.75),
                          borderRadius: BorderRadius.circular(14),
                          border: Border.all(color: scheme.outlineVariant),
                        ),
                        child: Text(
                          '${folder.bookIds.length} ${folder.bookIds.length == 1 ? 'Book' : 'Books'}',
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ),
                    Positioned(
                      bottom: 8,
                      left: 8,
                      child: Container(
                        width: 28,
                        height: 28,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: Colors.black
                              .withOpacity(0.75), // matches the pill
                          border: Border.all(color: scheme.outlineVariant),
                        ),
                        child: Stack(
                          alignment: Alignment.center,
                          children: [
                            SizedBox(
                              width: 22,
                              height: 22,
                              child: CircularProgressIndicator(
                                value: progress,
                                strokeWidth: 2.5,
                                backgroundColor: Colors.white24,
                                valueColor: AlwaysStoppedAnimation<Color>(
                                    scheme.primary),
                              ),
                            ),
                            Text(
                              '${(progress * 100).round()}%',
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 8,
                                fontWeight: FontWeight.w700,
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
          ],
        ),
      ),
    );
  }
}

// A single provider factory for both the displayed cover and its precache.
// The shared manager also serves Collection/reader cover warmups.
ImageProvider? _libraryCoverProvider(String path) {
  if (path.isEmpty || path.toLowerCase() == 'asset') return null;
  if (path.contains('http')) {
    return CachedNetworkImageProvider(
      coverUrl(path),
      cacheManager: JellyBookCacheManager.instance,
    );
  }
  return FileImage(File(path));
}

class _LibraryCover extends StatelessWidget {
  const _LibraryCover({required this.path});

  final String path;

  @override
  Widget build(BuildContext context) {
    final provider = _libraryCoverProvider(path);
    if (provider == null) {
      return Image.asset('assets/images/NoCoverArt.png', fit: BoxFit.cover);
    }
    return Image(
      image: provider,
      fit: BoxFit.cover,
      gaplessPlayback: true,
      errorBuilder: (_, __, ___) =>
          Image.asset('assets/images/NoCoverArt.png', fit: BoxFit.cover),
    );
  }
}
