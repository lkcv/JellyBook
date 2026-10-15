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
import 'package:jellybook/providers/libraryFilter.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_star/flutter_star.dart';
import 'package:jellybook/models/folder.dart';
import 'package:jellybook/screens/infoScreen.dart';
import 'package:jellybook/providers/fixRichText.dart';
import 'package:jellybook/l10n/app_localizations.dart';
import 'package:jellybook/themes/themeConstants.dart';
import 'package:jellybook/widgets/jellybookHeader.dart';
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
  final bool readingOnly;

  collectionScreen({
    required this.folderId,
    required this.name,
    required this.image,
    required this.bookIds,
    this.downloadedOnly = false,
    this.readingOnly = false,
  });

  @override
  _collectionScreenState createState() => _collectionScreenState(
      folderId: folderId, name: name, image: image, bookIds: bookIds,
      downloadedOnly: downloadedOnly, readingOnly: readingOnly);
}

class _collectionScreenState extends State<collectionScreen> with WidgetsBindingObserver {

  final String folderId;
  final String name;
  final String image;
  final List<String> bookIds;
  final bool downloadedOnly;
  final bool readingOnly;

  _collectionScreenState({
    required this.folderId,
    required this.name,
    required this.image,
    required this.bookIds,
    this.downloadedOnly = false,
    this.readingOnly = false,
  });

  final ScrollController _gridController = ScrollController();
  // Only mounted cards are tracked; the sliver still disposes offscreen cards.
  final Map<String, KuroStyleBookCardState> _mountedCards = {};
  // Reuse one database query across animation and layout rebuilds. Creating a
  // fresh Future in build() briefly replaces the grid with a spinner.
  late Future<List<Entry>> _entriesFuture;
  List<Entry>? _latestEntries;
  // Keep the complete Collection order for reader continuation. Library
  // filters affect what is displayed, never the sequence of volumes to read.
  List<Entry> _unfilteredEntries = const [];
  // Notifies just the visible badge/progress widgets, never the cover images.
  final ValueNotifier<int> _cardProgressRevision = ValueNotifier<int>(0);
  int _progressReadGeneration = 0;
  bool _emptyFilteredPopPending = false;
  bool _warmScheduled = false;
  bool _warming = false;
  bool _warmAgain = false;
  bool _inForeground = true;
  bool _coverWarmingPaused = false;
  int _coverWarmGeneration = 0;

  // Unlike precacheImage(), these listeners retain decoded covers until their
  // paths leave the moving viewport window or Collection is disposed.
  static const int _maxPinnedCovers = 42;
  bool _initialCoversReady = false;
  final Map<String, ({ImageStream stream, ImageStreamListener listener})>
      _pinnedCovers = {};
  final Set<String> _failedCovers = {};
  final Set<String> _revalidateCovers = {};
  double? _previousScrollOffset;
  DateTime? _previousScrollTime;
  int _scrollDirection = 1;
  bool _scrollingFast = false;

  @override
  void initState() {
    super.initState();
    _entriesFuture = getEntries();
    _gridController.addListener(_onGridScrolled);
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
      if (readingOnly &&
          (displayed.length != refreshed.length ||
              displayed.any((entry) => !byId.containsKey(entry.id)))) {
        // Progress changed membership: rebuild the filtered grid rather than
        // leaving a FINISHED/UNREAD volume visible under Continue Reading.
        setState(() => _entriesFuture = Future.value(refreshed));
        if (refreshed.isEmpty) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            _leaveEmptyFilteredCollection();
          });
        }
        return;
      }
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

  // Only pop once if overlapping reader and server progress callbacks both
  // discover that this filtered Collection no longer contains any volumes.
  void _leaveEmptyFilteredCollection() {
    if (!mounted || _emptyFilteredPopPending ||
        !(ModalRoute.of(context)?.isCurrent ?? false)) return;
    _emptyFilteredPopPending = true;
    unawaited(Navigator.of(context).maybePop());
  }

  Future<CoverReturnTarget> _resolveReturnCover(Entry entry) async {
    // A Library filter can hide the volume reached by swiping. Respect the
    // filter; don't animate its cover into the originally tapped card.
    final entries = _latestEntries;
    final index = entries?.indexWhere((item) => item.id == entry.id) ?? -1;
    if (!mounted || index < 0 || !_gridController.hasClients) {
      return CoverReturnTarget(coverPath: entry.imagePath, rect: null);
    }

    // Jump the Collection grid behind the non-opaque reader route, before the
    // reverse animation begins. This doesn't enable cover prewarming while
    // the reader is open, and doesn't animate the grid itself.
    final position = _gridController.position;
    final width = math.max(1.0, MediaQuery.sizeOf(context).width - 8);
    final tileWidth = (width - 12) / 3;
    final tileHeight = tileWidth / 0.69;
    final top = MediaQuery.paddingOf(context).top + 6;
    final rowTop = top + (index ~/ 3) * (tileHeight + 6);
    final offset = position.pixels;
    final isVisible = rowTop >= offset && rowTop + tileHeight <=
        offset + position.viewportDimension;
    if (isVisible) {
      final existing = _mountedCards[entry.id]?.coverRect;
      if (existing != null && !existing.isEmpty) {
        return CoverReturnTarget(coverPath: entry.imagePath, rect: existing);
      }
    } else {
      final centerOffset = rowTop + tileHeight / 2 -
          position.viewportDimension / 2;
      _gridController.jumpTo(centerOffset.clamp(
        position.minScrollExtent, position.maxScrollExtent,
      ).toDouble());
    }

    // Wait only if the card needs mounting/layout. The actual RenderBox,
    // not a guessed grid rectangle, supplies the shrink destination.
    WidgetsBinding.instance.scheduleFrame();
    await WidgetsBinding.instance.endOfFrame;
    if (!mounted) return CoverReturnTarget(
      coverPath: entry.imagePath, rect: null,
    );
    final rect = _mountedCards[entry.id]?.coverRect;
    return CoverReturnTarget(
      coverPath: entry.imagePath,
      rect: rect == null || rect.isEmpty ? null : rect,
    );
  }

  void _refreshEntries() {
    if (!mounted) return;
    final refreshed = getEntries();
    setState(() => _entriesFuture = refreshed);
    if (downloadedOnly || readingOnly) {
      // Removing the last matching volume leaves this filtered series empty.
      unawaited(refreshed.then((entries) {
        if (entries.isEmpty) _leaveEmptyFilteredCollection();
      }));
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _inForeground = true;
      // Revalidate existing pins after Android may have trimmed image memory.
      // Keep old listeners attached until replacements are actually ready.
      _failedCovers.clear();
      _revalidateCovers.addAll(_pinnedCovers.keys);
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
    _clearPinnedCovers();
    _gridController.removeListener(_onGridScrolled);
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
    // A reader can evict decoded images under memory pressure. The retained
    // pin records only tell us that a listener was installed earlier; they
    // don't prove its image is still ready after the reader closes.
    // Re-resolve the current viewport first, then its directional lookahead.
    // _pinCover keeps each existing listener until its replacement resolves.
    _failedCovers.clear();
    _revalidateCovers.addAll(_pinnedCovers.keys);
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

  void _onGridScrolled() {
    if (!_gridController.hasClients || !_initialCoversReady) return;
    final now = DateTime.now();
    final offset = _gridController.offset;
    final previous = _previousScrollOffset;
    final previousTime = _previousScrollTime;
    _previousScrollOffset = offset;
    _previousScrollTime = now;
    if (previous != null && previousTime != null) {
      final delta = offset - previous;
      if (delta.abs() < 0.5) return;
      final elapsed = now.difference(previousTime).inMicroseconds;
      _scrollDirection = delta >= 0 ? 1 : -1;
      if (elapsed > 0) {
        _scrollingFast = delta.abs() * 1000000 / elapsed > 1200;
      }
    }
    // Coalesced to one post-frame callback; scrolling never rebuilds the grid.
    _scheduleCoverWarming();
  }

  // The initial viewport is not mounted yet, so estimate its full height.
  ({int first, int end}) _visibleCoverRange(int count) {
    if (count == 0) return (first: 0, end: 0);
    final width = math.max(1.0, MediaQuery.sizeOf(context).width - 20);
    final rowHeight = (width / 3) / 0.69 + 6;
    if (!_gridController.hasClients) {
      final viewportHeight = MediaQuery.sizeOf(context).height -
          MediaQuery.paddingOf(context).bottom;
      final rows = math.max(1, (viewportHeight / rowHeight).ceil() + 1);
      return (first: 0, end: math.min(count, math.max(12, rows * 3)));
    }
    final firstRow = math.max(0, (_gridController.offset / rowHeight).floor());
    final rows = math.max(1,
        (_gridController.position.viewportDimension / rowHeight).ceil() + 1);
    return (
      first: math.min(count, firstRow * 3),
      end: math.min(count, (firstRow + rows) * 3),
    );
  }

  List<String> _prioritizedCovers(List<Entry> entries) {
    final visible = _visibleCoverRange(entries.length);
    final viewportCount = math.max(3, visible.end - visible.first);
    final ahead = viewportCount * (_scrollingFast ? 3 : 2);
    final behind = viewportCount;
    final paths = <String>[];
    final seen = <String>{};
    void add(int index) {
      if (index < 0 || index >= entries.length) return;
      final path = entries[index].imagePath;
      if (path.isNotEmpty && path.toLowerCase() != 'asset' &&
          seen.add(path)) paths.add(path);
    }

    // Always prepare the onscreen images first, including after a fling.
    for (var i = visible.first; i < visible.end; i++) add(i);
    if (_scrollDirection >= 0) {
      for (var i = visible.end; i < math.min(entries.length, visible.end + ahead); i++) add(i);
      for (var i = visible.first - 1; i >= math.max(0, visible.first - behind); i--) add(i);
    } else {
      for (var i = visible.first - 1; i >= math.max(0, visible.first - ahead); i--) add(i);
      for (var i = visible.end; i < math.min(entries.length, visible.end + behind); i++) add(i);
    }
    return paths.take(_maxPinnedCovers).toList();
  }

  void _releaseCoverPin(String path) {
    final pin = _pinnedCovers.remove(path);
    if (pin != null) pin.stream.removeListener(pin.listener);
    _revalidateCovers.remove(path);
  }

  void _clearPinnedCovers() {
    for (final path in _pinnedCovers.keys.toList()) {
      _releaseCoverPin(path);
    }
  }

  Future<void> _pinCover(String path, int generation,
      {Duration timeout = const Duration(seconds: 4)}) async {
    if (!_canWarmCovers(generation) ||
        _failedCovers.contains(path)) return;
    final previous = _pinnedCovers[path];
    if (previous != null && !_revalidateCovers.contains(path)) return;

    // Use exactly the same provider as _CollectionCoverImage. Changing the
    // decoded-image key would defeat prewarming and risk opening-animation jank.
    final ImageProvider provider;
    if (path.contains('http')) {
      provider = CachedNetworkImageProvider(
        coverUrl(path),
        cacheManager: JellyBookCacheManager.instance,
      );
    } else {
      provider = FileImage(File(path));
    }
    // Resolve errors must never strand the initial loading gate.
    final configuration = createLocalImageConfiguration(context);
    final ready = Completer<bool>();
    final stream = provider.resolve(configuration);
    final listener = ImageStreamListener(
      (image, synchronousCall) {
        image.dispose();
        if (!ready.isCompleted) ready.complete(true);
      },
      onError: (error, stackTrace) {
        if (!ready.isCompleted) ready.complete(false);
      },
    );
    try {
      stream.addListener(listener);
    } catch (_) {
      _failedCovers.add(path);
      return;
    }
    bool loaded;
    try {
      loaded = await ready.future.timeout(timeout, onTimeout: () => false);
    } catch (_) {
      loaded = false;
    }
    if (!loaded || !_canWarmCovers(generation) ||
        (_initialCoversReady &&
            !(_latestEntries == null ? <String>[] :
                _prioritizedCovers(_latestEntries!)).contains(path))) {
      stream.removeListener(listener);
      if (!loaded) _failedCovers.add(path);
      return;
    }
    // The old listener stays alive until its replacement has decoded.
    _pinnedCovers[path] = (stream: stream, listener: listener);
    if (previous != null) previous.stream.removeListener(previous.listener);
    _revalidateCovers.remove(path);
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
      if (!_initialCoversReady) {
        // Keep the first viewport hidden until its covers have decoded.
        // A shared deadline prevents a broken/offline image from holding the
        // Collection spinner indefinitely.
        final paths = _prioritizedCovers(entries);
        final visible = _visibleCoverRange(entries.length);
        final initialCount = math.min(paths.length, <String>{
          for (var i = visible.first; i < visible.end; i++)
            if (entries[i].imagePath.isNotEmpty &&
                entries[i].imagePath.toLowerCase() != 'asset')
              entries[i].imagePath,
        }.length);
        final deadline = DateTime.now().add(const Duration(seconds: 6));
        for (var i = 0; i < initialCount && _canWarmCovers(generation); i += 2) {
          final remaining = deadline.difference(DateTime.now());
          if (remaining <= Duration.zero) break;
          await Future.wait([
            for (var j = i; j < math.min(initialCount, i + 2); j++)
              _pinCover(paths[j], generation, timeout: remaining),
          ]);
        }
        if (_canWarmCovers(generation) && identical(entries, _latestEntries)) {
          setState(() => _initialCoversReady = true);
          // The scroll controller will attach when the grid first builds.
          _warmAgain = true;
        }
      } else {
        // Re-evaluate after each pair of loads. A fast fling never waits for
        // an obsolete FIFO queue from the previous scroll position.
        while (_canWarmCovers(generation) && identical(entries, _latestEntries)) {
          final desired = _prioritizedCovers(entries);
          final wanted = desired.toSet();
          for (final path in _pinnedCovers.keys.toList()) {
            if (!wanted.contains(path)) _releaseCoverPin(path);
          }
          final pending = desired.where((path) =>
              !_failedCovers.contains(path) &&
              (!_pinnedCovers.containsKey(path) ||
                  _revalidateCovers.contains(path))).take(2).toList();
          if (pending.isEmpty) break;
          await Future.wait([
            for (final path in pending) _pinCover(path, generation),
          ]);
          await Future<void>.delayed(const Duration(milliseconds: 12));
        }
      }
    } catch (error) {
      // A bad image may fail before its stream listener can be installed.
      // Never leave the Collection waiting forever for an initial cover.
      if (!_initialCoversReady && _canWarmCovers(generation) &&
          identical(entries, _latestEntries)) {
        setState(() => _initialCoversReady = true);
        _warmAgain = true;
      }
      logger.w('Collection cover warmup failed: $error');
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
    _unfilteredEntries = entryList.where((entry) =>
        entry.type != EntryType.folder && isSupportedEntry(entry)).toList();
    entryList = LibraryFilter(
      downloadedOnly: downloadedOnly,
      readingOnly: readingOnly,
    ).filterEntries(entryList);
    entryList.forEach((element) {
      if (element.type == EntryType.folder) {
        logger.f(element.title);
      }
    });
    return entryList;
  }

  @override
  Widget build(BuildContext context) {
    final headerBrightness = Theme.of(context).brightness;
    final headerForeground =
        FloatingSurfacePalette.foreground(headerBrightness);
    return Scaffold(
      // Let covers scroll behind the translucent header, as on the home screen.
      extendBodyBehindAppBar: true,
      appBar: JellyBookHeader(
        topInset: MediaQuery.paddingOf(context).top,
        children: [
          // Match the Reader's 18sp centered title and 56dp side margins.
          // Keep the Collection title inside its compact 36dp header; longer
          // two-line titles can shrink rather than overflow the grid.
          Positioned.fill(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: kToolbarHeight),
              child: Center(
                child: AutoSizeText(
                  name,
                  textAlign: TextAlign.center,
                  maxLines: 2,
                  minFontSize: 10,
                  maxFontSize: 18,
                  stepGranularity: 0.5,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                    color: headerForeground,
                  ),
                ),
              ),
            ),
          ),
          // Paint the button above the centered title so its hit target wins.
          Positioned(
            left: 0,
            top: 0,
            bottom: 0,
            child: SizedBox(
              width: kToolbarHeight,
              child: IconButton(
                tooltip: 'Back',
                icon: Icon(Icons.arrow_back, color: headerForeground),
                onPressed: () => Navigator.of(context).maybePop(),
              ),
            ),
          ),
        ],
      ),
      body: FutureBuilder<List<Entry>>(
        future: _entriesFuture,
        builder: (BuildContext context, AsyncSnapshot snapshot) {
          if (snapshot.hasData && snapshot.data!.isNotEmpty) {
            // The first viewport uses the same readiness gate as Library.
            // Keep pins attached until the actual cards subscribe to them.
            _scheduleCoverWarming(snapshot.data as List<Entry>);
            if (!_initialCoversReady) {
              return const Center(child: CircularProgressIndicator());
            }
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
                    onMounted: (state) => _mountedCards[entry.id] = state,
                    onUnmounted: (state) {
                      if (identical(_mountedCards[entry.id], state)) {
                        _mountedCards.remove(entry.id);
                      }
                    },
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
                              downloadedOnly: downloadedOnly,
                              readingOnly: readingOnly,
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
                        final returnTarget = ValueNotifier<CoverReturnTarget?>(null);
                        await _pushWithPausedCovers(
                          CoverOpeningRoute(
                            sourceRect: coverRect,
                            coverPath: entry.imagePath,
                            pageReady: firstPageReady,
                            skipReturnFade: skipReturnFade,
                            returnTarget: returnTarget,
                            builder: (context) => _VolumeReaderSession(
                              initialEntry: entry,
                              orderedEntries: List<Entry>.of(_unfilteredEntries),
                              openingReady: firstPageReady,
                              skipReturnFade: skipReturnFade,
                              returnTarget: returnTarget,
                              resolveReturnCover: _resolveReturnCover,
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

// A single reader route for the entire reading session. Replacing the keyed
// child disposes its page/zoom controllers and streaming resources; successive
// volumes never accumulate Navigator routes or inherit Collection filters.
class _VolumeReaderSession extends StatefulWidget {
  const _VolumeReaderSession({
    required this.initialEntry,
    required this.orderedEntries,
    required this.openingReady,
    required this.skipReturnFade,
    required this.returnTarget,
    required this.resolveReturnCover,
  });

  final Entry initialEntry;
  final List<Entry> orderedEntries;
  final ValueNotifier<bool> openingReady;
  final ValueNotifier<bool> skipReturnFade;
  final ValueNotifier<CoverReturnTarget?> returnTarget;
  final Future<CoverReturnTarget> Function(Entry) resolveReturnCover;

  @override
  State<_VolumeReaderSession> createState() => _VolumeReaderSessionState();
}

class _VolumeReaderSessionState extends State<_VolumeReaderSession> {
  late int _index;
  bool _changedVolume = false;
  bool _openingVolume = false;
  int? _rollbackIndex;

  @override
  void dispose() {
    // Only the session owns System UI restoration. Individual readers may
    // be replaced without showing the Android bars between volumes.
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    super.dispose();
  }

  void _recoverFailedContinuation() {
    if (!mounted || _rollbackIndex == null) return;
    final previous = _rollbackIndex!;
    _rollbackIndex = null;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Could not open adjacent volume'),
        duration: Duration(seconds: 2),
      ),
    );
    setState(() {
      _index = previous;
      _changedVolume = _index != widget.orderedEntries.indexWhere(
        (entry) => entry.id == widget.initialEntry.id,
      );
    });
  }

  @override
  void initState() {
    super.initState();
    _index = widget.orderedEntries.indexWhere(
      (entry) => entry.id == widget.initialEntry.id,
    );
  }

  Future<void> _prepareCoverReturn() async {
    final entry = _index >= 0
        ? widget.orderedEntries[_index] : widget.initialEntry;
    try {
      widget.returnTarget.value = await widget.resolveReturnCover(entry);
    } catch (_) {
      // Never fall back to the originally tapped cover after a failed lookup.
      widget.returnTarget.value = CoverReturnTarget(
        coverPath: entry.imagePath, rect: null,
      );
      rethrow;
    }
  }

  Entry? _adjacent(int delta) {
    final target = _index + delta;
    return _index >= 0 && target >= 0 &&
            target < widget.orderedEntries.length
        ? widget.orderedEntries[target]
        : null;
  }

  Future<String?> _openAdjacent(int delta) async {
    if (_openingVolume) return 'Already opening a volume';
    final candidate = _adjacent(delta);
    if (candidate == null) {
      return delta > 0 ? 'End of series' : 'Beginning of series';
    }
    _openingVolume = true;
    try {
      // Refresh the downloaded state without changing the Collection order.
      final isar = Isar.getInstance();
      final entry = await isar?.entrys.where().idEqualTo(candidate.id).findFirst();
      if (!mounted) return 'Reader closed';
      if (entry == null || !isSupportedEntry(entry)) {
        return 'Volume is no longer available';
      }
      final extension = entryFileExtension(entry.path);
      if (extension != 'cbz' && !(extension == 'zip' && entry.downloaded)) {
        return 'Volume cannot open in this reader';
      }
      if (entry.downloaded) {
        if (!await Directory(entry.folderPath).exists()) {
          return 'Downloaded pages are unavailable';
        }
      } else {
        final connection = Provider.of<ConnectionManager>(
          context, listen: false,
        ).status;
        if (connection != ConnectionStatus.online) {
          final count = await ReaderPageCache.getPageCount(entry.id);
          final savedIndex = (await ReaderPageCache.getCurrentPage(entry.id)) ??
              entry.pageNum;
          final cached = count != null && count > 0 &&
              (await ReaderPageCache.getPage(
                entry.id, savedIndex.clamp(0, count - 1).toInt(),
              )) != null;
          if (!cached) return 'Volume unavailable offline';
        }
      }
      if (!mounted) return 'Reader closed';
      setState(() {
        _rollbackIndex = _index;
        _index += delta;
        _changedVolume = _index != widget.orderedEntries.indexWhere(
          (entry) => entry.id == widget.initialEntry.id,
        );
      });
      // The keyed reader owns the target volume. If its load fails, recover
      // the previous reader instead of popping the whole session.
      return null;
    } catch (error) {
      logger.w('Could not switch volumes: $error');
      return 'Could not open volume';
    } finally {
      _openingVolume = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final entry = _index >= 0
        ? widget.orderedEntries[_index]
        : widget.initialEntry;
    return CbzReader(
      key: ValueKey(entry.id),
      title: entry.title,
      comicId: entry.id,
      openedDirectly: true,
      openingReady: widget.openingReady,
      skipReturnFade: widget.skipReturnFade,
      nextVolumeTitle: _adjacent(1)?.title,
      onNextVolume: () => _openAdjacent(1),
      previousVolumeTitle: _adjacent(-1)?.title,
      onPreviousVolume: () => _openAdjacent(-1),
      onPrepareCoverReturn: _changedVolume ? _prepareCoverReturn : null,
      // Returning to the initially tapped volume can still be a reload;
      // failure must recover the previous working reader in that case too.
      continuingVolume: _rollbackIndex != null,
      restoreSystemUiOnDispose: false,
      onContinuationLoadFailed: _rollbackIndex != null
          ? _recoverFailedContinuation : null,
    );
  }
}

// Kuro Reader-inspired book card widget
class KuroStyleBookCard extends StatefulWidget {
  final Entry entry;
  final ValueListenable<int>? progressRevision;
  final ValueChanged<Rect> onEntryTapped;
  final ValueChanged<KuroStyleBookCardState>? onMounted;
  final ValueChanged<KuroStyleBookCardState>? onUnmounted;
  final VoidCallback? onEntryLongPressed; // new

  const KuroStyleBookCard({
    required this.entry,
    this.progressRevision,
    required this.onEntryTapped,
    this.onMounted,
    this.onUnmounted,
    this.onEntryLongPressed, // new
  });

  @override
  KuroStyleBookCardState createState() => KuroStyleBookCardState();
}

class KuroStyleBookCardState extends State<KuroStyleBookCard> {
  final GlobalKey _coverKey = GlobalKey();

  Rect? get coverRect {
    final box = _coverKey.currentContext?.findRenderObject();
    return box is RenderBox && box.hasSize
        ? box.localToGlobal(Offset.zero) & box.size : null;
  }

  @override
  void initState() {
    super.initState();
    widget.onMounted?.call(this);
  }

  @override
  void didUpdateWidget(KuroStyleBookCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.entry.id != widget.entry.id) {
      oldWidget.onUnmounted?.call(this);
      widget.onMounted?.call(this);
    }
  }

  @override
  void dispose() {
    widget.onUnmounted?.call(this);
    super.dispose();
  }

  void _openFromCover() {
    widget.onEntryTapped(coverRect ?? Rect.zero);
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
                            final isUnread =
                                LibraryFilter.isUnread(widget.entry);
                            final isFinished =
                                LibraryFilter.isFinished(widget.entry);
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
