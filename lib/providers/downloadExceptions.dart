import 'package:dio/dio.dart';

class DownloadCanceled implements Exception {
  const DownloadCanceled();

  @override
  String toString() => 'Download canceled';
}

void checkDownloadCanceled(CancelToken? token) {
  if (token?.isCancelled ?? false) throw const DownloadCanceled();
}

class InterruptedDownload implements Exception {
  const InterruptedDownload(this.reason);

  final String reason;

  @override
  String toString() => reason;
}
