import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/widgets.dart';
import 'package:kurage/cache/cover_cache.dart';
import 'package:kurage/variables.dart';

class CollectionCoverPrewarmer {
  CollectionCoverPrewarmer({
    required this.isActive,
    required this.isCurrentRoute,
    required this.visibleRange,
    required this.imageConfiguration,
    required this.onInitialReady,
    required this.onWarmComplete,
  });

  final bool Function() isActive;
  final bool Function() isCurrentRoute;
  final ({int first, int end}) Function(int count) visibleRange;
  final ImageConfiguration Function() imageConfiguration;
  final VoidCallback onInitialReady;
  final VoidCallback onWarmComplete;

  static const int _maxPinnedCovers = 42;
  List<String>? _covers;
  bool _initialReady = false;
  bool _scheduled = false;
  bool _warming = false;
  bool _warmAgain = false;
  bool _paused = false;
  bool _disposed = false;
  int _generation = 0;

  final Map<String, ({ImageStream stream, ImageStreamListener listener})>
      _pinnedCovers = {};
  final Set<String> _failedCovers = {};
  final Set<String> _revalidateCovers = {};
  double? _previousScrollOffset;
  DateTime? _previousScrollTime;
  int _scrollDirection = 1;
  bool _scrollingFast = false;

  bool get initialReady => _initialReady;
  bool get isScheduled => _scheduled;
  bool get isWarming => _warming;
  bool get isPaused => _paused;

  void setCovers(List<String> covers) {
    _covers = covers;
    schedule();
  }

  void schedule() {
    if (_disposed || !isActive() || _paused || _covers == null) return;
    if (_warming) {
      _warmAgain = true;
      return;
    }
    if (_scheduled) return;
    _scheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scheduled = false;
      if (!_canWarm(_generation)) return;
      unawaited(_warmCovers(_covers!));
    });
    // Even an idle grid needs a frame to deliver this callback.
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  bool _canWarm(int generation) =>
      !_disposed && isActive() && !_paused &&
      generation == _generation && isCurrentRoute();

  void pause() {
    _paused = true;
    _generation++;
    _warmAgain = false;
  }

  void resume() {
    if (_disposed) return;
    _paused = false;
    revalidate();
  }

  void revalidate() {
    _failedCovers.clear();
    _revalidateCovers.addAll(_pinnedCovers.keys);
    schedule();
  }

  // Returns false for insignificant scroll signals, as before extraction.
  bool recordScroll(double offset) {
    final now = DateTime.now();
    final previous = _previousScrollOffset;
    final previousTime = _previousScrollTime;
    _previousScrollOffset = offset;
    _previousScrollTime = now;
    if (previous != null && previousTime != null) {
      final delta = offset - previous;
      if (delta.abs() < 0.5) return false;
      final elapsed = now.difference(previousTime).inMicroseconds;
      _scrollDirection = delta >= 0 ? 1 : -1;
      if (elapsed > 0) {
        _scrollingFast = delta.abs() * 1000000 / elapsed > 1200;
      }
    }
    return true;
  }

  List<String> _prioritizedCovers(List<String> covers) {
    final visible = visibleRange(covers.length);
    final viewportCount = math.max(3, visible.end - visible.first);
    final ahead = viewportCount * (_scrollingFast ? 3 : 2);
    final behind = viewportCount;
    final paths = <String>[];
    final seen = <String>{};
    void add(int index) {
      if (index < 0 || index >= covers.length) return;
      final path = covers[index];
      if (path.isNotEmpty && path.toLowerCase() != 'asset' &&
          seen.add(path)) {
        paths.add(path);
      }
    }

    for (var i = visible.first; i < visible.end; i++) {
      add(i);
    }
    if (_scrollDirection >= 0) {
      for (var i = visible.end; i < math.min(covers.length, visible.end + ahead); i++) {
        add(i);
      }
      for (var i = visible.first - 1; i >= math.max(0, visible.first - behind); i--) {
        add(i);
      }
    } else {
      for (var i = visible.first - 1; i >= math.max(0, visible.first - ahead); i--) {
        add(i);
      }
      for (var i = visible.end; i < math.min(covers.length, visible.end + behind); i++) {
        add(i);
      }
    }
    return paths.take(_maxPinnedCovers).toList();
  }

  void _releaseCoverPin(String path) {
    final pin = _pinnedCovers.remove(path);
    if (pin != null) pin.stream.removeListener(pin.listener);
    _revalidateCovers.remove(path);
  }

  Future<void> _pinCover(String path, int generation,
      {Duration timeout = const Duration(seconds: 4)}) async {
    if (!_canWarm(generation) || _failedCovers.contains(path)) return;
    final previous = _pinnedCovers[path];
    if (previous != null && !_revalidateCovers.contains(path)) return;

    // The same provider/key is used by the rendered Collection cover.
    final provider = coverImageProvider(path);
    if (provider == null) return;
    final ready = Completer<bool>();
    final stream = provider.resolve(imageConfiguration());
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
    if (!loaded || !_canWarm(generation) ||
        (_initialReady &&
            !(_covers == null ? <String>[] :
                _prioritizedCovers(_covers!)).contains(path))) {
      stream.removeListener(listener);
      if (!loaded) _failedCovers.add(path);
      return;
    }
    // Retain the previous image until its replacement has decoded.
    _pinnedCovers[path] = (stream: stream, listener: listener);
    if (previous != null) previous.stream.removeListener(previous.listener);
    _revalidateCovers.remove(path);
  }

  Future<void> _warmCovers(List<String> covers) async {
    if (_warming) {
      _warmAgain = true;
      return;
    }
    final generation = _generation;
    if (!_canWarm(generation)) return;
    _warming = true;
    try {
      if (!_initialReady) {
        final paths = _prioritizedCovers(covers);
        final visible = visibleRange(covers.length);
        final initialCount = math.min(paths.length, <String>{
          for (var i = visible.first; i < visible.end; i++)
            if (covers[i].isNotEmpty && covers[i].toLowerCase() != 'asset')
              covers[i],
        }.length);
        final deadline = DateTime.now().add(const Duration(seconds: 6));
        for (var i = 0; i < initialCount && _canWarm(generation); i += 2) {
          final remaining = deadline.difference(DateTime.now());
          if (remaining <= Duration.zero) break;
          await Future.wait([
            for (var j = i; j < math.min(initialCount, i + 2); j++)
              _pinCover(paths[j], generation, timeout: remaining),
          ]);
        }
        if (_canWarm(generation) && identical(covers, _covers)) {
          _initialReady = true;
          onInitialReady();
          _warmAgain = true;
        }
      } else {
        while (_canWarm(generation) && identical(covers, _covers)) {
          final desired = _prioritizedCovers(covers);
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
      if (!_initialReady && _canWarm(generation) &&
          identical(covers, _covers)) {
        _initialReady = true;
        onInitialReady();
        _warmAgain = true;
      }
      logger.w('Collection cover warmup failed: $error');
    } finally {
      _warming = false;
      if (_initialReady && !_disposed) onWarmComplete();
      if (_warmAgain && !_disposed && isActive() && !_paused) {
        _warmAgain = false;
        schedule();
      }
    }
  }

  void dispose() {
    _disposed = true;
    _generation++;
    for (final path in _pinnedCovers.keys.toList()) {
      _releaseCoverPin(path);
    }
  }
}
