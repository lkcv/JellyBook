import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

/// A short read is a connectivity failure, even if the HTTP stream ends
/// normally instead of reporting a SocketException.
class InterruptedDownload implements Exception {
  const InterruptedDownload(this.reason);
  final String reason;
  @override
  String toString() => reason;
}

// A socket can still close mid-body after the app has verified Jellyfin is
// online. Only retry genuine transport problems here; validation and disk
// failures must still be surfaced to the manager.
bool _isTransientBodyError(Object error) {
  if (error is SocketException || error is HttpException ||
      error is TimeoutException || error is HandshakeException) {
    return true;
  }
  if (error is! DioException) return false;
  if (error.error is FileSystemException || error.error is FormatException) {
    return false;
  }
  return error.type == DioExceptionType.connectionError ||
      error.type == DioExceptionType.connectionTimeout ||
      error.type == DioExceptionType.receiveTimeout ||
      error.type == DioExceptionType.sendTimeout ||
      error.type == DioExceptionType.unknown;
}

/// Keep incoming bytes in .part, with a small sidecar describing the HTTP
/// entity. Never expose the archive to extraction until it is complete.
Future<void> downloadResumableArchive({
  required Uri url,
  required Map<String, String> headers,
  required File destination,
  required void Function(double) onProgress,
}) async {
  final part = File('${destination.path}.part');
  final meta = File('${destination.path}.part.json');
  await destination.parent.create(recursive: true);

  final dio = Dio(BaseOptions(
    connectTimeout: const Duration(seconds: 15),
    receiveTimeout: const Duration(seconds: 30),
    // We handle 200/206/416 and all other statuses explicitly below.
    validateStatus: (_) => true,
  ));

  Future<void> discardPart() async {
    if (await part.exists()) await part.delete();
    if (await meta.exists()) await meta.delete();
  }

  try {
    // A finished HTTP transfer can outlive a crash during extraction.
    if (await destination.exists()) {
      onProgress(90);
      return;
    }

    // A changed/unsupported Range may restart once. Independently, one
    // interrupted *active* HTTP body may reconnect inline without switching
    // the job to Waiting. Keep these budgets separate and bounded.
    var rangeRestarts = 0;
    var inlineReconnects = 0;
    while (true) {
      final size = await part.exists() ? await part.length() : 0;
      Map<String, dynamic>? saved;
      if (await meta.exists()) {
        try {
          final decoded = jsonDecode(await meta.readAsString());
          if (decoded is Map<String, dynamic>) saved = decoded;
        } catch (_) {
          // An unparseable sidecar is not safe to resume.
        }
      }
      final sameEntity = size > 0 &&
          saved?['url'] == url.toString() &&
          saved?['total'] is int &&
          (saved!['total'] as int) > 0 &&
          size <= (saved['total'] as int);
      if (size > 0 && !sameEntity) await discardPart();

      final offset = sameEntity ? size : 0;
      final totalSaved = sameEntity ? saved!['total'] as int : 0;
      if (offset > 0 && offset == totalSaved) {
        // The last byte reached the file but the app stopped before rename.
        await part.rename(destination.path);
        if (await meta.exists()) await meta.delete();
        onProgress(90);
        return;
      }

      final requestHeaders = <String, String>{
        ...headers,
        // Byte ranges refer to uncompressed entity bytes.
        'Accept-Encoding': 'identity',
      };
      if (offset > 0) {
        requestHeaders['Range'] = 'bytes=$offset-';
        final validator = saved?['etag'] ?? saved?['lastModified'];
        if (validator is String && validator.isNotEmpty) {
          requestHeaders['If-Range'] = validator;
        }
      }

      final response = await dio.get<ResponseBody>(
        url.toString(),
        options: Options(headers: requestHeaders, responseType: ResponseType.stream),
      );
      final status = response.statusCode;
      if (status == 416 && offset > 0) {
        if (rangeRestarts++ >= 1) {
          throw const FormatException('Unable to restart changed download');
        }
        await discardPart();
        continue;
      }
      if (status != 200 && status != 206) {
        throw DioException(
          requestOptions: response.requestOptions,
          response: response,
          type: DioExceptionType.badResponse,
          message: 'Jellyfin returned HTTP $status',
        );
      }

      final contentRange = response.headers.value('content-range');
      final match = contentRange == null ? null :
          RegExp(r'^bytes (\d+)-(\d+)/(\d+)$').firstMatch(contentRange);
      final rangeStart = match == null ? null : int.parse(match.group(1)!);
      final rangeEnd = match == null ? null : int.parse(match.group(2)!);
      final rangeTotal = match == null ? null : int.parse(match.group(3)!);
      final append = status == 206 && offset > 0;
      if (status == 206 && (match == null || rangeStart != offset ||
          rangeEnd! < rangeStart! || rangeTotal! <= rangeEnd)) {
        // A mismatched Range must never be appended to saved bytes.
        if (offset == 0 || rangeRestarts++ >= 1) {
          throw const FormatException('Invalid Content-Range');
        }
        await discardPart();
        continue;
      }
      // A 200 in response to Range is a full replacement; truncate safely.
      final length = int.tryParse(response.headers.value('content-length') ?? '');
      final total = status == 206 ? rangeTotal : length;
      if (total == null || total <= 0) {
        throw const FormatException('Jellyfin did not supply a download length');
      }
      if (append && total != totalSaved) {
        if (rangeRestarts++ >= 1) {
          throw const FormatException('Unable to restart changed download');
        }
        await discardPart();
        continue;
      }
      if (append) {
        final oldTag = saved?['etag'];
        final newTag = response.headers.value('etag');
        final oldModified = saved?['lastModified'];
        final newModified = response.headers.value('last-modified');
        if ((oldTag is String && newTag != null && oldTag != newTag) ||
            (oldTag == null && oldModified is String &&
                newModified != null && oldModified != newModified)) {
          // Some proxies ignore If-Range. Never stitch two revisions together.
          if (rangeRestarts++ >= 1) {
            throw const FormatException('Unable to restart changed download');
          }
          await discardPart();
          continue;
        }
      }
      if (status == 206 && length != null &&
          length != rangeEnd! - rangeStart! + 1) {
        if (!append || rangeRestarts++ >= 1) {
          throw const FormatException('Inconsistent Content-Range length');
        }
        await discardPart();
        continue;
      }
      final file = await part.open(mode: append ? FileMode.append : FileMode.write);
      var received = append ? offset : 0;
      Object? bodyError;
      try {
        // Truncate the old bytes BEFORE changing the sidecar in a 200 reply.
        // A crash here can no longer label old bytes with new metadata.
        await meta.writeAsString(jsonEncode({
          'url': url.toString(),
          'total': total,
          'etag': response.headers.value('etag') ??
              (append && saved != null ? saved['etag'] : null),
          'lastModified': response.headers.value('last-modified') ??
              (append && saved != null ? saved['lastModified'] : null),
        }), flush: true);
        onProgress(received / total * 90);
        try {
          await for (final bytes in response.data!.stream) {
            await file.writeFrom(bytes);
            received += bytes.length;
            if (received > total) {
              throw const FormatException('Download larger than Content-Length');
            }
            onProgress(received / total * 90);
          }
        } catch (error, stack) {
          if (!_isTransientBodyError(error) || received <= offset ||
              inlineReconnects >= 1) {
            Error.throwWithStackTrace(error, stack);
          }
          // Preserve all received bytes; the next iteration will validate
          // Content-Range and append only if the server honors our offset.
          bodyError = error;
        }
      } finally {
        try {
          await file.flush();
        } finally {
          await file.close();
        }
      }
      if (bodyError != null || received != total) {
        if (received > offset && inlineReconnects < 1) {
          inlineReconnects++;
          debugPrint('ResumableTransfer: HTTP body interrupted after '
              '$received/$total bytes (${bodyError?.runtimeType ?? 'early EOF'}); '
              'continuing from retained bytes');
          continue;
        }
        if (bodyError != null) {
          throw bodyError;
        }
        throw const InterruptedDownload('Connection closed before transfer completed');
      }
      await part.rename(destination.path);
      if (await meta.exists()) await meta.delete();
      onProgress(90);
      return;
    }
  } finally {
    dio.close(force: true);
  }
}

/// Recover visible progress without depending on SharedPreferences writes for
/// every downloaded chunk. The .part file itself is the source of truth.
Future<double> retainedDownloadProgress(String archivePath) async {
  if (await File(archivePath).exists()) return 90;
  final part = File('$archivePath.part');
  final meta = File('$archivePath.part.json');
  if (!await part.exists() || !await meta.exists()) return 0;
  try {
    final data = jsonDecode(await meta.readAsString());
    if (data is! Map || data['total'] is! int) return 0;
    final total = data['total'] as int;
    if (total <= 0) return 0;
    return ((await part.length()) / total * 90).clamp(0.0, 90.0).toDouble();
  } catch (_) {
    return 0;
  }
}
