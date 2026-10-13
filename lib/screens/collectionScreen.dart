// The purpose of this file is to create a list of entries from a selected folder
import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:markdown/markdown.dart' as md;
import 'package:isar/isar.dart';
import 'package:isar_flutter_libs/isar_flutter_libs.dart';
import 'package:jellybook/models/entry.dart';
import 'package:jellybook/providers/supportedFormats.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_star/flutter_star.dart';
import 'package:jellybook/models/folder.dart';
import 'package:jellybook/screens/infoScreen.dart';
import 'package:jellybook/providers/fixRichText.dart';
import 'package:jellybook/l10n/app_localizations.dart';
import 'package:jellybook/variables.dart';
import 'package:jellybook/widgets/jellybookImageCache.dart';
import 'package:auto_size_text/auto_size_text.dart';
import 'package:jellybook/screens/readingScreen.dart';
import 'package:jellybook/providers/serverProgressRevision.dart';
import 'package:jellybook/providers/readerPageCache.dart';
import 'package:jellybook/screens/readingScreens/cbzReader.dart';
import 'package:jellybook/widgets/coverOpeningRoute.dart';
import 'package:provider/provider.dart';
import 'package:jellybook/providers/connectionManager.dart';

class collectionScreen extends StatefulWidget {
  final String folderId;
  final String name;
  final String image;
  final List<String> bookIds;
  final bool downloadedOnly;

  collectionScreen({
    required this.folderId,
    required this.name,
    required this.image,
    required this.bookIds,
    this.downloadedOnly = false,
  });

  @override
  _collectionScreenState createState() => _collectionScreenState(
      folderId: folderId, name: name, image: image, bookIds: bookIds,
      downloadedOnly: downloadedOnly);
}

class _collectionScreenState extends State<collectionScreen> with WidgetsBindingObserver {
  static const double _headerCornerRadius = 17.5;

  final String folderId;
  final String name;
  final String image;
  final List<String> bookIds;
  final bool downloadedOnly;

  _collectionScreenState({
    required this.folderId,
    required this.name,
    required this.image,
    required this.bookIds,
    this.downloadedOnly = false,
  });

  final ScrollController _gridController = ScrollController();
  // Reuse one database query across animation and layout rebuilds. Creating a
  // fresh Future in build() briefly replaces the grid with a spinner.
  late Future<List<Entry>> _entriesFuture;
  List<Entry>? _latestEntries;
  // Notifies just the visible badge/progress widgets, never the cover images.
  final ValueNotifier<int> _cardProgressRevision = ValueNotifier<int>(0);
  int _progressReadGeneration = 0;
  bool _warmScheduled = false;
  bool _warming = false;
  bool _warmAgain = false;
  bool _inForeground = true;
  bool _coverWarmingPaused = false;
  int _coverWarmGeneration = 0;

  @override
  void initState() {
    super.initState();
    _entriesFuture = getEntries();
    serverProgressRevision.addListener(_onServerProgressRefreshed);
    WidgetsBinding.instance.addObserver(this);
  }

  // A server refresh already wrote to Isar; reread only the saved page and
  // percentage, leaving the rendered entry list and its cover providers alone.
  void _onServerProgressRefreshed() {
    unawaited(_updateCardProgress());
  }

  Future<void> _updateCardProgress() async {
    final displayed = _latestEntries;
    if (!mounted || displayed == null) return;
    final generation = ++_progressReadGeneration;
    try {
      final refreshed = await getEntries();
      if (!mounted || generation != _progressReadGeneration ||
          !identical(displayed, _latestEntries)) return;
      final byId = {for (final entry in refreshed) entry.id: entry};
      var changed = false;
      for (final entry in displayed) {
        final newest = byId[entry.id];
        if (newest == null ||
            (entry.pageNum == newest.pageNum &&
                entry.progress == newest.progress)) continue;
        entry.pageNum = newest.pageNum;
        entry.progress = newest.progress;
        changed = true;
      }
      if (changed) _cardProgressRevision.value++;
    } catch (error) {
      logger.w('Could not update Collection progress indicators: $error');
    }
  }

  void _refreshEntries() {
    if (!mounted) return;
    final refreshed = getEntries();
    setState(() => _entriesFuture = refreshed);
    if (downloadedOnly) {
      // Removing the final download leaves this filtered series empty.
      unawaited(refreshed.then((entries) async {
        if (mounted && entries.isEmpty) await Navigator.of(context).maybePop();
      }));
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _inForeground = true;
      // Android may have reclaimed decoded images while the app was away.
      _scheduleCoverWarming();
    } else {
      _inForeground = false;
    }
  }

  @override
  void dispose() {
    _inForeground = false;
    serverProgressRevision.removeListener(_onServerProgressRefreshed);
    _cardProgressRevision.dispose();
    WidgetsBinding.instance.removeObserver(this);
    _gridController.dispose();
    super.dispose();
  }

  // A new Future result or an explicit lifecycle/navigation event may start
  // warming. Ordinary builds of the same list must not restart the queue.
  void _scheduleCoverWarming([List<Entry>? entries]) {
    if (entries != null) {
      if (identical(entries, _latestEntries)) return;
      _latestEntries = entries;
    }
    if (!mounted || !_inForeground || _coverWarmingPaused ||
        _latestEntries == null) return;
    if (_warming) {
      _warmAgain = true;
      return;
    }
    if (_warmScheduled) return;
    _warmScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _warmScheduled = false;
      if (!_canWarmCovers(_coverWarmGeneration)) return;
      unawaited(_precacheCollectionCovers(_latestEntries!));
    });
  }

  bool _canWarmCovers(int generation) =>
      mounted && _inForeground && !_coverWarmingPaused &&
      generation == _coverWarmGeneration &&
      (ModalRoute.of(context)?.isCurrent ?? true);

  void _pauseCoverWarming() {
    _coverWarmingPaused = true;
    // Let already-started image loads finish and enter the cache, but prevent
    // their old queue from continuing if the user returns quickly.
    _coverWarmGeneration++;
    _warmAgain = false;
  }

  void _resumeCoverWarming() {
    if (!mounted) return;
    _coverWarmingPaused = false;
    // Revisit remaining covers; already decoded ones are skipped below.
    _scheduleCoverWarming();
  }

  Future<T?> _pushWithPausedCovers<T extends Object?>(
      TransitionRoute<T> route) async {
    _pauseCoverWarming();
    try {
      return await Navigator.of(context).push<T>(route);
    } finally {
      // Navigator.push completes when pop begins; wait for the return
      // transition to finish before starting new image decodes.
      try {
        await route.completed;
      } finally {
        _resumeCoverWarming();
      }
    }
  }

  // Estimate which cards GridView.builder is currently displaying.
  ({int first, int end}) _visibleCoverRange(int count) {
    if (!_gridController.hasClients) {
      return (first: 0, end: math.min(count, 12));
    }
    // Three columns, 6px gaps, 4px horizontal padding per side.
    // The outer card edges stay fixed; reduced gaps give each card more width.
    final width = math.max(1.0, MediaQuery.sizeOf(context).width - 20);
    final rowHeight = (width / 3) / 0.69 + 6;
    final firstRow = math.max(0, (_gridController.offset / rowHeight).floor());
    final rows = math.max(1,
        (_gridController.position.viewportDimension / rowHeight).ceil() + 1);
    return (
      first: math.min(count, firstRow * 3),
      end: math.min(count, (firstRow + rows) * 3),
    );
  }

  Future<void> _warmCover(String path, int generation,
      {bool waitForVisible = false}) async {
    if (!_canWarmCovers(generation) || path.isEmpty ||
        path.toLowerCase() == 'asset') return;
    try {
      final ImageProvider provider;
      if (path.contains('http')) {
        provider = CachedNetworkImageProvider(
          coverUrl(path),
          cacheManager: JellyBookCacheManager.instance,
        );
      } else {
        final file = File(path);
        if (!await file.exists()) return;
        provider = FileImage(file);
      }
      // Don't begin a decode after a local-file existence check finishes
      // if navigation happened while that filesystem operation was pending.
      if (!_canWarmCovers(generation)) return;
      // A completed image may have been evicted since a prior prewarm.
      // For visible covers, await their first frame even if still pending.
      if (!waitForVisible &&
          PaintingBinding.instance.imageCache.containsKey(provider)) return;
      await precacheImage(provider, context, onError: (_, __) {});
    } catch (_) {
      // Offline or broken covers should not block the other images.
    }
  }

  Future<void> _precacheCollectionCovers(List<Entry> entries) async {
    if (_warming) {
      _warmAgain = true;
      return;
    }
    final generation = _coverWarmGeneration;
    if (!_canWarmCovers(generation)) return;
    _warming = true;
    try {
      final range = _visibleCoverRange(entries.length);
      // Join the same image loads as the visible widgets. Only begin work
      // on offscreen covers after the initial viewport is ready.
      await Future.wait([
        for (var i = range.first; i < range.end; i++)
          _warmCover(entries[i].imagePath, generation,
              waitForVisible: true),
      ]);
      if (!_canWarmCovers(generation)) return;

      final seen = <String>{};
      final remaining = <int>[];
      for (var i = 0; i < entries.length; i++) {
        final path = entries[i].imagePath;
        if (path.isEmpty || path.toLowerCase() == 'asset' ||
            !seen.add(path)) continue;
        if (i < range.first || i >= range.end) remaining.add(i);
      }

      // Keep a small background budget; prioritize whichever covers are now
      // closest to the viewport, even if the user has scrolled meanwhile.
      const batchSize = 2;
      while (remaining.isNotEmpty && _canWarmCovers(generation)) {
        final visible = _visibleCoverRange(entries.length);
        int distance(int index) => index < visible.first
            ? visible.first - index
            : index >= visible.end ? index - visible.end + 1 : 0;
        remaining.sort((a, b) => distance(a).compareTo(distance(b)));
        final batch = remaining.take(batchSize).toList();
        remaining.removeRange(0, batch.length);
        await Future.wait([
          for (final index in batch)
            _warmCover(entries[index].imagePath, generation),
        ]);
        // Yield to normal scrolling/painting between small batches.
        await Future<void>.delayed(const Duration(milliseconds: 16));
      }
    } finally {
      _warming = false;
      if (_warmAgain && mounted && _inForeground && !_coverWarmingPaused) {
        _warmAgain = false;
        _scheduleCoverWarming();
      }
    }
  }

  final isar = Isar.getInstance();

  Future<List<Entry>> getEntries() async {
    List<Entry> entryList = await isar!.entrys
        .where()
        .filter()
        .anyOf(bookIds, (q, String id) => q.idEqualTo(id))
        .findAll();
    entryList = entryList.where((entry) =>
        isSupportedEntry(entry) && (!downloadedOnly || entry.downloaded)).toList();
    entryList.forEach((element) {
      if (element.type == EntryType.folder) {
        logger.f(element.title);
      }
    });
    return entryList;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      // Let covers scroll behind the translucent header, as on the home screen.
      extendBodyBehindAppBar: true,
      appBar: PreferredSize(
        // Preserve the default AppBar's 56px toolbar plus status-bar inset.
        preferredSize: Size.fromHeight(
          MediaQuery.of(context).padding.top + kToolbarHeight,
        ),
        child: Container(
          color: Colors.black.withOpacity(0.90),
          padding: EdgeInsets.only(top: MediaQuery.of(context).padding.top),
          child: SizedBox(
            height: kToolbarHeight,
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                // Same 17.5px concave transitions as the Library header.
                // Draw only along the edges so covers remain visible below.
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: -_headerCornerRadius,
                  height: _headerCornerRadius,
                  child: IgnorePointer(
                    child: CustomPaint(
                      painter: _CollectionHeaderCornersPainter(
                        color: Colors.black.withOpacity(0.90),
                      ),
                    ),
                  ),
                ),
                Row(
                  children: [
                    SizedBox(
                      width: kToolbarHeight,
                      child: IconButton(
                        tooltip: 'Back',
                        icon: const Icon(Icons.arrow_back, color: Colors.white),
                        onPressed: () => Navigator.of(context).maybePop(),
                      ),
                    ),
                    Expanded(
                      child: Padding(
                        padding: const EdgeInsets.only(left: 16, right: 16),
                        child: AutoSizeText(
                          name,
                          maxLines: 2,
                          minFontSize: 10,
                          maxFontSize: 20,
                          stepGranularity: 0.5,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontWeight: FontWeight.bold,
                            color: Colors.white,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
      body: FutureBuilder<List<Entry>>(
        future: _entriesFuture,
        builder: (BuildContext context, AsyncSnapshot snapshot) {
          if (snapshot.hasData && snapshot.data!.isNotEmpty) {
            // Schedule only after a grid is actually included in this frame.
            _scheduleCoverWarming(snapshot.data as List<Entry>);
            return Padding(
              padding:
                  const EdgeInsets.symmetric(horizontal: 4.0, vertical: 4.0),
              child: GridView.builder(
                controller: _gridController,
                // Match the library's small header-to-grid gap without
                // adding another full toolbar-height of empty space.
                padding: EdgeInsets.only(
                  top: MediaQuery.of(context).padding.top + 6.0,
                ),
                gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: 3,
                  childAspectRatio: 0.69,
                  crossAxisSpacing: 6,
                  mainAxisSpacing: 6,
                ),
                itemCount: snapshot.data.length,
                itemBuilder: (BuildContext context, int index) {
                  Entry entry = snapshot.data[index];
                  return KuroStyleBookCard(
                    entry: entry,
                    progressRevision: _cardProgressRevision,
                    onEntryTapped: (coverRect) async {
                      if (entry.type == EntryType.folder) {
                        var folder = isar!.folders
                            .where()
                            .filter()
                            .idEqualTo(entry.id)
                            .findFirstSync();
                        await _pushWithPausedCovers(
                          MaterialPageRoute(
                            builder: (context) => collectionScreen(
                              folderId: folder!.id,
                              name: folder.name,
                              image: folder.image,
                              bookIds: folder.bookIds,
                            ),
                          ),
                        );
                        _refreshEntries();
                        return;
                      }

                      // Check connection status
                      if (!mounted || !isSupportedEntry(entry)) return;
                      final connectionStatus = Provider.of<ConnectionManager>(
                              context,
                              listen: false)
                          .status;
                      if (connectionStatus == ConnectionStatus.offline &&
                          !entry.downloaded) {
                        final cachedIndex =
                            await ReaderPageCache.getCurrentPage(entry.id) ??
                                entry.pageNum;
                        final cachedPage =
                            await ReaderPageCache.getPage(entry.id, cachedIndex);
                        if (!mounted) return;
                        if (cachedPage == null) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(
                              content: Text('Server is offline and this page is not cached'),
                              duration: Duration(seconds: 2),
                            ),
                          );
                          return;
                        }
                      }

                      // Open comic archives directly so the animated cover
                      // is not interrupted by ReadingScreen's extra route.
                      final extension = entryFileExtension(entry.path);
                      final isArchive = const ['cbz', 'zip'].contains(extension);
                      final streamable = extension == 'cbz';
                      if (isArchive && (entry.downloaded || streamable)) {
                        final firstPageReady = ValueNotifier<bool>(false);
                        final skipReturnFade = ValueNotifier<bool>(false);
                        await _pushWithPausedCovers(
                          CoverOpeningRoute(
                            sourceRect: coverRect,
                            coverPath: entry.imagePath,
                            pageReady: firstPageReady,
                            skipReturnFade: skipReturnFade,
                            builder: (context) => CbzReader(
                              title: entry.title,
                              comicId: entry.id,
                              openedDirectly: true,
                              openingReady: firstPageReady,
                              skipReturnFade: skipReturnFade,
                            ),
                          ),
                        );
                        _refreshEntries();
                        return;
                      }
                      // Other downloaded formats keep their existing reader.
                      if (entry.downloaded) {
                        await _pushWithPausedCovers(
                          MaterialPageRoute(
                            builder: (context) => ReadingScreen(
                              title: entry.title,
                              comicId: entry.id,
                            ),
                          ),
                        );
                        _refreshEntries();
                        return;
                      }
                      // For other formats, show the info screen
                      var result = await _pushWithPausedCovers(
                        MaterialPageRoute(
                          builder: (context) => InfoScreen(entry: entry),
                        ),
                      );
                      if (result != null) {
                        entry.isFavorited = result.isFavorited;
                        entry.downloaded = result.downloaded;
                        await isar?.writeTxn(() async {
                          await isar?.entrys.put(entry);
                        });
                        _refreshEntries();
                      }
                    },
                    onEntryLongPressed: () async {
                      var result = await _pushWithPausedCovers(
                        MaterialPageRoute(
                          builder: (context) => InfoScreen(entry: entry),
                        ),
                      );
                      if (result != null) {
                        _refreshEntries();
                      }
                    },
                  );
                },
              ),
            );
          } else if (snapshot.hasData && snapshot.data!.isEmpty) {
            return Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(
                    AppLocalizations.of(context)?.noResultsFound ??
                        'No results found in this folder',
                    style: const TextStyle(
                      fontSize: 25,
                    ),
                  ),
                  const SizedBox(height: 10),
                  const Icon(Icons.sentiment_dissatisfied, size: 100),
                ],
              ),
            );
          } else if (snapshot.hasError) {
            return Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(
                    AppLocalizations.of(context)?.unknownError ??
                        "An unknown error has occured.",
                    style: const TextStyle(
                      fontSize: 25,
                    ),
                  ),
                  const SizedBox(height: 10),
                  const Icon(Icons.sentiment_dissatisfied, size: 100),
                ],
              ),
            );
          } else {
            return const Center(
              child: CircularProgressIndicator(),
            );
          }
        },
      ),
    );
  }
}

// Match the Library header's two quarter-circle extensions. The center
// remains transparent so scrolling covers are visible behind the bar.
class _CollectionHeaderCornersPainter extends CustomPainter {
  const _CollectionHeaderCornersPainter({required this.color});

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final r = math.min(size.height, size.width / 2);
    if (r <= 0) return;
    final paint = Paint()..color = color;
    final cornerRadius = Radius.circular(r);

    final left = Path()
      ..moveTo(0, 0)
      ..lineTo(r, 0)
      ..arcToPoint(Offset(0, r), radius: cornerRadius, clockwise: false)
      ..close();
    final right = Path()
      ..moveTo(size.width - r, 0)
      ..lineTo(size.width, 0)
      ..lineTo(size.width, r)
      ..arcToPoint(Offset(size.width - r, 0),
          radius: cornerRadius, clockwise: false)
      ..close();

    canvas.drawPath(left, paint);
    canvas.drawPath(right, paint);
  }

  @override
  bool shouldRepaint(covariant _CollectionHeaderCornersPainter oldDelegate) =>
      oldDelegate.color != color;
}

// Kuro Reader-inspired book card widget
class KuroStyleBookCard extends StatefulWidget {
  final Entry entry;
  final ValueListenable<int>? progressRevision;
  final ValueChanged<Rect> onEntryTapped;
  final VoidCallback? onEntryLongPressed; // new

  const KuroStyleBookCard({
    required this.entry,
    this.progressRevision,
    required this.onEntryTapped,
    this.onEntryLongPressed, // new
  });

  @override
  KuroStyleBookCardState createState() => KuroStyleBookCardState();
}

class KuroStyleBookCardState extends State<KuroStyleBookCard> {
  final GlobalKey _coverKey = GlobalKey();

  void _openFromCover() {
    final box = _coverKey.currentContext?.findRenderObject();
    if (box is RenderBox && box.hasSize) {
      widget.onEntryTapped(box.localToGlobal(Offset.zero) & box.size);
    } else {
      widget.onEntryTapped(Rect.zero);
    }
  }

  // One radius for both the card and the cover image
  static const double _imageRadius = 10; // was 14
  static const double _cardRadius = _imageRadius + 4 + 1.5;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    // Check if offline
    final connectionStatus =
        Provider.of<ConnectionManager>(context).status;
    final isOffline = connectionStatus == ConnectionStatus.offline;
    final isUndownloaded = !widget.entry.downloaded;

    return Opacity(
      opacity: isOffline && isUndownloaded ? 0.5 : 1.0,
      child: GestureDetector(
        onTap: _openFromCover,
        onLongPress: widget.onEntryLongPressed,
        child: Container(
          padding: const EdgeInsets.all(4),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(_cardRadius),
            border: Border.all(color: scheme.outlineVariant, width: 1.5),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                child: ClipRRect(
                  key: _coverKey,
                  borderRadius: BorderRadius.circular(_imageRadius),
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      _CollectionCoverImage(path: widget.entry.imagePath),
                      Positioned(
                        top: 2,
                        left: 2,
                        child: ValueListenableBuilder<int>(
                          valueListenable:
                              widget.progressRevision ?? serverProgressRevision,
                          builder: (context, _, __) {
                            final progressPercent = widget.entry.progress;
                            final isUnread = widget.entry.pageNum == 0 &&
                                progressPercent <= 0;
                            final isFinished = progressPercent >= 100;
                            return Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 6, vertical: 2),
                              decoration: BoxDecoration(
                                color: isUnread
                                    ? const Color(0xFFE91E63)
                                    : isFinished
                                        ? const Color(0xFF4CAF50)
                                        : const Color(0xFFFF9800),
                                borderRadius: BorderRadius.circular(10),
                              ),
                              child: Text(
                                isUnread
                                    ? 'UNREAD'
                                    : isFinished
                                        ? 'FINISHED'
                                        : 'READING',
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 9,
                                  fontWeight: FontWeight.bold,
                                  letterSpacing: 0.5,
                                ),
                              ),
                            );
                          },
                        ),
                      ),
                      if (widget.entry.isFavorited == true)
                        Positioned(
                          top: 4,
                          right: 4,
                          child: Container(
                            decoration: BoxDecoration(
                              color: Colors.black.withOpacity(0.6),
                              borderRadius: BorderRadius.circular(20),
                            ),
                            padding: const EdgeInsets.all(4),
                            child: const Icon(
                              Icons.favorite,
                              color: Colors.red,
                              size: 16,
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 2),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 6),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(2),
                  child: SizedBox(
                    height: 3,
                    child: ValueListenableBuilder<int>(
                      valueListenable:
                              widget.progressRevision ?? serverProgressRevision,
                      builder: (context, _, __) => LinearProgressIndicator(
                        value: (widget.entry.progress / 100).clamp(0.0, 1.0),
                        backgroundColor: scheme.outlineVariant,
                        valueColor:
                            AlwaysStoppedAnimation<Color>(scheme.primary),
                      ),
                    ),
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

/// Display Collection covers using the shared cache provider without the
/// extra layout and placeholder widgets of RoundedImageWithShadow.
/// The enclosing card already provides the cover's shape and clipping.
class _CollectionCoverImage extends StatelessWidget {
  const _CollectionCoverImage({required this.path});

  final String path;

  @override
  Widget build(BuildContext context) {
    if (path.isEmpty || path.toLowerCase() == 'asset') {
      return Image.asset('assets/images/NoCoverArt.png', fit: BoxFit.cover);
    }

    final ImageProvider provider;
    if (path.contains('http')) {
      provider = CachedNetworkImageProvider(
        coverUrl(path),
        cacheManager: JellyBookCacheManager.instance,
      );
    } else {
      provider = FileImage(File(path));
    }

    return Image(
      image: provider,
      fit: BoxFit.cover,
      gaplessPlayback: true,
      errorBuilder: (context, error, stackTrace) =>
          Image.asset('assets/images/NoCoverArt.png', fit: BoxFit.cover),
    );
  }
}
