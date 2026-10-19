import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:isar/isar.dart';
import 'package:jellybook/cache/readerPageCache.dart';
import 'package:jellybook/models/entry.dart';
import 'package:jellybook/providers/cbzStream.dart';
import 'package:jellybook/providers/ComicInfoXML.dart';
import 'package:jellybook/providers/fileNameFromTitle.dart';
import 'package:jellybook/providers/downloadExceptions.dart';
import 'package:jellybook/providers/supportedFormats.dart';
import 'package:jellybook/variables.dart';
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
    final files = await staging.list().where((item) =>
        item is File && RegExp(r'/\d{6,}\.(jpg|jpeg|png|gif|webp|bmp|tiff)$',
            caseSensitive: false).hasMatch(item.path.replaceAll('\\', '/'))).length;
    return (files / count * 100).clamp(0.0, 99.0).toDouble();
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
    await manifest.writeAsString(jsonEncode(identity), flush: true);

    final completed = <int>{};
    for (var index = 0; index < count; index++) {
      checkDownloadCanceled(cancelToken);
      final file = stream.pageFile(index);
      if (await stream.isPageValid(index, file)) {
        completed.add(index);
      } else if (await file.exists()) {
        await file.delete();
      }
    }
    void report() {
      onProgress(completed.length == count
          ? 99
          : completed.length / count * 100);
    }
    report();

    for (var index = 0; index < count; index++) {
      if (completed.contains(index)) continue;
      checkDownloadCanceled(cancelToken);
      final cached = await ReaderPageCache.getPage(entry.id, index);
      if (cached == null) continue;
      final target = stream.pageFile(index);
      final temporary = File('${target.path}.tmp');
      try {
        await cached.copy(temporary.path);
        if (!await stream.isPageValid(index, temporary)) continue;
        checkDownloadCanceled(cancelToken);
        await temporary.rename(target.path);
        completed.add(index);
        report();
      } on FileSystemException {
        // Cache eviction can race a copy; the network path will fill the gap.
      } finally {
        if (await temporary.exists()) await temporary.delete();
      }
    }

    for (var index = 0; index < count; index++) {
      if (completed.contains(index)) continue;
      checkDownloadCanceled(cancelToken);
      await stream.getPage(index);
      completed.add(index);
      report();
    }
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
