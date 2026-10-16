import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:jellybook/providers/downloadQueue.dart';
import 'package:jellybook/cache/coverCache.dart';

/// A single low-priority disk-only cover fetcher shared by Library/Collection.
/// It deliberately never resolves an ImageProvider or pins decoded images.
/// Only one request can be active, including during changes of screen owner.
class SpeculativeCoverPrefetcher {
  SpeculativeCoverPrefetcher._();
  static final instance = SpeculativeCoverPrefetcher._();

  static const idleDelay = Duration(milliseconds: 450);
  Object? _owner;
  int _generation = 0;
  Timer? _timer;
  bool _running = false;
  bool _retryWhenIdle = false;
  bool Function()? _allowed;
  bool Function()? _busy;
  Future<List<String>> Function()? _urls;
  String _label = 'unknown';

  /// Replace the pending work for [owner]. Calling this on each scroll signal
  /// immediately invalidates the old queue and debounces the new viewport.
  void schedule({
    required Object owner,
    required String label,
    required bool Function() allowed,
    required bool Function() busy,
    required Future<List<String>> Function() urls,
  }) {
    _owner = owner;
    _label = label;
    _allowed = allowed;
    _busy = busy;
    _urls = urls;
    final generation = ++_generation;
    _arm(generation);
  }

  /// Stop before navigation; an HTTP request already in progress may finish,
  /// but its generation cannot launch a second request.
  void stop(Object owner) {
    if (!identical(owner, _owner)) return;
    _generation++;
    _timer?.cancel();
    _timer = null;
    _owner = null;
    _allowed = null;
    _busy = null;
    _urls = null;
    _retryWhenIdle = false;
  }

  void _arm(int generation) {
    _timer?.cancel();
    _timer = Timer(idleDelay, () {
      _timer = null;
      if (!_valid(generation)) return;
      if (_running) {
        _retryWhenIdle = true;
      } else {
        unawaited(_run(generation));
      }
    });
  }

  bool _valid(int generation) =>
      generation == _generation && _owner != null &&
      (_allowed?.call() ?? false);

  bool get _foregroundBusy =>
      (_busy?.call() ?? true) || DownloadQueue.instance.pendingCount > 0;

  Future<void> _run(int generation) async {
    if (!_valid(generation)) return;
    if (_foregroundBusy) {
      _arm(generation);
      return;
    }
    _running = true;
    var fetched = 0;
    var hits = 0;
    var failures = 0;
    final label = _label;
    try {
      final urls = await _urls!();
      if (!_valid(generation)) return;
      debugPrint('Speculative [$label]: ${urls.length} covers to check');
      final cache = CoverCacheManager.instance;
      for (final url in urls.toSet()) {
        if (!_valid(generation)) break;
        if (_foregroundBusy) {
          _arm(generation);
          break;
        }
        try {
          if (await cache.getFileFromCache(url) != null) {
            hits++;
          } else {
            if (!_valid(generation)) break;
            if (_foregroundBusy) {
              _arm(generation);
              break;
            }
            // CacheManager coalesces lookups and uses the same cache entries as
            // the displayed CachedNetworkImageProvider(coverUrl(path)).
            await cache.getSingleFile(url);
            fetched++;
          }
        } catch (_) {
          // A missing/broken cover must not block the rest of the series.
          failures++;
        }
      }
    } catch (error) {
      debugPrint('Speculative cover cache: $error');
    } finally {
      if (fetched + hits + failures > 0) {
        debugPrint('Speculative [$label]: $fetched fetched, '
            '$hits cached, $failures failed');
      }
      _running = false;
      if (_retryWhenIdle && _owner != null) {
        _retryWhenIdle = false;
        _arm(_generation);
      }
    }
  }
}
