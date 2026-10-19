import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:jellybook/themes/theme_constants.dart';

/// Shared 36dp top bar and translucent concave corners.
/// Individual screens own their controls, title, and navigation behavior.
class JellyBookHeader extends StatelessWidget implements PreferredSizeWidget {
  const JellyBookHeader({
    super.key,
    required this.topInset,
    required this.children,
    this.alignment = AlignmentDirectional.topStart,
  });

  static const double toolbarHeight = 36;
  static const double _cornerRadius = 17.5;

  final double topInset;
  final List<Widget> children;
  final AlignmentGeometry alignment;

  @override
  Size get preferredSize => Size.fromHeight(topInset + toolbarHeight);

  @override
  Widget build(BuildContext context) {
    final background = FloatingSurfacePalette.topBarBackground(
      Theme.of(context).brightness,
    );
    return Container(
      color: background,
      padding: EdgeInsets.only(top: topInset),
      child: SizedBox(
        height: toolbarHeight,
        child: Stack(
          alignment: alignment,
          clipBehavior: Clip.none,
          children: [
            Positioned(
              left: 0,
              right: 0,
              bottom: -_cornerRadius,
              height: _cornerRadius,
              child: IgnorePointer(
                child: CustomPaint(
                  painter: _HeaderCornersPainter(color: background),
                ),
              ),
            ),
            ...children,
          ],
        ),
      ),
    );
  }
}

// Paint only the outer concave edges so covers can scroll behind the header.
class _HeaderCornersPainter extends CustomPainter {
  const _HeaderCornersPainter({required this.color});

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final r = math.min(size.height, size.width / 2);
    if (r <= 0) return;
    final paint = Paint()..color = color;
    final cornerRadius = Radius.circular(r);

    final left = Path()
      ..moveTo(0, 0)
      ..lineTo(r, 0)
      ..arcToPoint(Offset(0, r), radius: cornerRadius, clockwise: false)
      ..close();
    final right = Path()
      ..moveTo(size.width - r, 0)
      ..lineTo(size.width, 0)
      ..lineTo(size.width, r)
      ..arcToPoint(Offset(size.width - r, 0),
          radius: cornerRadius, clockwise: false)
      ..close();

    canvas.drawPath(left, paint);
    canvas.drawPath(right, paint);
  }

  @override
  bool shouldRepaint(covariant _HeaderCornersPainter oldDelegate) =>
      oldDelegate.color != color;
}
