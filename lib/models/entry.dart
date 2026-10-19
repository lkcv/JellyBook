// The purpose of this file is to define how book/comic entries are stored in the database

import 'package:isar/isar.dart';

part 'entry.g.dart';

enum EntryType {
  book,
  comic,
  folder,
  // Legacy Isar enum value: keep its index stable for existing installations.
  // Audio entries are filtered out by supported_formats.dart.
  audiobook,
}

@Collection()
class Entry {
  Id isarId = Isar.autoIncrement;

  @Index()
  String id;
  String title;
  String description;
  String imagePath;
  String releaseDate;
  bool downloaded = false;
  String path;
  String url;
  List<String> tags;
  double rating = -1;
  double progress = 0.0;
  int pageNum = 0;
  String folderPath = "";
  String filePath = "";
  @enumerated
  EntryType type;
  String parentId = "";

  /// ComicInfoXML fields (for comics)
  String? writer;
  String? penciller;
  String? inker;
  String? colorist;
  String? letterer;
  String? coverArtist;
  String? editor;
  String? translator;
  String? publisher;
  String? imprint;

  Entry({
    required this.id,
    required this.title,
    required this.description,
    required this.imagePath,
    required this.releaseDate,
    this.downloaded = false,
    required this.path,
    required this.url,
    required this.tags,
    required this.rating,
    this.progress = 0.0,
    this.pageNum = 0,
    this.folderPath = '',
    this.filePath = '',
    this.type = EntryType.book,
    this.parentId = '',
    this.writer,
    this.penciller,
    this.inker,
    this.colorist,
    this.letterer,
    this.coverArtist,
    this.editor,
    this.translator,
    this.publisher,
    this.imprint,
    this.isarId = Isar.autoIncrement,
  });

  static Entry fromJson(Map<String, dynamic> json) {
    return Entry(
      isarId: json['isarId'] ?? Isar.autoIncrement,
      id: json['id'] ?? '',
      title: json['name'] ?? json['title'] ?? '',
      description: json['description'] ?? '',
      imagePath: json['imagePath'] ?? '',
      releaseDate: json['releaseDate'] ?? json['year'] ?? '',
      downloaded: json['downloaded'] ?? false,
      path: json['path'] ?? '',
      url: json['url'] ?? '',
      tags: json['tags'] != null ? List<String>.from(json['tags']) : [],
      rating: json['rating'] ?? -1,
      progress: json['progress'] ?? 0.0,
      pageNum: json['pageNum'] ?? 0,
      folderPath: json['folderPath'] ?? '',
      filePath: json['filePath'] ?? '',
      // type is an enum, so we need to convert it back to an enum or if it's null, set it to book
      type: json['type'] != null
          ? EntryType.values.firstWhere((e) => e.toString() == json['type'])
          : EntryType.book,
      parentId: json['parentId'] ?? '',
      writer: json['writer'],
      penciller: json['penciller'],
      inker: json['inker'],
      colorist: json['colorist'],
      letterer: json['letterer'],
      coverArtist: json['coverArtist'],
      editor: json['editor'],
      translator: json['translator'],
      publisher: json['publisher'],
      imprint: json['imprint'],
    );
  }

  // toString
  @override
  String toString() {
    return 'Entry{\n\tid: $id,\n\ttitle: $title,\n\tdescription: $description,\n\timagePath: $imagePath,\n\treleaseDate: $releaseDate,\n\tdownloaded: $downloaded,\n\tpath: $path,\n\turl: $url,\n\ttags: $tags,\n\trating: $rating,\n\tprogress: $progress,\n\tpageNum: $pageNum,\n\tfolderPath: $folderPath,\n\tfilePath: $filePath,\n\ttype: $type,\n\tparentId: $parentId,\n\twriter: $writer,\n\tpenciller: $penciller,\n\tinker: $inker,\n\tcolorist: $colorist,\n\tletterer: $letterer,\n\tcoverArtist: $coverArtist,\n\teditor: $editor,\n\ttranslator: $translator,\n\tpublisher: $publisher,\n\timprint: $imprint,\n}';
  }
}
