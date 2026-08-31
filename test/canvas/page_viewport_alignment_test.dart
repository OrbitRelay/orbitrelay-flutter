import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:orbitrelay_client_flutter/canvas/canvas_protocol.dart';
import 'package:orbitrelay_client_flutter/canvas/viewport_transform.dart';

Offset pdfPixelToViewport({
  required Offset pixel,
  required Size rasterSize,
  required Rect contentRect,
}) => Offset(
  contentRect.left + pixel.dx / rasterSize.width * contentRect.width,
  contentRect.top + pixel.dy / rasterSize.height * contentRect.height,
);

void main() {
  final cases = <(CanvasSpace, Size, Rect)>[
    (
      CanvasSpace(400, 600),
      const Size(1200, 600),
      const Rect.fromLTWH(400, 0, 400, 600),
    ),
    (
      CanvasSpace(400, 600),
      const Size(300, 800),
      const Rect.fromLTWH(0, 175, 300, 450),
    ),
    (
      CanvasSpace(600, 400),
      const Size(600, 900),
      const Rect.fromLTWH(0, 250, 600, 400),
    ),
    (
      CanvasSpace(600, 400),
      const Size(1000, 300),
      const Rect.fromLTWH(275, 0, 450, 300),
    ),
  ];

  test('PDF raster, Canvas paint, and Pointer inverse share contentRect', () {
    for (final entry in cases) {
      final transform = ViewportTransform(
        space: entry.$1,
        viewportSize: entry.$2,
      );
      expect(transform.canvasRect, entry.$3);
      final logical = CanvasPoint(
        entry.$1.width * 0.25,
        entry.$1.height * 0.75,
      );
      final canvasPaint = transform.canvasToViewport(logical);
      final pdfPixel = Offset(
        logical.x / entry.$1.width * 1200,
        logical.y / entry.$1.height * 1200,
      );
      final pdfVisual = pdfPixelToViewport(
        pixel: pdfPixel,
        rasterSize: const Size(1200, 1200),
        contentRect: transform.canvasRect,
      );
      expect(pdfVisual, canvasPaint);
      final pointerLogical = transform.viewportToCanvas(canvasPaint);
      expect(pointerLogical.x, closeTo(logical.x, 1e-12));
      expect(pointerLogical.y, closeTo(logical.y, 1e-12));
    }
  });

  test('resize changes only the shared contain transform', () {
    final space = CanvasSpace(400, 600);
    final point = CanvasPoint(100, 150);
    final wide = ViewportTransform(
      space: space,
      viewportSize: const Size(1000, 600),
    );
    final narrow = ViewportTransform(
      space: space,
      viewportSize: const Size(300, 800),
    );
    expect(wide.canvasToViewport(point), const Offset(400, 150));
    expect(narrow.canvasToViewport(point), const Offset(75, 287.5));
    expect(wide.containsViewportPoint(const Offset(100, 150)), isFalse);
    expect(narrow.containsViewportPoint(const Offset(75, 100)), isFalse);
  });
}
