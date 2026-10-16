import 'dart:async';

import 'package:flutter/material.dart';
import 'package:isar/isar.dart';
import 'package:jellybook/models/entry.dart';
import 'package:jellybook/providers/deleteComic.dart';
import 'package:jellybook/providers/downloadQueue.dart';
import 'package:jellybook/providers/libraryFilter.dart';
import 'package:jellybook/cache/readerPageCache.dart';
import 'package:jellybook/providers/serverProgressRevision.dart';
import 'package:jellybook/providers/supportedFormats.dart';
import 'package:jellybook/variables.dart';
import 'package:jellybook/widgets/itemActionSheet.dart';

/// Distinguishes filesystem/queue changes from progress-only badge updates.
enum VolumeActionChange { download, readingStatus }

enum _VolumeAction { download, deleteDownload, markFinished, markUnread }

/// Common volume actions for Collection and Search. All mutations stay outside
/// the presentation-only ItemActionSheet. The caller decides which UI refresh
/// is appropriate; routine download progress never rebuilds the cover grid.
Future<void> showVolumeActions(
  BuildContext context,
  Entry entry, {
  required void Function(VolumeActionChange) onChanged,
}) async {
  final database = Isar.getInstance();
  if (database == null) return;
  final queue = DownloadQueue.instance;
  await queue.restoreQueue();
  if (!context.mounted) return;
  final current = await database.entrys.where().idEqualTo(entry.id).findFirst();
  if (!context.mounted || current == null || !isSupportedEntry(current)) return;

  DownloadJob? pending;
  for (final job in queue.jobs) {
    if (job.id == current.id) {
      pending = job;
      break;
    }
  }
  final alreadyQueued = pending != null &&
      pending.state != DownloadJobState.failed &&
      pending.state != DownloadJobState.canceled &&
      pending.state != DownloadJobState.completed;
  final unread = LibraryFilter.isUnread(current);
  final finished = LibraryFilter.isFinished(current);
  final status = unread ? 'UNREAD' : finished ? 'FINISHED' : 'READING';
  final downloadStatus = current.downloaded
      ? 'Downloaded'
      : alreadyQueued ? 'Download queued' : 'Not downloaded';
  final selected = await showItemActionSheet<_VolumeAction>(
    context,
    title: current.title,
    subtitle: '$status · $downloadStatus',
    actions: [
      if (current.downloaded)
        const ItemSheetAction<_VolumeAction>(
          value: _VolumeAction.deleteDownload,
          label: 'Delete downloaded volume',
          subtitle: 'Keep reading progress and cached pages',
          icon: Icons.delete_outline_rounded,
          destructive: true,
        )
      else if (!alreadyQueued)
        ItemSheetAction<_VolumeAction>(
          value: _VolumeAction.download,
          label: pending?.state == DownloadJobState.failed
              ? 'Retry download' : 'Download volume',
          icon: Icons.download_rounded,
        ),
      if (!finished)
        const ItemSheetAction<_VolumeAction>(
          value: _VolumeAction.markFinished,
          label: 'Mark as FINISHED',
          icon: Icons.check_circle_outline_rounded,
        ),
      if (!unread)
        const ItemSheetAction<_VolumeAction>(
          value: _VolumeAction.markUnread,
          label: 'Mark as UNREAD',
          icon: Icons.restart_alt_rounded,
        ),
    ],
  );
  if (!context.mounted || selected == null) return;

  if (selected == _VolumeAction.download) {
    final latest = await database.entrys.where().idEqualTo(entry.id).findFirst();
    if (!context.mounted || latest == null) return;
    if (!latest.downloaded && isSupportedEntry(latest)) {
      // enqueue() deduplicates concurrent and failed jobs for this volume.
      final job = queue.enqueue(latest);
      // Refresh on completion only, never on transfer progress ticks.
      // A reader opened meanwhile will refresh Collection on its own exit.
      unawaited(job.result.then((downloaded) {
        if (downloaded != null && context.mounted &&
            (ModalRoute.of(context)?.isCurrent ?? false)) {
          onChanged(VolumeActionChange.download);
        }
      }));
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('Volume added to download queue'),
      ));
    }
    return;
  }

  if (selected == _VolumeAction.deleteDownload) {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Delete downloaded volume?'),
        content: Text('Remove the local copy of "${current.title}"? '
            'Reading progress and cached pages will be kept.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    ) ?? false;
    if (!confirmed || !context.mounted) return;
    // Never remove a local directory while a queued transfer may use it.
    if (queue.jobs.any((job) => job.id == entry.id)) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('Cancel the queued download before deleting'),
      ));
      return;
    }
    try {
      final removed = await removeDownloadedVolume(entry.id);
      if (!context.mounted) return;
      if (removed) onChanged(VolumeActionChange.download);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(removed ? 'Downloaded volume deleted'
            : 'This volume is no longer downloaded'),
      ));
    } catch (error) {
      if (!context.mounted) return;
      logger.w('Could not remove volume download ${entry.id}: $error');
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not delete downloaded volume')),
      );
    }
    return;
  }

  final markFinished = selected == _VolumeAction.markFinished;
  try {
    // Update both fields for UNREAD. A zero percentage with a saved page
    // above zero still counts as READING according to LibraryFilter.
    await database.writeTxn(() async {
      final latest = await database.entrys.where().idEqualTo(entry.id).findFirst();
      if (latest == null) return;
      latest.progress = markFinished ? 100.0 : 0.0;
      if (!markFinished) latest.pageNum = 0;
      await database.entrys.put(latest);
    });
    if (!markFinished) {
      // Keep the disk page snapshots, but don't reopen an UNREAD volume at
      // an old cached resume position (which is stored separately from Isar).
      try {
        await ReaderPageCache.restoreServerPage(entry.id, 0);
      } catch (error) {
        logger.w('Could not reset cached resume position ${entry.id}: $error');
      }
    }
    if (!context.mounted) return;
    entry.progress = markFinished ? 100.0 : 0.0;
    if (!markFinished) entry.pageNum = 0;
    onChanged(VolumeActionChange.readingStatus);
    serverProgressRevision.value++;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(markFinished ? 'Marked as FINISHED' : 'Marked as UNREAD'),
    ));
  } catch (error) {
    if (!context.mounted) return;
    logger.w('Could not update reading status ${entry.id}: $error');
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Could not update reading status')),
    );
  }
}
