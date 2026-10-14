import 'package:flutter/material.dart';

/// Shared translucent-surface colors. Light can also be reused by the
/// top bar later; Dark and AMOLED intentionally share the same charcoal.
class FloatingSurfacePalette {
  static const Color lightBase = Color(0xFFF4F5F7);
  static const Color darkBase = Color(0xFF242428);
  static const Color lightText = Color(0xFF24262A);
  static const Color darkText = Colors.white;

  static Color background(Brightness brightness, {double opacity = 0.94}) =>
      (brightness == Brightness.dark ? darkBase : lightBase)
          .withOpacity(opacity);

  static Color foreground(Brightness brightness) =>
      brightness == Brightness.dark ? darkText : lightText;
}

/// A single MaterialApp-level default. Individual SnackBars keep their own
/// messages, durations and actions, but inherit the same floating appearance.
SnackBarThemeData floatingSnackBarTheme(ThemeData theme) {
  final foreground =
      FloatingSurfacePalette.foreground(theme.brightness);

  return SnackBarThemeData(
    behavior: SnackBarBehavior.floating,
    backgroundColor:
        FloatingSurfacePalette.background(theme.brightness),
    contentTextStyle: (theme.textTheme.bodyMedium ?? const TextStyle())
        .copyWith(color: foreground),
    actionTextColor: theme.colorScheme.primary,
    disabledActionTextColor: foreground.withOpacity(0.38),
    closeIconColor: foreground.withOpacity(0.75),
    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(17)),
    insetPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
    elevation: 2,
  );
}
