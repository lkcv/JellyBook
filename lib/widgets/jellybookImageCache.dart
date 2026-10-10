import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';

/// One shared disk cache for all covers.
class JellyBookCacheManager {
  static final CacheManager instance = CacheManager(
    Config(
      'jellybook_image_cache',
      stalePeriod: const Duration(days: 365),
      maxNrOfCacheObjects: 5000,
    ),
  );

  /// Total bytes currently occupied by the shared cover disk cache.
  /// Decoded Flutter images in RAM are not included.
  static Future<int> getUsageBytes() async {
    final directory = await IOFileSystem.createDirectory('jellybook_image_cache');
    var bytes = 0;
    try {
      await for (final entity
          in directory.list(recursive: true, followLinks: false)) {
        try {
          final stat = await entity.stat();
          if (stat.type == FileSystemEntityType.file) {
            bytes += stat.size;
          }
        } on FileSystemException {
          // A file may disappear while the cache manager is clearing it.
        }
      }
    } on FileSystemException {
      // Cache may be cleared while the directory is being enumerated.
    }
    return bytes;
  }
}

/// Ask Jellyfin for a smaller cover. Smaller files download and decode faster,
/// and far more of them fit in memory.
String coverUrl(String url) {
  if (!url.contains('/Images/Primary') || url.contains('maxWidth=')) return url;
  return '$url${url.contains('?') ? '&' : '?'}maxWidth=400';
}

/// Load a cover into the disk cache and the in-memory image cache.
Future<void> precacheCover(BuildContext context, String url) {
  if (url.isEmpty || url.toLowerCase() == 'asset' || !url.contains('http')) {
    return Future.value();
  }
  return precacheImage(
    CachedNetworkImageProvider(
      coverUrl(url),
      cacheManager: JellyBookCacheManager.instance,
    ),
    context,
  );
}
