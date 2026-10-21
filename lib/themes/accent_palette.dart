import 'package:flutter/material.dart';

/// Curated accent colors. Material generates the companion used by the Reader;
/// [gradientEnd] is an independent, hand-picked navigation-bar color.
class AccentOption {
  const AccentOption({
    required this.name,
    required this.color,
    required this.gradientEnd,
  });

  final String name;
  final Color color;
  final Color gradientEnd;
}

class AccentPalette {
  const AccentPalette._();

  static const defaultAccent = Color(0xFFAA5CC3);
  static const defaultGradientEnd = Color(0xFF00A4DC);

  static const options = <AccentOption>[
    AccentOption(
      name: 'Scarlet', color: Color(0xFFD23B35),
      gradientEnd: Color(0xFFF07A59),
    ),
    AccentOption(
      name: 'Raspberry', color: Color(0xFFBD335C),
      gradientEnd: Color(0xFFE97980),
    ),
    AccentOption(
      name: 'Tangerine', color: Color(0xFFEF8532),
      gradientEnd: Color(0xFFF5BD4C),
    ),
    AccentOption(
      name: 'Saffron', color: Color(0xFFF4C430),
      gradientEnd: Color(0xFFEF8532),
    ),
    AccentOption(
      name: 'Emerald', color: Color(0xFF258557),
      gradientEnd: Color(0xFF26B6A5),
    ),
    AccentOption(
      name: 'Sea Glass', color: Color(0xFF1BA89E),
      gradientEnd: Color(0xFF58C6AF),
    ),
    AccentOption(
      name: 'Sky Blue', color: Color(0xFF169CCC),
      gradientEnd: Color(0xFF4F78DD),
    ),
    AccentOption(
      name: 'Royal Blue', color: Color(0xFF356EC0),
      gradientEnd: Color(0xFF7B6ED8),
    ),
    AccentOption(
      name: 'Iris', color: Color(0xFF6562C6),
      gradientEnd: Color(0xFF9D74D8),
    ),
    AccentOption(
      name: 'Lavender', color: Color(0xFFA17BD8),
      gradientEnd: Color(0xFFC7A3E9),
    ),
    AccentOption(
      name: 'Pink', color: Color(0xFFE065A6),
      gradientEnd: Color(0xFFF39CC4),
    ),
    AccentOption(
      name: 'Steel', color: Color(0xFF65758B),
      gradientEnd: Color(0xFF97A5B9),
    ),
  ];

  static AccentOption? forColor(Color? color) {
    if (color == null) return null;
    for (final option in options) {
      if (option.color == color) return option;
    }
    return null;
  }
}
