import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/widgets.dart';
import 'package:kurage/models/folder.dart';

class LibraryCoverPrewarmer {
  LibraryCoverPrewarmer({
    required this.canSchedule,
    required this.canWarm,
    required this.covers,
    required this.visibleRange,
    required this.provider,
    required this.context,
    required this.filterKey,
    required this.catalogSignature,
    required this.onInitialReady,
    required this.onStartupPainted,
  });

  final bool Function() canSchedule;
  final bool Function() canWarm;
  final List<Folder>? Function() covers;
  final ({int first, int end}) Function(int) visibleRange;
  final ImageProvider? Function(String) provider;
  final BuildContext Function() context;
  final String Function() filterKey;
  final String? Function() catalogSignature;
  final void Function() onInitialReady;
  final void Function() onStartupPainted;

  static const int _maxScrollCoverPins = 48;
  static const int _maxConcurrentScrollCoverLoads = 2;

  final List<({ImageStream stream, ImageStreamListener listener,
    Completer<void> ready})> _startupCoverPins = [];
  final Map<String, ({ImageStream stream, ImageStreamListener listener})>
      _scrollCoverPins = {};
  final Set<String> _scrollCoverLoading = {};
  final Set<String> _scrollCoverFailures = {};
  final Set<String> _scrollCoverRefreshPending = {};
  final Map<String, ({ImageStream stream, ImageStreamListener listener})>
      _scrollCoverReplacements = {};
  List<String> _scrollCoverPriority = const [];
  bool _resumeWarmWhileInactive = false;
  bool _scrollPumpScheduled = false;
  String? _scrollWindowKey;
  int _scrollCatalogVersion = 0;
  ScrollController? _lastScrollSource;
  double? _lastScrollOffset;
  DateTime? _lastScrollAt;
  double _scrollVelocity = 0;
  int _scrollDirection = 1;
  bool _warmScheduled = false;
  bool _warming = false;
  bool _warmAgain = false;
  bool _disposed = false;
  bool _initialCoversReady = false;

  bool get initialReady => _initialCoversReady;
  bool get resumeWarmWhileInactive => _resumeWarmWhileInactive;
  bool get isBusy => _warming || _warmScheduled || _scrollPumpScheduled ||
      _scrollCoverLoading.isNotEmpty;

  void invalidateWindow() => _scrollWindowKey = null;

  void filterChanged() {
    _scrollWindowKey = null;
    _scrollVelocity = 0;
    _lastScrollSource = null;
  }

  void catalogChanged(Set<String> validPaths) {
    _scrollCatalogVersion++;
    _scrollCoverFailures.clear();
    _scrollWindowKey = null;
    for (final path in _scrollCoverPins.keys.toList()) {
      if (!validPaths.contains(path)) _releaseScrollCover(path);
    }
  }

  void connectionRestored() {
    _scrollCoverFailures.clear();
    _scrollWindowKey = null;
  }

  void revalidate({bool allowInactive = false}) {
    _scrollCoverRefreshPending.addAll(_scrollCoverPins.keys);
    _scrollCoverFailures.clear();
    _scrollVelocity = 0;
    _resumeWarmWhileInactive = allowInactive;
    _scrollWindowKey = null;
  }

  bool recordScroll(ScrollController controller) {
    if (!_initialCoversReady || !canWarm() || !controller.hasClients) {
      return false;
    }
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
    return true;
  }

  void schedule() {
    if (_disposed || !canSchedule()) return;
    if (_warming) {
      _warmAgain = true;
      return;
    }
    if (_warmScheduled) return;
    _warmScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _warmScheduled = false;
      if (!_disposed && canWarm() && canSchedule()) {
        unawaited(_warmVisibleCovers());
      }
    });
    WidgetsBinding.instance.scheduleFrame();
  }

  Future<void> _warmVisibleCovers() async {
    if (_warming || _disposed || !canWarm()) return;
    _warmAgain = false;
    _warming = true;
    try {
      if (_initialCoversReady) {
        _updateScrollCoverWindow();
        return;
      }
      final folders = covers();
      if (folders == null) return;
      final signatureAtStart = catalogSignature();
      final range = visibleRange(folders.length);
      for (var i = range.first; i < range.end && canWarm(); i += 2) {
        await Future.wait([
          for (var j = i; j < math.min(range.end, i + 2); j++)
            _warmCover(folders[j].image),
        ]);
      }
      if (!_disposed && canWarm() && !_initialCoversReady &&
          signatureAtStart == catalogSignature()) {
        _initialCoversReady = true;
        onInitialReady();
        // The grid subscribes to these image streams before startup pins go.
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!_disposed) schedule();
        });
        WidgetsBinding.instance.addPostFrameCallback((_) {
          _releaseStartupCoverPins();
          onStartupPainted();
        });
      }
    } finally {
      _warming = false;
      if (_warmAgain && !_disposed && canWarm()) {
        _warmAgain = false;
        schedule();
      }
    }
  }

  Future<void> _warmCover(String path) async {
    if (_disposed || !canWarm()) return;
    final imageProvider = provider(path);
    if (imageProvider == null) return;
    try {
      if (!_initialCoversReady) {
        final ready = Completer<void>();
        final stream = imageProvider.resolve(createLocalImageConfiguration(context()));
        final listener = ImageStreamListener(
          (image, synchronousCall) {
            image.dispose();
            if (!ready.isCompleted) ready.complete();
          },
          onError: (error, stackTrace) {
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
        await precacheImage(imageProvider, context(), onError: (_, __) {});
      }
    } catch (_) {
      // Missing or offline covers must not hold up the startup gate.
    }
  }

  void _releaseStartupCoverPins() {
    for (final pin in _startupCoverPins) {
      pin.stream.removeListener(pin.listener);
      if (!pin.ready.isCompleted) pin.ready.complete();
    }
    _startupCoverPins.clear();
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

  void _scheduleScrollCoverPump() {
    if (_scrollPumpScheduled || !_initialCoversReady || !canWarm()) return;
    _scrollPumpScheduled = true;
    scheduleMicrotask(() {
      _scrollPumpScheduled = false;
      if (_disposed || !canWarm() || !_initialCoversReady) return;
      // The newest viewport replaces an obsolete queue during a fling.
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
      if (_resumeWarmWhileInactive && _scrollCoverLoading.isEmpty &&
          !_scrollCoverPriority.any((path) =>
              _scrollCoverRefreshPending.contains(path) ||
              (!_scrollCoverPins.containsKey(path) &&
                  !_scrollCoverFailures.contains(path)))) {
        _resumeWarmWhileInactive = false;
      }
    });
  }

  // Keep the previous decoded image pinned until its replacement succeeds.
  void _refreshScrollCoverPin(String path) {
    final previous = _scrollCoverPins[path];
    if (previous == null) return;
    try {
      final imageProvider = provider(path);
      if (imageProvider == null) {
        _scrollCoverRefreshPending.remove(path);
        return;
      }
      final stream = imageProvider.resolve(createLocalImageConfiguration(context()));
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
      final imageProvider = provider(path);
      if (imageProvider == null) return;
      final stream = imageProvider.resolve(createLocalImageConfiguration(context()));
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
    if (_disposed || !canWarm() || !_initialCoversReady) return;
    final folders = covers();
    if (folders == null) return;
    final range = visibleRange(folders.length);
    final span = math.max(8, range.end - range.first);
    final fast = _scrollVelocity > 2200;
    final ahead = math.min(fast ? 36 : 28, span * (fast ? 4 : 3));
    final behind = math.min(16, span);
    final key = '$_scrollCatalogVersion:${filterKey()}:${range.first}:'
        '${range.end}:$_scrollDirection:$fast';
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
    for (final path in _scrollCoverPins.keys.toList()) {
      if (!wanted.contains(path)) _releaseScrollCover(path);
    }
    _scrollCoverPriority = priority;
    _scheduleScrollCoverPump();
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _releaseStartupCoverPins();
    for (final path in _scrollCoverPins.keys.toList()) {
      _releaseScrollCover(path);
    }
    _scrollCoverPriority = const [];
    _scrollWindowKey = null;
    _resumeWarmWhileInactive = false;
  }
}
