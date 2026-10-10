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
import 'package:flutter/material.dart';
import 'package:flutter_star/flutter_star.dart';
import 'package:jellybook/models/folder.dart';
import 'package:jellybook/screens/infoScreen.dart';
import 'package:jellybook/providers/fixRichText.dart';
import 'package:fancy_shimmer_image/fancy_shimmer_image.dart';
import 'package:jellybook/l10n/app_localizations.dart';
import 'package:jellybook/variables.dart';
import 'package:jellybook/widgets/roundedImageWithShadow.dart';
import 'package:jellybook/widgets/jellybookImageCache.dart';
import 'package:auto_size_text/auto_size_text.dart';
import 'package:jellybook/screens/readingScreen.dart';
import 'package:jellybook/providers/readerPageCache.dart';
import 'package:jellybook/screens/readingScreens/cbrCbzReader.dart';
import 'package:jellybook/widgets/coverOpeningRoute.dart';
import 'package:provider/provider.dart';
import 'package:jellybook/providers/connectionManager.dart';

class collectionScreen extends StatefulWidget {
  final String folderId;
  final String name;
  final String image;
  final List<String> bookIds;

  collectionScreen({
    required this.folderId,
    required this.name,
    required this.image,
    required this.bookIds,
  });

  @override
  _collectionScreenState createState() => _collectionScreenState(
      folderId: folderId, name: name, image: image, bookIds: bookIds);
}

class _collectionScreenState extends State<collectionScreen> with WidgetsBindingObserver {
  final String folderId;
  final String name;
  final String image;
  final List<String> bookIds;

  _collectionScreenState({
    required this.folderId,
    required this.name,
    required this.image,
    required this.bookIds,
  });

  final ScrollController _gridController = ScrollController();
  // Reuse one database query across animation and layout rebuilds. Creating a
  // fresh Future in build() briefly replaces the grid with a spinner.
  late Future<List<Entry>> _entriesFuture;
  List<Entry>? _latestEntries;
  bool _warmScheduled = false;
  bool _warming = false;
  bool _warmAgain = false;
  bool _inForeground = true;

  @override
  void initState() {
    super.initState();
    _entriesFuture = getEntries();
    WidgetsBinding.instance.addObserver(this);
  }

  void _refreshEntries() {
    if (!mounted) return;
    setState(() => _entriesFuture = getEntries());
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
    WidgetsBinding.instance.removeObserver(this);
    _gridController.dispose();
    super.dispose();
  }

  void _scheduleCoverWarming([List<Entry>? entries]) {
    if (entries != null) _latestEntries = entries;
    if (!mounted || !_inForeground || _latestEntries == null) return;
    if (_warming) {
      _warmAgain = true;
      return;
    }
    if (_warmScheduled) return;
    _warmScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _warmScheduled = false;
      if (!mounted || !_inForeground ||
          !(ModalRoute.of(context)?.isCurrent ?? true)) return;
      unawaited(_precacheCollectionCovers(_latestEntries!));
    });
  }

  // Estimate which cards GridView.builder is currently displaying.
  ({int first, int end}) _visibleCoverRange(int count) {
    if (!_gridController.hasClients) {
      return (first: 0, end: math.min(count, 12));
    }
    // Three columns, 12px gaps, 4px horizontal padding, aspect ratio 0.69.
    final width = math.max(1.0, MediaQuery.sizeOf(context).width - 32);
    final rowHeight = (width / 3) / 0.69 + 12;
    final firstRow = math.max(0, (_gridController.offset / rowHeight).floor());
    final rows = math.max(1,
        (_gridController.position.viewportDimension / rowHeight).ceil() + 1);
    return (
      first: math.min(count, firstRow * 3),
      end: math.min(count, (firstRow + rows) * 3),
    );
  }

  Future<void> _warmCover(String path, {bool waitForVisible = false}) async {
    if (!mounted || !_inForeground || path.isEmpty ||
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
    _warming = true;
    try {
      final range = _visibleCoverRange(entries.length);
      // Join the same image loads as the visible widgets. Only begin work
      // on offscreen covers after the initial viewport is ready.
      await Future.wait([
        for (var i = range.first; i < range.end; i++)
          _warmCover(entries[i].imagePath, waitForVisible: true),
      ]);

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
      while (remaining.isNotEmpty && mounted && _inForeground &&
          (ModalRoute.of(context)?.isCurrent ?? true)) {
        final visible = _visibleCoverRange(entries.length);
        int distance(int index) => index < visible.first
            ? visible.first - index
            : index >= visible.end ? index - visible.end + 1 : 0;
        remaining.sort((a, b) => distance(a).compareTo(distance(b)));
        final batch = remaining.take(batchSize).toList();
        remaining.removeRange(0, batch.length);
        await Future.wait([
          for (final index in batch) _warmCover(entries[index].imagePath),
        ]);
        // Yield to normal scrolling/painting between small batches.
        await Future<void>.delayed(const Duration(milliseconds: 16));
      }
    } finally {
      _warming = false;
      if (_warmAgain && mounted && _inForeground) {
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
            child: Row(
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
                // Keep the initial covers below the header. Once scrolled,
                // the grid itself continues underneath the black overlay.
                padding: EdgeInsets.only(
                  top: MediaQuery.of(context).padding.top + kToolbarHeight,
                ),
                gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: 3,
                  childAspectRatio: 0.69,
                  crossAxisSpacing: 12,
                  mainAxisSpacing: 12,
                ),
                itemCount: snapshot.data.length,
                itemBuilder: (BuildContext context, int index) {
                  Entry entry = snapshot.data[index];
                  return KuroStyleBookCard(
                    entry: entry,
                    onEntryTapped: (coverRect) async {
                      if (entry.type == EntryType.folder) {
                        var folder = isar!.folders
                            .where()
                            .filter()
                            .idEqualTo(entry.id)
                            .findFirstSync();
                        await Navigator.push(
                          context,
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
                      if (!mounted) return;
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
                      final extension = entry.path.split('.').last.toLowerCase();
                      final isArchive = const ['cbz', 'cbr', 'zip', 'rar']
                          .contains(extension);
                      final streamable = extension == 'cbz' || extension == 'cbr';
                      if (isArchive && (entry.downloaded || streamable)) {
                        final firstPageReady = ValueNotifier<bool>(false);
                        final skipReturnFade = ValueNotifier<bool>(false);
                        await Navigator.push(
                          context,
                          CoverOpeningRoute(
                            sourceRect: coverRect,
                            coverPath: entry.imagePath,
                            pageReady: firstPageReady,
                            skipReturnFade: skipReturnFade,
                            builder: (context) => CbrCbzReader(
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
                        await Navigator.push(
                          context,
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
                      var result = await Navigator.push(
                        context,
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
                      var result = await Navigator.push(
                        context,
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

// Kuro Reader-inspired book card widget
class KuroStyleBookCard extends StatefulWidget {
  final Entry entry;
  final ValueChanged<Rect> onEntryTapped;
  final VoidCallback? onEntryLongPressed; // new

  const KuroStyleBookCard({
    required this.entry,
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
    // entry.progress is stored as a percentage (0-100), not a 0-1 fraction
    final double progressPercent = widget.entry.progress;
    final bool isUnread = widget.entry.pageNum == 0 && progressPercent <= 0;
    final bool isFinished = progressPercent >= 100;
    final double progress = (progressPercent / 100).clamp(0.0, 1.0);

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
                      RoundedImageWithShadow(
                        imageUrl: widget.entry.imagePath,
                        radius: _imageRadius,
                        shadowColor: Colors.transparent,
                      ),
                      Positioned(
                        top: 2,
                        left: 2,
                        child: Container(
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
                    child: LinearProgressIndicator(
                      value: progress,
                      backgroundColor: scheme.outlineVariant,
                      valueColor:
                          AlwaysStoppedAnimation<Color>(scheme.primary),
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
