import 'dart:io';
import 'package:flutter/material.dart';
import 'package:jellybook/providers/updatePagenum.dart';
import 'package:jellybook/screens/downloaderScreen.dart';
import 'package:jellybook/providers/fileNameFromTitle.dart';
import 'package:isar/isar.dart';
import 'package:isar_flutter_libs/isar_flutter_libs.dart';
import 'package:jellybook/models/entry.dart';
import 'package:jellybook/providers/progress.dart';
import 'package:jellybook/l10n/app_localizations.dart';
import 'package:jellybook/variables.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:jellybook/screens/AudioPicker.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:jellybook/widgets/AudioPlayerWidget.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sentry_flutter/sentry_flutter.dart';
import 'package:flutter/services.dart';
import 'package:auto_size_text/auto_size_text.dart';
import 'dart:collection';
import 'package:flutter/scheduler.dart';
import 'package:provider/provider.dart';
import 'package:jellybook/providers/connectionManager.dart';
import 'package:jellybook/providers/cbzStream.dart';
import 'package:jellybook/providers/downloadEntry.dart';

class CbrCbzReader extends StatefulWidget {
  final String title;
  final String comicId;

  const CbrCbzReader({
    Key? key,
    required this.title,
    required this.comicId,
  }) : super(key: key);

  @override
  _CbrCbzReaderState createState() => _CbrCbzReaderState();
}

class _CbrCbzReaderState extends State<CbrCbzReader>
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
  int _currentPage = 0;
  PageController? _pageController;
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
  Map<int, File> _pageCache = {};

  // Download in background
  bool _downloadInProgress = false;
  double _downloadProgress = 0.0;

  // Audio variables
  String audioPath = '';
  AudioPlayer audioPlayer = AudioPlayer();
  bool isPlaying = false;
  Duration audioPosition = Duration();
  String audioId = '';

  @override
  void initState() {
    super.initState();
    title = widget.title;
    comicId = widget.comicId;
    _load();
  }

  @override
  void dispose() {
    _pageController?.dispose();
    audioPlayer.dispose();
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    _tapTicker.dispose();
    _stream?.clear(); // Clean up streamed temp files
    super.dispose();
  }

  Widget _buildDownloadButton(ColorScheme scheme) {
    final connection =
        Provider.of<ConnectionManager>(context).status;
    final offline = connection == ConnectionStatus.offline;
    final enabled = !_downloadInProgress && !offline;

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
                value: _downloadInProgress ? _downloadProgress / 100 : 0,
                strokeWidth: 3,
                backgroundColor: Colors.white.withOpacity(0.3),
                valueColor: AlwaysStoppedAnimation<Color>(scheme.primary),
              ),
            ),
            _downloadInProgress
                ? Text(
                    '${_downloadProgress.round()}%',
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
  }

  Future<void> _load() async {
    try {
      PaintingBinding.instance.imageCache.maximumSizeBytes = 300 << 20;
      final prefs = await SharedPreferences.getInstance();
      direction = (prefs.getString('readingDirection') ?? 'ltr').toLowerCase();

      await getData();
      await getChapters();
      await getProgress(comicId);

      if (_isStreaming) {
        await _stream!.init();
        pageNums = _stream!.pageCount;
      } else {
        await createPageList();
      }

      final lastPage = pageNums == 0 ? 0 : pageNums - 1;
      _currentPage = pageNum.clamp(0, lastPage).toInt();
      _pageController = PageController(initialPage: _currentPage);
      _precacheAround(_currentPage);

      SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
      if (mounted) setState(() => _loading = false);
    } catch (e, s) {
      logger.e('CbrCbzReader: load failed: $e\n$s');
      if (mounted) {
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
        nav.pop(); // the reader sits on top of ReadingScreen
      }
    }
  }

  Future<void> getData() async {
    final isar = Isar.getInstance();
    return await isar!.entrys
        .where()
        .idEqualTo(comicId)
        .findFirst()
        .then((value) {
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
    final client = prefs.getString('client') ?? 'JellyBook';
    final device = prefs.getString('device') ?? '';
    final deviceId = prefs.getString('deviceId') ?? '';
    final version = prefs.getString('version') ?? '';

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
    if (pageNums == 0) return;
    final start = (index - 3).clamp(0, pageNums - 1);
    final end = (index + 3).clamp(0, pageNums - 1);
    for (int i = start; i <= end; i++) {
      if (_isStreaming && _stream != null) {
        _stream!.getPage(i).then((file) {
          if (mounted) precacheImage(FileImage(file), context);
        }).catchError((e) => logger.e('Precache error: $e'));
      } else if (i < pages.length) {
        precacheImage(FileImage(File(pages[i])), context);
      }
    }
  }

  Future<void> _downloadInBackground() async {
    if (_downloadInProgress) return;
    final isar = Isar.getInstance();
    final entry = await isar!.entrys.where().idEqualTo(comicId).findFirst();
    if (entry == null) return;

    setState(() {
      _downloadInProgress = true;
      _downloadProgress = 0.0;
    });
    try {
      await downloadEntry(
        entry,
        onProgress: (p) {
          if (!mounted) return;
          if (p < 100 && (p - _downloadProgress).abs() < 1) return;
          setState(() => _downloadProgress = p);
        },
      );
      await createPageList(); // local page paths ready
      if (!mounted) return;

      // Decode the pages currently on screen from disk *before* flipping
      // off streaming. Otherwise Image.file has a cold cache and the black
      // scaffold shows through for a frame.
      await _precacheLocalAround(_currentPage);
      if (!mounted) return;

      setState(() {
        _isStreaming = false;
        _downloadInProgress = false;
      });

      // Drop stream temp files only after the local images have painted
      final stream = _stream;
      _stream = null;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        stream?.clear();
      });
    } catch (e) {
      logger.e('CbrCbzReader: download failed: $e');
      if (mounted) setState(() => _downloadInProgress = false);
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
      } catch (e, s) {
        SharedPreferences prefs = await SharedPreferences.getInstance();
        bool useSentry = prefs.getBool('useSentry') ?? false;
        if (useSentry) await Sentry.captureException(e, stackTrace: s);
        logger.d("Error: not a valid directory, its a file");
      }
    }
  }

  Future<void> saveProgress(int page) async {
    final isar = Isar.getInstance();
    final entry = await isar!.entrys.where().idEqualTo(comicId).findFirst();

    entry!.pageNum = page;
    entry.progress = (page / (pageNums > 0 ? pageNums : 1)) * 100;

    await isar.writeTxn(() async {
      await isar.entrys.put(entry);
    });

    logger.d("saved progress: page $page / $pageNums");
    updatePagenum(entry.id, entry.pageNum);
  }

  void _handleTap(TapUpDetails details) {
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

  Widget _buildPage(int index) {
    if (_isStreaming && _stream != null) {
      return FutureBuilder<File>(
        future: _stream!.getPage(index),
        builder: (context, snapshot) {
          if (snapshot.hasData) {
            return InteractiveViewer(
              clipBehavior: Clip.none,
              child: Image.file(
                snapshot.data!,
                fit: BoxFit.contain,
                gaplessPlayback: true,
                filterQuality: FilterQuality.high,
              ),
            );
          } else if (snapshot.hasError) {
            return Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.error, size: 64, color: Colors.red),
                  SizedBox(height: 16),
                  Text('Error loading page'),
                ],
              ),
            );
          }
          return const Center(child: CircularProgressIndicator());
        },
      );
    } else {
      return InteractiveViewer(
        clipBehavior: Clip.none,
        child: Image.file(
          File(pages[index]),
          fit: BoxFit.contain,
          gaplessPlayback: true,
          filterQuality: FilterQuality.high,
        ),
      );
    }
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
        itemBuilder: (context, index) => _buildPage(index),
        onPageChanged: (index) {
          setState(() => _currentPage = index);
          saveProgress(index);
          _precacheAround(index);
        },
      ),
    );
  }

  Widget _buildVertical() {
    return SingleChildScrollView(
      child: Column(
        children: [
          for (int i = 0; i < pageNums; i++) _buildPage(i),
        ],
      ),
    );
  }

  void _toggleOverlay() {
    setState(() => _showOverlay = !_showOverlay);
    SystemChrome.setEnabledSystemUIMode(
      _showOverlay ? SystemUiMode.edgeToEdge : SystemUiMode.immersiveSticky,
    );
  }

  void _exit() {
    Navigator.pop(context);
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
    return Container(
      color: Colors.black.withOpacity(0.85),
      child: SafeArea(
        bottom: false,
        child: SizedBox(
          height: kToolbarHeight,
          child: Row(
            children: [
              IconButton(
                icon: const Icon(Icons.arrow_back, color: Colors.white),
                onPressed: _exit,
              ),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.only(right: 16),
                  child: AutoSizeText(
                    title,
                    maxLines: 2,
                    minFontSize: 10,
                    maxFontSize: 18,
                    stepGranularity: 0.5,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w600,
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

  Widget _buildBottomBar(ColorScheme scheme, bool isRtl) {
    final int lastPage = pageNums > 1 ? pageNums - 1 : 1;

    return Container(
      color: Colors.black.withOpacity(0.85),
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
                  inactiveTrackColor: scheme.primary.withOpacity(0.25),
                  thumbColor: scheme.primary,
                  overlayColor: scheme.primary.withOpacity(0.15),
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
      return Scaffold(
        appBar: AppBar(title: Text(title)),
        body: const Center(child: CircularProgressIndicator()),
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
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTapUp: isVertical ? (_) => _toggleOverlay() : _handleTap,
                child: isVertical ? _buildVertical() : _buildPager(isRtl),
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
          ],
        ),
      ),
    );
  }
}
