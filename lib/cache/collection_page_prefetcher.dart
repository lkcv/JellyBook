import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:kurage/cache/reader_page_cache.dart';
import 'package:kurage/models/entry.dart';
import 'package:kurage/providers/cbz_stream.dart';
import 'package:kurage/providers/download_queue.dart';
import 'package:kurage/providers/supported_formats.dart';
import 'package:path_provider/path_provider.dart';
import 'package:kurage/providers/session_store.dart';

class CollectionPagePrefetcher {
  CollectionPagePrefetcher({
    required this.allowed,
    required this.busy,
    required this.onComplete,
  });

  final bool Function() allowed;
  final bool Function() busy;
  final VoidCallback onComplete;

  static const _idleDelay = Duration(milliseconds: 450);
  Timer? _timer;
  CancelToken? _cancelToken;
  List<Entry> _entries = const [];
  String? _windowKey;
  String? _completedKey;
  int _generation = 0;
  bool _scheduled = false;
  bool _running = false;
  bool _disposed = false;

  bool get hasWork => _scheduled || _running;

  bool schedule(List<Entry> entries, int first, int end) {
    final visible = entries.sublist(first, end);
    final key = visible.map((entry) =>
        '${entry.id}:${entry.pageNum}:${entry.downloaded}').join('|');
    if (_windowKey == key) return hasWork;

    stop();
    _windowKey = key;
    _entries = visible.where((entry) =>
        !entry.downloaded && entryFileExtension(entry.path) == 'cbz').toList();
    if (_entries.isEmpty || _completedKey == key) return false;
    _arm(_generation);
    return true;
  }

  void stop() {
    ++_generation;
    _timer?.cancel();
    _timer = null;
    _scheduled = false;
    _cancelToken?.cancel();
    _windowKey = null;
  }

  void _arm(int generation) {
    if (!_valid(generation)) return;
    _timer?.cancel();
    _scheduled = true;
    _timer = Timer(_idleDelay, () {
      _scheduled = false;
      if (!_valid(generation)) return;
      if (_running || busy() || DownloadQueue.instance.pendingCount > 0) {
        _arm(generation);
        return;
      }
      unawaited(_run(generation));
    });
  }

  bool _valid(int generation) =>
      !_disposed && generation == _generation &&
      _windowKey != null && allowed();

  bool _canFetch(int generation) =>
      _valid(generation) && !busy() &&
      DownloadQueue.instance.pendingCount == 0;

  Future<void> _run(int generation) async {
    _running = true;
    var completed = false;
    try {
      final session = SessionStore.current;
      final server = session.server;
      final token = session.token;
      if (!_canFetch(generation)) return;
      if (server.isEmpty || token.isEmpty) {
        completed = true;
        return;
      }

      final entries = _entries;
      for (var pass = 0; pass < 2; pass++) {
        for (final entry in entries) {
          if (!_canFetch(generation)) return;
          final requestedPage = pass == 0
              ? 0
              : (await ReaderPageCache.getCurrentPage(entry.id) ??
                  entry.pageNum);
          if (pass == 1 && requestedPage <= 0) continue;
          if (await ReaderPageCache.getPage(entry.id, requestedPage) != null) {
            continue;
          }
          if (!_canFetch(generation)) return;

          final cancel = CancelToken();
          _cancelToken = cancel;
          Directory? directory;
          try {
            final temp = await getTemporaryDirectory();
            if (!_canFetch(generation)) return;
            directory = await Directory(temp.path)
                .createTemp('kurage_page_prefetch_');
            final stream = CbzStream(
              url: server,
              itemId: entry.id,
              headers: {'Authorization': 'MediaBrowser Token="$token"'},
              pageDirectory: directory,
              cancelToken: cancel,
            );
            await stream.init();
            if (!_canFetch(generation)) return;
            final pageIndex = requestedPage.clamp(0, stream.pageCount - 1).toInt();
            if (await ReaderPageCache.getPage(entry.id, pageIndex) != null) {
              continue;
            }
            final file = await stream.getPage(pageIndex);
            if (!_canFetch(generation)) return;
            await ReaderPageCache.savePrefetchedPage(
              volumeId: entry.id,
              pageCount: stream.pageCount,
              pageIndex: pageIndex,
              resumePage: entry.pageNum,
              file: file,
              allowed: () => _canFetch(generation),
            );
          } catch (error) {
            if (!_valid(generation)) return;
            debugPrint('Collection page prefetch ${entry.id}: $error');
          } finally {
            if (identical(_cancelToken, cancel)) _cancelToken = null;
            if (directory != null) {
              try {
                await directory.delete(recursive: true);
              } on FileSystemException {
                // Another operation may already have removed the temp files.
              }
            }
          }
        }
      }
      completed = true;
    } catch (error) {
      debugPrint('Collection page prefetch: $error');
      completed = true;
    } finally {
      _running = false;
      if (_valid(generation)) {
        if (completed) {
          _completedKey = _windowKey;
          onComplete();
        } else if (!_scheduled) {
          _arm(generation);
        }
      } else if (_valid(_generation) && !_scheduled) {
        _arm(_generation);
      }
    }
  }

  void dispose() {
    _disposed = true;
    stop();
  }
}
