import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:kurage/providers/update_pagenum.dart';
import 'package:kurage/providers/download_queue.dart';
import 'package:isar/isar.dart';
import 'package:kurage/models/entry.dart';
import 'package:kurage/providers/progress.dart';
import 'package:kurage/variables.dart';
import 'package:kurage/providers/app_settings_store.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter/services.dart';
import 'package:auto_size_text/auto_size_text.dart';
import 'dart:collection';
import 'package:flutter/scheduler.dart';
import 'package:provider/provider.dart';
import 'package:kurage/providers/connection_manager.dart';
import 'package:kurage/providers/cbz_stream.dart';
import 'package:kurage/cache/reader_page_cache.dart';
import 'package:kurage/widgets/reader_pinch_zoom.dart';
import 'package:kurage/widgets/cover_opening_route.dart';

class CbzReader extends StatefulWidget {
  final String title;
  final String comicId;
  /// Signal the cover transition once the first page is decoded and painted.
  final ValueNotifier<bool>? openingReady;
  final ValueNotifier<ReaderOpeningState>? openingState;
  /// Shared with the opening route to skip the reverse fade on page zero.
  final ValueNotifier<bool>? skipReturnFade;
  /// Available only when reading directly from an ordered Collection session.
  final String? nextVolumeTitle;
  final Future<String?> Function()? onNextVolume;
  final String? previousVolumeTitle;
  final Future<String?> Function()? onPreviousVolume;
  /// Prepare the active volume's cover position before popping this route.
  final Future<void> Function()? onPrepareCoverReturn;
  final bool continuingVolume;
  final bool restoreSystemUiOnDispose;
  final VoidCallback? onContinuationLoadFailed;

  const CbzReader({
    super.key,
    required this.title,
    required this.comicId,
    this.openingReady,
    this.openingState,
    this.skipReturnFade,
    this.nextVolumeTitle,
    this.onNextVolume,
    this.previousVolumeTitle,
    this.onPreviousVolume,
    this.onPrepareCoverReturn,
    this.continuingVolume = false,
    this.restoreSystemUiOnDispose = true,
    this.onContinuationLoadFailed,
  });

  @override
  State<CbzReader> createState() => _CbzReaderState();
}

class _CbzReaderState extends State<CbzReader>
    with SingleTickerProviderStateMixin {
  late String title;
  late String comicId;
  int pageNum = 0;
  int pageNums = 0;
  double progress = 0.0;
  late String path;
  late List<String> pages = [];
  late String direction;
  bool _loading = true;
  bool _showOverlay = false;
  bool _exiting = false;
  int _currentPage = 0;
  int? _pendingLocalPage;
  bool _savingLocalProgress = false;
  PageController? _pageController;
  final ScrollController _verticalScrollController = ScrollController();
  bool _zoomScrollLocked = false;
  // Track touches above PageView: once a drag starts, the next pointer may
  // hit a neighboring page, not the first page's ReaderPinchZoom.
  final Map<int, Offset> _readerTouches = <int, Offset>{};
  final Map<int, GlobalKey<ReaderPinchZoomState>> _zoomPageKeys = {};
  final Map<int, GlobalKey> _verticalPageKeys = {};
  int? _firstTouchPage;
  int? _activeZoomPage;
  bool _gestureHadMultitouch = false;
  // Only a new swipe starting at the first/last page boundary may switch
  // volumes. 1 means next, -1 means previous; zero means no armed gesture.
  // Pointer observation leaves PageView, vertical scrolling and zoom intact.
  bool _canSwipeNext = false;
  bool _canSwipePrevious = false;
  int _volumeSwipeDelta = 0;
  bool _volumeSwipePending = false;
  String? _volumeSwipeMessage;
  Timer? _volumeSwipeMessageTimer;
  // A zoomed page owns the first drag. Only a fresh swipe that STARTS at an
  // image boundary is allowed to turn exactly one page.
  Offset? _singleFingerStart;
  bool _edgePositiveAtStart = false;
  bool _edgeNegativeAtStart = false;
  bool _edgeTurnConsumed = false;
  bool _edgePageTurnPending = false;
  static const _normalDuration = Duration(milliseconds: 300);
  static const _fastDuration = Duration(milliseconds: 80);

  late final Ticker _tapTicker = createTicker(_onTapTick);
  final Queue<int> _tapQueue = Queue<int>();
  Duration _lastTick = Duration.zero;
  double _from = 0, _to = 0, _t = 0;
  Curve _legCurve = Curves.easeOutCubic;
  int _lastTarget = 0;

  // Streaming support
  bool _isStreaming = false;
  CbzStream? _stream;
  final Map<int, File> _pageCache = {};
  final Map<int, Future<File>> _pageLoads = {};
  final Map<int, String> _chapterLabels = {};
  Future<void>? _streamInitialization;
  // The previous reader instance may still be copying pages when reopened.
  // Its cleanup must finish before a new CbzStream uses the same temp path.
  static final Map<String, Future<void>> _cleanupByVolume = {};

  late final Future<void> _initialLoad;
  Future<Entry?>? _observedDownload;
  bool _switchingToLocal = false;

  @override
  void initState() {
    super.initState();
    title = widget.title;
    comicId = widget.comicId;
    _initialLoad = _load();
    DownloadQueue.instance.addListener(_onDownloadQueueChanged);
    _onDownloadQueueChanged();
  }

  @override
  void dispose() {
    DownloadQueue.instance.removeListener(_onDownloadQueueChanged);
    _volumeSwipeMessageTimer?.cancel();
    _pageController?.dispose();
    _verticalScrollController.dispose();
    if (widget.restoreSystemUiOnDispose) {
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    }
    _tapTicker.dispose();
    _clearStreamAfterPageWork(_stream);
    super.dispose();
  }

  Widget _buildDownloadButton(ColorScheme scheme) {
    final manager = DownloadQueue.instance;
    return ListenableBuilder(
      listenable: manager,
      builder: (context, _) {
        DownloadJob? job;
        for (final candidate in manager.jobs) {
          if (candidate.id == comicId) {
            job = candidate;
            break;
          }
        }
        final active = _switchingToLocal || (job != null &&
            (job.state == DownloadJobState.queued ||
                job.state == DownloadJobState.downloading ||
                job.state == DownloadJobState.waitingForNetwork ||
                job.state == DownloadJobState.waitingForServer ||
                job.state == DownloadJobState.canceling));
        final offline = Provider.of<ConnectionManager>(context).status ==
            ConnectionStatus.offline;
        final enabled = !active && !offline;
        final progress = _switchingToLocal ? 100.0 : (job?.progress ?? 0.0);

        return GestureDetector(
          onTap: enabled ? _downloadInBackground : null,
          child: SizedBox(
            width: 50,
            height: 50,
            child: Stack(
              alignment: Alignment.center,
              children: [
                SizedBox(
                  width: 40,
                  height: 40,
                  child: CircularProgressIndicator(
                    value: active ? progress / 100 : 0,
                    strokeWidth: 3,
                    backgroundColor: Colors.white.withValues(alpha: 0.3),
                    valueColor: AlwaysStoppedAnimation<Color>(scheme.primary),
                  ),
                ),
                active
                    ? Text(
                        '${progress.round()}%',
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                        ),
                      )
                    : Icon(
                        Icons.download,
                        size: 20,
                        color: enabled ? scheme.primary : Colors.grey,
                      ),
              ],
            ),
          ),
        );
      },
    );
  }

  Future<void> _load() async {
    try {
      PaintingBinding.instance.imageCache.maximumSizeBytes = 300 << 20;
      direction = AppSettingsStore.current.readingDirection.toLowerCase();
      if (!mounted) return;

      await getData();
      if (!mounted) return;
      await getChapters();
      if (!mounted) return;
      await getProgress(comicId);
      if (!mounted) return;

      if (_isStreaming) {
        // Restore a saved page before waiting for the server to enumerate
        // the archive. This also works while the server is offline.
        final cachedCount = await ReaderPageCache.getPageCount(comicId);
        if (cachedCount != null && cachedCount > 0) {
          pageNums = cachedCount;
          final cachedIndex = ((await ReaderPageCache.getCurrentPage(comicId)) ??
                  pageNum)
              .clamp(0, pageNums - 1)
              .toInt();
          final saved = await ReaderPageCache.getPage(comicId, cachedIndex);
          if (saved != null) {
            _pageCache[cachedIndex] = saved;
            _currentPage = cachedIndex;
            _chapterLabels
              ..clear()
              ..addAll(await ReaderPageCache.getChapterLabels(comicId));
            logger.d('CbzReader: restored cached page $cachedIndex '
                'of volume $comicId without a network request');
            _pageController = PageController(initialPage: _currentPage);
            SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
            await _finishOpening();
            if (!mounted) return;
            // Reopening never needs the network for the retained page.
            // The cache is touched before adjacent-page prefetch begins.
            ReaderPageCache.touch(
              volumeId: comicId, pageCount: pageNums,
              currentPage: _currentPage,
            ).catchError((Object e) {
              logger.w('ReaderPageCache: could not touch volume: $e');
            });
            _precacheAround(_currentPage);
            // Caches created before chapter detection have no labels. Index
            // the archive after the first frame, without blocking page paint.
            if (_chapterLabels.isEmpty &&
                context.read<ConnectionManager>().status !=
                    ConnectionStatus.offline) {
              WidgetsBinding.instance.addPostFrameCallback((_) {
                if (!mounted) return;
                _ensureStreamInitialized().catchError((Object error) {
                  logger.w('CbzReader: chapter index unavailable: $error');
                });
              });
            }
            // The retained image itself never waits for the server.
            return;
          }
        }
        _setOpeningState(ReaderOpeningState.loadingPage);
        await _ensureStreamInitialized();
      } else {
        await createPageList();
        var originalNames = pages;
        final namesFile = File('$path/.kurage-page-names.json');
        if (await namesFile.exists()) {
          try {
            final decoded = jsonDecode(await namesFile.readAsString());
            if (decoded is List && decoded.length == pages.length &&
                decoded.every((value) => value is String)) {
              originalNames = decoded.cast<String>();
            }
          } catch (_) {}
        }
        _chapterLabels
          ..clear()
          ..addAll(_chaptersFromNames(originalNames));
      }

      final lastPage = pageNums == 0 ? 0 : pageNums - 1;
      _currentPage = pageNum.clamp(0, lastPage).toInt();
      _pageController = PageController(initialPage: _currentPage);
      if (_isStreaming || pages.isNotEmpty) {
        await ReaderPageCache.saveWindow(
          volumeId: comicId,
          pageCount: pageNums,
          currentPage: _currentPage,
          lastUsed: DateTime.now().millisecondsSinceEpoch,
          sourceFiles: const <int, File>{},
          chapterLabels: _chapterLabels,
        );
      }
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
      await _finishOpening();
      if (mounted) _precacheAround(_currentPage);
    } catch (e, s) {
      logger.e('CbzReader: load failed: $e\n$s');
      if (mounted) {
        if (widget.continuingVolume &&
            widget.onContinuationLoadFailed != null) {
          // Recover the previous volume without leaving the reading session.
          widget.onContinuationLoadFailed!();
        } else {
          final messenger = ScaffoldMessenger.of(context);
          final nav = Navigator.of(context);
          messenger.showSnackBar(
            SnackBar(
              content: Text('Could not open this volume: $e'),
              duration: const Duration(seconds: 15),
              showCloseIcon: true,
            ),
          );
          nav.pop();
        }
      }
    }
  }

  /// Avoid competing with the 300ms cover expansion when decoding the
  /// initial reader page. Non-animated reader entry is unchanged.
  Future<bool> _waitUntilCoverExpanded() async {
    if (widget.openingReady == null) return true;
    await WidgetsBinding.instance.endOfFrame;
    if (!mounted) return false;

    final animation = ModalRoute.of(context)?.animation;
    if (animation == null || animation.status == AnimationStatus.completed) {
      return true;
    }
    if (animation.status == AnimationStatus.reverse ||
        animation.status == AnimationStatus.dismissed) {
      return false;
    }

    final done = Completer<void>();
    void onStatus(AnimationStatus status) {
      if (status == AnimationStatus.completed ||
          status == AnimationStatus.reverse ||
          status == AnimationStatus.dismissed) {
        if (!done.isCompleted) done.complete();
      }
    }

    animation.addStatusListener(onStatus);
    try {
      onStatus(animation.status); // Handle completion during registration.
      await done.future;
    } finally {
      animation.removeStatusListener(onStatus);
    }
    return mounted && animation.status == AnimationStatus.completed;
  }

  void _setOpeningState(ReaderOpeningState state) {
    if (mounted && widget.openingReady?.value == false) {
      widget.openingState?.value = state;
    }
  }

  /// Keep the cover visible until the page is decoded and painted.
  /// Without an opening route, preserve the existing loading behavior.
  Future<void> _finishOpening() async {
    if (widget.openingReady != null && pageNums > 0) {
      if (!await _waitUntilCoverExpanded()) return;
      try {
        final file = await _loadPageFile(_currentPage);
        if (!mounted) return;
        final provider = FileImage(file);
        final status = PaintingBinding.instance.imageCache.statusForKey(provider);
        if (!status.keepAlive && !(status.live && !status.pending)) {
          _setOpeningState(ReaderOpeningState.loadingPage);
        }
        await precacheImage(provider, context);
      } catch (error) {
        logger.w('CbzReader: could not precache opening page: $error');
      }
    }
    if (!mounted) return;
    setState(() => _loading = false);
    // The transition should not fade away until the page widget has had a
    // frame to build with its now-decoded FileImage.
    if (widget.openingReady != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          _setOpeningState(ReaderOpeningState.ready);
          widget.openingReady!.value = true;
        }
      });
    }
  }

  Future<void> getData() async {
    final isar = Isar.getInstance();
    return await isar!.entrys
        .where()
        .idEqualTo(comicId)
        .findFirst()
        .then((value) {
      if (!mounted) return;
      setState(() {
        pageNum = value!.pageNum;
        progress = value.progress;
        _isStreaming = !value.downloaded;
      });
    });
  }

  Future<void> getChapters() async {
    final isar = Isar.getInstance();
    final entry = await isar!.entrys.where().idEqualTo(comicId).findFirst();

    path = entry!.folderPath;
    logger.d("title: ${entry.title}");
    logger.d("path: ${entry.filePath}");
    logger.d("folder path: ${entry.folderPath}");
    logger.d("downloaded: ${entry.downloaded}");

    if (entry.downloaded) {
      progress = entry.progress;
      pageNum = entry.pageNum;
    } else {
      // Streaming: initialize the stream
      await _initStream(entry);
    }
  }

  Future<void> _initStream(Entry entry) async {
    final prefs = await SharedPreferences.getInstance();
    final server = prefs.getString('server') ?? '';
    final token = prefs.getString('accessToken') ?? '';

    final headers = {
      'Authorization': 'MediaBrowser Token="$token"',
    };

    _stream = CbzStream(
      url: server,
      itemId: entry.id,
      headers: headers,
    );
  }


  /// Awaited precache of local extracted files (used when leaving streaming).
  Future<void> _precacheLocalAround(int index) async {
    if (pages.isEmpty) return;
    final start = (index - 1).clamp(0, pages.length - 1);
    final end = (index + 1).clamp(0, pages.length - 1);
    final futures = <Future<void>>[];
    for (int i = start; i <= end; i++) {
      futures.add(
        precacheImage(FileImage(File(pages[i])), context).catchError((e) {
          logger.e('Local precache error: $e');
        }),
      );
    }
    await Future.wait(futures);
  }

  void _precacheAround(int index) {
    if (!mounted || pageNums == 0) return;
    final start = (index - 3).clamp(0, pageNums - 1).toInt();
    final end = (index + 3).clamp(0, pageNums - 1).toInt();
    for (int i = start; i <= end; i++) {
      // _loadPageFile now waits for the durable copy. This is a read-through
      // cache, not an independent background snapshot of a temporary file.
      _loadPageFile(i).then((file) {
        if (mounted) {
          precacheImage(FileImage(file), context).catchError((Object error) {
            logger.w('CbzReader: image precache failed: $error');
          });
        }
      }).catchError((Object error) {
        logger.w('CbzReader: page $i precache failed: $error');
      });
    }
  }

  Future<File> _loadPageFile(int index) {
    final existing = _pageLoads[index];
    if (existing != null) return existing;
    late final Future<File> tracked;
    tracked = _resolvePageFile(index).whenComplete(() {
      // Returning the removed Future from whenComplete would make it await
      // itself forever. The cleanup callback must return void.
      _pageLoads.remove(index);
    });
    _pageLoads[index] = tracked;
    return tracked;
  }

  Future<File> _persistPage(int index, File file) async {
    try {
      await ReaderPageCache.saveWindow(
        volumeId: comicId,
        pageCount: pageNums,
        currentPage: _currentPage,
        lastUsed: DateTime.now().millisecondsSinceEpoch,
        sourceFiles: <int, File>{index: file},
        // An older network request must not move the reading position back.
        updatePosition: false,
      );
      final durable = await ReaderPageCache.getPage(comicId, index);
      if (durable != null) {
        _pageCache[index] = durable;
        return durable;
      }
    } catch (error) {
      // A storage failure should not prevent displaying a page fetched from
      // the server or loaded from the downloaded volume.
      logger.w('ReaderPageCache: failed to retain page $index: $error');
    }
    _pageCache[index] = file;
    return file;
  }

  Future<File> _resolvePageFile(int index) async {
    if (index < 0 || index >= pageNums) {
      throw RangeError('Invalid page index: $index');
    }
    // Always prefer durable pages before checking the stream. Flutter can
    // discard its decoded image cache without affecting these files.
    final retained = _pageCache[index];
    if (retained != null && await retained.exists()) {
      // Local downloaded files also need a recovery copy.
      if (!_isStreaming && index < pages.length &&
          retained.path == pages[index]) {
        return _persistPage(index, retained);
      }
      return retained;
    }
    final saved = await ReaderPageCache.getPage(comicId, index);
    if (saved != null) {
      _pageCache[index] = saved;
      return saved;
    }
    if (!_isStreaming && index < pages.length) {
      final local = File(pages[index]);
      if (await local.exists()) return _persistPage(index, local);
    }
    if (_isStreaming) {
      _setOpeningState(ReaderOpeningState.loadingPage);
      await _ensureStreamInitialized();
      final temporary = await _stream!.getPage(index);
      // Do not let FutureBuilder render the page until its recovery copy has
      // been written. dispose() waits for these loads before stream.clear().
      return _persistPage(index, temporary);
    }
    throw StateError('No local or saved page exists for page $index');
  }

  /// Infer chapters using explicit chapter markers in an image's filename or
  /// archive folder, e.g. "Chapter 12/003.jpg", "ch_12_page_003.png",
  /// or "c001 - p000.png".
  /// Ordinary page numbers alone are not chapter numbers.
  Map<int, String> _chaptersFromNames(Iterable<String> names) {
    final marker = RegExp(
      r'(?:^|[/\\\s._\-\[(])(?:chapter|chap|ch|c)[\s._:#\-]*0*(\d+(?:\.\d+)?)',
      caseSensitive: false,
    );
    final result = <int, String>{};
    String? chapter;
    var index = 0;
    for (final name in names) {
      final match = marker.firstMatch(name);
      if (match != null) chapter = 'Chapter ${match.group(1)}';
      if (chapter != null) result[index] = chapter;
      index++;
    }
    return result;
  }

  Future<void> _ensureStreamInitialized() async {
    final existing = _streamInitialization;
    if (existing != null) return existing;
    final stream = _stream;
    if (stream == null) throw StateError('No streaming reader is available');
    Future<void> initializeStream() async {
      final previousCleanup = _cleanupByVolume[comicId];
      if (previousCleanup != null) {
        try {
          await previousCleanup;
        } catch (error) {
          logger.w('CbzReader: previous cleanup failed: $error');
        }
      }
      await stream.init();
      final chapters = _chaptersFromNames(
        List<String>.generate(stream.pageCount, (i) => stream.pageName(i) ?? ''),
      );
      _chapterLabels
        ..clear()
        ..addAll(chapters);
      if (mounted && !_loading) setState(() {});
      if (stream.pageCount > 0 && chapters.isNotEmpty) {
        await ReaderPageCache.saveWindow(
          volumeId: comicId,
          pageCount: stream.pageCount,
          currentPage: pageNum,
          lastUsed: DateTime.now().millisecondsSinceEpoch,
          sourceFiles: const <int, File>{},
          chapterLabels: chapters,
          updatePosition: false,
        );
      }
      if (stream.pageCount > 0 && pageNums != stream.pageCount) {
        pageNums = stream.pageCount;
        if (mounted) setState(() {});
      }
    }
    final initialization = initializeStream();
    _streamInitialization = initialization;
    try {
      await initialization;
    } catch (_) {
      if (identical(_streamInitialization, initialization)) {
        _streamInitialization = null;
      }
      rethrow;
    }
  }

  void _clearStreamAfterPageWork(CbzStream? stream) {
    if (stream == null) return;
    final pending = _pageLoads.values.toList();
    final initialization = _streamInitialization;
    Future<void> finishAndClear() async {
      // The index operation may still be populating _cacheDir.
      if (initialization != null) {
        try {
          await initialization;
        } catch (_) {
          // A failed initialization has no valid index to save.
        }
      }
      // The reader is only allowed to display fetched pages after this
      // read-through loader writes its durable copy.
      for (final job in pending) {
        try {
          await job;
        } catch (_) {
          // Failed fetches have nothing to persist.
        }
      }
      await stream.clear();
    }
    final cleanup = finishAndClear();
    _cleanupByVolume[comicId] = cleanup;
    cleanup.then((_) {
      if (identical(_cleanupByVolume[comicId], cleanup)) {
        _cleanupByVolume.remove(comicId);
      }
    }).catchError((Object error) {
      if (identical(_cleanupByVolume[comicId], cleanup)) {
        _cleanupByVolume.remove(comicId);
      }
      logger.w('CbzReader: stream cleanup failed: $error');
    });
  }

  void _onDownloadQueueChanged() {
    for (final job in DownloadQueue.instance.jobs) {
      if (job.id != comicId || job.state == DownloadJobState.failed ||
          job.state == DownloadJobState.canceling ||
          job.state == DownloadJobState.canceled) {
        continue;
      }
      final completion = job.result;
      if (!identical(_observedDownload, completion)) {
        _observedDownload = completion;
        unawaited(_switchToLocalOnCompletion(completion));
      }
      break;
    }
  }

  Future<void> _switchToLocalOnCompletion(Future<Entry?> completion) async {
    try {
      final downloaded = await completion;
      if (downloaded == null) return;
      await _initialLoad;
      if (!mounted || !_isStreaming) return;
      setState(() => _switchingToLocal = true);
      await createPageList();
      if (!mounted) return;
      await _precacheLocalAround(_currentPage);
      if (!mounted) return;
      setState(() {
        _isStreaming = false;
        _switchingToLocal = false;
      });
      _pageCache.clear();
      _precacheAround(_currentPage);
      final stream = _stream;
      _stream = null;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _clearStreamAfterPageWork(stream);
      });
    } catch (error) {
      logger.e('CbzReader: download completion failed: $error');
    } finally {
      if (mounted && _switchingToLocal) {
        setState(() => _switchingToLocal = false);
      }
    }
  }

  Future<void> _downloadInBackground() async {
    try {
      final isar = Isar.getInstance();
      final entry = await isar?.entrys.where().idEqualTo(comicId).findFirst();
      if (entry == null || !mounted) return;
      DownloadQueue.instance.enqueue(entry);
      _onDownloadQueueChanged();
    } catch (error) {
      logger.e('CbzReader: could not enqueue download: $error');
    }
  }

  Future<void> createPageList() async {
    final isar = Isar.getInstance();
    final entry = await isar!.entrys.where().idEqualTo(comicId).findFirst();

    path = entry!.folderPath;

    await getChaptersFromDirectory(Directory(path));
    logger.d("chapters: $path");

    List<String> formats = [
      ".jpg",
      ".jpeg",
      ".png",
      ".gif",
      ".webp",
      ".bmp",
      ".tiff"
    ];

    List<String> pageFiles = [];
    for (var chapter in [path]) {
      List<String> files =
          Directory(chapter).listSync().map((e) => e.path).toList();
      for (var file in files) {
        if (formats.any((element) => file.toLowerCase().endsWith(element))) {
          pageFiles.add(file);
        }
      }
    }
    pageFiles.sort();
    pages = pageFiles;
    pageNums = pageFiles.length;
  }

  Future<void> getChaptersFromDirectory(FileSystemEntity directory) async {
    List<String> fileTypes = [
      '.jpg',
      '.jpeg',
      '.png',
      '.gif',
      '.webp',
      '.bmp',
      '.tiff'
    ];

    if (fileTypes
        .any((fileType) => directory.path.toLowerCase().endsWith(fileType))) {
      // It's a file, not a directory
      return;
    } else {
      List<FileSystemEntity> files = [];
      try {
        files = Directory(directory.path).listSync();
        for (var file in files) {
          await getChaptersFromDirectory(file);
        }
      } catch (e) {
        logger.d("Error: not a valid directory, its a file");
      }
    }
  }

  // Both local persistence and server reporting are ordered by the observed
  // page changes, not by whichever asynchronous Isar query finishes first.
  void saveProgress(int page) {
    // Queue immediately so rapid Isar writes cannot reorder server positions.
    unawaited(updatePagenum(comicId, page).catchError((Object error) {
      logger.w('Could not queue page progress: $error');
    }));
    _pendingLocalPage = page;
    if (!_savingLocalProgress) unawaited(_saveLocalProgress());
  }

  Future<void> _saveLocalProgress() async {
    _savingLocalProgress = true;
    try {
      while (_pendingLocalPage != null) {
        final page = _pendingLocalPage!;
        _pendingLocalPage = null;
        try {
          final isar = Isar.getInstance();
          if (isar == null) return;
          final entry = await isar.entrys.where().idEqualTo(comicId).findFirst();
          if (entry == null) return;
          entry.pageNum = page;
          // Page indices are zero-based: the final page is pageNums - 1.
          // Reaching it must complete the volume, without changing the
          // existing percentage calculation for earlier pages.
          entry.progress = pageNums > 0 && page >= pageNums - 1
              ? 100.0
              : (page / (pageNums > 0 ? pageNums : 1)) * 100;
          await isar.writeTxn(() async => isar.entrys.put(entry));
          logger.d('saved progress: page $page / $pageNums');
        } catch (error) {
          logger.w('Could not save local page progress: $error');
        }
      }
    } finally {
      _savingLocalProgress = false;
    }
  }

  void _handleTap(TapUpDetails details) {
    // A side tap is an explicit page-turn command, even at 5x zoom.
    // Ignore taps only during/after multitouch or a boundary page-turn drag.
    if (_gestureHadMultitouch || _edgeTurnConsumed || _edgePageTurnPending) {
      return;
    }
    final screenWidth = MediaQuery.of(context).size.width;
    final tapX = details.globalPosition.dx;
    final zone = screenWidth * 0.2;

    final isLeftTap = tapX < zone;
    final isRightTap = tapX > screenWidth - zone;

    if (!isLeftTap && !isRightTap) {
      _toggleOverlay();
      return;
    }

    final goForward = direction == 'rtl' ? isLeftTap : isRightTap;
    _queuePage(goForward ? 1 : -1);
  }

  void _queuePage(int delta) {
    final c = _pageController;
    if (c == null || !c.hasClients) return;

    if (!_tapTicker.isActive) _lastTarget = _currentPage;

    final target = _lastTarget + delta;
    if (target < 0 || target >= (pageNums > 0 ? pageNums : 1)) return;
    _lastTarget = target;

    if (_tapTicker.isActive) {
      _tapQueue.add(target);
    } else {
      _startLeg(target);
      _lastTick = Duration.zero;
      _tapTicker.start();
    }
  }

  void _startLeg(int page) {
    final c = _pageController!;
    _from = c.position.pixels;
    _to = page * c.position.viewportDimension * c.viewportFraction;
    _t = 0;
    _legCurve = _tapQueue.isNotEmpty ? Curves.linear : Curves.easeOutCubic;
  }

  void _onTapTick(Duration elapsed) {
    final c = _pageController;
    if (c == null || !c.hasClients) {
      _cancelTapAnimation();
      return;
    }

    final dt = elapsed - _lastTick;
    _lastTick = elapsed;

    final dur =
        (_tapQueue.isNotEmpty ? _fastDuration : _normalDuration).inMicroseconds;
    _t += dt.inMicroseconds / dur;

    if (_t >= 1) {
      c.jumpTo(_to);
      if (_tapQueue.isEmpty) {
        _tapTicker.stop();
        return;
      }
      final overflow = _t - 1;
      _startLeg(_tapQueue.removeFirst());
      _t = overflow.clamp(0.0, 0.99).toDouble();
    }

    c.jumpTo(_from + (_to - _from) * _legCurve.transform(_t));
  }

  void _cancelTapAnimation() {
    if (_tapTicker.isActive) _tapTicker.stop();
    _tapQueue.clear();
  }

  // Suspend page scrolling on the second pointer, including mid-swipe.
  // Single-finger page dragging remains in the normal PageView path.
  void _setZoomScrollLocked(bool locked, int index) {
    if (!mounted || _zoomScrollLocked == locked) return;
    if (locked) {
      _cancelTapAnimation();
      if (_verticalScrollController.hasClients) {
        final position = _verticalScrollController.position;
        if (position is ScrollPositionWithSingleContext) {
          position.goIdle();
        }
      }
      final controller = _pageController;
      if (controller != null && controller.hasClients) {
        final page = controller.page ?? _currentPage.toDouble();
        if ((page - index).abs() > 0.01) {
          // A second finger can arrive halfway through a swipe. Finish on
          // the touched page before manipulating its image.
          controller.jumpToPage(index);
        } else {
          final position = controller.position;
          if (position is ScrollPositionWithSingleContext) {
            position.goIdle(); // Stop an existing page drag.
          }
        }
      }
    }
    setState(() => _zoomScrollLocked = locked);
  }

  // Find the page under the FIRST pointer, before a page swipe can move it.
  // This also supports vertical scrolling, where _currentPage is not updated.
  int? _pageAt(Offset point) {
    for (final entry in _zoomPageKeys.entries) {
      if (entry.value.currentState?.containsGlobalPoint(point) ?? false) {
        return entry.key;
      }
    }
    return null;
  }

  ReaderPinchZoomState? _zoomState(int? index) =>
      index == null ? null : _zoomPageKeys[index]?.currentState;

  void _readerPointerDown(PointerDownEvent event) {
    if (_readerTouches.isEmpty) {
      _gestureHadMultitouch = false;
      // A page-turn gesture that arrives at a boundary is not allowed to
      // change volumes. Sample both boundaries at the *start* of this touch.
      final vertical = direction == 'vertical';
      final controller = _pageController;
      final atStart = vertical
          ? (_verticalScrollController.hasClients &&
              _verticalScrollController.position.extentBefore <= 1)
          : (controller != null && controller.hasClients &&
              _currentPage == 0 &&
              (controller.page ?? _currentPage.toDouble()).abs() < 0.02);
      final atEnd = vertical
          ? (_verticalScrollController.hasClients &&
              _verticalScrollController.position.extentAfter <= 1)
          : (controller != null && controller.hasClients &&
              _currentPage == pageNums - 1 &&
              ((controller.page ?? _currentPage.toDouble()) -
                      (pageNums - 1))
                  .abs() < 0.02);
      final eligible = !_volumeSwipePending && pageNums > 0 &&
          !_zoomScrollLocked &&
          !(_zoomState(_activeZoomPage)?.isZoomed ?? false);
      _canSwipeNext = eligible && atEnd && widget.onNextVolume != null;
      _canSwipePrevious = eligible && atStart &&
          widget.onPreviousVolume != null;
      _volumeSwipeDelta = 0;
      _edgeTurnConsumed = false;
      _firstTouchPage = _activeZoomPage ?? _pageAt(event.position);
      // Take a snapshot of the boundaries BEFORE any movement. Reaching an
      // edge during this gesture must not trigger an unexpected page turn.
      _singleFingerStart = event.position;
      final zoom = _zoomState(_activeZoomPage);
      _edgePositiveAtStart = !_edgePageTurnPending &&
          (zoom?.atPanBoundary(vertical: vertical, positive: true) ?? false);
      _edgeNegativeAtStart = !_edgePageTurnPending &&
          (zoom?.atPanBoundary(vertical: vertical, positive: false) ?? false);
    }
    _readerTouches[event.pointer] = event.position;
    if (_readerTouches.length == 2) {
      _gestureHadMultitouch = true;
      _canSwipeNext = false;
      _canSwipePrevious = false;
      if (_volumeSwipeDelta != 0) {
        setState(() => _volumeSwipeDelta = 0);
      }
      _edgePositiveAtStart = false;
      _edgeNegativeAtStart = false;
      var index = _firstTouchPage ?? _currentPage;
      // The first page may have left the viewport during a fast drag.
      if (_zoomState(index) == null) {
        index = _pageAt(event.position) ?? _currentPage;
      }
      final target = _zoomState(index);
      if (target == null) return; // The page image is still loading.
      _activeZoomPage = index;
      // Cancels an already-running PageView drag *synchronously*, before any
      // pinch movement. Locks the pager until ALL fingers have been lifted.
      _setZoomScrollLocked(true, index);
      final points = _readerTouches.values.take(2).toList();
      target.beginPinch(points[0], points[1]);
    }
  }

  void _readerPointerMove(PointerMoveEvent event) {
    final previous = _readerTouches[event.pointer];
    if (previous == null) return;
    _readerTouches[event.pointer] = event.position;

    // Observe only an extra swipe that begins at either volume boundary.
    // Suppress the fleeting early "Next:" preview: show only the release pill
    // once the swipe is long enough to actually open a neighboring volume.
    if ((_canSwipeNext || _canSwipePrevious) &&
        _readerTouches.length == 1 && !_gestureHadMultitouch &&
        !_edgePageTurnPending) {
      final start = _singleFingerStart;
      if (start != null) {
        final travel = event.position - start;
        final vertical = direction == 'vertical';
        final forward = vertical ? -travel.dy :
            (direction == 'rtl' ? travel.dx : -travel.dx);
        final cross = vertical ? travel.dx.abs() : travel.dy.abs();
        final directionDelta = forward > 0 ? 1 : -1;
        final available = directionDelta == 1
            ? _canSwipeNext : _canSwipePrevious;
        final armed = available && forward.abs() >= 72 &&
            forward.abs() > cross * 1.3;
        final nextDelta = armed ? directionDelta : 0;
        if (_volumeSwipeDelta != nextDelta) {
          setState(() => _volumeSwipeDelta = nextDelta);
        }
      }
    }

    final state = _zoomState(_activeZoomPage);
    if (state == null) return;
    if (_readerTouches.length >= 2) {
      final points = _readerTouches.values.take(2).toList();
      state.updatePinch(points[0], points[1]);
    } else if (_zoomScrollLocked && _readerTouches.length == 1 &&
        !_edgeTurnConsumed && !_edgePageTurnPending) {
      if (!_gestureHadMultitouch && _tryBoundaryPageTurn(state, event.position)) {
        return; // Don't also pan the image on the page-turning movement.
      }
      // Pan immediately. Inward drags at an edge remain normal image pans.
      state.pan(event.position - previous);
    }
  }

  // Horizontal in paged mode; vertical in continuous-reading mode. This is
  // pointer-level handling, so it doesn't add a gesture-recognizer delay.
  bool _tryBoundaryPageTurn(ReaderPinchZoomState state, Offset position) {
    final start = _singleFingerStart;
    if (start == null || !state.isZoomed) return false;
    final travel = position - start;
    final vertical = direction == 'vertical';
    final main = vertical ? travel.dy : travel.dx;
    final cross = vertical ? travel.dx : travel.dy;

    // Moving inward disqualifies that edge for the rest of this touch.
    if (main < -12) _edgePositiveAtStart = false;
    if (main > 12) _edgeNegativeAtStart = false;
    // A substantially diagonal gesture is a pan, not a page turn.
    if (cross.abs() > 32 && cross.abs() > main.abs() * 0.7) {
      _edgePositiveAtStart = false;
      _edgeNegativeAtStart = false;
    }
    const swipeDistance = 56.0; // logical pixels
    if (main.abs() < swipeDistance ||
        main.abs() < cross.abs() * 1.3) {
      return false;
    }

    final outward = main > 0 ? _edgePositiveAtStart : _edgeNegativeAtStart;
    if (!outward) return false;
    final delta = vertical
        ? (main > 0 ? -1 : 1)
        : ((main > 0) == (direction == 'rtl') ? 1 : -1);
    final source = _activeZoomPage ?? _currentPage;
    final target = source + delta;
    if (target < 0 || target >= pageNums) return false;
    if (vertical && _verticalPageKeys[target]?.currentContext == null) {
      return false; // Don't consume a swipe when the target has no layout.
    }

    _edgeTurnConsumed = true; // At most one page for this entire touch.
    _edgePageTurnPending = true;
    if (vertical) {
      unawaited(_turnVerticalZoomPage(target));
    } else {
      _queuePage(delta); // Keep the existing tap-turn ticker/animation.
    }
    return true;
  }

  Future<void> _turnVerticalZoomPage(int target) async {
    final targetContext = _verticalPageKeys[target]?.currentContext;
    if (targetContext == null) {
      _edgePageTurnPending = false;
      return;
    }
    var succeeded = false;
    try {
      await Scrollable.ensureVisible(
        targetContext,
        duration: _normalDuration,
        curve: Curves.easeOutCubic,
        alignment: 0,
      );
      succeeded = true;
    } catch (error) {
      logger.w('CbzReader: zoomed vertical page turn failed: $error');
    }
    if (!mounted) return;
    _zoomState(_activeZoomPage)?.reset();
    _activeZoomPage = null;
    _edgePageTurnPending = false;
    _setZoomScrollLocked(_readerTouches.isNotEmpty, target);
    if (!succeeded) return;
    setState(() => _currentPage = target);
    saveProgress(target);
    _precacheAround(target);
  }

  void _readerPointerEnd(int pointer, {bool cancelled = false}) {
    if (_readerTouches.remove(pointer) == null) return;
    if (_readerTouches.length >= 2) {
      // A third finger can replace a lifted pointer without scale jumping.
      final points = _readerTouches.values.take(2).toList();
      _zoomState(_activeZoomPage)?.beginPinch(points[0], points[1]);
      return;
    }
    if (_readerTouches.isNotEmpty) return;

    final volumeDelta = !cancelled && !_gestureHadMultitouch &&
        !_zoomScrollLocked && !_edgePageTurnPending &&
        !_volumeSwipePending ? _volumeSwipeDelta : 0;
    _canSwipeNext = false;
    _canSwipePrevious = false;
    if (_volumeSwipeDelta != 0) {
      setState(() => _volumeSwipeDelta = 0);
    }
    if (volumeDelta != 0) unawaited(_openAdjacentVolume(volumeDelta));

    // Do NOT unlock when the second finger is lifted: the original finger
    // may still be moving, which must not turn the page at 1x.
    _firstTouchPage = null;
    _singleFingerStart = null;
    _edgePositiveAtStart = false;
    _edgeNegativeAtStart = false;
    if (_edgePageTurnPending) return; // Wait for page transition to finish.
    final state = _zoomState(_activeZoomPage);
    if (state?.isZoomed != true) {
      state?.reset(); // Snap sub-pixel residual scaling back to exactly 1x.
      _activeZoomPage = null;
      _setZoomScrollLocked(false, _currentPage);
    }
    // Keep _gestureHadMultitouch set until the NEXT pointer down, so a tap
    // callback from the just-finished gesture cannot queue a page turn.
  }

  void _showVolumeMessage(String message) {
    _volumeSwipeMessageTimer?.cancel();
    if (!mounted) return;
    setState(() {
      _volumeSwipePending = false;
      _volumeSwipeDelta = 0;
      _volumeSwipeMessage = message;
    });
    _volumeSwipeMessageTimer = Timer(const Duration(milliseconds: 1600), () {
      if (mounted) setState(() => _volumeSwipeMessage = null);
    });
  }

  Future<void> _openAdjacentVolume(int delta) async {
    if (_volumeSwipePending) return;
    final next = delta > 0;
    final title = next ? widget.nextVolumeTitle : widget.previousVolumeTitle;
    final action = next ? widget.onNextVolume : widget.onPreviousVolume;
    if (title == null || action == null) {
      _showVolumeMessage(next ? 'End of series' : 'Beginning of series');
      return;
    }
    _volumeSwipeMessageTimer?.cancel();
    setState(() {
      _volumeSwipePending = true;
      _volumeSwipeMessage = null;
      _volumeSwipeDelta = 0; // The pull indicator ends on release.
    });
    // Vertical reading has no per-page onPageChanged callback. Reaching the
    // bottom and deliberately advancing completes this volume as well.
    if (next && direction == 'vertical' && pageNums > 0) {
      saveProgress(pageNums - 1);
    }
    try {
      final error = await action();
      // Success replaces this keyed reader; do not flash a message on success.
      if (mounted && error != null) _showVolumeMessage(error);
    } catch (error) {
      logger.w('CbzReader: adjacent volume unavailable: $error');
      _showVolumeMessage('Could not open ${next ? 'next' : 'previous'} volume');
    }
  }

  Widget _volumeSwipePill() {
    final next = _volumeSwipeDelta >= 0;
    final title = next ? widget.nextVolumeTitle : widget.previousVolumeTitle;
    final message = _volumeSwipeMessage ??
        (title == null
            ? (next ? 'End of series' : 'Beginning of series')
            : 'Release to open $title');
    return Center(
      child: IgnorePointer(
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxWidth: MediaQuery.sizeOf(context).width * 0.82,
          ),
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: const Color(0xED252525),
              borderRadius: BorderRadius.circular(24),
              border: Border.all(color: Colors.white24),
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.menu_book_rounded, color: Colors.white,
                      size: 19),
                  const SizedBox(width: 10),
                  Flexible(
                    child: Text(message,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(color: Colors.white,
                          fontWeight: FontWeight.w600),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _zoomablePage(int index, File file) {
    return ReaderPinchZoom(
      key: _zoomPageKeys.putIfAbsent(
        index, () => GlobalKey<ReaderPinchZoomState>(),
      ),
      child: Image.file(
        file,
        fit: BoxFit.contain,
        gaplessPlayback: true,
        filterQuality: FilterQuality.high,
      ),
    );
  }

  Widget _buildPage(int index) {
    // Bypass FutureBuilder when a local or retained file is already present.
    final retained = _pageCache[index];
    if (retained != null && retained.existsSync()) {
      return _zoomablePage(index, retained);
    }
    if (!_isStreaming && index < pages.length) {
      final local = File(pages[index]);
      if (local.existsSync()) {
        return _zoomablePage(index, local);
      }
    }
    return FutureBuilder<File>(
      future: _loadPageFile(index),
      builder: (context, snapshot) {
        if (snapshot.hasData) {
          return _zoomablePage(index, snapshot.data!);
        }
        if (snapshot.hasError) {
          return const Center(child: Text('Error loading page'));
        }
        return const Center(child: CircularProgressIndicator());
      },
    );
  }

  Widget _buildPager(bool isRtl) {
    return NotificationListener<ScrollStartNotification>(
      onNotification: (n) {
        if (n.dragDetails != null) _cancelTapAnimation();
        return false;
      },
      child: PageView.builder(
        reverse: isRtl,
        itemCount: pageNums,
        controller: _pageController,
        physics: _zoomScrollLocked
            ? const NeverScrollableScrollPhysics()
            : null,
        itemBuilder: (context, index) => _buildPage(index),
        onPageChanged: (index) {
          // Slider/tap navigation away from a magnified page must not leave
          // the newly displayed page permanently locked against swiping.
          if ((_readerTouches.isEmpty || _edgePageTurnPending) &&
              _activeZoomPage != null &&
              _activeZoomPage != index) {
            _zoomState(_activeZoomPage)?.reset();
            _activeZoomPage = null;
            _edgePageTurnPending = false;
            // Hold the lock if the boundary-swipe finger is still down.
            _zoomScrollLocked = _readerTouches.isNotEmpty;
          }
          setState(() => _currentPage = index);
          // Record navigation before launching speculative page fetches.
          // The displayed page will be copied before its loader completes.
          ReaderPageCache.touch(
            volumeId: comicId, pageCount: pageNums, currentPage: index,
          ).catchError((Object error) {
            logger.w('ReaderPageCache: could not save position: $error');
          });
          saveProgress(index);
          _precacheAround(index);
        },
      ),
    );
  }

  Widget _buildVertical() {
    return SingleChildScrollView(
      controller: _verticalScrollController,
      physics: _zoomScrollLocked ? const NeverScrollableScrollPhysics() : null,
      child: Column(
        children: [
          for (int i = 0; i < pageNums; i++)
            KeyedSubtree(
              key: _verticalPageKeys.putIfAbsent(i, () => GlobalKey()),
              child: _buildPage(i),
            ),
        ],
      ),
    );
  }

  void _toggleOverlay() {
    if (_gestureHadMultitouch || _edgeTurnConsumed || _edgePageTurnPending) {
      return;
    }
    setState(() => _showOverlay = !_showOverlay);
    SystemChrome.setEnabledSystemUIMode(
      _showOverlay ? SystemUiMode.edgeToEdge : SystemUiMode.immersiveSticky,
    );
  }

  void _exit() {
    if (_exiting) return;
    _exiting = true;
    unawaited(_finishExit());
  }

  Future<void> _finishExit() async {
    // Both toolbar Back and Android Back use the same active-volume target.
    try {
      await widget.onPrepareCoverReturn?.call();
    } catch (error) {
      logger.w('CbzReader: could not prepare return cover: $error');
    }
    if (!mounted) return;
    widget.skipReturnFade?.value = _currentPage == 0;
    Navigator.pop(context);
  }

  Widget _fade(Widget child) {
    return IgnorePointer(
      ignoring: !_showOverlay,
      child: AnimatedOpacity(
        opacity: _showOverlay ? 1 : 0,
        duration: const Duration(milliseconds: 200),
        child: child,
      ),
    );
  }

  Widget _buildTopBar() {
    final chapter = _chapterLabels[_currentPage];
    return Container(
      color: Colors.black.withValues(alpha: 0.85),
      child: SafeArea(
        bottom: false,
        child: SizedBox(
          height: 76,
          child: Stack(
            children: [
              // Use the Collection header's 36dp band and 56dp side margins.
              // The Reader overlay remains 76dp tall, so page layout and the
              // existing overlay animation are otherwise unchanged.
              Positioned(
                top: 0,
                left: kToolbarHeight,
                right: kToolbarHeight,
                height: 36,
                child: Center(
                  child: AutoSizeText(
                    title,
                    textAlign: TextAlign.center,
                    maxLines: 2,
                    minFontSize: 10,
                    maxFontSize: 18,
                    stepGranularity: 0.5,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ),
              if (chapter != null)
                Positioned(
                  top: 36,
                  left: kToolbarHeight,
                  right: kToolbarHeight,
                  height: 18,
                  child: Center(
                    child: Text(
                      chapter,
                      textAlign: TextAlign.center,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Colors.white70,
                        fontSize: 12,
                      ),
                    ),
                  ),
                ),
              // Keep the back button over the title, just like Collection.
              Positioned(
                top: 0,
                left: 0,
                height: 36,
                child: SizedBox(
                  width: kToolbarHeight,
                  child: IconButton(
                    icon: const Icon(Icons.arrow_back, color: Colors.white),
                    onPressed: _exit,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildBottomBar(ColorScheme scheme, bool isRtl) {
    final int lastPage = pageNums > 1 ? pageNums - 1 : 1;

    return Container(
      color: Colors.black.withValues(alpha: 0.85),
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Directionality(
              textDirection: isRtl ? TextDirection.rtl : TextDirection.ltr,
              child: SliderTheme(
                data: SliderTheme.of(context).copyWith(
                  trackHeight: 6,
                  activeTrackColor: scheme.primary,
                  inactiveTrackColor: scheme.primary.withValues(alpha: 0.25),
                  thumbColor: scheme.primary,
                  overlayColor: scheme.primary.withValues(alpha: 0.15),
                ),
                child: Slider(
                  value: _currentPage.toDouble(),
                  min: 0,
                  max: lastPage.toDouble(),
                  onChanged: (v) => setState(() => _currentPage = v.round()),
                  onChangeEnd: (v) => _pageController?.jumpToPage(v.round()),
                ),
              ),
            ),
            const SizedBox(height: 4),
            SizedBox(
              height: 50,
              child: Stack(
                alignment: Alignment.center,
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 20, vertical: 8),
                    decoration: BoxDecoration(
                      color: scheme.primaryContainer,
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Text(
                      '${_currentPage + 1} / $pageNums',
                      style: TextStyle(
                        color: scheme.onPrimaryContainer,
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  if (_isStreaming)
                    Align(
                      alignment: Alignment.centerRight,
                      child: _buildDownloadButton(scheme),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      // The reader overlay is the only title bar. Avoid showing a temporary
      // Material AppBar with a different font size during initialization.
      if (widget.continuingVolume) {
        return PopScope(
          canPop: false,
          onPopInvokedWithResult: (didPop, result) {
            if (!didPop) _exit();
          },
          child: const Scaffold(
            backgroundColor: Colors.black,
            body: Center(child: CircularProgressIndicator()),
          ),
        );
      }
      return const Scaffold(
        backgroundColor: Colors.black,
        body: Center(child: CircularProgressIndicator()),
      );
    }

    final scheme = Theme.of(context).colorScheme;
    final bool isRtl = direction == 'rtl';
    final bool isVertical = direction == 'vertical';

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop) _exit();
      },
      child: Scaffold(
        backgroundColor: Colors.black,
        body: Stack(
          children: [
            Positioned.fill(
              child: Listener(
                behavior: HitTestBehavior.opaque,
                onPointerDown: _readerPointerDown,
                onPointerMove: _readerPointerMove,
                onPointerUp: (event) => _readerPointerEnd(event.pointer),
                onPointerCancel: (event) =>
                    _readerPointerEnd(event.pointer, cancelled: true),
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTapUp: isVertical ? (_) => _toggleOverlay() : _handleTap,
                  child: isVertical ? _buildVertical() : _buildPager(isRtl),
                ),
              ),
            ),
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: _fade(_buildTopBar()),
            ),
            if (!isVertical)
              Positioned(
                bottom: 0,
                left: 0,
                right: 0,
                child: _fade(_buildBottomBar(scheme, isRtl)),
              ),
            if (_volumeSwipeDelta != 0 || _volumeSwipeMessage != null)
              Positioned.fill(child: _volumeSwipePill()),
          ],
        ),
      ),
    );
  }
}
