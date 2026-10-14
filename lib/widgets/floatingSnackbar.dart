import 'package:flutter/material.dart';
import 'package:jellybook/themes/themeConstants.dart';

/// The default floating snackbar appearance, shared by all app themes.
/// Its colors and opacity are defined alongside the app's theme palettes.
SnackBarThemeData floatingSnackBarTheme(ThemeData theme) {
  final foreground = FloatingSurfacePalette.foreground(theme.brightness);

  return SnackBarThemeData(
    behavior: SnackBarBehavior.floating,
    backgroundColor:
        FloatingSurfacePalette.snackBarBackground(theme.brightness),
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
