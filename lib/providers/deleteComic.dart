// Remove a local download without removing its Jellyfin/Isar library entry.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:isar/isar.dart';
import 'package:jellybook/models/entry.dart';
import 'package:jellybook/l10n/app_localizations.dart';
import 'package:jellybook/variables.dart';
import 'package:path_provider/path_provider.dart';

/// Shared by Volume Info and Settings. Throws on filesystem failure, leaving
/// Isar's downloaded flag unchanged. Never touches the seven-page reader cache.
Future<bool> removeDownloadedVolume(String id) async {
  final isar = Isar.getInstance();
  if (isar == null) throw StateError('Database unavailable');
  final entry = await isar.entrys.where().idEqualTo(id).findFirst();
  if (entry == null || !entry.downloaded) return false;

  final root = (await getApplicationDocumentsDirectory()).absolute.path;
  final directoryPath = entry.folderPath;
  if (directoryPath.isEmpty) {
    throw StateError('Download has no local directory');
  }
  final dir = Directory(directoryPath);
  final absolute = dir.absolute.path;
  // Never recursively delete the documents root (or a path outside it).
  if (absolute == root ||
      !absolute.startsWith('$root${Platform.pathSeparator}')) {
    throw StateError('Invalid download directory: $directoryPath');
  }

  // Old titles could map to the same extraction directory. Do not remove a
  // shared directory and silently corrupt another downloaded volume.
  final otherDownloads = await isar.entrys.where().filter()
      .downloadedEqualTo(true).findAll();
  if (otherDownloads.any((other) =>
      other.id != id && other.folderPath == directoryPath)) {
    throw StateError('Download directory is shared with another volume');
  }

  if (!await dir.exists()) {
    throw FileSystemException('Downloaded directory does not exist', directoryPath);
  }
  await dir.delete(recursive: true);

  // Preserve pageNum, progress, favorites, server metadata and image caches.
  entry
    ..downloaded = false
    ..folderPath = ''
    ..filePath = '';
  await isar.writeTxn(() async => isar.entrys.put(entry));
  logger.i('Removed local download: ${entry.title}');
  return true;
}

/// Confirmation dialog used by the existing Volume Info screen.
/// Returns false on cancellation or failure; callers must not navigate away
/// or change the displayed download status unless this returns true.
Future<bool> deleteComic(String id, BuildContext context) async {
  final confirmed = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: Text(AppLocalizations.of(dialogContext)?.delete ?? 'Delete Comic'),
          content: Text(AppLocalizations.of(dialogContext)?.deleteConfirm ??
              'Remove the downloaded copy? Reading progress will be kept.'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: Text(AppLocalizations.of(dialogContext)?.cancel ?? 'Cancel'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              child: Text(AppLocalizations.of(dialogContext)?.delete ?? 'Delete'),
            ),
          ],
        ),
      ) ?? false;
  if (!confirmed) return false;
  try {
    return await removeDownloadedVolume(id);
  } catch (error) {
    logger.e('Could not delete local download: $error');
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not remove download: $error')),
      );
    }
    return false;
  }
}

// Retain this entry point for any legacy callers.
Future<void> confirmedDelete(String id, BuildContext context) async {
  try {
    await removeDownloadedVolume(id);
  } catch (error) {
    logger.e('Could not delete local download: $error');
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not remove download: $error')),
      );
    }
  }
}
