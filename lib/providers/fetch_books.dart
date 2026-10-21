// the purpose of this file is to fetch books from the database to be displayed in the app

import 'package:shared_preferences/shared_preferences.dart';
import 'package:kurage/providers/jellyfin_api.dart';

// database imports
import 'package:kurage/models/entry.dart';
import 'package:kurage/models/folder.dart';
import 'package:kurage/providers/supported_formats.dart';
import 'package:kurage/providers/update_pagenum.dart';
import 'package:kurage/cache/reader_page_cache.dart';
import 'package:isar/isar.dart';
import 'package:kurage/variables.dart';

// get comics
Future<Set<String>> getComics(String comicsId) async {
  logger.d('getting comics');
  final prefs = await SharedPreferences.getInstance();
  final token = prefs.getString('accessToken');
  final url = prefs.getString('server');
  final userId = prefs.getString('UserId');
  final client = prefs.getString('client');
  final device = prefs.getString('device');
  final deviceId = prefs.getString('deviceId');
  final version = prefs.getString('version');
  prefs.setString('comicsId', comicsId);
  // '$url/Users/$userId/Items?StartIndex=0&Fields=PrimaryImageAspectRatio,SortName,Path,SongCount,ChildCount,MediaSourceCount,Tags,Overview,ParentId&ImageTypeLimit=1&ParentId=$comicsId&Recursive=true&SortBy=SortName&SortOrder=Ascending'),
  var headers = {
    'Accept': 'application/json',
    'Connection': 'keep-alive',
    'Accept-Language': 'en-US,en;q=0.5',
    'Accept-Encoding': 'gzip, deflate',
    'Authorization':
        'MediaBrowser Client="$client", Device="$device", DeviceId="$deviceId", Version="$version", Token="$token"',
  };
  final api = JellyfinApi(url!);
  final revisionBeforeFetch = progressRevision();
  // Preserve pages that were pending when this network request began, even if
  // their upload completes before the (possibly older) GET response arrives.
  final protectedAtFetchStart =
      await locallyProtectedProgressIds(revisionBeforeFetch);
  List<dynamic> responseData = [];
  try {
    final response = await api.getItems(
      userId: userId!,
      headers: headers,
      parentId: comicsId,
    );
    final data = response.data;
    if (data == null || data['Items'] is! List) {
      throw StateError('Invalid Jellyfin items response');
    }
    responseData = data['Items'] as List<dynamic>;
    final total = (data['TotalRecordCount'] as num?)?.toInt();
    if (total != null && total != responseData.length) {
      throw StateError('Incomplete Jellyfin items response');
    }
  } catch (e) {
    logger.e(e);
    rethrow;
  }
  final protectedIds = protectedAtFetchStart
    ..addAll(await locallyProtectedProgressIds(revisionBeforeFetch));
  final restoredPages = <String, int>{};

  logger.d("Now saving comics to database");

  final isar = Isar.getInstance();
  final existing = {
    for (final entry in await isar!.entrys.where().findAll()) entry.id: entry,
  };
  final updated = <Entry>[];
  final serverIds = <String>{};
  for (final raw in responseData) {
    final element = raw as Map<String, dynamic>;
    // Jellyfin can flag a one-volume series directory as IsFolder while its
    // item type is still Book. Treat those as books, not folders.
    final jellyfinKind = (element['Type'] as String? ?? '').toLowerCase();
    final isRealFolder =
        element['IsFolder'] == true && jellyfinKind != 'book';
    final imageTags = element['ImageTags'] as Map<String, dynamic>?;
    final itemId = element['Id'] as String? ?? '';
    if (itemId.isEmpty) throw StateError('Jellyfin item without an ID');
    // Include unsupported types so their previously stored rows aren't purged.
    serverIds.add(itemId);
    Entry entry = Entry(
      id: itemId,
      title: element['Name'] as String? ?? '',
      imagePath: imageTags?['Primary'] != null
          ? '$url/Items/$itemId/Images/Primary?quality=90'
          : 'Asset',
      releaseDate: element['ProductionYear'].toString(),
      path: element['Path'] as String? ?? '',
      description: element['Overview'] as String? ?? '',
      url: url,
      rating: (element['CommunityRating'] as num?)?.toDouble() ?? -1,
      type: isRealFolder ? EntryType.folder : EntryType.book,
      tags: (element['Tags'] as List<dynamic>?)?.cast<String>().toList() ?? [],
      parentId: element['ParentId'] as String? ?? '',
      downloaded: false,
    );
    List<String> comicFileTypes = ['cbz', 'zip'];

    String entryPath = (element['Path'] as String?).toString().toLowerCase();
    // Audio entries are excluded by the shared format policy.
    if (jellyfinKind == 'folder') {
      entry.type = EntryType.folder;
    } else if (comicFileTypes.contains(entryPath)) {
      entry.type = EntryType.comic;
    }

    // Do not import newly encountered unsupported files. Previously stored
    // rows remain in Isar but are hidden by the same format policy.
    if (!isSupportedEntry(entry)) continue;

    final previous = existing[entry.id];
    if (previous != null) {
      entry.isarId = previous.isarId;
      entry.downloaded = previous.downloaded;
      entry.progress = previous.progress;
      entry.folderPath = previous.folderPath;
      entry.filePath = previous.filePath;
      entry.pageNum = previous.pageNum;
    }
    // Jellyfin reports comic page indices as 10,000 ticks per zero-based
    // page. Only CBZ/ZIP progress uses this convention; EPUB is separate.
    // A pending local upload or a page change during the GET wins over this
    // potentially stale server snapshot.
    final extension = entryFileExtension(entry.path);
    final userData = element['UserData'] as Map<String, dynamic>?;
    final ticks = (userData?['PlaybackPositionTicks'] as num?)?.toInt();
    if ((extension == 'cbz' || extension == 'zip') &&
        !protectedIds.contains(entry.id) &&
        ticks != null && ticks >= 0) {
      final serverPage = ticks ~/ 10000;
      if (entry.pageNum != serverPage) {
        entry.pageNum = serverPage;
        final serverPercent = userData?['PlayedPercentage'] as num?;
        if (serverPercent != null) {
          entry.progress = serverPercent.toDouble().clamp(0.0, 100.0).toDouble();
        } else if (serverPage == 0) {
          entry.progress = 0;
        }
        restoredPages[entry.id] = serverPage;
        logger.d('Restored Jellyfin page index $serverPage for ${entry.id}');
      }
    }
    updated.add(entry);
  }
  await isar.writeTxn(() async {
    await isar.entrys.putAll(updated);
  });

  // The streaming reader prefers the retained cache's page marker. Bring it
  // into agreement with Isar without discarding downloaded page images.
  for (final restored in restoredPages.entries) {
    try {
      await ReaderPageCache.restoreServerPage(
        restored.key, restored.value);
    } catch (error) {
      logger.w('Could not align cached page for ${restored.key}: $error');
    }
  }

  return serverIds;
}

/// Reconcile a completed, successful Jellyfin library snapshot with Isar.
/// Never interpret a failed fetch as an empty catalog; getComics validates
/// every response before this is called. A running scan can be incomplete.
/// This changes database metadata only; it does not delete local files.
Future<void> reconcileMissingEntries(
  Set<String> serverIds, {
  required JellyfinApi api,
  required Map<String, String> headers,
}) async {
  final isar = Isar.getInstance()!;
  final entries = await isar.entrys.where().findAll();
  final folders = await isar.folders.where().findAll();
  final missingEntries = entries
      .where((entry) => !serverIds.contains(entry.id))
      .toList();
  final missingFolders = folders
      .where((folder) => !serverIds.contains(folder.id))
      .toList();

  if (missingEntries.isEmpty && missingFolders.isEmpty) return;
  if (await api.isLibraryScanRunning(headers: headers) == true) {
    logger.i('Skipping library pruning while Jellyfin is scanning');
    return;
  }

  // An absent item should no longer appear in the Library after one
  // successful refresh, regardless of its old Isar insertion order or
  // whether it was previously downloaded. Leave physical files untouched.
  await isar.writeTxn(() async {
    await isar.entrys.deleteAll(
        missingEntries.map((entry) => entry.isarId).toList());
    await isar.folders.deleteAll(
        missingFolders.map((folder) => folder.isarId).toList());
  });
  logger.i('Pruned ${missingEntries.length} missing entries and '
      '${missingFolders.length} missing folders from Isar');
}

Future<void> updateFolders() async {
  final isar = Isar.getInstance();
  List<Entry> entryFolders =
      await isar!.entrys.filter().typeEqualTo(EntryType.folder).findAll();
  List<Entry> entrys = await isar.entrys.where().findAll();
  List<Folder> folders = [];
  folders = await isar.folders.where().findAll();
  // check if any folders are missing
  for (Entry e in entryFolders) {
    if (folders.indexWhere((element) => element.id == e.id) == -1) {
      // add folder
      Folder folder = Folder(
        id: e.id,
        name: e.title,
        image: e.imagePath,
      );
      folders.add(folder);
    }
  }
  // add entrys to folders
  for (Entry e in entrys) {
    folders.indexWhere((element) {
      if (element.id == e.parentId) {
        // make sure its not already in the list
        List<String> updatedBookIds = List.from(element.bookIds);
        if (updatedBookIds.indexWhere((element) => element == e.id) == -1) {
          updatedBookIds.add(e.id);
        }
        element.bookIds = updatedBookIds;

        return true;
      } else {
        return false;
      }
    });
  }

  await isar.writeTxn(() async {
    await isar.folders.putAll(folders);
  });
}

Map<String, String> getHeaders(
  String url,
  String client,
  String device,
  String deviceId,
  String version,
  String token,
) {
  var uri = Uri.parse(url);
  var headers = {
    'Accept': 'application/json',
    'Accept-Language': 'en-US,en;q=0.5',
    'Accept-Encoding': 'gzip, deflate',
    'Authorization':
        'MediaBrowser Client="$client", Device="$device", DeviceId="$deviceId", Version="$version", Token="$token"',
    'Connection': 'keep-alive',
  };

  if (uri.scheme == "https") {
    headers.addAll({
      'Host': uri.host,
      'Sec-Fetch-Dest': 'empty',
      'Sec-Fetch-Mode': 'cors',
      'Sec-Fetch-Site': 'same-origin',
    });
  }

  return headers;
}
