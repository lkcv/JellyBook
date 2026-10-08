// The purpose of this file is to take the list of entries and create folders if their parentId is not one of the categories

import 'package:shared_preferences/shared_preferences.dart';

import 'package:isar/isar.dart';
import 'package:jellybook/models/folder.dart';
import 'package:jellybook/models/entry.dart';

// This function takes the list of entries and creates folders if their parentId is not one of the categories
// It adds the folder to the list of folders in a isar box
class CreateFolders {
static Future<void> createFolders(
      List<Entry> entries, List<String> categories) async {
    final isar = Isar.getInstance();
  
    final prefs = await SharedPreferences.getInstance();
    List<String> categories = prefs.getStringList('categories') ?? [];
    List<Folder> newFolders = [];
    entries.forEach((entry) {
      List<Entry> bookEntries =
          isar!.entrys.filter().parentIdEqualTo(entry.id).findAllSync();
      List<String> bookEntryIds = bookEntries.map((entry) => entry.id).toList();
      
      // Get folder image - use first book's image if folder doesn't have one
      String folderImage = entry.imagePath ?? '';
      if ((folderImage.isEmpty || folderImage == 'Asset') && bookEntries.isNotEmpty) {
        folderImage = bookEntries.first.imagePath ?? '';
      }
      
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

  static Future<void> getFolders(List<String> categories) async {
    final isar = Isar.getInstance();
    final entries =
        await isar!.entrys.filter().typeEqualTo(EntryType.folder).findAll();
    await CreateFolders.createFolders(entries, categories);
  }
}
