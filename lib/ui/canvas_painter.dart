import 'package:flutter/material.dart';

import '../canvas/canvas_render_state.dart';
import '../canvas/viewport_transform.dart';

final class CanvasPainter extends CustomPainter {
  const CanvasPainter({
    required this.state,
    required this.transform,
    this.paintSurface = true,
  });

  final CanvasRenderState state;
  final ViewportTransform transform;
  final bool paintSurface;

  @override
  void paint(Canvas canvas, Size size) {
    if (paintSurface) {
      canvas.drawRect(
        Offset.zero & size,
        Paint()..color = const Color(0xFFE2E5E1),
      );
      canvas.drawRect(
        transform.canvasRect,
        Paint()..color = const Color(0xFFFFFFFF),
      );
    }
    canvas.save();
    canvas.clipRect(transform.canvasRect);
    for (final stroke in state.strokes) {
      if (stroke.points.isEmpty) {
        continue;
      }
      final color = Color.fromARGB(
        stroke.style.color.alpha,
        stroke.style.color.red,
        stroke.style.color.green,
        stroke.style.color.blue,
      );
      final width = stroke.style.width * transform.scale;
      final paint = Paint()
        ..color = color
        ..strokeWidth = width
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round
        ..style = PaintingStyle.stroke
        ..isAntiAlias = true;
      final first = transform.canvasToViewport(stroke.points.first);
      if (stroke.points.length == 1) {
        canvas.drawCircle(first, width / 2, Paint()..color = color);
        continue;
      }
      final path = Path()..moveTo(first.dx, first.dy);
      for (final point in stroke.points.skip(1)) {
        final offset = transform.canvasToViewport(point);
        path.lineTo(offset.dx, offset.dy);
      }
      canvas.drawPath(path, paint);
    }
    canvas.restore();
    canvas.drawRect(
      transform.canvasRect,
      Paint()
        ..color = const Color(0xFFADB4AE)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1,
    );
  }

  @override
  bool shouldRepaint(CanvasPainter oldDelegate) =>
      oldDelegate.state != state ||
      oldDelegate.transform.viewportSize != transform.viewportSize ||
      oldDelegate.paintSurface != paintSurface;
}
