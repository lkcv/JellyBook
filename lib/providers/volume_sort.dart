import 'package:kurage/models/entry.dart';

// Compare number runs numerically, so Volume 2 sorts before Volume 10.
final _chunks = RegExp(r'\d+|\D+');

int _naturalCompare(String left, String right) {
  final a = _chunks.allMatches(left.toLowerCase()).map((m) => m[0]!).toList();
  final b = _chunks.allMatches(right.toLowerCase()).map((m) => m[0]!).toList();

  for (var i = 0; i < a.length && i < b.length; i++) {
    final aNumber = BigInt.tryParse(a[i]);
    final bNumber = BigInt.tryParse(b[i]);
    final comparison = aNumber != null && bNumber != null
        ? aNumber.compareTo(bNumber)
        : a[i].compareTo(b[i]);
    if (comparison != 0) return comparison;
  }
  return a.length.compareTo(b.length);
}

// Work around issue where refreshing while Jellyfin is scanning new volumes might populate Isar in non-numeric
// This would cause the collection to be displayed in the wrong order (ex. vol 4 before vol. 1)
int compareVolumeEntries(Entry a, Entry b) {
  final byTitle = _naturalCompare(a.title, b.title);
  if (byTitle != 0) return byTitle;

  final byPath = _naturalCompare(a.path, b.path);
  if (byPath != 0) return byPath;

  return a.id.compareTo(b.id);
}
