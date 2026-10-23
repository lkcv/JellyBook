import 'package:isar/isar.dart';

part 'app_settings.g.dart';

@Collection(accessor: 'appSettings')
class AppSettings {
  static const Id singletonId = 1;

  Id isarId = singletonId;
  String themeSelection;
  int? accentColor;
  String readingDirection;
  String localeString;
  int? readerCacheLimitMb;

  AppSettings({
    this.themeSelection = 'system',
    this.accentColor,
    this.readingDirection = 'LTR',
    this.localeString = 'en',
    this.readerCacheLimitMb,
  });

  AppSettings copy() => AppSettings(
        themeSelection: themeSelection,
        accentColor: accentColor,
        readingDirection: readingDirection,
        localeString: localeString,
        readerCacheLimitMb: readerCacheLimitMb,
      );
}
