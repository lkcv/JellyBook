import 'package:isar/isar.dart';

import 'package:kurage/models/app_settings.dart';

class AppSettingsStore {
  AppSettingsStore._();

  static late AppSettings current;
  static Future<void> _writes = Future<void>.value();

  static Future<void> initialize(Isar isar) async {
    final saved = await isar.appSettings.get(AppSettings.singletonId);
    if (saved != null) {
      current = saved;
      return;
    }

    current = AppSettings();
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
