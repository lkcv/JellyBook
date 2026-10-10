import 'dart:io';
import 'dart:typed_data';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:jellybook/variables.dart';

class _ZipEntry {
  final String name;
  final int offset; // local header offset
  final int compressedSize;
  final int method; // 0 = stored, 8 = deflate
  _ZipEntry(this.name, this.offset, this.compressedSize, this.method);
}

/// Reads individual pages of a CBZ over HTTP Range requests.
class CbzStream {
  final String url;
  final String itemId;
  final Map<String, String> headers;

  late Directory _cacheDir;
  int _totalSize = 0;
  List<_ZipEntry> _pages = [];
  bool _ready = false;
  final Map<int, Future<File>> _inflight = {};

  CbzStream({
    required this.url,
    required this.itemId,
    required this.headers,
  });

  int get pageCount => _pages.length;

  /// Original path within the archive, used to infer chapter boundaries.
  String? pageName(int index) =>
      _ready && index >= 0 && index < _pages.length ? _pages[index].name : null;

  Future<void> init() async {
    if (_ready) return;
    final temp = await getTemporaryDirectory();
    _cacheDir = Directory('${temp.path}/cbz_stream_$itemId');
    await _cacheDir.create(recursive: true);

    _totalSize = await _fetchTotalSize();
    logger.d('CbzStream: total size = $_totalSize');

    // Search for EOCD signature in the last 64 KB
    // EOCD is at least 22 bytes, plus up to ~65KB for a comment
    final searchSize = (_totalSize > 65536 ? 65536 : _totalSize).toInt();
    final searchStart = _totalSize - searchSize;
    final searchData = await _fetchRange(searchStart, _totalSize - 1);

    int eocdOffset = -1;
    for (int i = searchData.length - 22; i >= 0; i--) {
      if (_u32(searchData, i) == 0x06054b50) {
        eocdOffset = searchStart + i;
        break;
      }
    }

    if (eocdOffset < 0) {
      throw Exception('EOCD not found; zip may be corrupted or zip64');
    }

    logger.d('CbzStream: EOCD found at $eocdOffset');

    // Read EOCD from that position
    final eocd = await _fetchRange(eocdOffset, eocdOffset + 21);
    final cdSize = _u32(eocd, 12);
    final cdOffset = _u32(eocd, 16);

    logger.d(
        'CbzStream: central directory at $cdOffset, size $cdSize');

    if (cdOffset < 0 || cdSize < 0 || cdOffset + cdSize > _totalSize) {
      throw Exception('Invalid central directory offsets');
    }

    final cd = await _fetchRange(cdOffset, cdOffset + cdSize - 1);

    const exts = ['.jpg', '.jpeg', '.png', '.gif', '.webp', '.bmp', '.tiff'];
    final entries = <_ZipEntry>[];
    int p = 0;
    while (p + 46 <= cd.length && _u32(cd, p) == 0x02014b50) {
      final method = _u16(cd, p + 10);
      final csize = _u32(cd, p + 20);
      final nameLen = _u16(cd, p + 28);
      final extraLen = _u16(cd, p + 30);
      final commentLen = _u16(cd, p + 32);
      final offset = _u32(cd, p + 42);
      final name = String.fromCharCodes(cd.sublist(p + 46, p + 46 + nameLen));
      p += 46 + nameLen + extraLen + commentLen;
      if (exts.any((e) => name.toLowerCase().endsWith(e))) {
        entries.add(_ZipEntry(name, offset, csize, method));
      }
    }
    entries.sort((a, b) => a.name.compareTo(b.name));
    _pages = entries;
    _ready = true;
    logger.d('CbzStream: indexed ${_pages.length} pages');
  }

  Future<File> getPage(int index) {
    return _inflight.putIfAbsent(index, () => _loadPage(index));
  }

  Future<File> _loadPage(int index) async {
    if (!_ready) await init();
    final entry = _pages[index];
    final ext = entry.name.split('.').last;
    final file = File('${_cacheDir.path}/$index.$ext');
    if (await file.exists()) return file;

    // local header: 30 bytes + name + extra, then the compressed data
    final header = await _fetchRange(entry.offset, entry.offset + 29);
    final nameLen = _u16(header, 26);
    final extraLen = _u16(header, 28);
    final dataStart = entry.offset + 30 + nameLen + extraLen;
    final raw =
        await _fetchRange(dataStart, dataStart + entry.compressedSize - 1);

    final bytes = entry.method == 0
        ? raw
        : Uint8List.fromList(ZLibCodec(raw: true).decode(raw));
    await file.writeAsBytes(bytes);
    return file;
  }

  Future<void> clear() async {
    try {
      if (await _cacheDir.exists()) await _cacheDir.delete(recursive: true);
    } catch (e) {
      logger.e('CbzStream: error clearing cache: $e');
    }
  }

  Future<int> _fetchTotalSize() async {
    final r = await http.get(Uri.parse('$url/Items/$itemId/Download'),
        headers: {
          ...headers,
          'Range': 'bytes=0-0'
        }).timeout(const Duration(seconds: 15));
    final range = r.headers['content-range']; // "bytes 0-0/180204386"
    if (r.statusCode != 206 || range == null) {
      throw Exception('Server does not support range requests');
    }
    return int.parse(range.split('/').last);
  }

  Future<Uint8List> _fetchRange(int start, int end) async {
    final r = await http.get(Uri.parse('$url/Items/$itemId/Download'),
        headers: {
          ...headers,
          'Range': 'bytes=$start-$end'
        }).timeout(const Duration(seconds: 30));
    if (r.statusCode != 206) {
      throw Exception('Range request failed (${r.statusCode})');
    }
    return r.bodyBytes;
  }

  int _u16(Uint8List d, int o) => d[o] | (d[o + 1] << 8);
  int _u32(Uint8List d, int o) =>
      d[o] | (d[o + 1] << 8) | (d[o + 2] << 16) | (d[o + 3] << 24);
}
