import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Keep the existing DownloadQueue's Flutter process in foreground-service
/// priority while its FIFO queue drains. No second Dart isolate or worker.
/// Android may still terminate the process or deny service starts; Phase 2a
/// handles recovery on the next app launch.
class DownloadBackground {
  DownloadBackground._();

  static const MethodChannel _channel =
      MethodChannel('jellybook/download_background');
  static bool _started = false;

  static Future<void> start() async {
    if (!Platform.isAndroid || _started) return;
    try {
      _started = await _channel.invokeMethod<bool>('start') ?? false;
      if (!_started) {
        debugPrint('DownloadBackground: could not start foreground service');
      }
    } catch (error) {
      debugPrint('DownloadBackground: foreground service unavailable: $error');
    }
  }

  static Future<void> stop() async {
    if (!Platform.isAndroid || !_started) return;
    _started = false;
    try {
      await _channel.invokeMethod<void>('stop');
    } catch (error) {
      debugPrint('DownloadBackground: could not stop foreground service: $error');
    }
  }
}
