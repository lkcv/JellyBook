import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:isar/isar.dart';
import 'package:kurage/cache/reader_page_cache.dart';
import 'package:kurage/models/entry.dart';
import 'package:kurage/providers/cbz_stream.dart';
import 'package:kurage/providers/comic_info_xml.dart';
import 'package:kurage/providers/file_name_from_title.dart';
import 'package:kurage/providers/download_exceptions.dart';
import 'package:kurage/providers/supported_formats.dart';
import 'package:kurage/variables.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

typedef ProgressCallback = void Function(double progress);

Future<Directory> _stagingDirectory(Entry entry) async {
  final root = await getApplicationDocumentsDirectory();
  final folderName = await fileNameFromTitle(entry.title);
  return Directory('${root.path}/$folderName.pages.part');
}

Future<double> retainedPageDownloadProgress(Entry entry) async {
  final staging = await _stagingDirectory(entry);
  final manifest = File('${staging.path}/.kurage-part.json');
  if (!await manifest.exists()) return 0;
  try {
    final saved = jsonDecode(await manifest.readAsString());
    if (saved is! Map || saved['itemId'] != entry.id) return 0;
    final count = saved['pageCount'];
    if (count is! int || count <= 0) return 0;
    final savedSizes = saved['pageSizes'];
    final sizes = savedSizes is List && savedSizes.length == count &&
            savedSizes.every((size) => size is int && size >= 0)
        ? savedSizes.cast<int>()
        : <int>[];
    final totalBytes = sizes.fold<int>(0, (sum, size) => sum + size);
    final completed = <int>{};
    final pageFile = RegExp(r'^(\d{6,})\.(jpg|jpeg|png|gif|webp|bmp|tiff)$',
        caseSensitive: false);
    await for (final item in staging.list()) {
      if (item is! File) continue;
      final match = pageFile.firstMatch(item.uri.pathSegments.last);
      if (match == null) continue;
      final index = int.parse(match.group(1)!) - 1;
      if (index < 0 || index >= count || completed.contains(index)) continue;
      if (totalBytes > 0 && await item.length() != sizes[index]) continue;
      completed.add(index);
    }
    final fraction = totalBytes > 0
        ? completed.fold<int>(0, (sum, index) => sum + sizes[index]) / totalBytes
        : completed.length / count;
    return (fraction * 100).clamp(0.0, 99.0).toDouble();
  } catch (_) {
    return 0;
  }
}

Future<void> discardPageDownload(Entry entry) async {
  final staging = await _stagingDirectory(entry);
  if (await staging.exists()) await staging.delete(recursive: true);
  final root = await getApplicationDocumentsDirectory();
  final archiveName = await fileNameFromTitle(entry.path.split('/').last);
  final archive = '${root.path}/$archiveName';
  for (final path in [archive, '$archive.part', '$archive.part.json']) {
    final file = File(path);
    if (await file.exists()) await file.delete();
  }
}

Future<Entry> downloadEntry(
  Entry entry, {
  required ProgressCallback onProgress,
  bool forceDownload = false,
  CancelToken? cancelToken,
}) async {
  checkDownloadCanceled(cancelToken);
  if (!isSupportedEntry(entry)) {
    throw UnsupportedError('Unsupported file format: ${entry.path}');
  }
  final isar = Isar.getInstance();
  if (isar == null) throw StateError('Isar not initialized');
  if (entry.downloaded && entry.folderPath.isNotEmpty && !forceDownload &&
      await Directory(entry.folderPath).exists()) {
    onProgress(100);
    return entry;
  }

  final originalDownloaded = entry.downloaded;
  final originalFolderPath = entry.folderPath;
  final originalFilePath = entry.filePath;
  final root = await getApplicationDocumentsDirectory();
  final folderName = await fileNameFromTitle(entry.title);
  final finalDirectory = Directory('${root.path}/$folderName');
  final staging = await _stagingDirectory(entry);
  final backup = Directory('${finalDirectory.path}.previous');
  if (await backup.exists() && !await finalDirectory.exists()) {
    await backup.rename(finalDirectory.path);
  }
  final prefs = await SharedPreferences.getInstance();
  final server = prefs.getString('server') ?? entry.url;
  final token = prefs.getString('accessToken') ?? '';
  final client = prefs.getString('client') ?? 'JellyBook';
  final device = prefs.getString('device') ?? '';
  final deviceId = prefs.getString('deviceId') ?? '';
  final version = prefs.getString('version') ?? '';
  final headers = <String, String>{
    'Authorization': 'MediaBrowser Client="$client", Device="$device", '
        'DeviceId="$deviceId", Version="$version", Token="$token"',
  };
  final stream = CbzStream(
    url: server,
    itemId: entry.id,
    headers: headers,
    pageDirectory: staging,
    cancelToken: cancelToken,
  );
  var published = false;
  var committed = false;

  try {
    await stream.init();
    checkDownloadCanceled(cancelToken);
    final count = stream.pageCount;
    final pageSizes = List<int>.generate(count, stream.pageSize);
    final totalBytes = pageSizes.fold<int>(0, (sum, size) => sum + size);
    final manifest = File('${staging.path}/.kurage-part.json');
    final identity = <String, Object>{
      'itemId': entry.id,
      'pageCount': count,
      'fingerprint': stream.fingerprint,
    };
    final completedMarker = File('${finalDirectory.path}/.kurage-complete.json');
    if (!originalDownloaded && await completedMarker.exists()) {
      try {
        final saved = jsonDecode(await completedMarker.readAsString());
        if (saved is Map && saved['itemId'] == entry.id &&
            saved['pageCount'] == count &&
            saved['fingerprint'] == stream.fingerprint) {
          var valid = true;
          for (var index = 0; index < count; index++) {
            final file = File('${finalDirectory.path}/'
                '${stream.pageFile(index).uri.pathSegments.last}');
            if (!await stream.isPageValid(index, file)) {
              valid = false;
              break;
            }
          }
          if (valid) {
            checkDownloadCanceled(cancelToken);
            entry.folderPath = finalDirectory.path;
            entry.filePath = finalDirectory.path;
            entry.downloaded = true;
            await isar.writeTxn(() async => isar.entrys.put(entry));
            committed = true;
            onProgress(100);
            if (await staging.exists()) await staging.delete(recursive: true);
            return entry;
          }
        }
      } on FileSystemException {
        // Recovery falls through to the staged page download.
      } on FormatException {
        // Recovery falls through to the staged page download.
      }
    }
    var reuse = false;
    if (await manifest.exists()) {
      try {
        final saved = jsonDecode(await manifest.readAsString());
        reuse = saved is Map && saved['itemId'] == entry.id &&
            saved['pageCount'] == count &&
            saved['fingerprint'] == stream.fingerprint;
      } catch (_) {}
    }
    if (!reuse && await staging.exists()) {
      await staging.delete(recursive: true);
    }
    await staging.create(recursive: true);
    await manifest.writeAsString(
        jsonEncode({...identity, 'pageSizes': pageSizes}), flush: true);

    final completed = <int>{};
    var completedBytes = 0;
    for (var index = 0; index < count; index++) {
      checkDownloadCanceled(cancelToken);
      final file = stream.pageFile(index);
      if (await stream.isPageValid(index, file)) {
        completed.add(index);
        completedBytes += pageSizes[index];
      } else if (await file.exists()) {
        await file.delete();
      }
    }

    final cachedPages = await ReaderPageCache.snapshotPages(entry.id);
    final candidates = <int, File>{};
    var pendingCachedBytes = 0;
    for (final candidate in cachedPages.entries) {
      checkDownloadCanceled(cancelToken);
      final index = candidate.key;
      if (index >= count || completed.contains(index)) continue;
      try {
        if (await candidate.value.length() != pageSizes[index]) continue;
        candidates[index] = candidate.value;
        pendingCachedBytes += pageSizes[index];
      } on FileSystemException {
        // The cache can be evicted while the downloader takes its snapshot.
      }
    }
    var pendingCachedCount = candidates.length;
    void report() {
      final fraction = totalBytes > 0
          ? (completedBytes + pendingCachedBytes) / totalBytes
          : (completed.length + pendingCachedCount) / count;
      onProgress((fraction * 100).clamp(0.0, 99.0).toDouble());
    }
    report();

    Future<void> copyCachedPages() async {
      for (final candidate in candidates.entries) {
        checkDownloadCanceled(cancelToken);
        final index = candidate.key;
        final target = stream.pageFile(index);
        final temporary = File('${target.path}.tmp');
        var copied = false;
        try {
          await candidate.value.copy(temporary.path);
          if (!await stream.isPageValid(index, temporary)) continue;
          checkDownloadCanceled(cancelToken);
          await temporary.rename(target.path);
          completed.add(index);
          completedBytes += pageSizes[index];
          copied = true;
        } on FileSystemException {
          // Cache eviction can race a copy; the network path will fill the gap.
        } finally {
          pendingCachedBytes -= pageSizes[index];
          pendingCachedCount--;
          if (!copied) report();
          if (await temporary.exists()) await temporary.delete();
        }
      }
    }

    Future<void> downloadPages(Iterable<int> indices) async {
      for (final index in indices) {
        checkDownloadCanceled(cancelToken);
        await stream.getPage(index);
        completed.add(index);
        completedBytes += pageSizes[index];
        report();
      }
    }

    final missing = [
      for (var index = 0; index < count; index++)
        if (!completed.contains(index) && !candidates.containsKey(index)) index,
    ];
    await Future.wait([downloadPages(missing), copyCachedPages()]);
    await downloadPages([
      for (var index = 0; index < count; index++)
        if (!completed.contains(index)) index,
    ]);
    checkDownloadCanceled(cancelToken);

    final names = [
      for (var index = 0; index < count; index++) stream.pageName(index) ?? ''
    ];
    await File('${staging.path}/.kurage-page-names.json')
        .writeAsString(jsonEncode(names), flush: true);
    await stream.getComicInfo(File('${staging.path}/ComicInfo.xml'));
    await File('${staging.path}/.kurage-complete.json')
        .writeAsString(jsonEncode(identity), flush: true);
    if (await manifest.exists()) await manifest.delete();
    checkDownloadCanceled(cancelToken);

    if (originalDownloaded && await finalDirectory.exists()) {
      if (await backup.exists()) await backup.delete(recursive: true);
      await finalDirectory.rename(backup.path);
    } else if (await finalDirectory.exists()) {
      await finalDirectory.delete(recursive: true);
    }
    await staging.rename(finalDirectory.path);
    published = true;
    entry.folderPath = finalDirectory.path;
    entry.filePath = finalDirectory.path;
    entry.downloaded = true;
    checkDownloadCanceled(cancelToken);
    await isar.writeTxn(() async => isar.entrys.put(entry));
    committed = true;
    onProgress(100);
    if (await File('${finalDirectory.path}/ComicInfo.xml').exists()) {
      try {
        await parseXML(entry);
      } catch (error) {
        logger.w('Could not read ComicInfo.xml for ${entry.id}: $error');
      }
    }
    try {
      if (await backup.exists()) await backup.delete(recursive: true);
    } catch (error) {
      logger.w('Could not remove replaced download: $error');
    }
    try {
      final archiveName = await fileNameFromTitle(entry.path.split('/').last);
      final archive = '${root.path}/$archiveName';
      for (final path in [archive, '$archive.part', '$archive.part.json']) {
        final old = File(path);
        if (await old.exists()) await old.delete();
      }
    } catch (error) {
      logger.w('Could not remove old archive download: $error');
    }
    return entry;
  } catch (error) {
    if (published && !committed) {
      if (await staging.exists()) await staging.delete(recursive: true);
      await finalDirectory.rename(staging.path);
      if (await backup.exists()) await backup.rename(finalDirectory.path);
    }
    if (!committed) {
      entry.downloaded = originalDownloaded;
      entry.folderPath = originalFolderPath;
      entry.filePath = originalFilePath;
    }
    if (cancelToken?.isCancelled ?? false) {
      await discardPageDownload(entry);
      throw const DownloadCanceled();
    }
    rethrow;
  }
}
