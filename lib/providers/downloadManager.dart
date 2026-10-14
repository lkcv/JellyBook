import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:dio/dio.dart';

import 'package:flutter/foundation.dart';
import 'package:isar/isar.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:jellybook/models/entry.dart';
import 'package:jellybook/providers/downloadEntry.dart';
import 'package:jellybook/providers/downloadBackground.dart';
import 'package:jellybook/providers/resumableTransfer.dart';
import 'package:jellybook/providers/fileNameFromTitle.dart';
import 'package:jellybook/providers/supportedFormats.dart';
import 'package:path_provider/path_provider.dart';
import 'package:jellybook/providers/connectionManager.dart';

/// Shared queue with a persistent journal and optional Android foreground
/// execution while it drains. The service helps with lock/background survival,
/// but cannot survive a force-stop or process kill. Interrupted transfers are
/// resumed from retained bytes after restart, while queued work survives.
enum DownloadJobState {
  queued,
  downloading,
  canceling,
  waitingForNetwork,
  waitingForServer,
  completed,
  failed,
  canceled,
}

class DownloadJob {
  DownloadJob(this.entry);

  Entry entry;
  String get id => entry.id;
  String get title => entry.title;
  DownloadJobState state = DownloadJobState.queued;
  double progress = 0;
  Object? error;
  Completer<Entry?> _completion = Completer<Entry?>();
  CancelToken? _cancelToken;

  /// Returns null on failure/cancellation; inspect [state] for the reason.
  Future<Entry?> get result => _completion.future;
}

class DownloadManager extends ChangeNotifier {
  DownloadManager._();

  /// Use the same authenticated server status as the Library header.
  /// Binding is performed once from the app's ConnectionManager provider.
  /// The OS connectivity stream is NOT a signal to start an HTTP transfer.
  void bindConnectionManager(ConnectionManager manager) {
    if (identical(_connectionManager, manager)) return;
    _connectionManager?.removeListener(_onConnectionChanged);
    _connectionManager = manager;
    _lastConnectionStatus = null;
    manager.addListener(_onConnectionChanged);
    _onConnectionChanged();
  }

  void _onConnectionChanged() {
    final current = _connectionManager?.status;
    if (current == null || current == _lastConnectionStatus) return;
    final wasOnline = _lastConnectionStatus == ConnectionStatus.online;
    _lastConnectionStatus = current;

    if (current != ConnectionStatus.online) {
      // The provider is still validating (or has confirmed an outage).
      // Don't let a scheduled retry race ahead of that validation.
      _retryTimer?.cancel();
      _retryTimer = null;
      return;
    }
    if (wasOnline) return;

    // Jellyfin's /System/Info/Public and authenticated /Users/Me checks
    // have succeeded. Wake only now, not when Android first sees Wi-Fi.
    _consecutiveInterruptions = 0;
    _recentReconnectUntil = DateTime.now().add(
      const Duration(seconds: 30),
    );
    _quickReconnectRetryAvailable = true;
    _retryTimer?.cancel();
    _retryTimer = null;
    if (!_restored) return; // Preserve Library's deferred startup restore.
    _wakeWaitingJobs();
    if (_nextRunnableJob() != null) unawaited(_drain());
  }

  static final DownloadManager instance = DownloadManager._();

  final List<DownloadJob> _jobs = [];
  final ValueNotifier<int> _headerChanges = ValueNotifier<int>(0);
  bool _draining = false;
  DateTime? _lastProgressNotice;
  ConnectionManager? _connectionManager;
  ConnectionStatus? _lastConnectionStatus;
  Timer? _retryTimer;
  int _consecutiveInterruptions = 0;
  DateTime? _recentReconnectUntil;
  bool _quickReconnectRetryAvailable = false;

  bool _isWaiting(DownloadJobState state) =>
      state == DownloadJobState.waitingForNetwork ||
      state == DownloadJobState.waitingForServer;

  // Do not let a waiting head-of-line job bypass the FIFO ordering.
  DownloadJob? _nextRunnableJob() {
    for (final job in _jobs) {
      if (_isWaiting(job.state)) return null;
      if (job.state == DownloadJobState.queued) return job;
    }
    return null;
  }

  void _wakeWaitingJobs() {
    // ConnectivityResult.wifi is not sufficient: wait for Jellyfin validation.
    if (_connectionManager?.status != ConnectionStatus.online) return;
    if (!_jobs.any((job) => _isWaiting(job.state))) return;
    _retryTimer?.cancel();
    _retryTimer = null;
    for (final job in _jobs) {
      if (_isWaiting(job.state)) {
        job.state = DownloadJobState.queued;
        job.error = null;
      }
    }
    _changed();
    // If the previous _drain is still stopping the foreground service,
    // its finally block will start the new queued attempt instead.
    unawaited(_drain());
  }

  void _scheduleRetry({bool quickReconnect = false}) {
    _retryTimer?.cancel();
    _retryTimer = null;
    // ConnectionManager handles revalidation while offline. Timed retries
    // are only for transient transfer errors with a verified online server.
    if (_connectionManager?.status != ConnectionStatus.online) return;
    // One quick retry after Wi-Fi comes back handles a transient socket or
    // route switch. Otherwise keep bounded backoff for a real server outage.
    final int seconds;
    if (quickReconnect) {
      seconds = 2;
    } else {
      final shift = (_consecutiveInterruptions++).clamp(0, 4).toInt();
      seconds = (5 * (1 << shift)).clamp(5, 60).toInt();
    }
    debugPrint('DownloadManager: retrying waiting download in ${seconds}s'
        '${quickReconnect ? ' (reconnect grace)' : ''}');
    _retryTimer = Timer(Duration(seconds: seconds), _wakeWaitingJobs);
  }

  bool _recoverable(Object error) {
    if (error is InterruptedDownload || error is SocketException ||
        error is HttpException || error is TimeoutException ||
        error is HandshakeException) return true;
    if (error is! DioException) return false;
    final status = error.response?.statusCode;
    if (status != null) {
      return status == 408 || status == 429 || status >= 500;
    }
    // Streaming-body errors may be wrapped as DioExceptionType.unknown.
    // File errors and malformed bodies must remain terminal failures.
    if (error.error is FileSystemException ||
        error.error is FormatException) return false;
    return error.type == DioExceptionType.connectionError ||
        error.type == DioExceptionType.connectionTimeout ||
        error.type == DioExceptionType.receiveTimeout ||
        error.type == DioExceptionType.sendTimeout ||
        error.type == DioExceptionType.unknown;
  }

  Future<DownloadJobState> _waitingState() async {
    try {
      final interfaces = await Connectivity().checkConnectivity();
      if (interfaces.isNotEmpty &&
          interfaces.every((item) => item == ConnectivityResult.none)) {
        return DownloadJobState.waitingForNetwork;
      }
    } catch (_) {
      // Platform connectivity may be unavailable, but periodic retries work.
    }
    return DownloadJobState.waitingForServer;
  }

  @override
  void dispose() {
    _retryTimer?.cancel();
    _connectionManager?.removeListener(_onConnectionChanged);
    _headerChanges.dispose();
    super.dispose();
  }

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
              state != 'waitingForNetwork' && state != 'waitingForServer' &&
              state != 'failed') continue;
          if (!savedIds.add(id)) continue;
          final entry = await isar.entrys.where().idEqualTo(id).findFirst();
          // Never resurrect queued downloads for formats we no longer support.
          // Leave any partial files on disk; only prune the queue journal.
          if (entry == null || entry.downloaded || !isSupportedEntry(entry)) {
            continue;
          }
          final job = DownloadJob(entry);
          final fileName = await fileNameFromTitle(entry.path.split('/').last);
          final directory = await getApplicationDocumentsDirectory();
          job.progress = await retainedDownloadProgress('${directory.path}/$fileName');
          if (state == 'queued' || state == 'downloading' ||
              state == 'waitingForNetwork' || state == 'waitingForServer') {
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
            _isWaiting(job.state) ||
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
      job.state == DownloadJobState.downloading ||
      job.state == DownloadJobState.canceling ||
      _isWaiting(job.state)).length;
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

  /// Cancel any unfinished job. Canceling is intentionally NOT journaled;
  /// a killed app must not resume an item the user removed.
  void cancel(String id) {
    for (final job in _jobs.toList()) {
      if (job.id != id || job.state == DownloadJobState.canceling ||
          job.state == DownloadJobState.canceled) continue;
      if (job.state == DownloadJobState.downloading) {
        job.state = DownloadJobState.canceling;
        _changed();
        // This interrupts the socket, including a currently streamed body.
        job._cancelToken?.cancel('Canceled by user');
      } else {
        job.state = DownloadJobState.canceling;
        _changed();
        unawaited(_finishCanceledJob(job));
      }
      if (!_jobs.any((other) => _isWaiting(other.state))) {
        _retryTimer?.cancel();
        _retryTimer = null;
      }
      return;
    }
  }

  Future<void> _finishCanceledJob(DownloadJob job) async {
    try {
      // A canceled queue entry must not reuse its old Range sidecar when
      // somebody explicitly requests the same book again.
      final filename = await fileNameFromTitle(job.entry.path.split('/').last);
      final folder = await getApplicationDocumentsDirectory();
      final archive = '${folder.path}/$filename';
      for (final path in [archive, '$archive.part', '$archive.part.json']) {
        final file = File(path);
        if (await file.exists()) await file.delete();
      }
    } catch (error) {
      debugPrint('DownloadManager: could not clean canceled download: $error');
    } finally {
      job.state = DownloadJobState.canceled;
      if (!job._completion.isCompleted) job._completion.complete(null);
      _jobs.remove(job);
      _changed();
      // Canceling a waiting head-of-line job can unblock the next queued job.
      if (_nextRunnableJob() != null) unawaited(_drain());
    }
  }

  /// Compatibility for any callers still using the queue-only API.
  void cancelQueued(String id) => cancel(id);

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
      if (_connectionManager?.status == ConnectionStatus.online &&
          _nextRunnableJob() != null) {
        await DownloadBackground.start();
      }
      while (_connectionManager?.status == ConnectionStatus.online) {
        final job = _nextRunnableJob();
        if (job == null) break;
        job.state = DownloadJobState.downloading;
        job._cancelToken = CancelToken();
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
          if (job.state == DownloadJobState.canceling) {
            throw const DownloadCanceled();
          }
          final result = await downloadEntry(
            latest ?? job.entry,
            cancelToken: job._cancelToken,
            onProgress: (value) {
              if (job.state != DownloadJobState.downloading) return;
              final now = DateTime.now();
              // Don't repaint a progress sheet on every Dio receive callback.
              if (value >= 100 || _lastProgressNotice == null ||
                  now.difference(_lastProgressNotice!) >=
                      const Duration(milliseconds: 250)) {
                // Real forward byte progress is a successful connection,
                // even if this large transfer isn't finished yet.
                if (value > job.progress + 0.01) {
                  _consecutiveInterruptions = 0;
                }
                job.progress = value.clamp(0.0, 100.0).toDouble();
                _lastProgressNotice = now;
                _changed(status: false);
              }
            },
          );
          if (job.state == DownloadJobState.canceling) {
            await _finishCanceledJob(job);
            continue;
          }
          _consecutiveInterruptions = 0;
          _quickReconnectRetryAvailable = false;
          job.entry = result;
          job.progress = 100;
          job.state = DownloadJobState.completed;
          job._completion.complete(result);
          _jobs.remove(job); // Completed files live in the Downloaded filter.
        } catch (error) {
          if (job.state == DownloadJobState.canceling ||
              job._cancelToken?.isCancelled == true ||
              error is DownloadCanceled) {
            await _finishCanceledJob(job);
            continue;
          }
          job.error = error;
          if (_recoverable(error)) {
            job.state = await _waitingState();
            debugPrint('DownloadManager: ${job.id} interrupted ($error), '
                'waiting as ${job.state.name}');
            // Preserve the existing completion Future and .part bytes.
            // No immediate requeue: only a connectivity event or timer wakes it.
            _changed();
            final quickReconnect = _quickReconnectRetryAvailable &&
                _recentReconnectUntil != null &&
                DateTime.now().isBefore(_recentReconnectUntil!) &&
                job.state != DownloadJobState.waitingForNetwork;
            if (quickReconnect) _quickReconnectRetryAvailable = false;
            _scheduleRetry(quickReconnect: quickReconnect);
            break;
          }
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
      if (_connectionManager?.status == ConnectionStatus.online &&
          _nextRunnableJob() != null) {
        unawaited(_drain());
      }
    }
  }
}
