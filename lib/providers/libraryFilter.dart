// Shared eligibility policy for Library series and Collection volumes.
// Keep the selection logic here; scrolling, pinning, and navigation remain
// owned by their screens.
import 'package:isar/isar.dart';
import 'package:jellybook/models/entry.dart';
import 'package:jellybook/models/folder.dart';
import 'package:jellybook/providers/supportedFormats.dart';

class LibraryFilter {
  const LibraryFilter({this.downloadedOnly = false, this.readingOnly = false});

  final bool downloadedOnly;
  final bool readingOnly;
  bool get isActive => downloadedOnly || readingOnly;

  LibraryFilter copyWith({bool? downloadedOnly, bool? readingOnly}) =>
      LibraryFilter(
        downloadedOnly: downloadedOnly ?? this.downloadedOnly,
        readingOnly: readingOnly ?? this.readingOnly,
      );

  // Use the Collection card's exact UNREAD / READING / FINISHED rule.
  // A nonzero page number with 0% progress still counts as READING.
  static bool isUnread(Entry entry) =>
      entry.pageNum == 0 && entry.progress <= 0;
  static bool isFinished(Entry entry) => entry.progress >= 100;
  static bool isReading(Entry entry) =>
      !isUnread(entry) && !isFinished(entry);

  // Both enabled filters must match the same volume (intersection).
  // This also controls filtered series-card progress.
  bool matchesEntry(Entry entry) =>
      (!downloadedOnly || entry.downloaded) &&
      (!readingOnly || isReading(entry));

  bool includesEntry(Entry entry) =>
      isSupportedEntry(entry) && matchesEntry(entry);

  List<Entry> filterEntries(Iterable<Entry> entries) =>
      entries.where(includesEntry).toList();

  // Restrict Downloaded candidates in Isar before applying the policy.
  // Reading status is not indexed, so Library caches Reading eligibility
  // rather than scanning the entire catalog for every scroll window.
  Set<String> matchingEntryIds(Isar? isar) {
    if (!isActive || isar == null) return <String>{};
    final entries = downloadedOnly
        ? isar.entrys.where().filter().downloadedEqualTo(true).findAllSync()
        : isar.entrys.where().findAllSync();
    return entries.where(includesEntry).map((entry) => entry.id).toSet();
  }

  List<Folder> filterFolders(List<Folder> folders, Set<String> matchingIds) {
    if (!isActive) return folders;
    return folders.where((folder) =>
        folder.bookIds.any(matchingIds.contains)).toList();
  }

  // Null means an unfiltered series, which keeps the existing all-volume pill.
  int? matchingVolumeCount(Folder folder, Set<String> matchingIds) =>
      isActive
          ? folder.bookIds.where(matchingIds.contains).length
          : null;
}
