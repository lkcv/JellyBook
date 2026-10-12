// One format policy for server discovery and all Isar-backed UI screens.
// Only ZIP-based comic archives are supported; CBR/RAR are excluded.
import 'package:jellybook/models/entry.dart';

const supportedFileExtensions = <String>{
  'cbz', 'zip',
  'epub',
  // Preserve formats already listed by the importer until a separate cleanup.
  'mobi', 'azw3', 'kpf',
  'flac', 'mpga', 'mp3', 'm3u', 'm3u8', 'm4a', 'm4b', 'wav',
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
