import 'dart:ui';

import 'canvas_protocol.dart';

final class ViewportTransform {
  ViewportTransform({required this.space, required this.viewportSize})
    : scale = _scale(space, viewportSize),
      offset = _offset(space, viewportSize);

  final CanvasSpace space;
  final Size viewportSize;
  final double scale;
  final Offset offset;

  Rect get canvasRect => Rect.fromLTWH(
    offset.dx,
    offset.dy,
    space.width * scale,
    space.height * scale,
  );

  Offset canvasToViewport(CanvasPoint point) =>
      Offset(offset.dx + point.x * scale, offset.dy + point.y * scale);

  CanvasPoint viewportToCanvas(Offset point) => CanvasPoint(
    (point.dx - offset.dx) / scale,
    (point.dy - offset.dy) / scale,
  );

  bool containsViewportPoint(Offset point) {
    final rect = canvasRect;
    return point.dx >= rect.left &&
        point.dx <= rect.right &&
        point.dy >= rect.top &&
        point.dy <= rect.bottom;
  }

  static double _scale(CanvasSpace space, Size viewport) {
    if (viewport.width <= 0 || viewport.height <= 0) {
      return 1;
    }
    return (viewport.width / space.width).clamp(
      0,
      viewport.height / space.height,
    );
  }

  static Offset _offset(CanvasSpace space, Size viewport) {
    final scale = _scale(space, viewport);
    return Offset(
      (viewport.width - space.width * scale) / 2,
      (viewport.height - space.height * scale) / 2,
    );
  }
}
