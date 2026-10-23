import 'dart:async';

import 'package:flutter/material.dart';
import 'package:kurage/models/app_settings.dart';
import 'package:kurage/providers/app_settings_store.dart';

class LocaleChangeNotifier extends ChangeNotifier {
  LocaleChangeNotifier(AppSettings settings)
      : _locale = Locale(settings.localeString);

  Locale _locale;

  Locale get locale => _locale;

  set setLocale(String localeString) {
    if (_locale.toString() == localeString) return;
    _locale = Locale(localeString);
    notifyListeners();
    unawaited(AppSettingsStore.update((s) => s.localeString = localeString)
        .catchError((Object error) => debugPrint('Locale save failed: $error')));
  }
}
