import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:jellybook/providers/jellyfinApi.dart';
import 'package:jellybook/providers/downloadExceptions.dart';
import 'package:jellybook/variables.dart';
import 'package:path_provider/path_provider.dart';

class _ZipEntry {
  final String name;
  final int offset;
  final int compressedSize;
  final int uncompressedSize;
  final int method;
  final int crc;

  const _ZipEntry(this.name, this.offset, this.compressedSize,
      this.uncompressedSize, this.method, this.crc);
}

final _crcTable = List<int>.generate(256, (index) {
  var value = index;
  for (var bit = 0; bit < 8; bit++) {
    value = (value & 1) == 1
        ? (value >> 1) ^ 0xedb88320
        : value >> 1;
  }
  return value;
});

int _updateCrc(int crc, List<int> bytes) {
  for (final byte in bytes) {
    crc = _crcTable[(crc ^ byte) & 0xff] ^ (crc >> 8);
  }
  return crc;
}

int _crc32(List<int> bytes) =>
    (_updateCrc(0xffffffff, bytes) ^ 0xffffffff) & 0xffffffff;

Future<bool> _validFile(File file, int size, int crc) async {
  if (!await file.exists() || await file.length() != size) return false;
  return Isolate.run(() async {
    var result = 0xffffffff;
    await for (final chunk in file.openRead()) {
      result = _updateCrc(result, chunk);
    }
    return ((result ^ 0xffffffff) & 0xffffffff) == crc;
  });
}

class CbzStream {
  final String url;
  final String itemId;
  final Map<String, String> headers;
  final Directory? pageDirectory;
  final CancelToken? cancelToken;
  late final JellyfinApi _api = JellyfinApi(url);

  late Directory _cacheDir;
  int _totalSize = 0;
  List<_ZipEntry> _pages = [];
  _ZipEntry? _comicInfo;
  bool _ready = false;
  String _fingerprint = '';
  final Map<int, Future<File>> _inflight = {};

  CbzStream({
    required this.url,
    required this.itemId,
    required this.headers,
    this.pageDirectory,
    this.cancelToken,
  });

  int get pageCount => _pages.length;
  String get fingerprint => _fingerprint;

  String? pageName(int index) =>
      _ready && index >= 0 && index < _pages.length ? _pages[index].name : null;

  File pageFile(int index) {
    if (!_ready || index < 0 || index >= _pages.length) {
      throw RangeError.index(index, _pages);
    }
    final ext = _pages[index].name.split('.').last.toLowerCase();
    return File('${_cacheDir.path}/${(index + 1).toString().padLeft(6, '0')}.$ext');
  }

  Future<bool> isPageValid(int index, File file) {
    final entry = _pages[index];
    return _validFile(file, entry.uncompressedSize, entry.crc);
  }

  void _checkCanceled() {
    if (cancelToken?.isCancelled ?? false) {
      throw const DownloadCanceled();
    }
  }

  Future<void> init() async {
    if (_ready) return;
    _checkCanceled();
    final temp = await getTemporaryDirectory();
    _cacheDir = pageDirectory ?? Directory('${temp.path}/cbz_stream_$itemId');
    await _cacheDir.create(recursive: true);

    final first = await _api.getItemDownloadRange(
      itemId: itemId, start: 0, end: 0, headers: headers,
      cancelToken: cancelToken,
    ).timeout(const Duration(seconds: 15));
    _checkRetryableStatus(first);
    final contentRange = first.headers.value('content-range');
    if (first.statusCode != 206 || contentRange == null) {
      throw const FormatException('Server does not support CBZ byte ranges');
    }
    final match = RegExp(r'^bytes 0-0/(\d+)$').firstMatch(contentRange);
    if (match == null) throw const FormatException('Invalid Content-Range');
    _totalSize = int.parse(match.group(1)!);
    final etag = first.headers.value('etag');
    final modified = first.headers.value('last-modified');
    if (_totalSize < 22) throw const FormatException('Invalid ZIP size');

    final searchSize = _totalSize < 65557 ? _totalSize : 65557;
    final searchStart = _totalSize - searchSize;
    final searchData = await _fetchRange(searchStart, _totalSize - 1);
    var eocdOffset = -1;
    for (var i = searchData.length - 22; i >= 0; i--) {
      if (_u32(searchData, i) == 0x06054b50 &&
          i + 22 + _u16(searchData, i + 20) == searchData.length) {
        eocdOffset = searchStart + i;
        break;
      }
    }
    if (eocdOffset < 0) {
      throw const FormatException('ZIP end-of-central-directory not found');
    }
    final eocd = searchData.sublist(eocdOffset - searchStart);
    final cdSize = _u32(eocd, 12);
    final cdOffset = _u32(eocd, 16);
    if (cdSize == 0xffffffff || cdOffset == 0xffffffff ||
        cdOffset + cdSize > _totalSize || cdSize == 0) {
      throw const FormatException('Unsupported ZIP directory');
    }
    final cd = await _fetchRange(cdOffset, cdOffset + cdSize - 1);
    _fingerprint = '$_totalSize:${_crc32(cd)}:${etag ?? modified ?? ''}';

    const exts = ['.jpg', '.jpeg', '.png', '.gif', '.webp', '.bmp', '.tiff'];
    final entries = <_ZipEntry>[];
    var p = 0;
    while (p + 46 <= cd.length && _u32(cd, p) == 0x02014b50) {
      final flags = _u16(cd, p + 8);
      final method = _u16(cd, p + 10);
      final crc = _u32(cd, p + 16);
      final compressed = _u32(cd, p + 20);
      final uncompressed = _u32(cd, p + 24);
      final nameLen = _u16(cd, p + 28);
      final extraLen = _u16(cd, p + 30);
      final commentLen = _u16(cd, p + 32);
      final offset = _u32(cd, p + 42);
      final next = p + 46 + nameLen + extraLen + commentLen;
      if (next > cd.length) throw const FormatException('Invalid ZIP entry');
      final nameBytes = cd.sublist(p + 46, p + 46 + nameLen);
      final name = (flags & 0x800) != 0
          ? utf8.decode(nameBytes)
          : latin1.decode(nameBytes);
      p = next;
      final isPage = exts.any((ext) => name.toLowerCase().endsWith(ext));
      final isComicInfo = name.split('/').last.toLowerCase() == 'comicinfo.xml';
      if (!isPage && !isComicInfo) continue;
      if ((flags & 1) != 0 || (method != 0 && method != 8) ||
          compressed == 0xffffffff || uncompressed == 0xffffffff ||
          offset == 0xffffffff) {
        throw const FormatException('Unsupported ZIP entry encoding');
      }
      final entry = _ZipEntry(
          name, offset, compressed, uncompressed, method, crc);
      if (isPage) entries.add(entry);
      if (isComicInfo && _comicInfo == null) _comicInfo = entry;
    }
    if (entries.isEmpty) throw const FormatException('No CBZ pages found');
    entries.sort((a, b) => a.name.compareTo(b.name));
    _pages = entries;
    _ready = true;
  }

  Future<File> getPage(int index) {
    if (!_ready) {
      return init().then((_) => getPage(index));
    }
    return _inflight.putIfAbsent(index, () {
      final request = _loadEntry(_pages[index], pageFile(index));
      request.then<void>((_) {
        _inflight.remove(index);
      }, onError: (Object _, StackTrace __) {
        _inflight.remove(index);
      });
      return request;
    });
  }

  Future<File?> getComicInfo(File destination) async {
    if (!_ready) await init();
    final info = _comicInfo;
    if (info == null) return null;
    return _loadEntry(info, destination);
  }

  Future<File> _loadEntry(_ZipEntry entry, File target) async {
    _checkCanceled();
    if (await _validFile(target, entry.uncompressedSize, entry.crc)) {
      return target;
    }
    final header = await _fetchRange(entry.offset, entry.offset + 29);
    if (_u32(header, 0) != 0x04034b50) {
      throw const FormatException('Invalid ZIP local header');
    }
    final dataStart = entry.offset + 30 + _u16(header, 26) + _u16(header, 28);
    final compressed = await _fetchRange(dataStart, dataStart + entry.compressedSize - 1);
    final method = entry.method;
    final expectedSize = entry.uncompressedSize;
    final expectedCrc = entry.crc;
    final decoded = await Isolate.run(() {
      final bytes = method == 0
          ? compressed
          : Uint8List.fromList(ZLibCodec(raw: true).decode(compressed));
      if (bytes.length != expectedSize || _crc32(bytes) != expectedCrc) {
        throw const FormatException('ZIP entry checksum mismatch');
      }
      return bytes;
    });
    _checkCanceled();
    await target.parent.create(recursive: true);
    final partial = File('${target.path}.tmp');
    try {
      await partial.writeAsBytes(decoded, flush: true);
      _checkCanceled();
      if (await target.exists()) await target.delete();
      await partial.rename(target.path);
    } finally {
      if (await partial.exists()) await partial.delete();
    }
    return target;
  }

  Future<void> clear() async {
    if (pageDirectory != null) return;
    try {
      if (await _cacheDir.exists()) await _cacheDir.delete(recursive: true);
    } catch (error) {
      logger.e('CbzStream: error clearing cache: $error');
    }
  }

  Future<Uint8List> _fetchRange(int start, int end) async {
    _checkCanceled();
    if (end < start) throw const FormatException('Invalid ZIP byte range');
    final response = await _api.getItemDownloadRange(
      itemId: itemId, start: start, end: end, headers: headers,
      cancelToken: cancelToken,
    ).timeout(const Duration(seconds: 30));
    final range = response.headers.value('content-range');
    _checkRetryableStatus(response);
    if (response.statusCode != 206 || range != 'bytes $start-$end/$_totalSize') {
      throw const FormatException('Invalid ZIP byte-range response');
    }
    final bytes = response.data;
    if (bytes == null || bytes.length != end - start + 1) {
      throw const InterruptedDownload('Connection closed during ZIP byte range');
    }
    return bytes is Uint8List ? bytes : Uint8List.fromList(bytes);
  }

  void _checkRetryableStatus(Response<List<int>> response) {
    final status = response.statusCode;
    if (status == 408 || status == 429 || (status != null && status >= 500)) {
      throw DioException(
        requestOptions: response.requestOptions,
        response: response,
        type: DioExceptionType.badResponse,
      );
    }
  }

  int _u16(List<int> d, int o) => d[o] | (d[o + 1] << 8);
  int _u32(List<int> d, int o) =>
      d[o] | (d[o + 1] << 8) | (d[o + 2] << 16) | (d[o + 3] << 24);
}
