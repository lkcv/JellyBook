import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:jellybook/themes/accent_palette.dart';

class ThemeChangeNotifier extends ChangeNotifier {
  ThemeChangeNotifier(BuildContext context, SharedPreferences prefs)
      : _prefs = prefs,
        _accentColor = prefs.getInt('accentColor') == null
            ? null
            : Color(prefs.getInt('accentColor')!) {
    _themeMode = (prefs.getString('theme') ?? 'dark').toLowerCase();
    _theme = _buildTheme(_themeMode);
  }

  static const Color defaultAccent = AccentPalette.defaultAccent;

  final SharedPreferences _prefs;
  Color? _accentColor;
  String _themeMode = 'dark';
  late ThemeData _theme;

  Color? get accentColor => _accentColor;
  ThemeData get getTheme => _theme;

  Future<String> get getThemeName async {
    SharedPreferences prefs = await SharedPreferences.getInstance();
    String theme = prefs.getString("theme") ?? "dark";
    switch (theme.toLowerCase()) {
      case "dark":
        return "Dark";
      case "light":
        return "Light";
      case "amoled":
        return "Amoled";
      case "system":
        return "System";
      default:
        return "Dark";
    }
  }

  set setTheme(String theme) {
    _themeMode = theme;
    _theme = _buildTheme(theme);
    notifyListeners();
    _prefs.setString('theme', theme);
  }

  set setAccentColor(Color? color) {
    if (_accentColor?.toARGB32() == color?.toARGB32()) return;
    _accentColor = color;
    _theme = _buildTheme(_themeMode);
    notifyListeners();
    if (color == null) {
      _prefs.remove('accentColor');
    } else {
      _prefs.setInt('accentColor', color.toARGB32());
    }
  }

  // Flutter's stock light scheme assigns the deep and pale purples to the
  // opposite roles from the dark theme. Normalize the color pairs at the
  // source, so every widget can continue using the usual scheme roles.
  static ColorScheme _defaultScheme(ColorScheme scheme) {
    if (scheme.brightness != Brightness.light) return scheme;
    return scheme.copyWith(
      primary: scheme.primaryContainer,
      onPrimary: scheme.onPrimaryContainer,
      primaryContainer: scheme.primary,
      onPrimaryContainer: scheme.onPrimary,
    );
  }

  // For Settings previews: use the actual *default* roles even when a
  // different accent is currently selected.
  static ColorScheme defaultColorScheme(Brightness brightness) {
    final theme = brightness == Brightness.light
        ? ThemeData.light(useMaterial3: true)
        : ThemeData.dark(useMaterial3: true);
    return _defaultScheme(theme.colorScheme);
  }

  ThemeData _buildTheme(String mode) {
    final ThemeData base;
    switch (mode) {
      case 'light':
        base = ThemeData.light(useMaterial3: true);
        break;
      case 'amoled':
        base = oledTheme;
        break;
      case 'system':
        base = WidgetsBinding.instance.platformDispatcher.platformBrightness ==
                Brightness.light
            ? ThemeData.light(useMaterial3: true)
            : ThemeData.dark(useMaterial3: true);
        break;
      default:
        base = ThemeData.dark(useMaterial3: true);
    }
    final accent = _accentColor;
    if (accent == null) {
      if (base.brightness == Brightness.dark) return base;
      return base.copyWith(colorScheme: _defaultScheme(base.colorScheme));
    }

    // Keep Material's two-tone color generation, including the Reader's
    // separate slider/thumbnail and page-counter colors.
    final palette = ColorScheme.fromSeed(
      seedColor: accent,
      brightness: base.brightness,
    );
    return base.copyWith(
      colorScheme: base.colorScheme.copyWith(
        primary: palette.primary,
        onPrimary: palette.onPrimary,
        primaryContainer: accent,
        // Keep accent-container foregrounds consistent across theme modes.
        onPrimaryContainer: Colors.white,
        inversePrimary: palette.inversePrimary,
        secondary: palette.secondary,
        onSecondary: palette.onSecondary,
        secondaryContainer: palette.secondaryContainer,
        onSecondaryContainer: palette.onSecondaryContainer,
      ),
    );
  }

  // oled theme
  final ThemeData oledTheme = ThemeData(
    useMaterial3: true,
    brightness: Brightness.dark,
    scaffoldBackgroundColor: Colors.black,
    primarySwatch: Colors.blue,
    primaryColor: Colors.black,
    textTheme: const TextTheme(
      displayLarge: TextStyle(color: Colors.white),
      displayMedium: TextStyle(color: Colors.white),
      displaySmall: TextStyle(color: Colors.white),
    ),
    cardTheme: const CardThemeData(
      color: Colors.black,
      shadowColor: Colors.white,
    ),
    cardColor: Colors.black,
    buttonTheme: const ButtonThemeData(
      buttonColor: Colors.blue,
      colorScheme: ColorScheme.dark(),
      textTheme: ButtonTextTheme.primary,
    ),
    listTileTheme: const ListTileThemeData(
      tileColor: Colors.transparent,
      iconColor: Colors.white,
      textColor: Colors.white,
    ),
    dividerColor: Colors.white,
    drawerTheme: const DrawerThemeData(
      backgroundColor: Colors.black,
    ),
    bottomNavigationBarTheme: const BottomNavigationBarThemeData(
      backgroundColor: Colors.black,
      selectedItemColor: Colors.blue,
      unselectedItemColor: Colors.white,
    ),
  );
}
