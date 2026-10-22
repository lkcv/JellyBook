// The purpose of this file is to create the library screen (this is part of the list of screens in the bottom navigation bar)
import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:kurage/models/folder.dart';
import 'package:kurage/providers/fetch_categories.dart';
import 'package:kurage/providers/library_filter.dart';
import 'package:kurage/providers/download_queue.dart';
import 'package:kurage/providers/delete_comic.dart';
import 'package:kurage/providers/supported_formats.dart';
import 'package:kurage/widgets/item_action_sheet.dart';
import 'package:kurage/widgets/download_queue_sheet.dart';
import 'package:kurage/providers/server_progress_revision.dart';
import 'package:kurage/screens/collection_screen.dart';
import 'package:isar/isar.dart';
import 'package:kurage/models/entry.dart';
import 'package:kurage/l10n/app_localizations.dart';
import 'package:kurage/themes/theme_constants.dart';
import 'package:kurage/widgets/floating_surface_header.dart';
import 'package:kurage/variables.dart';
import 'package:kurage/cache/cover_cache.dart';
import 'package:kurage/cache/library_cover_prewarmer.dart';
import 'package:kurage/cache/speculative_cover_prefetcher.dart';
import 'package:infinite_scroll_pagination/infinite_scroll_pagination.dart';
import 'package:provider/provider.dart';
import 'package:kurage/providers/connection_manager.dart';
import 'package:kurage/providers/theme_provider.dart';

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
  late final LibraryCoverPrewarmer _coverPrewarmer = LibraryCoverPrewarmer(
    canSchedule: () => mounted && _inForeground && _lastFolders != null,
    canWarm: () => mounted && _inForeground &&
        (widget.isActive || _coverPrewarmer.resumeWarmWhileInactive) &&
        (ModalRoute.of(context)?.isCurrent ?? true),
    covers: () => _lastFolders == null
        ? null
        : _visibleFolders(_lastFolders!),
    visibleRange: _visibleCoverRange,
    provider: (path) => _libraryCoverProvider(path, context),
    context: () => context,
    filterKey: () => '${_filter.downloadedOnly}:${_filter.readingOnly}',
    catalogSignature: () => _coverSignature,
    onInitialReady: () => setState(() {}),
    onStartupPainted: () {
      unawaited(DownloadQueue.instance.restoreQueue()
          .whenComplete(_scheduleSpeculative));
      _tryPendingSync();
    },
  );

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
      _coverPrewarmer.invalidateWindow();
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
    _coverPrewarmer.filterChanged();
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
        !_coverPrewarmer.initialReady || _activeRefresh != null ||
        _connectionManager?.status != ConnectionStatus.online) {
      return;
    }
    _startupSyncPending = false;
    if (!_serverRefreshStarted) unawaited(_reloadCategories(background: true));
  }

  // Only revalidate on returning to Library; never poll while it is idle.
  void _refreshOnLibraryReturnIfStale() {
    if (!mounted || !widget.isActive || !_inForeground ||
        !_coverPrewarmer.initialReady || _activeRefresh != null ||
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

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _inForeground = state == AppLifecycleState.resumed;
    if (_inForeground) {
      // Revalidate pins even when Library is retained offstage in Settings.
      if (_wasBackgrounded && _coverPrewarmer.initialReady) {
        _coverPrewarmer.revalidate(allowInactive: !widget.isActive);
      } else {
        _coverPrewarmer.invalidateWindow();
      }
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

  void _stopSpeculative() => SpeculativeCoverPrefetcher.instance.stop(this);

  bool get _mayPrefetchLibrary => mounted && _inForeground &&
      widget.isActive && _coverPrewarmer.initialReady && _lastFolders != null &&
      _connectionManager?.status == ConnectionStatus.online &&
      (ModalRoute.of(context)?.isCurrent ?? false);

  bool get _libraryPrefetchBusy => _coverPrewarmer.isBusy ||
      _activeRefresh != null ||
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
    if (!_coverPrewarmer.recordScroll(_libraryScrollController)) return;
    _scheduleSpeculative();
    _scheduleCoverWarming();
  }

  void _scheduleCoverWarming() => _coverPrewarmer.schedule();

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

  void _onFoldersLoaded(List<Folder> folders) {
    // Don't prewarm again on progress-notifier rebuilds or tab switches.
    final signature = folders.map((f) => '${f.id}\u0000${f.image}').join('\u0001');
    if (signature == _coverSignature) return;
    _readingIdsCache = null;
    _coverSignature = signature;
    _scheduleSpeculative();
    _coverPrewarmer.catalogChanged(folders.map((folder) => folder.image).toSet());
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
        _coverPrewarmer.connectionRestored();
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
                            // Re-resolve visible covers after reader decoding.
                            _coverPrewarmer.revalidate();
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
    _coverPrewarmer.dispose();
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
              return cached != null && _coverPrewarmer.initialReady
                  ? _buildGrid(cached)
                  : const Center(child: CircularProgressIndicator());
            }

            if (snapshot.hasData && snapshot.data != null) {
              final List<Folder> folders = snapshot.data.$2 ?? <Folder>[];
              _lastFolders = folders;
              _onFoldersLoaded(folders);
              return _coverPrewarmer.initialReady
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
                return _coverPrewarmer.initialReady
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

ImageProvider? _libraryCoverProvider(String path, BuildContext context) {
  if (path.isEmpty || path.toLowerCase() == 'asset') return null;
  // Decode near displayed size rather than keeping huge source bitmaps in RAM.
  final tileWidth = (MediaQuery.sizeOf(context).width - 22) / 2;
  final pixelWidth = math.max(1,
      (tileWidth * MediaQuery.devicePixelRatioOf(context)).ceil());
  return coverImageProvider(path, pixelWidth: pixelWidth);
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
