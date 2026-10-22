// The purpose of this file is to create a list of entries from a selected folder
import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:isar/isar.dart';
import 'package:kurage/models/entry.dart';
import 'package:kurage/providers/supported_formats.dart';
import 'package:kurage/providers/volume_sort.dart';
import 'package:kurage/providers/library_filter.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:kurage/models/folder.dart';
import 'package:kurage/l10n/app_localizations.dart';
import 'package:kurage/themes/theme_constants.dart';
import 'package:kurage/widgets/floating_surface_header.dart';
import 'package:kurage/variables.dart';
import 'package:kurage/cache/cover_cache.dart';
import 'package:kurage/cache/collection_cover_prewarmer.dart';
import 'package:kurage/cache/speculative_cover_prefetcher.dart';
import 'package:auto_size_text/auto_size_text.dart';
import 'package:kurage/providers/server_progress_revision.dart';
import 'package:kurage/cache/reader_page_cache.dart';
import 'package:kurage/screens/readingScreens/cbz_reader.dart';
import 'package:kurage/widgets/cover_opening_route.dart';
import 'package:kurage/widgets/volume_actions.dart';
import 'package:provider/provider.dart';
import 'package:kurage/providers/connection_manager.dart';

class CollectionScreen extends StatefulWidget {
  final String folderId;
  final String name;
  final String image;
  final List<String> bookIds;
  final bool downloadedOnly;
  final bool readingOnly;

  const CollectionScreen({
    super.key,
    required this.folderId,
    required this.name,
    required this.image,
    required this.bookIds,
    this.downloadedOnly = false,
    this.readingOnly = false,
  });

  @override
  State<CollectionScreen> createState() => _CollectionScreenState();
}

class _CollectionScreenState extends State<CollectionScreen> with WidgetsBindingObserver {

  late final String folderId;
  late final String name;
  late final String image;
  late final List<String> bookIds;
  late final bool downloadedOnly;
  late final bool readingOnly;

  final GlobalKey<NavigatorState> _readerNavigatorKey = GlobalKey<NavigatorState>();
  final ValueNotifier<CoverOpeningRoute?> _activeCoverRoute = ValueNotifier(null);
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
  bool _inForeground = true;
  ConnectionManager? _prefetchConnection;
  late final CollectionCoverPrewarmer _coverPrewarmer = CollectionCoverPrewarmer(
    isActive: () => mounted && _inForeground,
    isCurrentRoute: () => ModalRoute.of(context)?.isCurrent ?? true,
    visibleRange: _visibleCoverRange,
    imageConfiguration: () => createLocalImageConfiguration(context),
    onInitialReady: () => setState(() {}),
    onWarmComplete: _scheduleSpeculative,
  );

  @override
  void initState() {
    super.initState();
    folderId = widget.folderId;
    name = widget.name;
    image = widget.image;
    bookIds = widget.bookIds;
    downloadedOnly = widget.downloadedOnly;
    readingOnly = widget.readingOnly;
    _entriesFuture = getEntries();
    _gridController.addListener(_onGridScrolled);
    serverProgressRevision.addListener(_onServerProgressRefreshed);
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final manager = context.read<ConnectionManager>();
    if (!identical(_prefetchConnection, manager)) {
      _prefetchConnection?.removeListener(_onPrefetchConnectionChanged);
      _prefetchConnection = manager;
      manager.addListener(_onPrefetchConnectionChanged);
    }
  }

  void _onPrefetchConnectionChanged() {
    if (_prefetchConnection?.status == ConnectionStatus.online) {
      _scheduleSpeculative();
    } else {
      _stopSpeculative();
    }
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
          !identical(displayed, _latestEntries)) {
        return;
      }
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
                entry.progress == newest.progress)) {
          continue;
        }
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
        !(ModalRoute.of(context)?.isCurrent ?? false)) {
      return;
    }
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
    if (!mounted) {
      return CoverReturnTarget(
        coverPath: entry.imagePath, rect: null,
      );
    }
    final rect = _mountedCards[entry.id]?.coverRect;
    return CoverReturnTarget(
      coverPath: entry.imagePath,
      rect: rect == null || rect.isEmpty ? null : rect,
    );
  }

  // Long-press manages one volume; the sheet never owns queue or disk work.
  Future<void> _showVolumeActions(Entry entry) => showVolumeActions(
        context,
        entry,
        onChanged: (change) {
          if (!mounted) return;
          if (change == VolumeActionChange.download || readingOnly) {
            _refreshEntries();
          } else {
            // A progress update needs only the status widgets to repaint.
            _cardProgressRevision.value++;
          }
        },
      );

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

  void _stopSpeculative() => SpeculativeCoverPrefetcher.instance.stop(this);

  bool get _mayPrefetchCollection => mounted && _inForeground &&
      !_coverPrewarmer.isPaused && _coverPrewarmer.initialReady &&
      _prefetchConnection?.status == ConnectionStatus.online &&
      (ModalRoute.of(context)?.isCurrent ?? false);

  bool get _collectionPrefetchBusy =>
      _coverPrewarmer.isWarming || _coverPrewarmer.isScheduled ||
      (_gridController.hasClients &&
          _gridController.position.isScrollingNotifier.value);

  void _scheduleSpeculative() {
    if (!_mayPrefetchCollection) {
      _stopSpeculative();
      return;
    }
    SpeculativeCoverPrefetcher.instance.schedule(
      owner: this,
      label: 'Collection',
      allowed: () => _mayPrefetchCollection,
      busy: () => _collectionPrefetchBusy,
      urls: _collectionVolumeUrls,
    );
  }

  Future<List<String>> _collectionVolumeUrls() async {
    // Always use the unfiltered series, even when Library opened a filtered
    // Collection. The displayed list and decoded-image pins remain untouched.
    final urls = <String>[];
    final seen = <String>{};
    for (final entry in _unfilteredEntries) {
      final path = entry.imagePath;
      if (path.isEmpty || !path.contains('http')) continue;
      final url = coverUrl(path);
      if (seen.add(url)) urls.add(url);
    }
    return urls;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _inForeground = true;
      _coverPrewarmer.revalidate();
      _scheduleSpeculative();
    } else {
      _stopSpeculative();
      _inForeground = false;
    }
  }

  @override
  void dispose() {
    _stopSpeculative();
    _prefetchConnection?.removeListener(_onPrefetchConnectionChanged);
    _inForeground = false;
    serverProgressRevision.removeListener(_onServerProgressRefreshed);
    _cardProgressRevision.dispose();
    _activeCoverRoute.dispose();
    WidgetsBinding.instance.removeObserver(this);
    _coverPrewarmer.dispose();
    _gridController.removeListener(_onGridScrolled);
    _gridController.dispose();
    super.dispose();
  }

  // Ordinary builds of the same entry list must not restart warming.
  void _scheduleCoverWarming([List<Entry>? entries]) {
    if (entries != null) {
      if (identical(entries, _latestEntries)) return;
      _latestEntries = entries;
      _coverPrewarmer.setCovers([
        for (final entry in entries) entry.imagePath,
      ]);
      return;
    }
    _coverPrewarmer.schedule();
  }

  void _pauseCoverWarming() {
    _stopSpeculative();
    _coverPrewarmer.pause();
  }

  void _resumeCoverWarming() {
    if (!mounted) return;
    _coverPrewarmer.resume();
    _scheduleSpeculative();
  }

  Future<T?> _pushWithPausedCovers<T extends Object?>(
      TransitionRoute<T> route, {bool inCollection = false}) async {
    _pauseCoverWarming();
    try {
      final navigator = inCollection
          ? _readerNavigatorKey.currentState!
          : Navigator.of(context);
      final result = navigator.push<T>(route);
      if (inCollection && route is CoverOpeningRoute) {
        _activeCoverRoute.value = route as CoverOpeningRoute;
      }
      return await result;
    } finally {
      try {
        await route.completed;
      } finally {
        if (mounted && identical(_activeCoverRoute.value, route)) {
          _activeCoverRoute.value = null;
        }
        _resumeCoverWarming();
      }
    }
  }

  void _onGridScrolled() {
    if (!_gridController.hasClients || !_coverPrewarmer.initialReady) return;
    if (!_coverPrewarmer.recordScroll(_gridController.offset)) return;
    _scheduleSpeculative();
    _coverPrewarmer.schedule();
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

  final isar = Isar.getInstance();

  Future<List<Entry>> getEntries() async {
    List<Entry> entryList = await isar!.entrys
        .where()
        .filter()
        .anyOf(bookIds, (q, String id) => q.idEqualTo(id))
        .findAll();
    entryList.sort(compareVolumeEntries);
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
    final header = FloatingSurfaceHeader(
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
      );
    return Scaffold(
      // Let covers scroll behind the translucent header, as on the home screen.
      extendBodyBehindAppBar: true,
      appBar: PreferredSize(
        preferredSize: header.preferredSize,
        child: ValueListenableBuilder<CoverOpeningRoute?>(
          valueListenable: _activeCoverRoute,
          child: header,
          builder: (context, route, child) {
            final animation = route?.animation ??
                const AlwaysStoppedAnimation<double>(0);
            return AnimatedBuilder(
              animation: animation,
              child: child,
              builder: (context, headerChild) {
                final value = animation.value.clamp(0.0, 1.0).toDouble();
                final double opacity;
                if (animation.status == AnimationStatus.reverse) {
                  final elapsed = 1.0 - value;
                  final onCoverPage = route?.skipReturnFade?.value ?? false;
                  final shrink = Curves.easeInOutCubic.transform(
                    onCoverPage
                        ? elapsed
                        : ((elapsed - 0.4) / 0.6)
                            .clamp(0.0, 1.0)
                            .toDouble(),
                  );
                  opacity = ((shrink - 0.15) / 0.25)
                      .clamp(0.0, 1.0)
                      .toDouble();
                } else {
                  opacity = (1.0 - value / 0.45)
                      .clamp(0.0, 1.0)
                      .toDouble();
                }
                return IgnorePointer(
                  ignoring: route != null,
                  child: Opacity(opacity: opacity, child: headerChild),
                );
              },
            );
          },
        ),
      ),
      body: NavigatorPopHandler(
        onPopWithResult: (_) => _readerNavigatorKey.currentState?.maybePop(),
        child: HeroControllerScope.none(
          child: Navigator(
            key: _readerNavigatorKey,
            onDidRemovePage: (_) {},
            pages: [
              MaterialPage<void>(
                key: const ValueKey('collection-grid'),
                child: FutureBuilder<List<Entry>>(
        future: _entriesFuture,
        builder: (BuildContext context, AsyncSnapshot snapshot) {
          if (snapshot.hasData && snapshot.data!.isNotEmpty) {
            // The first viewport uses the same readiness gate as Library.
            // Keep pins attached until the actual cards subscribe to them.
            _scheduleCoverWarming(snapshot.data as List<Entry>);
            if (!_coverPrewarmer.initialReady) {
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
                            builder: (context) => CollectionScreen(
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
                        if (!mounted || !context.mounted) return;
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

                      // Open supported archives through the cover animation.
                      final extension = entryFileExtension(entry.path);
                      final isArchive = const ['cbz', 'zip'].contains(extension);
                      final streamable = extension == 'cbz';
                      if (isArchive && (entry.downloaded || streamable)) {
                        final firstPageReady = ValueNotifier<bool>(false);
                        final openingState = ValueNotifier<ReaderOpeningState>(
                          ReaderOpeningState.preparing,
                        );
                        final skipReturnFade = ValueNotifier<bool>(false);
                        final returnTarget = ValueNotifier<CoverReturnTarget?>(null);
                        await _pushWithPausedCovers(
                          CoverOpeningRoute(
                            sourceRect: coverRect,
                            coverPath: entry.imagePath,
                            pageReady: firstPageReady,
                            openingState: openingState,
                            skipReturnFade: skipReturnFade,
                            returnTarget: returnTarget,
                            builder: (readerContext) {
                              final mediaQuery = MediaQuery.of(readerContext);
                              return MediaQuery(
                                data: mediaQuery.copyWith(
                                  padding: mediaQuery.padding.copyWith(
                                    top: MediaQuery.paddingOf(this.context).top,
                                  ),
                                ),
                                child: _VolumeReaderSession(
                                  initialEntry: entry,
                                  orderedEntries: List<Entry>.of(_unfilteredEntries),
                                  openingReady: firstPageReady,
                                  openingState: openingState,
                                  skipReturnFade: skipReturnFade,
                                  returnTarget: returnTarget,
                                  resolveReturnCover: _resolveReturnCover,
                                ),
                              );
                            },
                          ),
                          inCollection: true,
                        );
                        _refreshEntries();
                        return;
                      }
                      // Supported formats without a direct reader can still
                      // be queued or marked via the same volume actions.
                      await _showVolumeActions(entry);
                    },
                    onEntryLongPressed: () => _showVolumeActions(entry),
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
              ),
            ],
          ),
        ),
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
    required this.openingState,
    required this.skipReturnFade,
    required this.returnTarget,
    required this.resolveReturnCover,
  });

  final Entry initialEntry;
  final List<Entry> orderedEntries;
  final ValueNotifier<bool> openingReady;
  final ValueNotifier<ReaderOpeningState> openingState;
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
      openingReady: widget.openingReady,
      openingState: widget.openingState,
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
    super.key,
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
    final provider = coverImageProvider(path);
    if (provider == null) {
      return Image.asset('assets/images/NoCoverArt.png', fit: BoxFit.cover);
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
