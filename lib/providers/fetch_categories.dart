// The purpose of this file is to fetch the categories from the database

import 'package:dio/dio.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:kurage/providers/jellyfin_api.dart';
import 'package:kurage/providers/fetch_books.dart';
import 'package:kurage/providers/folder_provider.dart';
import 'package:kurage/providers/supported_formats.dart';
import 'package:kurage/models/entry.dart';
import 'package:kurage/models/folder.dart';
import 'package:isar/isar.dart';
import 'package:package_info_plus/package_info_plus.dart' as p_info;
import 'package:kurage/variables.dart';

/// Return UI-only folder projections. Do not mutate persisted Folder records;
/// previously indexed PDFs and downloaded files remain intact in Isar.
/// Also handles nested folders and virtual one-volume folders whose folder ID
/// equals their book ID.
List<Folder> visibleLibraryFolders(
  List<Folder> folders,
  Iterable<Entry> entries, {
  Iterable<String> excludedNames = const <String>[],
}) {
  final byEntryId = {for (final e in entries) e.id: e};
  final byFolderId = {for (final folder in folders) folder.id: folder};
  final excluded = excludedNames.toSet();

  List<String> visibleMemberIds(Folder folder, Set<String> visiting) {
    if (!visiting.add(folder.id)) return <String>[];
    final members = <String>[];
    for (final id in folder.bookIds) {
      final entry = byEntryId[id];
      if (entry != null && entry.type != EntryType.folder &&
          isSupportedEntry(entry)) {
        members.add(id);
        continue;
      }
      final childFolder = byFolderId[id];
      if (childFolder != null &&
          visibleMemberIds(childFolder, visiting).isNotEmpty) {
        members.add(id);
      }
    }
    visiting.remove(folder.id);
    return members;
  }

  final result = <Folder>[];
  for (final folder in folders) {
    if (excluded.contains(folder.name)) continue;
    final members = visibleMemberIds(folder, <String>{});
    if (members.isEmpty) continue;
    final visible = Folder(
      id: folder.id,
      name: folder.name,
      image: folder.image,
      bookIds: members,
    )..isarId = folder.isarId;
    result.add(visible);
  }
  result.sort((a, b) =>
      a.name.toLowerCase().compareTo(b.name.toLowerCase()));
  return result;
}

// have optional perameter to have the function return the list of folders
Future<(List<Entry>, List<Folder>)> getServerCategories({
  bool force = false,
  void Function()? onCacheHit,
}) async {
  logger.d("getting server categories");
  final p_info.PackageInfo packageInfo =
      await p_info.PackageInfo.fromPlatform();
  final prefs = await SharedPreferences.getInstance();
  final token = prefs.getString('accessToken') ?? "";
  final url = prefs.getString('server') ?? "";
  final userId = prefs.getString('UserId') ?? "";
  final client = prefs.getString('client') ?? "JellyBook";
  final device = prefs.getString('device') ?? "";
  final deviceId = prefs.getString('deviceId') ?? "";
  final version = prefs.getString('version') ?? packageInfo.version;

  // check if already has books and folders
  final isar = Isar.getInstance();
  // Not final: on a first load the prefs are empty here, so this is updated
  // below once the library names have been fetched from the server.
  var libraryNames = prefs.getStringList('categories') ?? [];
  // Project membership using the entries already loaded for the library.
  // Avoid an extra Isar query during the startup cover prewarm.
  List<Folder> withoutLibraries(List<Folder> folders, List<Entry> books) =>
      visibleLibraryFolders(folders, books, excludedNames: libraryNames);
  final List<Folder> foldersTemp = await isar!.folders.where().findAll();
  QueryBuilder<Entry, Entry, QAfterFilterCondition> typeNotBook =
      isar.entrys.filter().not().typeEqualTo(EntryType.folder);
  List<Entry> booksTemp = await typeNotBook.sortByTitle().findAll();
  final hasCachedBooks = booksTemp.isNotEmpty;
  booksTemp = booksTemp.where(isSupportedEntry).toList();
  if (foldersTemp.isNotEmpty && hasCachedBooks && !force) {
    // Let the Library render from Isar immediately, then revalidate remote
    // progress without holding up its first frame or cover prewarming.
    onCacheHit?.call();
    return (booksTemp, withoutLibraries(foldersTemp, booksTemp));
  }

  // turn all the previous logger.d's into a single logger.d with multiple lines
  logger.i(
      "accessToken: $token\nserver: $url\nUserId: $userId\nclient: $client\ndevice: $device\ndeviceId: $deviceId\nversion: $version");

  logger.d("got prefs");
  Map<String, String> headers =
      getHeaders(url, client, device, deviceId, version, token);
  final api = JellyfinApi(url);
  late final Response<Map<String, dynamic>> response;
  try {
    response = await api.getUserViews(
      userId: userId,
      headers: headers,
      includeHidden: true,
    );
    // logger.d(response);
  } catch (e) {
    logger.e(e);
    rethrow;
  }

  logger.d("got response");
  logger.d(response.statusCode.toString());

  if (response.data == null) {
    throw Exception("Empty response from server");
  }
  final data = (response.data!['Items'] as List<dynamic>? ?? [])
      .cast<Map<String, dynamic>>()
      .where((element) => element['CollectionType'] == 'books')
      .toList();

  bool hasComics = true;
  if (hasComics) {
    String comicsId = '';
    List<String> categories = [];
    // add all data['Items'] to categories
    data.forEach((element) {
      categories.add(element['Name'] as String);
    });

    List<Entry> comics = [];
    List<String> comicsIds = [];
    logger.d("selected: $categories");
    data.forEach((element) {
      comicsId = element['Id'] as String;
      comicsIds.add(comicsId);
    });
    final serverIds = <String>{};
    for (int i = 0; i < comicsIds.length; i++) {
      // turn List<Entry> into Iterable<Entry>
      serverIds.addAll(await getComics(comicsIds[i]));
      // comics.addAll(comicsTemp);
    }
    // Only reconcile after every library returned a complete, successful GET.
    // A transiently empty UserViews response cannot wipe the local catalog.
    if (comicsIds.isNotEmpty) {
      await reconcileMissingEntries(
        serverIds,
        api: api,
        headers: headers,
      );
    }
    comics = (await typeNotBook.sortByTitle().findAll())
        .where(isSupportedEntry).toList();
    comics.sort((a, b) => a.title.compareTo(b.title));

    prefs.setStringList('comicsIds', comicsIds);

    logger.d("comics: ${comics.length}");

    // final isar = Isar.getInstance();
    List<String> categoriesList = [];
    for (int i = 0; i < data.length; i++) {
      categoriesList.add(data[i]['Name'] as String);
    }
    logger.i("categoriesList: $categoriesList");
    prefs.setStringList('categories', categoriesList);
    libraryNames = categoriesList;
    await CreateFolders.getFolders(categoriesList);
    List<Folder> folders = withoutLibraries(
        await isar.folders.where().findAll(), comics);
    return (comics, folders);
  }
}

Future<(int, List<Entry>)> fetchEntries(int offset, int limit) async {
  final isar = Isar.getInstance();
  QueryBuilder<Entry, Entry, QAfterFilterCondition> typeNotBook =
      isar!.entrys.filter().not().typeEqualTo(EntryType.folder);
  List<Entry> entries = await typeNotBook.sortByTitle().findAll();
  entries = entries.where(isSupportedEntry).skip(offset).take(limit).toList();
  int length = entries.length;
  logger.f("entries: ${entries.length}");
  return (length, entries);
}

// check to see if a folder isn't a subfolder of another folder
Future<List<Map<String, dynamic>>> compareFolders(
  List<Map<String, dynamic>> folders,
) async {
  logger.d("comparing folders");
  List<Map<String, dynamic>> newFolders = [];
  logger.d("folders: ${folders.length}");
  for (int i = 0; i < folders.length; i++) {
    logger.d("folder: ${folders[i]['name']}");
    bool isSubfolder = false;
    for (int j = 0; j < folders.length; j++) {
      if (i != j) {
        if (folders[j]['entries'].contains(folders[i]['id'])) {
          isSubfolder = true;
        }
      }
    }
    if (!isSubfolder) {
      newFolders.add(folders[i]);
    }
  }
  logger.d("newFolders: ${newFolders.length}");
  return newFolders;
}

// function to remove entries from the database that are not in the server
Future<void> removeEntriesFromDatabase(
    List<Future<List<Map<String, dynamic>>>> comicsArray) async {
  // now see if the database has any entries that are not in the server
  // if it does, remove those from the database

  // get all the entries from the database

  final isar = Isar.getInstance();
  final entries = await isar!.entrys.where().findAll();
  final folders = await isar.folders.where().findAll();
  List<String> entryIds = entries.map((entry) => entry.id).toList();
  List<String> folderIds = folders.map((folder) => folder.id).toList();
  List<String> serverIds = [];
  List<int> entriesToRemove = [];
  List<int> foldersToRemove = [];

  // get all the ids from the server
  for (int i = 0; i < comicsArray.length; i++) {
    List<Map<String, dynamic>> comics = await comicsArray[i];
    for (int j = 0; j < comics.length; j++) {
      serverIds.add(comics[j]['id']);
    }
  }

  // check if the database has any ids that are not in the server
  for (int i = 0; i < entryIds.length; i++) {
    if (!serverIds.contains(entryIds[i])) {
      entriesToRemove.add(i);
    }
  }

  // check if the database has any ids that are not in the server
  for (int i = 0; i < folderIds.length; i++) {
    if (!serverIds.contains(folderIds[i])) {
      foldersToRemove.add(i);
    }
  }

  // remove the entries from the database
  await isar.writeTxn(() async {
    await isar.entrys.deleteAll(entriesToRemove);
    await isar.folders.deleteAll(foldersToRemove);
  });
}
