// The purpose of this file is to create the library screen (this is part of the list of screens in the bottom navigation bar)
import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:jellybook/models/folder.dart';
import 'package:jellybook/providers/fetch_categories.dart';
import 'package:jellybook/providers/library_filter.dart';
import 'package:jellybook/providers/download_queue.dart';
import 'package:jellybook/providers/delete_comic.dart';
import 'package:jellybook/providers/supported_formats.dart';
import 'package:jellybook/widgets/item_action_sheet.dart';
import 'package:jellybook/widgets/download_queue_sheet.dart';
import 'package:jellybook/providers/server_progress_revision.dart';
import 'package:jellybook/screens/collection_screen.dart';
import 'package:isar/isar.dart';
import 'package:jellybook/models/entry.dart';
import 'package:jellybook/l10n/app_localizations.dart';
import 'package:jellybook/themes/theme_constants.dart';
import 'package:jellybook/widgets/floating_surface_header.dart';
import 'package:jellybook/variables.dart';
import 'package:jellybook/cache/cover_cache.dart';
import 'package:jellybook/cache/speculative_cover_prefetcher.dart';
import 'package:infinite_scroll_pagination/infinite_scroll_pagination.dart';
import 'package:provider/provider.dart';
import 'package:jellybook/providers/connection_manager.dart';
import 'package:jellybook/providers/theme_provider.dart';

enum _SeriesAction { downloadRemaining, deleteDownloaded }

class LibraryScreen extends StatefulWidget {
  // Library stays mounted in HomeScreen's IndexedStack across tab changes.
  final bool isActive;

  const LibraryScreen({super.key, this.isActive = true});

  @override
  State<LibraryScreen> createState() => _LibraryScreenState();
}

class _LibraryScreenState extends State<LibraryScreen> with WidgetsBindingObserver {
  static const _pageSize = 20;
  static const double _gridTopGap = 12;

  double _headerHeight(BuildContext context) =>
      MediaQuery.paddingOf(context).top + FloatingSurfaceHeader.toolbarHeight;
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

  late Future<(List<Entry>, List<Folder>)> _categoriesFuture;
  bool _initialCoversReady = false;
  // Keep decoded startup covers alive until the first grid frame is painted.
  final List<({ImageStream stream, ImageStreamListener listener,
    Completer<void> ready})> _startupCoverPins = [];

  // Once the grid is visible, hold a small moving set of decoded covers in
  // memory. Scroll position alone retains the grid's widgets, not images a few
  // rows beyond Flutter's offscreen sliver cache.
  static const int _maxScrollCoverPins = 48;
  static const int _maxConcurrentScrollCoverLoads = 2;
  final Map<String, ({ImageStream stream, ImageStreamListener listener})>
      _scrollCoverPins = {};
  final Set<String> _scrollCoverLoading = {};
  final Set<String> _scrollCoverFailures = {};
  // After Android resumes, re-resolve existing pins without dropping their
  // listeners first. At most two replacement streams are live at once.
  final Set<String> _scrollCoverRefreshPending = {};
  final Map<String, ({ImageStream stream, ImageStreamListener listener})>
      _scrollCoverReplacements = {};
  // Permit one bounded refresh while the retained Library tab is offstage in
  // Settings; ordinary scroll warming remains limited to the active Library.
  bool _resumeWarmWhileInactive = false;
  List<String> _scrollCoverPriority = const [];
  bool _scrollPumpScheduled = false;
  String? _scrollWindowKey;
  int _scrollCatalogVersion = 0;
  ScrollController? _lastScrollSource;
  double? _lastScrollOffset;
  DateTime? _lastScrollAt;
  double _scrollVelocity = 0;
  int _scrollDirection = 1;

  static const int _maxSpeculativeSeries = 8;

  ConnectionManager? _connectionManager;
  bool _wasOffline = false;

  bool _errorModalShowing = false;
  List<Folder>? _lastFolders;
  // Each filter combination retains its own scroll position.
  final ScrollController _allScrollController = ScrollController();
  final ScrollController _downloadedScrollController = ScrollController();
  final ScrollController _readingScrollController = ScrollController();
  final ScrollController _downloadedReadingScrollController = ScrollController();
  ScrollController get _libraryScrollController {
    if (_filter.downloadedOnly && _filter.readingOnly) {
      return _downloadedReadingScrollController;
    }
    if (_filter.downloadedOnly) return _downloadedScrollController;
    if (_filter.readingOnly) return _readingScrollController;
    return _allScrollController;
  }
  String get _libraryPageKey {
    if (_filter.downloadedOnly && _filter.readingOnly) {
      return 'library-downloaded-reading';
    }
    if (_filter.downloadedOnly) return 'library-downloaded';
    if (_filter.readingOnly) return 'library-reading';
    return 'library-all';
  }
  LibraryFilter _filter = const LibraryFilter();
  Set<String>? _readingIdsCache;
  bool _hadMatchesWhenLeaving = false;

  @override
  void didUpdateWidget(covariant LibraryScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.isActive && !widget.isActive) {
      _stopSpeculative();
      // An intentionally empty filtered view stays empty across tab changes.
      _hadMatchesWhenLeaving = _filter.isActive && _lastFolders != null &&
          _visibleFolders(_lastFolders!).isNotEmpty;
    } else if (!oldWidget.isActive && widget.isActive) {
      // Settings may have changed eligibility; discard cached Reading IDs.
      _readingIdsCache = null;
      if (_hadMatchesWhenLeaving && _filter.isActive &&
          _lastFolders != null && _visibleFolders(_lastFolders!).isEmpty) {
        // The last matching volume vanished while Library was offstage.
        _filter = const LibraryFilter();
        _coverSignature = null;
        _scheduleCoverWarming();
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text(
                'No matching volumes remaining — showing all series',
              ),
              duration: Duration(seconds: 2),
            ),
          );
        });
      }
      _hadMatchesWhenLeaving = false;
      // The IndexedStack preserves this tab (and its decoded-image pins).
      // Recheck the current window in case Android reclaimed other images.
      _scrollWindowKey = null;
      _scheduleCoverWarming();
      _scheduleSpeculative();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && widget.isActive) _refreshOnLibraryReturnIfStale();
      });
    }
  }

  Set<String> _matchingIds() {
    if (!_filter.isActive) return const <String>{};
    final isar = Isar.getInstance();
    // Keep Downloaded eligibility live, as before Phase 3. Only the Reading
    // scan needs caching; otherwise every fling would scan the full catalog.
    if (!_filter.readingOnly) return _filter.matchingEntryIds(isar);
    final readingIds = _readingIdsCache ??=
        const LibraryFilter(readingOnly: true).matchingEntryIds(isar);
    if (!_filter.downloadedOnly) return readingIds;
    return const LibraryFilter(downloadedOnly: true)
        .matchingEntryIds(isar)
        .where(readingIds.contains)
        .toSet();
  }

  List<Folder> _visibleFolders(List<Folder> all) =>
      _filter.filterFolders(all, _matchingIds());

  void _selectFilter(LibraryFilter next) {
    setState(() {
      _filter = next;
      _readingIdsCache = null;
    });
    _coverSignature = null;
    _scrollWindowKey = null;
    _scrollVelocity = 0;
    _lastScrollSource = null;
    _scheduleCoverWarming();
    _scheduleSpeculative();
  }

  bool _inForeground = true;
  bool _startupSyncScheduled = false;
  bool _startupSyncPending = false;
  bool _serverRefreshStarted = false;
  Future<void>? _activeRefresh;
  // True only after the app was actually backgrounded (including screen lock).
  // A brief inactive/focus change alone should not cause a network refresh.
  bool _wasBackgrounded = false;
  static const _libraryReturnRefreshInterval = Duration(minutes: 1);
  DateTime? _lastSuccessfulServerRefreshAt;
  DateTime? _lastServerRefreshAttemptAt;
  bool _warmScheduled = false;
  bool _warming = false;
  bool _warmAgain = false;
  String? _coverSignature;

  // Tell visible cards to recalculate progress after leaving a collection.
  final ValueNotifier<int> _progressRevision = ValueNotifier<int>(0);

  @override
  void initState() {
    super.initState();
    // Never reissue a category request merely because a parent rebuilds.
    _categoriesFuture = getServerCategories(
      force: false,
      onCacheHit: _scheduleStartupSync,
    ).then((result) {
      // Without a cache hit, initial loading already fetched the server.
      if (!_startupSyncScheduled) {
        _lastSuccessfulServerRefreshAt = DateTime.now();
      }
      return result;
    });
    WidgetsBinding.instance.addObserver(this);
    _allScrollController.addListener(_onLibraryScroll);
    _downloadedScrollController.addListener(_onLibraryScroll);
    _readingScrollController.addListener(_onLibraryScroll);
    _downloadedReadingScrollController.addListener(_onLibraryScroll);
  }

  // A warm launch reads Isar first. Schedule the remote revalidation after
  // that initial data has been rendered; don't make the first frame wait for it.
  void _scheduleStartupSync() {
    if (_startupSyncScheduled) return;
    _startupSyncScheduled = true;
    unawaited(_syncAfterCachedFirstFrame());
  }

  Future<void> _syncAfterCachedFirstFrame() async {
    try {
      await _categoriesFuture;
    } catch (_) {
      return;
    }
    if (!mounted) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _startupSyncPending = true;
      _tryPendingSync();
    });
  }

  void _tryPendingSync() {
    if (!_startupSyncPending || !mounted || !_inForeground ||
        !_initialCoversReady || _activeRefresh != null ||
        _connectionManager?.status != ConnectionStatus.online) {
      return;
    }
    _startupSyncPending = false;
    if (!_serverRefreshStarted) unawaited(_reloadCategories(background: true));
  }

  // Only revalidate on returning to Library; never poll while it is idle.
  void _refreshOnLibraryReturnIfStale() {
    if (!mounted || !widget.isActive || !_inForeground ||
        !_initialCoversReady || _activeRefresh != null ||
        _connectionManager?.status != ConnectionStatus.online) {
      return;
    }
    if (_startupSyncPending) {
      _tryPendingSync();
      return;
    }
    final now = DateTime.now();
    final success = _lastSuccessfulServerRefreshAt;
    final attempt = _lastServerRefreshAttemptAt;
    if ((success != null &&
            now.difference(success) < _libraryReturnRefreshInterval) ||
        (attempt != null &&
            now.difference(attempt) < _libraryReturnRefreshInterval)) {
      return;
    }
    unawaited(_reloadCategories(background: true));
  }

  Future<void> _reloadCategories({bool background = false}) {
    final active = _activeRefresh;
    if (active != null) return active;
    _lastServerRefreshAttemptAt = DateTime.now();
    _serverRefreshStarted = true;
    final operation = _performReloadCategories(background);
    _activeRefresh = operation;
    return operation.whenComplete(() {
      _activeRefresh = null;
      // A resume while a request was running may require another GET.
      _tryPendingSync();
    });
  }

  Future<void> _performReloadCategories(bool background) async {
    final future = getServerCategories(force: true);
    if (!background) {
      _readingIdsCache = null;
      setState(() => _categoriesFuture = future);
    }
    try {
      final result = await future;
      _lastSuccessfulServerRefreshAt = DateTime.now();
      if (mounted) {
        // Silent revalidation must never replace a cached first frame with
        // a loading spinner, or show an error dialog if Jellyfin is down.
        if (background) {
          _readingIdsCache = null;
          setState(() => _categoriesFuture = Future.value(result));
        }
        // Server progress is now in Isar. Cards read progress from there.
        _progressRevision.value++;
        serverProgressRevision.value++;
      }
    } catch (error) {
      if (background) logger.w('Background library sync failed: $error');
      // Interactive refresh keeps the existing FutureBuilder error handling.
    }
  }

  void _releaseStartupCoverPins() {
    for (final pin in _startupCoverPins) {
      pin.stream.removeListener(pin.listener);
      // Let any in-progress warm finish if this widget is disposed.
      if (!pin.ready.isCompleted) pin.ready.complete();
    }
    _startupCoverPins.clear();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _inForeground = state == AppLifecycleState.resumed;
    if (_inForeground) {
      // A real background/lock transition may have reclaimed decoded images.
      // Revalidate the current pins, preserving each until a replacement is
      // ready. Do it in Settings too, before switching back to Library.
      if (_wasBackgrounded && _initialCoversReady) {
        _scrollCoverRefreshPending.addAll(_scrollCoverPins.keys);
        _scrollCoverFailures.clear();
        _scrollVelocity = 0;
        _resumeWarmWhileInactive = !widget.isActive;
      }
      _scrollWindowKey = null;
      _scheduleCoverWarming();
      _scheduleSpeculative();
      // Refresh immediately after an actual background/lock transition,
      // regardless of how briefly the app was away. This is a silent fetch.
      if (_wasBackgrounded) {
        _wasBackgrounded = false;
        _serverRefreshStarted = false;
        _startupSyncPending = true;
      }
      _tryPendingSync();
    } else if (state == AppLifecycleState.hidden ||
        state == AppLifecycleState.paused) {
      _wasBackgrounded = true;
      _stopSpeculative();
    }
  }

  bool get _canWarm => mounted && _inForeground &&
      (widget.isActive || _resumeWarmWhileInactive) &&
      (ModalRoute.of(context)?.isCurrent ?? true);

  // An inexpensive scroll signal. Work is coalesced into a post-frame pass,
  // where the new viewport is sampled; no setState or image resolution here.
  void _stopSpeculative() => SpeculativeCoverPrefetcher.instance.stop(this);

  bool get _mayPrefetchLibrary => mounted && _inForeground &&
      widget.isActive && _initialCoversReady && _lastFolders != null &&
      _connectionManager?.status == ConnectionStatus.online &&
      (ModalRoute.of(context)?.isCurrent ?? false);

  bool get _libraryPrefetchBusy => _warming || _warmScheduled ||
      _activeRefresh != null || _scrollPumpScheduled ||
      _scrollCoverLoading.isNotEmpty ||
      (_libraryScrollController.hasClients &&
          _libraryScrollController.position.isScrollingNotifier.value);

  void _scheduleSpeculative() {
    if (!_mayPrefetchLibrary) {
      _stopSpeculative();
      return;
    }
    SpeculativeCoverPrefetcher.instance.schedule(
      owner: this,
      label: 'Library',
      allowed: () => _mayPrefetchLibrary,
      busy: () => _libraryPrefetchBusy,
      urls: _visibleSeriesVolumeUrls,
    );
  }

  Future<List<String>> _visibleSeriesVolumeUrls() async {
    final all = _lastFolders;
    final isar = Isar.getInstance();
    if (all == null || isar == null) return const [];
    final folders = _visibleFolders(all);
    final range = _visibleCoverRange(folders.length);
    final series = folders.skip(range.first)
        .take(math.min(_maxSpeculativeSeries, range.end - range.first))
        .toList();
    if (series.isEmpty) return const [];
    final ids = <String>{for (final folder in series) ...folder.bookIds};
    if (ids.isEmpty) return const [];
    final entries = await isar.entrys.filter()
        .anyOf(ids.toList(), (q, String id) => q.idEqualTo(id))
        .findAll();
    final byId = {
      for (final entry in entries)
        if (entry.type != EntryType.folder && isSupportedEntry(entry))
          entry.id: entry,
    };
    final urls = <String>[];
    final seen = <String>{};
    // One volume per visible series per rotation. Continue without a stage
    // boundary until all their eligible covers are on disk.
    final longest = series.fold<int>(0,
        (maxCount, folder) => math.max(maxCount, folder.bookIds.length));
    for (var index = 0; index < longest; index++) {
      for (final folder in series) {
        if (index >= folder.bookIds.length) continue;
        final path = byId[folder.bookIds[index]]?.imagePath;
        if (path == null || !path.contains('http')) continue;
        final url = coverUrl(path);
        if (seen.add(url)) urls.add(url);
      }
    }
    return urls;
  }

  void _onLibraryScroll() {
    if (!_initialCoversReady || !_canWarm) return;
    final controller = _libraryScrollController;
    if (!controller.hasClients) return;
    if (_lastScrollSource != controller) {
      _lastScrollSource = controller;
      _lastScrollOffset = null;
      _lastScrollAt = null;
      _scrollVelocity = 0;
    }
    final now = DateTime.now();
    final offset = controller.offset;
    final lastOffset = _lastScrollOffset;
    final lastAt = _lastScrollAt;
    if (lastOffset != null && lastAt != null) {
      final elapsed = now.difference(lastAt).inMilliseconds;
      final delta = offset - lastOffset;
      if (delta.abs() > 0.5 && elapsed >= 8) {
        _scrollDirection = delta > 0 ? 1 : -1;
        _scrollVelocity = (_scrollVelocity * 0.4) +
            ((delta.abs() * 1000 / elapsed) * 0.6);
      }
    }
    _lastScrollOffset = offset;
    _lastScrollAt = now;
    _scheduleSpeculative();
    _scheduleCoverWarming();
  }

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
      // During cold startup the grid is deliberately not mounted yet.
      // Estimate the visible rows to decode them before the first grid frame.
      final width = math.max(1.0, MediaQuery.sizeOf(context).width - 16);
      final rowHeight = ((width - 6) / 2) / 0.63 + 6;
      final gridTop = _headerHeight(context) + _gridTopGap;
      final rows = math.max(1,
          ((MediaQuery.sizeOf(context).height - gridTop) / rowHeight).ceil() + 1);
      return (first: 0, end: math.min(count, math.max(10, rows * 2)));
    }
    final viewport = _libraryScrollController.position.viewportDimension;
    final offset = _libraryScrollController.offset;
    final width = math.max(1.0, MediaQuery.sizeOf(context).width - 16);
    final tileWidth = (width - 6) / 2;
    final rowHeight = tileWidth / 0.63 + 6;
    final gridTop = _headerHeight(context) + _gridTopGap;
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
      if (_initialCoversReady) {
        _updateScrollCoverWindow();
        return;
      }
      final allFolders = _lastFolders;
      if (allFolders == null) return;
      final folders = _visibleFolders(allFolders);
      final signatureAtStart = _coverSignature;
      final range = _visibleCoverRange(folders.length);
      // At most two concurrent decodes, joining the exact same providers
      // used by SeriesCard. Avoid competing with navigation/reader work.
      for (var i = range.first; i < range.end && _canWarm; i += 2) {
        await Future.wait([
          for (var j = i; j < math.min(range.end, i + 2); j++)
            _warmCover(folders[j].image),
        ]);
      }
      if (_canWarm && !_initialCoversReady &&
          signatureAtStart == _coverSignature) {
        setState(() => _initialCoversReady = true);
        // Begin the scrolling prewarmer only after the first grid frame. This
        // stays separate from the startup pins' release callback.
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _scheduleCoverWarming();
        });
        // Image widgets subscribe to the pinned streams in this frame.
        // Release the extra listeners only after those widgets have mounted.
        WidgetsBinding.instance.addPostFrameCallback((_) {
          _releaseStartupCoverPins();
          // Recover pending downloads only after startup covers have painted,
          // so resumed transfers don't compete with the first Library frame.
          unawaited(DownloadQueue.instance.restoreQueue()
              .whenComplete(_scheduleSpeculative));
          // The grid has painted; retry any startup sync waiting on covers.
          _tryPendingSync();
        });
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
    final provider = _libraryCoverProvider(path, context);
    if (provider == null) return;
    try {
      if (!_initialCoversReady) {
        // Unlike precacheImage, this listener remains attached across frames.
        // Previously warmed images cannot be evicted before the grid appears.
        final ready = Completer<void>();
        final stream = provider.resolve(createLocalImageConfiguration(context));
        final listener = ImageStreamListener(
          (image, synchronousCall) {
            image.dispose();
            if (!ready.isCompleted) ready.complete();
          },
          onError: (error, stackTrace) {
            // Missing covers are shown by Image.errorBuilder later.
            if (!ready.isCompleted) ready.complete();
          },
        );
        _startupCoverPins.add((
          stream: stream,
          listener: listener,
          ready: ready,
        ));
        stream.addListener(listener);
        await ready.future;
      } else {
        await precacheImage(provider, context, onError: (_, __) {});
      }
    } catch (_) {
      // Offline, unreadable, or missing covers should not block others.
    }
  }

  void _releaseScrollCover(String path) {
    final replacement = _scrollCoverReplacements.remove(path);
    if (replacement != null) {
      replacement.stream.removeListener(replacement.listener);
    }
    final pin = _scrollCoverPins.remove(path);
    if (pin != null) pin.stream.removeListener(pin.listener);
    _scrollCoverLoading.remove(path);
    _scrollCoverRefreshPending.remove(path);
  }

  void _releaseScrollCoverPins() {
    for (final path in _scrollCoverPins.keys.toList()) {
      _releaseScrollCover(path);
    }
    _scrollCoverPriority = const [];
    _scrollWindowKey = null;
    _resumeWarmWhileInactive = false;
  }

  void _scheduleScrollCoverPump() {
    if (_scrollPumpScheduled || !_initialCoversReady || !_canWarm) return;
    _scrollPumpScheduled = true;
    scheduleMicrotask(() {
      _scrollPumpScheduled = false;
      if (!_canWarm || !_initialCoversReady) return;
      // The newest window takes priority. No stale FIFO backlog builds up
      // during a fast fling or an abrupt reversal.
      for (final path in _scrollCoverPriority) {
        if (_scrollCoverLoading.length >= _maxConcurrentScrollCoverLoads) break;
        if (_scrollCoverLoading.contains(path) ||
            _scrollCoverFailures.contains(path)) {
          continue;
        }
        if (_scrollCoverPins.containsKey(path)) {
          if (_scrollCoverRefreshPending.contains(path)) {
            _refreshScrollCoverPin(path);
          }
        } else {
          _startScrollCoverPin(path);
        }
      }
      // Once Settings' one-time resume pass finishes, stop warming offstage.
      if (_resumeWarmWhileInactive && _scrollCoverLoading.isEmpty &&
          !_scrollCoverPriority.any((path) =>
              _scrollCoverRefreshPending.contains(path) ||
              (!_scrollCoverPins.containsKey(path) &&
                  !_scrollCoverFailures.contains(path)))) {
        _resumeWarmWhileInactive = false;
      }
    });
  }

  // Resolve the same resized provider anew. Retain the old image listener
  // until the replacement has decoded so a routine resume never creates a
  // gap in the cached viewport. Failure leaves the original pin in place.
  void _refreshScrollCoverPin(String path) {
    final previous = _scrollCoverPins[path];
    if (previous == null) return;
    try {
      final provider = _libraryCoverProvider(path, context);
      if (provider == null) {
        _scrollCoverRefreshPending.remove(path);
        return;
      }
      final stream = provider.resolve(createLocalImageConfiguration(context));
      late final ImageStreamListener listener;
      listener = ImageStreamListener(
        (image, synchronousCall) {
          image.dispose();
          if (_scrollCoverReplacements[path]?.stream != stream) return;
          _scrollCoverPins[path] = (stream: stream, listener: listener);
          _scrollCoverReplacements.remove(path);
          previous.stream.removeListener(previous.listener);
          _scrollCoverLoading.remove(path);
          _scrollCoverRefreshPending.remove(path);
          _scheduleScrollCoverPump();
        },
        onError: (error, stackTrace) {
          if (_scrollCoverReplacements[path]?.stream != stream) return;
          _scrollCoverReplacements.remove(path);
          stream.removeListener(listener);
          _scrollCoverLoading.remove(path);
          _scrollCoverRefreshPending.remove(path);
          _scrollCoverFailures.add(path);
          _scheduleScrollCoverPump();
        },
      );
      _scrollCoverReplacements[path] = (stream: stream, listener: listener);
      _scrollCoverLoading.add(path);
      stream.addListener(listener);
    } catch (_) {
      final replacement = _scrollCoverReplacements.remove(path);
      if (replacement != null) {
        replacement.stream.removeListener(replacement.listener);
      }
      _scrollCoverLoading.remove(path);
      _scrollCoverRefreshPending.remove(path);
      _scrollCoverFailures.add(path);
      _scheduleScrollCoverPump();
    }
  }

  void _startScrollCoverPin(String path) {
    try {
      final provider = _libraryCoverProvider(path, context);
      if (provider == null) return;
      final stream = provider.resolve(createLocalImageConfiguration(context));
      late final ImageStreamListener listener;
      listener = ImageStreamListener(
        (image, synchronousCall) {
          image.dispose();
          if (_scrollCoverPins[path]?.stream != stream) return;
          _scrollCoverLoading.remove(path);
          _scheduleScrollCoverPump();
        },
        onError: (error, stackTrace) {
          if (_scrollCoverPins[path]?.stream != stream) return;
          // Don't repeatedly retry a missing image on every scroll frame.
          _scrollCoverFailures.add(path);
          _releaseScrollCover(path);
          _scheduleScrollCoverPump();
        },
      );
      _scrollCoverPins[path] = (stream: stream, listener: listener);
      _scrollCoverLoading.add(path);
      stream.addListener(listener);
    } catch (_) {
      _scrollCoverFailures.add(path);
      _releaseScrollCover(path);
      _scheduleScrollCoverPump();
    }
  }

  void _updateScrollCoverWindow() {
    if (!_canWarm || !_initialCoversReady || _lastFolders == null) return;
    final folders = _visibleFolders(_lastFolders!);
    final range = _visibleCoverRange(folders.length);
    // One viewport behind, 2-3 ahead. Fast swipes widen the leading edge.
    // The hard cap bounds decoded-memory residency even in huge libraries.
    final span = math.max(8, range.end - range.first);
    final fast = _scrollVelocity > 2200;
    final ahead = math.min(fast ? 36 : 28, span * (fast ? 4 : 3));
    final behind = math.min(16, span);
    final key = '$_scrollCatalogVersion:${_filter.downloadedOnly}:'
        '${_filter.readingOnly}:${range.first}:${range.end}:'
        '$_scrollDirection:$fast';
    if (key == _scrollWindowKey) return;
    _scrollWindowKey = key;

    final priority = <String>[];
    final wanted = <String>{};
    void addIndex(int index) {
      if (index < 0 || index >= folders.length ||
          priority.length >= _maxScrollCoverPins) {
        return;
      }
      final path = folders[index].image;
      if (path.isNotEmpty && path.toLowerCase() != 'asset' &&
          wanted.add(path)) {
        priority.add(path);
      }
    }

    // Resolve covers already on screen first; alternate the lookahead and
    // lookbehind by distance, biased toward the direction of travel.
    for (var index = range.first; index < range.end; index++) {
      addIndex(index);
    }
    for (var distance = 0; distance < math.max(ahead, behind); distance++) {
      if (_scrollDirection >= 0) {
        if (distance < ahead) addIndex(range.end + distance);
        if (distance < behind) addIndex(range.first - 1 - distance);
      } else {
        if (distance < ahead) addIndex(range.first - 1 - distance);
        if (distance < behind) addIndex(range.end + distance);
      }
    }
    // Keep the decoded pins across tab switches and app backgrounding, but
    // release covers outside the new bounded window as scrolling continues.
    for (final path in _scrollCoverPins.keys.toList()) {
      if (!wanted.contains(path)) _releaseScrollCover(path);
    }
    _scrollCoverPriority = priority;
    _scheduleScrollCoverPump();
  }

  void _onFoldersLoaded(List<Folder> folders) {
    // Don't prewarm again on progress-notifier rebuilds or tab switches.
    final signature = folders.map((f) => '${f.id}\u0000${f.image}').join('\u0001');
    if (signature == _coverSignature) return;
    _readingIdsCache = null;
    _coverSignature = signature;
    _scrollCatalogVersion++;
    _scheduleSpeculative();
    _scrollCoverFailures.clear();
    _scrollWindowKey = null;
    // Do not discard every decoded pin on a catalogue refresh. Keep paths
    // still used by the catalogue; only genuinely obsolete covers go away.
    // The next window pass updates priorities and releases distant pins.
    final validPaths = folders.map((folder) => folder.image).toSet();
    for (final path in _scrollCoverPins.keys.toList()) {
      if (!validPaths.contains(path)) _releaseScrollCover(path);
    }
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
      _stopSpeculative();
      _wasOffline = true;
    } else if (status == ConnectionStatus.online) {
      _scheduleSpeculative();
      if (_wasOffline) {
        _scrollCoverFailures.clear();
        _scrollWindowKey = null;
        _scheduleCoverWarming();
        _wasOffline = false;
        if (mounted) {
          logger.d('LibraryScreen: connection restored, refreshing library');
          _pagingController.refresh();
          unawaited(_reloadCategories());
        }
      } else {
        // Startup may have finished while connectivity was validating.
        _tryPendingSync();
      }
    }
  }

  // Series actions always use the entire series, never the active Library
  // filter. Keep disk deletion and queue mutations out of the sheet widget.
  Future<void> _showSeriesActions(Folder folder) async {
    final isar = Isar.getInstance();
    if (isar == null) return;
    final queue = DownloadQueue.instance;
    // Include recovered jobs before deciding which volumes are still missing.
    await queue.restoreQueue();
    if (!mounted) return;

    Future<List<Entry>> seriesEntries() => isar.entrys
        .where()
        .filter()
        .anyOf(folder.bookIds, (q, String id) => q.idEqualTo(id))
        .findAll();

    bool isVolume(Entry entry) =>
        entry.type == EntryType.book || entry.type == EntryType.comic;
    final entries = (await seriesEntries()).where(isVolume).toList();
    if (!mounted) return;
    final queuedIds = queue.jobs.map((job) => job.id).toSet();
    final missing = entries.where((entry) =>
        isSupportedEntry(entry) && !entry.downloaded &&
        !queuedIds.contains(entry.id)).toList();
    final downloaded = entries.where((entry) => entry.downloaded).toList();
    if (missing.isEmpty && downloaded.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('No new downloads available for this series'),
      ));
      return;
    }

    final selected = await showItemActionSheet<_SeriesAction>(
      context,
      title: folder.name,
      subtitle: '${entries.length} volumes · ${downloaded.length} downloaded',
      actions: [
        if (missing.isNotEmpty)
          ItemSheetAction(
            value: _SeriesAction.downloadRemaining,
            icon: Icons.download_rounded,
            label: 'Download remaining ${missing.length} '
                '${missing.length == 1 ? 'volume' : 'volumes'}',
            subtitle: 'Add missing volumes to the download queue',
          ),
        if (downloaded.isNotEmpty)
          ItemSheetAction(
            value: _SeriesAction.deleteDownloaded,
            icon: Icons.delete_outline_rounded,
            label: 'Delete ${downloaded.length} downloaded '
                '${downloaded.length == 1 ? 'volume' : 'volumes'}',
            subtitle: 'Keep reading progress and cached pages',
            destructive: true,
          ),
      ],
    );
    if (!mounted || selected == null) return;

    if (selected == _SeriesAction.downloadRemaining) {
      // Another request may have enqueued a volume while the sheet was open.
      // The queue itself also deduplicates in case of a concurrent enqueue.
      final latest = await seriesEntries();
      if (!mounted) return;
      final knownJobs = queue.jobs.map((job) => job.id).toSet();
      var added = 0;
      for (final entry in latest.where(isVolume)) {
        if (entry.downloaded || !isSupportedEntry(entry) ||
            !knownJobs.add(entry.id)) {
          continue;
        }
        queue.enqueue(entry);
        added++;
      }
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(added == 0
            ? 'All remaining volumes are already queued or downloaded'
            : 'Queued $added ${added == 1 ? 'volume' : 'volumes'}'),
      ));
      return;
    }

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Delete downloaded volumes?'),
        content: Text('Remove local copies of all downloaded volumes in '
            '"${folder.name}"? Reading progress and cached pages will be kept.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    ) ?? false;
    if (!confirmed || !mounted) return;

    // Re-read Isar after confirmation. Only completed local downloads are
    // removed; do not cancel pending jobs or race an active transfer.
    final latest = await seriesEntries();
    final inQueue = queue.jobs.map((job) => job.id).toSet();
    var removed = 0;
    var failed = 0;
    for (final entry in latest.where(
        (item) => isVolume(item) && item.downloaded)) {
      if (inQueue.contains(entry.id)) {
        failed++;
        continue;
      }
      try {
        if (await removeDownloadedVolume(entry.id)) removed++;
      } catch (error) {
        failed++;
        logger.w('Could not remove series download ${entry.id}: $error');
      }
    }
    if (!mounted) return;
    // Reevaluate downloaded/reading filter membership from Isar. Cover pins
    // and scroll controllers are left intact; there is no navigation here.
    if (removed > 0) {
      _readingIdsCache = null;
    }
    if (removed > 0 && _filter.isActive && _lastFolders != null &&
        _visibleFolders(_lastFolders!).isEmpty) {
      _selectFilter(const LibraryFilter());
    } else if (removed > 0) {
      setState(() {});
    }
    if (removed > 0) _progressRevision.value++;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text('Removed $removed ${removed == 1 ? 'volume' : 'volumes'}'
          '${failed == 0 ? '' : '; $failed could not be removed'}'),
    ));
  }

  Widget _buildGrid(List<Folder> allFolders) {
    final matchingIds = _matchingIds();
    final folders = _filter.filterFolders(allFolders, matchingIds);
    return CustomScrollView(
      key: PageStorageKey<String>(_libraryPageKey),
      physics: const AlwaysScrollableScrollPhysics(),
      controller: _libraryScrollController,
      slivers: <Widget>[
        SliverToBoxAdapter(
          child: SizedBox(
            // Leave the same gap below the overlay header as before.
            height: _headerHeight(context) + _gridTopGap,
          ),
        ),
        if (_filter.isActive && folders.isEmpty)
          SliverFillRemaining(
            hasScrollBody: false,
            child: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    _filter.readingOnly
                        ? Icons.chrome_reader_mode_outlined
                        : Icons.download_for_offline_outlined,
                    size: 48,
                  ),
                  const SizedBox(height: 12),
                  Text(_filter.readingOnly
                      ? (_filter.downloadedOnly
                          ? 'No downloaded volumes being read'
                          : 'No volumes currently being read')
                      : 'No downloaded volumes'),
                ],
              ),
            ),
          ),
        if (folders.isNotEmpty) SliverPadding(
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
                    onLongPress: () => _showSeriesActions(folder),
                    matchingCount:
                        _filter.matchingVolumeCount(folder, matchingIds),
                    filter: _filter,
                    onTap: () async {
                      _stopSpeculative();
                      final collectionRoute = PageRouteBuilder<void>(
                        pageBuilder: (context, animation, secondaryAnimation) =>
                            CollectionScreen(
                              folderId: folder.id,
                              name: folder.name,
                              image: folder.image,
                              bookIds: folder.bookIds,
                              downloadedOnly: _filter.downloadedOnly,
                              readingOnly: _filter.readingOnly,
                            ),
                        transitionDuration: const Duration(milliseconds: 280),
                        reverseTransitionDuration:
                            const Duration(milliseconds: 240),
                        transitionsBuilder: (context, animation, _, child) {
                          final progress = animation.drive(
                            CurveTween(curve: Curves.easeOutCubic),
                          );
                          return FadeTransition(
                            opacity: progress,
                            child: SlideTransition(
                              position: Tween<Offset>(
                                begin: const Offset(0.018, 0),
                                end: Offset.zero,
                              ).animate(progress),
                              child: child,
                            ),
                          );
                        },
                      );
                      await Navigator.of(context).push<void>(collectionRoute);
                      // Navigator.push completes when pop begins. Wait for the
                      // reverse animation to finish before revalidating covers.
                      await collectionRoute.completed;
                      _scheduleSpeculative();
                      // Read saved progress from Isar, not from the server.
                      if (mounted) {
                        // Returning from a filtered Collection may have
                        // changed Reading progress or download eligibility.
                        _readingIdsCache = null;
                        final showAll = _filter.isActive &&
                            _lastFolders != null &&
                            _visibleFolders(_lastFolders!).isEmpty;
                        setState(() {
                          if (showAll) _filter = const LibraryFilter();
                        });
                        _progressRevision.value++;
                        WidgetsBinding.instance.addPostFrameCallback((_) {
                          if (mounted && widget.isActive) {
                            // Reader decoding may have evicted Library covers.
                            // Retain old pins until replacements are decoded.
                            _scrollCoverRefreshPending.addAll(_scrollCoverPins.keys);
                            _scrollCoverFailures.clear();
                            _scrollVelocity = 0;
                            _scrollWindowKey = null;
                            _scheduleCoverWarming();
                            _refreshOnLibraryReturnIfStale();
                          }
                        });
                        if (showAll) {
                          // Use the existing All scroll controller and warm
                          // its visible covers, exactly as with a manual toggle.
                          _coverSignature = null;
                          _scheduleCoverWarming();
                          ScaffoldMessenger.of(this.context).showSnackBar(
                            const SnackBar(
                              content: Text(
                                'No matching volumes remaining — showing all series',
                              ),
                              duration: Duration(seconds: 2),
                            ),
                          );
                        }
                      }
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
    _stopSpeculative();
    _inForeground = false;
    WidgetsBinding.instance.removeObserver(this);
    _releaseStartupCoverPins();
    _releaseScrollCoverPins();
    _allScrollController.removeListener(_onLibraryScroll);
    _downloadedScrollController.removeListener(_onLibraryScroll);
    _readingScrollController.removeListener(_onLibraryScroll);
    _downloadedReadingScrollController.removeListener(_onLibraryScroll);
    _allScrollController.dispose();
    _downloadedScrollController.dispose();
    _readingScrollController.dispose();
    _downloadedReadingScrollController.dispose();
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
                unawaited(_reloadCategories());
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
    final topInset = MediaQuery.paddingOf(context).top;
    final headerHeight = _headerHeight(context);
    final headerBrightness = Theme.of(context).brightness;
    final headerForeground =
        FloatingSurfacePalette.foreground(headerBrightness);
    final accent = context.watch<ThemeChangeNotifier>().accentColor ??
        ThemeChangeNotifier.defaultAccent;
    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: FloatingSurfaceHeader(
        topInset: topInset,
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
                    style: TextStyle(
                      fontSize: 22,
                      fontWeight: FontWeight.bold,
                      color: headerForeground,
                    ),
                  ),
                ),
                // A single tap filters to series with complete local volumes.
                Positioned(
                  left: 4,
                  child: IconButton(
                    icon: Icon(
                      Icons.download_for_offline_outlined,
                      color: _filter.downloadedOnly
                          ? Theme.of(context).colorScheme.primary
                          : headerForeground,
                    ),
                    tooltip: _filter.downloadedOnly
                        ? 'Disable Downloaded filter'
                        : 'Show downloaded series',
                    onPressed: () {
                      _selectFilter(_filter.copyWith(
                          downloadedOnly: !_filter.downloadedOnly));
                    },
                  ),
                ),
                // Only this header control observes the download queue;
                // progress ticks never rebuild Library cards or cover images.
                Positioned(
                  left: 52,
                  child: ValueListenableBuilder<int>(
                    valueListenable: DownloadQueue.instance.headerChanges,
                    builder: (context, _, __) {
                      final manager = DownloadQueue.instance;
                      final pending = manager.pendingCount;
                      final failed = manager.failedCount;
                      if (pending == 0 && failed == 0) {
                        return const SizedBox.shrink();
                      }
                      return IconButton(
                        tooltip: 'Download queue',
                        onPressed: () => showModalBottomSheet<void>(
                          context: context,
                          isScrollControlled: true,
                          builder: (_) => const DownloadQueueSheet(),
                        ),
                        icon: SizedBox(
                          width: 27,
                          height: 27,
                          child: Stack(
                            clipBehavior: Clip.none,
                            children: [
                              Center(child: Icon(
                                pending == 0 ? Icons.error_outline :
                                    Icons.downloading_rounded,
                                color: pending == 0 ? Colors.redAccent :
                                    headerForeground,
                                size: 23,
                              )),
                              if (pending > 0)
                                Positioned(
                                  bottom: -4,
                                  right: -5,
                                  child: Container(
                                    padding: const EdgeInsets.symmetric(
                                        horizontal: 4, vertical: 1),
                                    decoration: BoxDecoration(
                                      color: accent,
                                      borderRadius: const BorderRadius.all(
                                          Radius.circular(10)),
                                    ),
                                    child: Text(pending > 99 ? '99+' : '$pending',
                                        style: const TextStyle(
                                            color: Colors.white, fontSize: 9,
                                            fontWeight: FontWeight.bold)),
                                  ),
                                ),
                              if (failed > 0 && pending > 0)
                                const Positioned(
                                  top: -2,
                                  right: -3,
                                  child: Icon(Icons.circle,
                                      size: 8, color: Colors.redAccent),
                                ),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
                ),
                // Keep transient connection status inside the right filter.
                Positioned(
                  right: 52,
                  child: Consumer<ConnectionManager>(
                    builder: (context, connectionManager, _) {
                      final status = connectionManager.status;

                      if (status == ConnectionStatus.offline) {
                        return IconButton(
                          icon: Icon(Icons.cloud_off, color: headerForeground),
                          tooltip: 'Offline - tap to retry',
                          onPressed: () {
                            connectionManager.retry();
                          },
                        );
                      } else if (status == ConnectionStatus.validating && _wasOffline) {
                        return Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 16.0),
                          child: SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: headerForeground,
                            ),
                          ),
                        );
                      }

                      return const SizedBox.shrink();
                    },
                  ),
                ),
                // Symmetric with Downloaded on the far left. Filters combine.
                Positioned(
                  right: 4,
                  child: IconButton(
                    icon: Icon(
                      Icons.chrome_reader_mode_outlined,
                      color: _filter.readingOnly
                          ? Theme.of(context).colorScheme.primary
                          : headerForeground,
                    ),
                    tooltip: _filter.readingOnly
                        ? 'Disable Continue Reading filter'
                        : 'Show series being read',
                    onPressed: () => _selectFilter(_filter.copyWith(
                        readingOnly: !_filter.readingOnly)),
                  ),
                ),
          ],
      ),
      body: RefreshIndicator(
        // Keep the spinner below the translucent header, without moving the grid.
        edgeOffset: headerHeight,
        onRefresh: () async {
          _pagingController.refresh();
          await _reloadCategories();
        },
        child: FutureBuilder<(List<Entry>, List<Folder>)>(
          future: _categoriesFuture,
          builder: (context, AsyncSnapshot snapshot) {
            // while loading/refreshing, keep showing the last grid if we have one
            if (snapshot.connectionState != ConnectionState.done) {
              final cached = _lastFolders;
              return cached != null && _initialCoversReady
                  ? _buildGrid(cached)
                  : const Center(child: CircularProgressIndicator());
            }

            if (snapshot.hasData && snapshot.data != null) {
              final List<Folder> folders = snapshot.data.$2 ?? <Folder>[];
              _lastFolders = folders;
              _onFoldersLoaded(folders);
              return _initialCoversReady
                  ? _buildGrid(folders)
                  : const Center(child: CircularProgressIndicator());
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
                return _initialCoversReady
                    ? _buildGrid(cached)
                    : const Center(child: CircularProgressIndicator());
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
  final int? matchingCount;
  final LibraryFilter filter;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;

  const SeriesCard({super.key, required this.folder, required this.onTap,
      this.onLongPress,
      this.matchingCount, this.filter = const LibraryFilter()});

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
    final shown = entries.where(widget.filter.matchesEntry).toList();
    if (shown.isEmpty) return 0.0;
    // entry.progress is a percentage (0-100); return a 0-1 fraction
    final total = shown.fold<double>(0.0, (sum, e) => sum + e.progress);
    return (total / shown.length / 100).clamp(0.0, 1.0);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final folder = widget.folder; // added
    final progress = _calcProgress(); // added

    return GestureDetector(
      onTap: widget.onTap,
      onLongPress: widget.onLongPress,
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
                          color: Colors.black.withValues(alpha: 0.75),
                          borderRadius: BorderRadius.circular(14),
                          border: Border.all(color: scheme.outlineVariant),
                        ),
                        child: Text(
                          '${widget.matchingCount ?? folder.bookIds.length} ${(widget.matchingCount ?? folder.bookIds.length) == 1 ? 'Book' : 'Books'}',
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
                              .withValues(alpha: 0.75), // matches the pill
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
ImageProvider? _libraryCoverProvider(String path, BuildContext context) {
  if (path.isEmpty || path.toLowerCase() == 'asset') return null;
  final ImageProvider source;
  if (path.contains('http')) {
    source = CachedNetworkImageProvider(
      coverUrl(path),
      cacheManager: CoverCacheManager.instance,
    );
  } else {
    source = FileImage(File(path));
  }
  // The rendered grid and the warm queue MUST use the same decoded-image key.
  // Decode near displayed size rather than keeping huge source bitmaps in RAM.
  final tileWidth = (MediaQuery.sizeOf(context).width - 22) / 2;
  final pixelWidth = math.max(1,
      (tileWidth * MediaQuery.devicePixelRatioOf(context)).ceil());
  return ResizeImage.resizeIfNeeded(pixelWidth, null, source);
}

class _LibraryCover extends StatelessWidget {
  const _LibraryCover({required this.path});

  final String path;

  @override
  Widget build(BuildContext context) {
    final provider = _libraryCoverProvider(path, context);
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
