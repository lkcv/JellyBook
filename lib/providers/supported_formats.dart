// One format policy for server discovery and all Isar-backed UI screens.
import 'package:kurage/models/entry.dart';

const supportedFileExtensions = <String>{
  'cbz', 'zip',
};

String entryFileExtension(String path) {
  final clean = path.split(RegExp(r'[?#]')).first;
  final name = clean.split(RegExp(r'[/\\]')).last;
  final dot = name.lastIndexOf('.');
  return dot < 0 ? '' : name.substring(dot + 1).toLowerCase();
}

bool isSupportedEntry(Entry entry) =>
    entry.type == EntryType.folder ||
    supportedFileExtensions.contains(entryFileExtension(entry.path));
