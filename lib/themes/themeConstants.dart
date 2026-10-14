// The purpose of this file is to define the themes for the app

import 'package:flutter/material.dart';

/// Shared surface palette for floating headers and snackbars.
/// System uses the resolved Light/Dark ThemeData; Dark and AMOLED intentionally
/// share snackbar charcoal, while their top bars remain translucent black.
class FloatingSurfacePalette {
  static const Color lightBase = Color(0xFFF4F5F7);
  static const Color darkSnackBarBase = Color(0xFF242428);
  static const Color lightText = Color(0xFF24262A);
  static const Color darkText = Colors.white;
  static const double topBarOpacity = 0.90;
  static const double snackBarOpacity = 0.94;

  static Color topBarBackground(Brightness brightness) =>
      (brightness == Brightness.dark ? Colors.black : lightBase)
          .withOpacity(topBarOpacity);

  static Color snackBarBackground(Brightness brightness) =>
      (brightness == Brightness.dark ? darkSnackBarBase : lightBase)
          .withOpacity(snackBarOpacity);

  static Color foreground(Brightness brightness) =>
      brightness == Brightness.dark ? darkText : lightText;
}

// Dark theme
ThemeData darkTheme = ThemeData(
  brightness: Brightness.dark,
  primaryColor: Color(0xFF1E1E1E),
  scaffoldBackgroundColor: Color(0xFF121212),
  cardColor: Color(0xFF1E1E1E),
  popupMenuTheme: PopupMenuThemeData(
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(12.0),
    ),
    color: Colors.grey[800],
  ),
  textTheme: TextTheme(
    headlineLarge: const TextStyle(
      color: Colors.white,
      fontSize: 24,
      fontWeight: FontWeight.bold,
    ),
    headlineMedium: const TextStyle(
      color: Colors.white,
      fontSize: 16,
      fontWeight: FontWeight.bold,
    ),
  ),
);

// Light theme
ThemeData lightTheme = ThemeData(
  brightness: Brightness.light,
  primaryColor: Color(0xFFF5F5F5),
  scaffoldBackgroundColor: Colors.white,
  cardColor: Color(0xFFFAFAFA),
  popupMenuTheme: PopupMenuThemeData(
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(12.0),
    ),
    color: Colors.grey[200],
  ),
);

// OLED theme - optimized for OLED screens
ThemeData oled = ThemeData(
  brightness: Brightness.dark,
  primaryColor: Colors.black,
  scaffoldBackgroundColor: Colors.black,
  cardColor: Colors.black,
  popupMenuTheme: PopupMenuThemeData(
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(12.0),
    ),
    color: Colors.grey[900],
  ),
  textTheme: TextTheme(
    headlineLarge: const TextStyle(
      color: Colors.white,
      fontSize: 24,
      fontWeight: FontWeight.bold,
    ),
    headlineMedium: const TextStyle(
      color: Colors.white,
      fontSize: 16,
      fontWeight: FontWeight.bold,
    ),
    headlineSmall: const TextStyle(
      color: Colors.white,
      fontSize: 12,
      fontWeight: FontWeight.bold,
    ),
    bodyLarge: const TextStyle(
      color: Colors.white,
      fontSize: 14,
    ),
    bodyMedium: const TextStyle(
      color: Colors.white,
      fontSize: 12,
    ),
    labelMedium: const TextStyle(
      color: Colors.white,
      fontSize: 10,
    ),
    labelSmall: const TextStyle(
      color: Colors.white,
      fontSize: 8,
    ),
  ),
);
