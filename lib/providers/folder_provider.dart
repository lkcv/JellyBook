// The purpose of this file is to take the list of entries and create folders if their parentId is not one of the categories

import 'package:isar/isar.dart';
import 'package:kurage/models/folder.dart';
import 'package:kurage/models/entry.dart';
import 'package:kurage/providers/supported_formats.dart';
import 'package:kurage/providers/volume_sort.dart';
import 'package:kurage/variables.dart';

// This function takes the list of entries and creates folders if their parentId is not one of the categories
// It adds the folder to the list of folders in a isar box
class CreateFolders {
static Future<void> createFolders(
      List<Entry> entries, List<String> categories) async {
    final isar = Isar.getInstance();
    List<Folder> newFolders = [];
    entries.forEach((entry) {
      List<Entry> bookEntries = isar!.entrys
          .filter().parentIdEqualTo(entry.id).findAllSync()
          .where(isSupportedEntry).toList();
      List<String> bookEntryIds = bookEntries.map((entry) => entry.id).toList();
      
      final coverEntries = bookEntries.where((book) =>
          book.type != EntryType.folder &&
          book.imagePath.isNotEmpty &&
          book.imagePath != 'Asset').toList()
        ..sort(compareVolumeEntries);
      final folderImage = coverEntries.isNotEmpty
          ? coverEntries.first.imagePath
          : entry.imagePath;
      
      // IMPORTANT: Only create folders for non-library items
      // Skip if this entry IS a library category (top-level)
      if (!categories.contains(entry.id)) {
        Folder newFolder = Folder(
          id: entry.id,
          name: entry.title,
          bookIds: bookEntryIds,
          image: folderImage,
        );
        newFolders.add(newFolder);
      }
    });
    
    for (int i = 0; i < newFolders.length; i++) {
      var folder =
          isar!.folders.filter().idEqualTo(newFolders[i].id).findFirstSync();
      if (folder != null) {
        final folderIsarId = folder.isarId;
        newFolders[i].isarId = folderIsarId;
        await isar.writeTxn(() async {
          await isar.folders.put(newFolders[i]);
        });
      } else {
        await isar.writeTxn(() async {
          await isar.folders.put(newFolders[i]);
        });
      }
    }
  }

  // Jellyfin turns a directory that holds exactly one book file into a Book
  // item (no Folder item is created for it), so a one-book series arrives
  // parented directly to the library and never gets a Folder row. Wrap each
  // such book in a one-book Folder so it shows up in the series grid.
  // Virtual folders reuse the book's id as their own id.
  static Future<void> createSingleBookFolders(List<String> libraryNames) async {
    final isar = Isar.getInstance();
    if (isar == null) return;
    // Jellyfin returns each library's root as a folder item (e.g. "Manga")
    // whose children are the series folders. A "loose" book is one that sits
    // directly in that root (or has no stored parent folder at all) instead
    // of inside a series folder.
    final folderEntries =
        await isar.entrys.filter().typeEqualTo(EntryType.folder).findAll();
    final folderEntryIds = folderEntries.map((f) => f.id).toSet();
    final libraryRootIds = folderEntries
        .where((f) => libraryNames.contains(f.title))
        .map((f) => f.id)
        .toSet();
    final allBooks = (await isar.entrys
            .filter().not().typeEqualTo(EntryType.folder).findAll())
        .where(isSupportedEntry).toList();
    final looseBooks = allBooks
        .where((b) =>
            libraryRootIds.contains(b.parentId) ||
            !folderEntryIds.contains(b.parentId))
        .toList();
    final looseIds = looseBooks.map((b) => b.id).toSet();
    logger.i('single-book folders: ${looseBooks.length} loose of '
        '${allBooks.length} books; library roots: ${libraryRootIds.length} '
        '(names: $libraryNames); sample: '
        '${looseBooks.take(5).map((b) => '${b.title}=${b.parentId}').toList()}');

    // Drop virtual folders for books that are no longer loose (e.g. a second
    // book was added to the directory, so Jellyfin now makes a real folder).
    final bookIds = allBooks.map((b) => b.id).toSet();
    final existing = await isar.folders.where().findAll();
    final staleIsarIds = existing
        .where((f) => bookIds.contains(f.id) && !looseIds.contains(f.id))
        .map((f) => f.isarId)
        .toList();

    final existingById = {for (final f in existing) f.id: f};
    final virtualFolders = looseBooks.map((book) {
      final folder = Folder(
        id: book.id,
        name: book.title,
        image: book.imagePath,
        bookIds: [book.id],
      );
      final prev = existingById[book.id];
      if (prev != null) folder.isarId = prev.isarId;
      return folder;
    }).toList();

    await isar.writeTxn(() async {
      await isar.folders.deleteAll(staleIsarIds);
      await isar.folders.putAll(virtualFolders);
    });
  }

  static Future<void> getFolders(List<String> categories) async {
    final isar = Isar.getInstance();
    final entries =
        await isar!.entrys.filter().typeEqualTo(EntryType.folder).findAll();
    await CreateFolders.createFolders(entries, categories);
    await CreateFolders.createSingleBookFolders(categories);
  }
}
