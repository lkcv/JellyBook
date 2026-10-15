// Shared eligibility policy for Library series and Collection volumes.
// Keep the selection logic here; scrolling, pinning, and navigation remain
// owned by their screens.
import 'package:isar/isar.dart';
import 'package:jellybook/models/entry.dart';
import 'package:jellybook/models/folder.dart';
import 'package:jellybook/providers/supportedFormats.dart';

class LibraryFilter {
  const LibraryFilter({this.downloadedOnly = false});

  final bool downloadedOnly;

  LibraryFilter copyWith({bool? downloadedOnly}) =>
      LibraryFilter(downloadedOnly: downloadedOnly ?? this.downloadedOnly);

  // This predicate also controls which volumes count toward a filtered
  // series card's reading progress.
  bool matchesEntry(Entry entry) => !downloadedOnly || entry.downloaded;

  bool includesEntry(Entry entry) =>
      isSupportedEntry(entry) && matchesEntry(entry);

  List<Entry> filterEntries(Iterable<Entry> entries) =>
      entries.where(includesEntry).toList();

  // Isar handles the indexed Downloaded lookup; the same supported-format
  // policy is then used for both series membership and Collection contents.
  Set<String> matchingEntryIds(Isar? isar) {
    if (!downloadedOnly || isar == null) return <String>{};
    return isar.entrys.where().filter().downloadedEqualTo(true).findAllSync()
        .where(includesEntry).map((entry) => entry.id).toSet();
  }

  List<Folder> filterFolders(List<Folder> folders, Set<String> matchingIds) {
    if (!downloadedOnly) return folders;
    return folders.where((folder) =>
        folder.bookIds.any(matchingIds.contains)).toList();
  }

  // Null means an unfiltered series, which keeps the existing all-volume pill.
  int? matchingVolumeCount(Folder folder, Set<String> matchingIds) =>
      downloadedOnly
          ? folder.bookIds.where(matchingIds.contains).length
          : null;
}
