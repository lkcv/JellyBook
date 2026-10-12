import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:vector_math/vector_math_64.dart' show Matrix4;

/// Paints a transformed reader page. Raw pointers are tracked by the reader,
/// *above* PageView, so a second finger can be detected even if the first
/// finger is already dragging a different page.
class ReaderPinchZoom extends StatefulWidget {
  const ReaderPinchZoom({super.key, required this.child});

  final Widget child;

  @override
  State<ReaderPinchZoom> createState() => ReaderPinchZoomState();
}

/// Imperative, pointer-level transformation API used by the reader's Listener.
/// No gesture recognizer is involved, so one-finger paging stays immediate.
class ReaderPinchZoomState extends State<ReaderPinchZoom> {
  static const double _maxScale = 5;
  final TransformationController _transform = TransformationController();

  double _startScale = 1;
  double _startDistance = 1;
  Offset _sceneFocalPoint = Offset.zero;

  bool get isZoomed => _transform.value.getMaxScaleOnAxis() > 1.001;

  // A NEW, single-finger swipe may turn a page only when the enlarged image
  // was already at the corresponding edge when that finger touched down.
  // A positive movement drags the content right/down; a negative one left/up.
  bool atPanBoundary({required bool vertical, required bool positive}) {
    if (!isZoomed) return false;
    final size = _box?.size;
    if (size == null) return false;
    final matrix = _transform.value;
    final scale = matrix.getMaxScaleOnAxis();
    final translation = vertical ? matrix.storage[13] : matrix.storage[12];
    final length = vertical ? size.height : size.width;
    final minTranslation = length * (1 - scale);
    const tolerance = 1.0;
    return positive
        ? translation >= -tolerance
        : translation <= minTranslation + tolerance;
  }

  void reset() => _transform.value = Matrix4.identity();

  @override
  void dispose() {
    _transform.dispose();
    super.dispose();
  }

  RenderBox? get _box {
    final renderObject = context.findRenderObject();
    return renderObject is RenderBox && renderObject.hasSize
        ? renderObject
        : null;
  }

  bool containsGlobalPoint(Offset point) {
    final box = _box;
    return box != null &&
        (Offset.zero & box.size).contains(box.globalToLocal(point));
  }

  Offset _toLocal(Offset point) => _box?.globalToLocal(point) ?? point;

  void beginPinch(Offset firstGlobal, Offset secondGlobal) {
    final a = _toLocal(firstGlobal);
    final b = _toLocal(secondGlobal);
    final midpoint = (a + b) / 2;
    _startDistance = math.max(1, (a - b).distance);
    _startScale = _transform.value.getMaxScaleOnAxis();
    _sceneFocalPoint = _transform.toScene(midpoint);
  }

  void updatePinch(Offset firstGlobal, Offset secondGlobal) {
    final a = _toLocal(firstGlobal);
    final b = _toLocal(secondGlobal);
    final midpoint = (a + b) / 2;
    final distance = (a - b).distance;
    final scale = (_startScale * distance / _startDistance)
        .clamp(1.0, _maxScale)
        .toDouble();
    _setTransform(scale, midpoint - _sceneFocalPoint * scale);
  }

  void pan(Offset delta) {
    if (!isZoomed) return;
    final matrix = _transform.value;
    _setTransform(
      matrix.getMaxScaleOnAxis(),
      Offset(matrix.storage[12], matrix.storage[13]) + delta,
    );
  }

  void _setTransform(double scale, Offset translation) {
    final size = _box?.size ?? Size.zero;
    // Keep the enlarged page covering its original viewport.
    final minX = size.width * (1 - scale);
    final minY = size.height * (1 - scale);
    final dx = translation.dx.clamp(minX, 0.0).toDouble();
    final dy = translation.dy.clamp(minY, 0.0).toDouble();
    _transform.value = Matrix4.identity()
      ..translate(dx, dy)
      ..scale(scale);
  }

  @override
  Widget build(BuildContext context) {
    return ClipRect(
      child: AnimatedBuilder(
        animation: _transform,
        child: widget.child,
        builder: (context, child) => Transform(
          alignment: Alignment.topLeft,
          transform: _transform.value,
          child: child,
        ),
      ),
    );
  }
}
