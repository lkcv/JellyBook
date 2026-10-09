import 'dart:convert';
import 'dart:io';

import 'package:jellybook/variables.dart';
import 'package:path_provider/path_provider.dart';

class _ReaderPosition {
  final int count;
  final int page;
  final int timestamp;

  const _ReaderPosition(this.count, this.page, this.timestamp);
}

/// Durable snapshots of the pages most recently viewed in a comic.
///
/// This cache lives outside Entry.folderPath, so deleting a downloaded volume
/// does not delete the reader's recovery copy. It keeps up to seven pages for
/// each of the two most recently used volumes; it is not a full download.
class ReaderPageCache {
  static const int _maxVolumes = 2;
  static const int _maxPagesPerVolume = 7;
  static Future<void> _writeQueue = Future<void>.value();
  // Updated synchronously on navigation, not when a background fetch finishes.
  static final Map<String, _ReaderPosition> _positions = {};
  static const Set<String> _imageExtensions = {
    'jpg',
    'jpeg',
    'png',
    'gif',
    'webp',
    'bmp',
    'tiff',
  };

  static Future<Directory> _root() async {
    final support = await getApplicationSupportDirectory();
    final root = Directory('${support.path}/jellybook_reader_cache');
    await root.create(recursive: true);
    return root;
  }

  static String _key(String volumeId) => Uri.encodeComponent(volumeId);

  static Future<Map<String, dynamic>> _readManifest(
    Directory directory,
  ) async {
    final file = File('${directory.path}/manifest.json');
    try {
      if (!await file.exists()) return <String, dynamic>{};
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is Map) return Map<String, dynamic>.from(decoded);
    } catch (error) {
      logger.w('ReaderPageCache: invalid manifest in ${directory.path}: $error');
    }
    return <String, dynamic>{};
  }

  static Future<int?> getPageCount(String volumeId) async {
    final root = await _root();
    final directory = Directory('${root.path}/${_key(volumeId)}');
    if (!await directory.exists()) return null;
    final count = (await _readManifest(directory))['pageCount'];
    return count is num && count > 0 ? count.toInt() : null;
  }

  static Future<int?> getCurrentPage(String volumeId) async {
    final root = await _root();
    final directory = Directory('${root.path}/${_key(volumeId)}');
    if (!await directory.exists()) return null;
    final current = (await _readManifest(directory))['currentPage'];
    return current is num ? current.toInt() : null;
  }

  static Future<File?> getPage(String volumeId, int pageIndex) async {
    if (pageIndex < 0) return null;
    final root = await _root();
    final directory = Directory('${root.path}/${_key(volumeId)}');
    if (!await directory.exists()) return null;
    final manifest = await _readManifest(directory);
    final rawPages = manifest['pages'];
    if (rawPages is! Map) return null;
    final filename = rawPages['$pageIndex'];
    if (filename is! String || filename.isEmpty) return null;
    // Only accept a filename, never a path read from the manifest.
    if (filename.contains('/') || filename.contains(Platform.pathSeparator)) {
      return null;
    }
    final file = File('${directory.path}/$filename');
    return await file.exists() ? file : null;
  }

  /// Record a page turn immediately, even if the network fetch has not
  /// finished. The serialized disk update also persists the last page.
  static Future<void> touch({
    required String volumeId,
    required int pageCount,
    required int currentPage,
  }) => saveWindow(
        volumeId: volumeId,
        pageCount: pageCount,
        currentPage: currentPage,
        lastUsed: DateTime.now().millisecondsSinceEpoch,
        sourceFiles: const <int, File>{},
      );

  /// Save one or more page files. The saved position is always the latest
  /// requested position, regardless of which prefetch completed last.
  /// A shared queue prevents manifest and file races between readers.
  static Future<void> saveWindow({
    required String volumeId,
    required int pageCount,
    required int currentPage,
    required int lastUsed,
    required Map<int, File> sourceFiles,
    bool updatePosition = true,
  }) {
    if (pageCount <= 0) return Future<void>.value();
    final existing = _positions[volumeId];
    if (existing == null || (updatePosition && lastUsed >= existing.timestamp)) {
      _positions[volumeId] = _ReaderPosition(
        pageCount,
        currentPage.clamp(0, pageCount - 1).toInt(),
        lastUsed,
      );
    }
    final queued = _writeQueue
        .catchError((Object _) {})
        .then((_) {
          final position = _positions[volumeId]!;
          return _saveWindow(
            volumeId: volumeId,
            pageCount: position.count,
            currentPage: position.page,
            lastUsed: position.timestamp,
            sourceFiles: sourceFiles,
          );
        });
    _writeQueue = queued;
    return queued;
  }

  static Future<void> _saveWindow({
    required String volumeId,
    required int pageCount,
    required int currentPage,
    required int lastUsed,
    required Map<int, File> sourceFiles,
  }) async {
    if (pageCount <= 0) return;

    final safeCurrent = currentPage.clamp(0, pageCount - 1).toInt();
    final root = await _root();
    final directory = Directory('${root.path}/${_key(volumeId)}');
    await directory.create(recursive: true);

    final manifestFile = File('${directory.path}/manifest.json');
    final oldManifest = await _readManifest(directory);
    final rawPages = oldManifest['pages'];
    final pages = rawPages is Map
        ? <String, String>{
            for (final entry in rawPages.entries)
              if (entry.key is String &&
                  entry.value is String &&
                  !(entry.value as String).contains('/') &&
                  !(entry.value as String).contains(Platform.pathSeparator))
                entry.key as String: entry.value as String,
          }
        : <String, String>{};
    final obsoleteFiles = <String>{};

    for (final entry in sourceFiles.entries) {
      final index = entry.key;
      final source = entry.value;
      if (index < 0 || index >= pageCount ||
          (index - safeCurrent).abs() > 3) {
        continue;
      }
      try {
        if (!await source.exists()) continue;
        var extension = source.path.split('.').last.toLowerCase();
        if (!_imageExtensions.contains(extension)) extension = 'img';
        final filename = 'page_$index.$extension';
        final target = File('${directory.path}/$filename');
        final previousName = pages['$index'];

        if (source.absolute.path != target.absolute.path) {
          // Copy to a sibling first so an interrupted copy does not truncate
          // the old cached page that the current manifest still references.
          final temporary = File('${target.path}.tmp');
          if (await temporary.exists()) await temporary.delete();
          await source.copy(temporary.path);
          try {
            await temporary.rename(target.path);
          } on FileSystemException {
            // Some platforms don't replace existing files during rename.
            if (!await target.exists()) rethrow;
            final backup = File('${target.path}.backup');
            if (await backup.exists()) await backup.delete();
            await target.rename(backup.path);
            try {
              await temporary.rename(target.path);
              obsoleteFiles.add(backup.path);
            } catch (_) {
              if (!await target.exists() && await backup.exists()) {
                await backup.rename(target.path);
              }
              rethrow;
            }
          }
        }
        pages['$index'] = filename;
        if (previousName != null && previousName != filename) {
          obsoleteFiles.add('${directory.path}/$previousName');
        }
      } catch (error) {
        logger.w('ReaderPageCache: could not save page $index: $error');
      }
    }

    // Count only files that made it safely to disk.
    final validIndices = <int>[];
    for (final entry in pages.entries) {
      final index = int.tryParse(entry.key);
      if (index == null || (index - safeCurrent).abs() > 3) continue;
      if (await File('${directory.path}/${entry.value}').exists()) {
        validIndices.add(index);
      }
    }
    validIndices.sort((a, b) {
      final distance =
          (a - safeCurrent).abs().compareTo((b - safeCurrent).abs());
      return distance != 0 ? distance : a.compareTo(b);
    });
    final keep = validIndices.take(_maxPagesPerVolume).toSet();
    for (final entry in pages.entries.toList()) {
      final index = int.tryParse(entry.key);
      if (index != null && keep.contains(index)) continue;
      obsoleteFiles.add('${directory.path}/${entry.value}');
      pages.remove(entry.key);
    }

    // If the new page has not arrived yet, reopen at the closest retained
    // page; saving the displayed page below updates this immediately.
    final cachedIndices = pages.keys.map(int.tryParse).whereType<int>().toList();
    final persistedCurrent = pages.containsKey('$safeCurrent')
        ? safeCurrent
        : (cachedIndices.isEmpty
            ? safeCurrent
            : (cachedIndices..sort((a, b) {
                final distance = (a - safeCurrent)
                    .abs()
                    .compareTo((b - safeCurrent).abs());
                return distance != 0 ? distance : a.compareTo(b);
              })).first);

    final previousLastUsed = oldManifest['lastUsed'];
    final previousLastUsedMs =
        previousLastUsed is num ? previousLastUsed.toInt() : 0;
    final effectiveLastUsed =
        previousLastUsedMs > lastUsed ? previousLastUsedMs : lastUsed;
    final updatedManifest = <String, dynamic>{
      'pageCount': pageCount,
      'currentPage': persistedCurrent,
      'lastUsed': effectiveLastUsed,
      'pages': pages,
    };
    final temporaryManifest = File('${directory.path}/manifest.json.tmp');
    await temporaryManifest.writeAsString(jsonEncode(updatedManifest), flush: true);
    try {
      await temporaryManifest.rename(manifestFile.path);
    } on FileSystemException {
      if (await manifestFile.exists()) await manifestFile.delete();
      await temporaryManifest.rename(manifestFile.path);
    }

    // Commit the manifest before deleting anything it might reference. A
    // crash during cleanup therefore leaves a usable recovery snapshot.
    final trackedFiles = pages.values.toSet();
    await for (final entity in directory.list(followLinks: false)) {
      if (entity is! File) continue;
      final name = entity.path.split(Platform.pathSeparator).last;
      if ((name.startsWith('page_') || name.endsWith('.backup')) &&
          !trackedFiles.contains(name)) {
        obsoleteFiles.add(entity.path);
      }
    }
    for (final path in obsoleteFiles) {
      final name = path.split(Platform.pathSeparator).last;
      if (trackedFiles.contains(name)) continue;
      try {
        final file = File(path);
        if (await file.exists()) await file.delete();
      } catch (_) {
        // Orphans are harmless and can be cleaned on the next write.
      }
    }

    await _pruneOtherVolumes(root);
  }

  static Future<void> _pruneOtherVolumes(Directory root) async {
    final volumes = <MapEntry<Directory, int>>[];
    await for (final entity in root.list(followLinks: false)) {
      if (entity is! Directory) continue;
      final manifest = await _readManifest(entity);
      if (manifest.isEmpty || manifest['pages'] is! Map ||
          (manifest['pages'] as Map).isEmpty) continue;
      final rawLastUsed = manifest['lastUsed'];
      final lastUsed = rawLastUsed is num ? rawLastUsed.toInt() : 0;
      volumes.add(MapEntry(entity, lastUsed));
    }
    volumes.sort((a, b) => b.value.compareTo(a.value));

    // Keep the two most recently touched volumes, not simply whichever async
    // cache write happened to finish last.
    for (final stale in volumes.skip(_maxVolumes)) {
      try {
        if (await stale.key.exists()) await stale.key.delete(recursive: true);
      } catch (error) {
        logger.w('ReaderPageCache: could not prune ${stale.key.path}: $error');
      }
    }
  }
}
