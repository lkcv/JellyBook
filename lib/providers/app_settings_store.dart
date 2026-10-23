import 'package:isar/isar.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:kurage/models/app_settings.dart';

class AppSettingsStore {
  AppSettingsStore._();

  static late AppSettings current;
  static Future<void> _writes = Future<void>.value();

  static Future<void> initialize(Isar isar, SharedPreferences prefs) async {
    final saved = await isar.appSettings.get(AppSettings.singletonId);
    if (saved != null) {
      current = saved;
      return;
    }

    final oldTheme = prefs.getString('themeSelection') ??
        prefs.getString('theme') ?? 'system';
    final cacheLimit = prefs.getInt('reader_cache_limit_mb');
    current = AppSettings(
      themeSelection: {'system', 'light', 'dark', 'amoled'}.contains(oldTheme)
          ? oldTheme
          : 'system',
      accentColor: prefs.getInt('accentColor'),
      readingDirection: prefs.getString('readingDirection') ?? 'LTR',
      localeString: prefs.getString('localeString') ?? 'en',
      // Absence means follow the current application default.
      readerCacheLimitMb: cacheLimit != null && cacheLimit >= 1 &&
              cacheLimit <= 1024 * 1024
          ? cacheLimit
          : null,
    );
    await isar.writeTxn(() async {
      await isar.appSettings.put(current);
    });
  }

  static Future<void> update(void Function(AppSettings settings) change) {
    change(current);
    final snapshot = current.copy();
    final isar = Isar.getInstance()!;
    final pending = _writes.then((_) async {
      await isar.writeTxn(() async {
        await isar.appSettings.put(snapshot);
      });
    });
    // A failed write must not permanently block subsequent settings updates.
    _writes = pending.catchError((Object _) {});
    return pending;
  }
}
