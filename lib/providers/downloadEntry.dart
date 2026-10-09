import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';
import 'package:dio/dio.dart';
import 'package:archive/archive_io.dart';
import 'package:unrar_file/unrar_file.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:isar/isar.dart';
import 'package:jellybook/models/entry.dart';
import 'package:jellybook/providers/fileNameFromTitle.dart';
import 'package:jellybook/providers/ComicInfoXML.dart';
import 'package:jellybook/variables.dart';
import 'package:sentry_flutter/sentry_flutter.dart';
import 'package:tentacle/tentacle.dart';

typedef ProgressCallback = void Function(double progress);

/// Download and extract an entry. Calls onProgress with 0–100 as it progresses.
Future<Entry> downloadEntry(
  Entry entry, {
  required ProgressCallback onProgress,
  bool forceDownload = false,
}) async {
  final storage = await SharedPreferences.getInstance();
  final isar = Isar.getInstance();
  if (isar == null) throw Exception('Isar not initialized');

  onProgress(0);

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

  // Fetch the file
  final api = _getTentacleApi(entry);
  final headers = _getHeaders(entry, storage);

  try {
    Response<Uint8List> download = await api
        .getDownload(
          itemId: entry.id,
          headers: headers,
          onReceiveProgress: (received, total) {
            if (total > 0) {
              onProgress((received / total) * 90); // 0-90% for download
            }
          },
        )
        .timeout(const Duration(minutes: 30));

    if (download.statusCode != 200) {
      throw Exception('Download failed with ${download.statusCode}');
    }

    // Write archive to disk, then drop the in-memory copy before extract so
    // peak RAM is not (download buffer + full decoded zip) at the same time.
    final bytes = download.data;
    if (bytes == null || bytes.isEmpty) {
      throw Exception('Download returned empty body');
    }
    await File(dir).writeAsBytes(bytes, flush: true);
    onProgress(92);

    await _extractFile(entry, dirLocation, fileName, dir);
    onProgress(100);

    // Update the entry (do not reset reading progress)
    entry.downloaded = true;
    await isar.writeTxn(() async {
      await isar.entrys.put(entry);
    });

    logger.d('Download complete: ${entry.title}');
    return entry;
  } catch (e, s) {
    logger.e('Download failed: $e');
    bool useSentry = storage.getBool('useSentry') ?? false;
    if (useSentry) await Sentry.captureException(e, stackTrace: s);
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

  final storage = await SharedPreferences.getInstance();
  bool useSentry = storage.getBool('useSentry') ?? false;

  final folderName = await fileNameFromTitle(entry.title);
  String comicFolder = '$dirLocation/$folderName';
  await Directory(comicFolder).create(recursive: true);

  try {
    if (dir.contains('.zip') || dir.contains('.cbz')) {
      // Stream entries to disk on a background isolate. Avoids decodeBytes()
      // which keeps the entire archive in RAM and starves the reader.
      await _extractZipOffUi(dir, comicFolder);
      final archiveFile = File('$dirLocation/$fileName');
      if (await archiveFile.exists()) {
        await archiveFile.delete();
      }
      entry.downloaded = true;
      entry.folderPath = comicFolder;
    } else if (dir.contains('.rar') || dir.contains('.cbr')) {
      // unrar_file uses platform channels — must stay on the root isolate.
      await Future<void>.delayed(Duration.zero);
      await UnrarFile.extract_rar('$dirLocation/$fileName', '$comicFolder/');
      final archiveFile = File('$dirLocation/$fileName');
      if (await archiveFile.exists()) {
        await archiveFile.delete();
      }
      entry.downloaded = true;
      entry.folderPath = comicFolder;
    } else if (entry.path.contains('.pdf')) {
      var file = File('$dirLocation/$fileName');
      await Directory(comicFolder).create(recursive: true);
      file.renameSync('$comicFolder/$fileName');
      entry.folderPath = comicFolder;
      entry.filePath = '$comicFolder/$fileName';
      entry.downloaded = true;
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

    parseXML(entry);
    await isar.writeTxn(() async {
      await isar.entrys.put(entry);
    });
  } catch (e, s) {
    if (useSentry) await Sentry.captureException(e, stackTrace: s);
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

dynamic _getTentacleApi(Entry entry) {
  final api = Tentacle(basePathOverride: entry.url).getLibraryApi();
  return api;
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
