import 'dart:async';
import 'dart:collection';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:isar/isar.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:jellybook/models/entry.dart';
import 'package:jellybook/providers/downloadEntry.dart';
import 'package:jellybook/providers/downloadBackground.dart';
import 'package:jellybook/providers/resumableTransfer.dart';
import 'package:jellybook/providers/fileNameFromTitle.dart';
import 'package:path_provider/path_provider.dart';

/// Shared queue with a persistent journal and optional Android foreground
/// execution while it drains. The service helps with lock/background survival,
/// but cannot survive a force-stop or process kill. Interrupted transfers are
/// resumed from retained bytes after restart, while queued work survives.
enum DownloadJobState { queued, downloading, completed, failed, canceled }

class DownloadJob {
  DownloadJob(this.entry);

  Entry entry;
  String get id => entry.id;
  String get title => entry.title;
  DownloadJobState state = DownloadJobState.queued;
  double progress = 0;
  Object? error;
  Completer<Entry?> _completion = Completer<Entry?>();

  /// Returns null on failure/cancellation; inspect [state] for the reason.
  Future<Entry?> get result => _completion.future;
}

class DownloadManager extends ChangeNotifier {
  DownloadManager._();
  static final DownloadManager instance = DownloadManager._();

  final List<DownloadJob> _jobs = [];
  final ValueNotifier<int> _headerChanges = ValueNotifier<int>(0);
  bool _draining = false;
  DateTime? _lastProgressNotice;

  static const _queueStorageKey = 'jellybook_download_queue_v1';
  Future<void>? _restoreFuture;
  Future<void> _persistenceTail = Future<void>.value();
  bool _restored = false;

  /// Rebuild queued/failed jobs from Isar-backed entries when Library is ready.
  /// Safe to call more than once (or concurrently with a new enqueue).
  Future<void> restoreQueue() {
    if (_restored) return Future<void>.value();
    // Deferring by one event turn also ensures _restoreFuture is assigned
    // before an early failure attempts to clear it for a later retry.
    return _restoreFuture ??= Future<void>(_loadSavedQueue);
  }

  Future<void> _loadSavedQueue() async {
    try {
      final isar = Isar.getInstance();
      if (isar == null) throw StateError('Database unavailable');
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_queueStorageKey);
      dynamic saved;
      try {
        saved = raw == null ? null : jsonDecode(raw);
      } on FormatException catch (error) {
        // An unreadable journal cannot be recovered, but new downloads must
        // still work. Do not fail the entire manager initialization.
        debugPrint('DownloadManager: invalid saved queue: $error');
      }
      if (saved is List) {
        final recovered = <DownloadJob>[];
        final savedIds = <String>{};
        for (final record in saved) {
          if (record is! Map) continue;
          final id = record['id'];
          final state = record['state'];
          if (id is! String || id.isEmpty) continue;
          if (state != 'queued' && state != 'downloading' &&
              state != 'failed') continue;
          if (!savedIds.add(id)) continue;
          final entry = await isar.entrys.where().idEqualTo(id).findFirst();
          // Downloads completed before an app crash are already in Isar.
          if (entry == null || entry.downloaded) continue;
          final job = DownloadJob(entry);
          final fileName = await fileNameFromTitle(entry.path.split('/').last);
          final directory = await getApplicationDocumentsDirectory();
          job.progress = await retainedDownloadProgress('${directory.path}/$fileName');
          if (state == 'queued' || state == 'downloading') {
            job.state = DownloadJobState.queued;
          } else {
            job.state = DownloadJobState.failed;
            job.error = state == 'downloading'
                ? 'Download interrupted when the app stopped. Tap Retry.'
                : 'Previous download failed. Tap Retry.';
            job._completion.complete(null);
          }
          recovered.add(job);
        }
        // Enqueue may have run during the asynchronous Isar lookups above.
        // Those jobs already have callers awaiting their Futures; keep them
        // rather than recovering a duplicate with a different completion.
        final liveIds = _jobs.map((job) => job.id).toSet();
        recovered.removeWhere((job) => !liveIds.add(job.id));
        // Jobs from the previous session retain their FIFO position ahead of
        // any new requests made while the journal was loading.
        _jobs.insertAll(0, recovered);
        if (recovered.isNotEmpty) _changed();
      }
    } catch (error) {
      // If storage or Isar is temporarily unavailable, don't erase a queue
      // we haven't managed to read. A later restore attempt may succeed.
      debugPrint('DownloadManager: queue recovery deferred: $error');
      _restoreFuture = null;
      return;
    }
    _restored = true;
    // Prune completed/missing entries and merge any in-memory enqueues.
    await _persistQueue();
    unawaited(_drain());
  }

  /// Store only IDs/order/states, not archive data, credentials or frequent
  /// progress callbacks. Serialize writes so older snapshots cannot win.
  Future<void> _persistQueue() {
    final snapshot = jsonEncode([
      for (final job in _jobs)
        if (job.state == DownloadJobState.queued ||
            job.state == DownloadJobState.downloading ||
            job.state == DownloadJobState.failed)
          {'id': job.id, 'state': job.state.name},
    ]);
    _persistenceTail = _persistenceTail.then((_) async {
      final prefs = await SharedPreferences.getInstance();
      if (!await prefs.setString(_queueStorageKey, snapshot)) {
        debugPrint('DownloadManager: could not persist download queue');
      }
    }).catchError((Object error) {
      debugPrint('DownloadManager: could not persist queue: $error');
    });
    return _persistenceTail;
  }

  ValueListenable<int> get headerChanges => _headerChanges;
  UnmodifiableListView<DownloadJob> get jobs => UnmodifiableListView(_jobs);
  int get pendingCount => _jobs.where((job) =>
      job.state == DownloadJobState.queued ||
      job.state == DownloadJobState.downloading).length;
  int get failedCount => _jobs.where((job) =>
      job.state == DownloadJobState.failed).length;

  DownloadJob enqueue(Entry entry) {
    // Completed downloads don't need to re-enter the queue.
    if (entry.downloaded) {
      final completed = DownloadJob(entry)
        ..state = DownloadJobState.completed
        ..progress = 100;
      completed._completion.complete(entry);
      return completed;
    }
    for (final job in _jobs) {
      if (job.id != entry.id) continue;
      if (job.state == DownloadJobState.failed) {
        _retryJob(job);
      }
      return job;
    }
    final job = DownloadJob(entry);
    _jobs.add(job);
    _changed();
    unawaited(_drain());
    return job;
  }

  void retry(String id) {
    for (final job in _jobs) {
      if (job.id == id && job.state == DownloadJobState.failed) {
        _retryJob(job);
        return;
      }
    }
  }

  void _retryJob(DownloadJob job) {
    job.state = DownloadJobState.queued;
    job.error = null;
    // Keep the last visible partial progress during a manual retry.
    job._completion = Completer<Entry?>();
    _changed();
    unawaited(_drain());
  }

  /// Only queued jobs can be cancelled in this phase. An in-flight Dio request
  /// has no cancellation token yet, so never pretend it has been stopped.
  void cancelQueued(String id) {
    for (final job in _jobs.toList()) {
      if (job.id != id || job.state != DownloadJobState.queued) continue;
      job.state = DownloadJobState.canceled;
      job._completion.complete(null);
      _jobs.remove(job);
      _changed();
      return;
    }
  }

  void dismissFailure(String id) {
    _jobs.removeWhere((job) =>
        job.id == id && job.state == DownloadJobState.failed);
    _changed();
  }

  void _changed({bool status = true}) {
    notifyListeners();
    if (status) {
      _headerChanges.value++;
      if (_restored) unawaited(_persistQueue());
    }
  }

  Future<void> _drain() async {
    if (_draining) return;
    _draining = true;
    try {
      // Enqueues may occur before the persisted queue has been restored.
      await restoreQueue();
      if (!_restored) return; // Never start work before the journal is read.
      // Run the foreground service before starting the first network transfer.
      // It stays up across the whole FIFO queue, then stops when work finishes.
      if (_jobs.any((job) => job.state == DownloadJobState.queued)) {
        await DownloadBackground.start();
      }
      while (true) {
        DownloadJob? current;
        for (final job in _jobs) {
          if (job.state == DownloadJobState.queued) {
            current = job;
            break;
          }
        }
        if (current == null) break;
        final job = current;
        job.state = DownloadJobState.downloading;
        _changed();
        // Record the in-flight state before network/disk work begins. If the
        // process dies during extraction, don't auto-retry a partial folder.
        await _persistenceTail;
        _lastProgressNotice = null;
        try {
          // A queued Entry may be old by the time its turn arrives.
          final isar = Isar.getInstance();
          final latest = isar == null ? null :
              await isar.entrys.where().idEqualTo(job.id).findFirst();
          final result = await downloadEntry(
            latest ?? job.entry,
            onProgress: (value) {
              if (job.state != DownloadJobState.downloading) return;
              final now = DateTime.now();
              // Don't repaint a progress sheet on every Dio receive callback.
              if (value >= 100 || _lastProgressNotice == null ||
                  now.difference(_lastProgressNotice!) >=
                      const Duration(milliseconds: 250)) {
                job.progress = value.clamp(0.0, 100.0).toDouble();
                _lastProgressNotice = now;
                _changed(status: false);
              }
            },
          );
          job.entry = result;
          job.progress = 100;
          job.state = DownloadJobState.completed;
          job._completion.complete(result);
          _jobs.remove(job); // Completed files live in the Downloaded filter.
        } catch (error) {
          job.error = error;
          job.state = DownloadJobState.failed;
          job._completion.complete(null);
        }
        _changed();
      }
    } finally {
      // A failure (or an empty queue) must not leave a foreground service or
      // wake lock running once no more transfers are in progress.
      await DownloadBackground.stop();
      _draining = false;
      // Enqueue could have happened after the final empty-queue check while
      // the service was being stopped. Don't strand that late request.
      if (_jobs.any((job) => job.state == DownloadJobState.queued)) {
        unawaited(_drain());
      }
    }
  }
}
