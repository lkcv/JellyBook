// Synchronize CBZ page indices with Jellyfin without racing rapid page turns.
import 'dart:async';
import 'dart:convert';

import 'package:package_info_plus/package_info_plus.dart' as p_info;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:jellybook/providers/jellyfinApi.dart';
import 'package:jellybook/variables.dart';

final _progressQueue = _JellyfinProgressQueue();

/// Queues a zero-based page index. Each volume retains only its latest page.
/// Network activity never blocks the reader's page-change callback.
Future<void> updatePagenum(String id, int pageIndex) {
  // Observe page changes before any async SharedPreferences or HTTP work.
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
  static const _storageKey = 'jellybook.pendingPageProgress.v1';
  static const _requestTimeout = Duration(seconds: 12);
  final Map<String, int> _pending = <String, int>{};
  final Map<String, int> _localChangeRevisions = <String, int>{};
  int _revision = 0;
  int get revision => _revision;

  void noteLocalPageChange(String id) {
    if (id.isNotEmpty) _localChangeRevisions[id] = ++_revision;
  }

  Future<Set<String>> protectedItemIds(int sinceRevision) async {
    // Wait for currently queued SharedPreferences mutations, so offline pages
    // persisted moments ago are visible to the library importer.
    await _mutations;
    final prefs = await SharedPreferences.getInstance();
    _load(prefs);
    final server =
        (prefs.getString('server') ?? '').replaceFirst(RegExp(r'/+$'), '');
    final userId = prefs.getString('UserId') ?? '';
    final protected = <String>{
      for (final entry in _localChangeRevisions.entries)
        if (entry.value > sinceRevision) entry.key,
    };
    for (final key in _pending.keys) {
      try {
        final parts = (jsonDecode(key) as List).cast<String>();
        if (parts.length == 3 && parts[0] == server && parts[1] == userId) {
          protected.add(parts[2]);
        }
      } catch (_) {
        // Malformed legacy queue entries cannot authorize a server restore.
      }
    }
    return protected;
  }

  Future<void> _mutations = Future<void>.value();
  bool _loaded = false;
  bool _sending = false;

  // Serialize preference writes, so a slower earlier write cannot overwrite
  // a later page index or a successful upload acknowledgement.
  Future<void> _mutate(Future<void> Function() action) {
    final operation = _mutations.then((_) => action());
    _mutations = operation.then<void>((_) {}, onError: (Object e, StackTrace st) {
      logger.e('Progress queue storage error: $e');
    });
    return operation;
  }

  void _load(SharedPreferences prefs) {
    if (_loaded) return;
    _loaded = true;
    final encoded = prefs.getString(_storageKey);
    if (encoded == null) return;
    try {
      final decoded = jsonDecode(encoded);
      if (decoded is! Map<String, dynamic>) return;
      for (final entry in decoded.entries) {
        if (entry.value is int && entry.value >= 0) {
          _pending[entry.key] = entry.value as int;
        }
      }
    } catch (e) {
      logger.w('Ignoring invalid saved progress queue: $e');
    }
  }

  Future<void> _persist(SharedPreferences prefs) async {
    if (!await prefs.setString(_storageKey, jsonEncode(_pending))) {
      throw StateError('Could not persist pending Jellyfin progress');
    }
  }

  Future<void> enqueue(String id, int pageIndex) => _mutate(() async {
        final prefs = await SharedPreferences.getInstance();
        _load(prefs);
        final server =
            (prefs.getString('server') ?? '').replaceFirst(RegExp(r'/+$'), '');
        final userId = prefs.getString('UserId') ?? '';
        if (server.isEmpty || userId.isEmpty || id.isEmpty || pageIndex < 0) {
          logger.w('Progress not queued: missing account/item or invalid page');
          return;
        }
        // Never sync an old account's saved progress to a new account.
        _pending[jsonEncode(<String>[server, userId, id])] = pageIndex;
        await _persist(prefs);
        _start();
      });

  Future<void> retry() => _mutate(() async {
        _load(await SharedPreferences.getInstance());
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
        final prefs = await SharedPreferences.getInstance();
        final server =
            (prefs.getString('server') ?? '').replaceFirst(RegExp(r'/+$'), '');
        final userId = prefs.getString('UserId') ?? '';
        final token = prefs.getString('accessToken') ?? '';
        if (server.isEmpty || userId.isEmpty || token.isEmpty) return;

        MapEntry<String, int>? next;
        String? itemId;
        for (final entry in _pending.entries) {
          try {
            final parts = (jsonDecode(entry.key) as List).cast<String>();
            if (parts.length == 3 &&
                parts[0] == server && parts[1] == userId) {
              next = entry;
              itemId = parts[2];
              break;
            }
          } catch (_) {
            // Ignore an invalid or obsolete key rather than misroute it.
          }
        }
        if (next == null || itemId == null) return;
        final key = next.key;
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
            await _persist(prefs);
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
      'Authorization': 'MediaBrowser Client="JellyBook", '
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
