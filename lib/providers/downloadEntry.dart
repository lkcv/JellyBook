import 'dart:io';
import 'dart:isolate';
import 'package:dio/dio.dart';
import 'package:archive/archive_io.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:isar/isar.dart';
import 'package:jellybook/models/entry.dart';
import 'package:jellybook/providers/supportedFormats.dart';
import 'package:jellybook/providers/fileNameFromTitle.dart';
import 'package:jellybook/providers/ComicInfoXML.dart';
import 'package:jellybook/variables.dart';
import 'package:jellybook/providers/resumableTransfer.dart';

typedef ProgressCallback = void Function(double progress);

/// Download and extract an entry. Calls onProgress with 0–100 as it progresses.
Future<Entry> downloadEntry(
  Entry entry, {
  required ProgressCallback onProgress,
  bool forceDownload = false,
  CancelToken? cancelToken,
}) async {
  checkDownloadCanceled(cancelToken);
  final originalDownloaded = entry.downloaded;
  final originalFolderPath = entry.folderPath;
  final originalFilePath = entry.filePath;
  // Reject before writing to disk or issuing a download request.
  if (!isSupportedEntry(entry)) {
    throw UnsupportedError('Unsupported file format: ${entry.path}');
  }

  final storage = await SharedPreferences.getInstance();
  final isar = Isar.getInstance();
  if (isar == null) throw Exception('Isar not initialized');

  // Check if already downloaded
  if (entry.folderPath.isNotEmpty && entry.downloaded && !forceDownload) {
    onProgress(100);
    return entry;
  }

  // Prepare directory
  String dirLocation = (await getApplicationDocumentsDirectory()).path;
  await Directory(dirLocation).create(recursive: true);

  String fileName = await fileNameFromTitle(entry.path.split('/').last);
  String dir = '$dirLocation/$fileName';
  entry.filePath = dir;

  logger.d('Downloading: ${entry.title} to $dir');

  // Stream the archive into a persisted .part file, rather than buffering an
  // entire volume in memory. Range requests resume existing bytes.
  final headers = _getHeaders(entry, storage);
  var extractionStarted = false;
  var databaseCommitted = false;
  try {
    checkDownloadCanceled(cancelToken);
    final base = Uri.parse(entry.url);
    final prefix = base.path.endsWith('/') ? base.path : '${base.path}/';
    final uri = base.replace(path: '${prefix}Items/${Uri.encodeComponent(entry.id)}/Download');
    await downloadResumableArchive(
      url: uri,
      headers: headers,
      destination: File(dir),
      onProgress: onProgress,
      cancelToken: cancelToken,
    );
    checkDownloadCanceled(cancelToken);
    onProgress(92);

    extractionStarted = true;
    await _extractFile(entry, dirLocation, fileName, dir);
    checkDownloadCanceled(cancelToken);
    onProgress(100);

    // Update the entry (do not reset reading progress)
    entry.downloaded = true;
    checkDownloadCanceled(cancelToken);
    await isar.writeTxn(() async {
      await isar.entrys.put(entry);
    });
    databaseCommitted = true;
    checkDownloadCanceled(cancelToken);

    // Retain the complete archive through extraction and the final Isar commit.
    // After a crash during extraction, startup can safely try again.
    final archive = File(dir);
    if (await archive.exists()) await archive.delete();
    // Cancellation can arrive during the final asynchronous file operation.
    checkDownloadCanceled(cancelToken);
    logger.d('Download complete: ${entry.title}');
    return entry;
  } catch (e) {
    if (cancelToken?.isCancelled ?? false) {
      // Do not leave an archive or half-extracted book behind. The extraction
      // isolate has finished before this cleanup runs, so files aren't deleted
      // while it still writes to them.
      entry.downloaded = originalDownloaded;
      entry.folderPath = originalFolderPath;
      entry.filePath = originalFilePath;
      if (databaseCommitted) {
        await isar.writeTxn(() async => isar.entrys.put(entry));
      }
      if (extractionStarted && !originalDownloaded) {
        final folderName = await fileNameFromTitle(entry.title);
        final folder = Directory('$dirLocation/$folderName');
        if (await folder.exists()) await folder.delete(recursive: true);
      }
      for (final path in [dir, '$dir.part', '$dir.part.json']) {
        final file = File(path);
        if (await file.exists()) await file.delete();
      }
      throw const DownloadCanceled();
    }
    logger.e('Download failed: $e');
    rethrow;
  }
}

Future<void> _extractFile(
  Entry entry,
  String dirLocation,
  String fileName,
  String dir,
) async {
  final isar = Isar.getInstance();
  if (isar == null) return;

  final folderName = await fileNameFromTitle(entry.title);
  String comicFolder = '$dirLocation/$folderName';
  await Directory(comicFolder).create(recursive: true);

  try {
    if (dir.contains('.zip') || dir.contains('.cbz')) {
      // Clear any files left by a previous interrupted extraction.
      if (await Directory(comicFolder).exists()) {
        await Directory(comicFolder).delete(recursive: true);
      }
      await Directory(comicFolder).create(recursive: true);
      // Stream entries to disk on a background isolate. Avoids decodeBytes()
      // which keeps the entire archive in RAM and starves the reader.
      await _extractZipOffUi(dir, comicFolder);
      entry.downloaded = true;
      entry.folderPath = comicFolder;
    } else if (dir.contains('.epub')) {
      var file = File('$dirLocation/$fileName');
      await Directory(comicFolder).create(recursive: true);
      file.renameSync('$comicFolder/$fileName');
      entry.folderPath = comicFolder;
      entry.filePath = '$comicFolder/$fileName';
      entry.downloaded = true;
    } else if (_isAudioFile(dir)) {
      var file = File('$dirLocation/$fileName');
      await Directory(comicFolder).create(recursive: true);
      file.renameSync('$comicFolder/$fileName');
      entry.folderPath = comicFolder;
      entry.filePath = '$comicFolder/$fileName';
      entry.downloaded = true;
    }

    // The caller performs the single durable Isar update after checking
    // cancellation. Committing here could resurrect a canceled download.
    parseXML(entry);
  } catch (e) {
    logger.e('Extract failed: $e');
    rethrow;
  }
}

/// Stream-unzip a CBZ/ZIP on a background isolate.
/// Uses file streams so pages are written one at a time instead of holding
/// the full decompressed archive in memory (which caused UI jank ~95%).
Future<void> _extractZipOffUi(String archivePath, String destFolder) async {
  await Isolate.run(() {
    final input = InputFileStream(archivePath);
    try {
      final archive = ZipDecoder().decodeBuffer(input);
      for (final file in archive) {
        if (!file.isFile) continue;
        final name = file.name.replaceAll('\\', '/');
        if (name.isEmpty || name.endsWith('/')) continue;
        if (name.split('/').contains('..')) continue;
        final outPath = '$destFolder/$name';
        // Keep writes inside the destination folder
        final destCanon = Directory(destFolder).absolute.path;
        final outCanon = File(outPath).absolute.path;
        if (!outCanon.startsWith(destCanon)) continue;

        File(outPath).parent.createSync(recursive: true);
        final output = OutputFileStream(outPath);
        try {
          file.writeContent(output);
        } finally {
          output.close();
        }
        // Free this entry's decompressed bytes before the next one
        file.clear();
      }
    } finally {
      input.close();
    }
  });
}

bool _isAudioFile(String path) {
  final audioExts = [
    '.flac',
    '.mpga',
    '.mp3',
    '.m3u',
    '.m3u8',
    '.m4a',
    '.m4b',
    '.wav'
  ];
  return audioExts.any(path.toLowerCase().endsWith);
}

Map<String, String> _getHeaders(Entry entry, SharedPreferences prefs) {
  String client = prefs.getString('client') ?? 'JellyBook';
  String token = prefs.getString('accessToken') ?? '';
  String device = prefs.getString('device') ?? '';
  String deviceId = prefs.getString('deviceId') ?? '';
  String version = prefs.getString('version') ?? '';

  return {
    'Accept':
        'text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,*/*;q=0.8',
    'Accept-Encoding': 'gzip, deflate',
    'Accept-Language': 'en-US,en;q=0.5',
    'Connection': 'keep-alive',
    'Upgrade-Insecure-Requests': '1',
    'Authorization':
        'MediaBrowser Client="$client", Device="$device", DeviceId="$deviceId", Version="$version", Token="$token"',
  };
}
