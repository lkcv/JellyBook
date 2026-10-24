// Synchronize CBZ page indices with Jellyfin without racing rapid page turns.
import 'dart:async';

import 'package:isar/isar.dart';
import 'package:package_info_plus/package_info_plus.dart' as p_info;
import 'package:kurage/models/pending_progress_record.dart';
import 'package:kurage/providers/jellyfin_api.dart';
import 'package:kurage/providers/session_store.dart';
import 'package:kurage/variables.dart';

typedef _ProgressKey = ({String server, String userId, String itemId});

final _progressQueue = _JellyfinProgressQueue();

/// Queues a zero-based page index. Each volume retains only its latest page.
/// Network activity never blocks the reader's page-change callback.
Future<void> updatePagenum(String id, int pageIndex) {
  // Observe page changes before any asynchronous database or HTTP work.
  _progressQueue.noteLocalPageChange(id);
  return _progressQueue.enqueue(id, pageIndex);
}

/// Capture this before requesting Jellyfin library data. A page change while
/// the request is in flight must not be overwritten by an older response.
int progressRevision() => _progressQueue.revision;

/// Item IDs that must retain local progress (offline uploads or page changes
/// during the Jellyfin library request). Scoped to the current server/user.
Future<Set<String>> locallyProtectedProgressIds(int sinceRevision) =>
    _progressQueue.protectedItemIds(sinceRevision);

/// Called by ConnectionManager after authentication succeeds, including after
/// app restarts, resume, and reconnection.
Future<void> retryPendingProgress() => _progressQueue.retry();

class _JellyfinProgressQueue {
  static const _requestTimeout = Duration(seconds: 12);
  final Map<_ProgressKey, int> _pending = <_ProgressKey, int>{};
  final Map<String, int> _localChangeRevisions = <String, int>{};
  int _revision = 0;
  int get revision => _revision;

  void noteLocalPageChange(String id) {
    if (id.isNotEmpty) _localChangeRevisions[id] = ++_revision;
  }

  Future<Set<String>> protectedItemIds(int sinceRevision) async {
    // Wait for queued writes so recent offline pages remain protected.
    await _mutations;
    await _ensureLoaded();
    final session = SessionStore.current;
    final server = session.server.replaceFirst(RegExp(r'/+$'), '');
    final userId = session.userId;
    final protected = <String>{
      for (final entry in _localChangeRevisions.entries)
        if (entry.value > sinceRevision) entry.key,
    };
    for (final key in _pending.keys) {
      if (key.server == server && key.userId == userId) {
        protected.add(key.itemId);
      }
    }
    return protected;
  }

  Future<void> _mutations = Future<void>.value();
  Future<void>? _loading;
  bool _sending = false;

  // Serialize writes so an older page cannot overwrite a newer one or an
  // upload acknowledgement.
  Future<void> _mutate(Future<void> Function() action) {
    final operation = _mutations.then((_) => action());
    _mutations = operation.then<void>((_) {}, onError: (Object e, StackTrace st) {
      logger.e('Progress queue storage error: $e');
    });
    return operation;
  }

  Future<void> _ensureLoaded() async {
    try {
      await (_loading ??= _loadSaved());
    } catch (_) {
      _loading = null;
      rethrow;
    }
  }

  Future<void> _loadSaved() async {
    final isar = Isar.getInstance();
    if (isar == null) throw StateError('Database unavailable');
    final records = await isar.pendingProgressRecords.where().findAll();
    records.sort((a, b) => a.position.compareTo(b.position));
    final saved = <_ProgressKey, int>{};
    for (final record in records) {
      if (record.server.isEmpty || record.userId.isEmpty ||
          record.itemId.isEmpty || record.pageIndex < 0) {
        continue;
      }
      saved[(server: record.server, userId: record.userId,
          itemId: record.itemId)] = record.pageIndex;
    }

    _pending.addAll(saved);
  }

  Future<void> _persistSnapshot(Map<_ProgressKey, int> snapshot) async {
    final isar = Isar.getInstance();
    if (isar == null) throw StateError('Database unavailable');
    final records = <PendingProgressRecord>[];
    for (final entry in snapshot.entries) {
      records.add(PendingProgressRecord(
        server: entry.key.server,
        userId: entry.key.userId,
        itemId: entry.key.itemId,
        pageIndex: entry.value,
        position: records.length,
      ));
    }
    await isar.writeTxn(() async {
      await isar.pendingProgressRecords.clear();
      if (records.isNotEmpty) {
        await isar.pendingProgressRecords.putAll(records);
      }
    });
  }

  Future<void> _persist() => _persistSnapshot(_pending);

  Future<void> enqueue(String id, int pageIndex) => _mutate(() async {
        await _ensureLoaded();
        final session = SessionStore.current;
        final server = session.server.replaceFirst(RegExp(r'/+$'), '');
        final userId = session.userId;
        if (server.isEmpty || userId.isEmpty || id.isEmpty || pageIndex < 0) {
          logger.w('Progress not queued: missing account/item or invalid page');
          return;
        }
        // Never sync an old account's saved progress to a new account.
        _pending[(server: server, userId: userId, itemId: id)] = pageIndex;
        await _persist();
        _start();
      });

  Future<void> retry() => _mutate(() async {
        await _ensureLoaded();
        _start();
      });

  void _start() {
    if (_sending || _pending.isEmpty) return;
    _sending = true;
    unawaited(_drain());
  }

  Future<void> _drain() async {
    try {
      while (true) {
        // Include any page changes persisted while a request was in flight.
        await _mutations;
        if (_pending.isEmpty) return;
        final session = SessionStore.current;
        final server = session.server.replaceFirst(RegExp(r'/+$'), '');
        final userId = session.userId;
        final token = session.token;
        if (server.isEmpty || userId.isEmpty || token.isEmpty) return;

        MapEntry<_ProgressKey, int>? next;
        for (final entry in _pending.entries) {
          if (entry.key.server == server && entry.key.userId == userId) {
            next = entry;
            break;
          }
        }
        if (next == null) return;
        final key = next.key;
        final itemId = key.itemId;
        final page = next.value;
        try {
          await _report(server, token, itemId, page);
        } catch (e) {
          // Keep the latest page on disk for the next online transition.
          logger.w('Jellyfin progress pending for $itemId (page $page): $e');
          return;
        }
        await _mutate(() async {
          // A newer page may have arrived while the HTTP request ran.
          if (_pending[key] == page) {
            _pending.remove(key);
            await _persist();
          }
        });
      }
    } catch (e) {
      logger.e('Progress synchronization halted: $e');
    } finally {
      _sending = false;
    }
  }

  Future<void> _report(
      String server, String token, String itemId, int pageIndex) async {
    final version = (await p_info.PackageInfo.fromPlatform()).version;
    final headers = <String, String>{
      'Accept': 'application/json',
      'Content-Type': 'application/json',
      'Authorization': 'MediaBrowser Client="Kurage", '
          'Device="Unknown Device", DeviceId="Unknown Device id", '
          'Version="$version", Token="$token"',
    };
    final response = await JellyfinApi(server)
        .reportPlaybackProgress(
          itemId: itemId,
          positionTicks: pageIndex * 10000,
          headers: headers,
        )
        .timeout(_requestTimeout);
    final status = response.statusCode;
    if (status == null || status < 200 || status >= 300) {
      throw StateError('Jellyfin HTTP $status');
    }
    logger.d('Jellyfin progress synced for $itemId, page index $pageIndex');
  }
}
