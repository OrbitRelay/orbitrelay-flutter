import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:orbitrelay_client_flutter/canvas/canvas_protocol.dart';
import 'package:orbitrelay_client_flutter/canvas/canvas_render_state.dart';
import 'package:orbitrelay_client_flutter/canvas/viewport_transform.dart';
import 'package:orbitrelay_client_flutter/ui/canvas_painter.dart';

Future<int> _centerAlpha({required bool paintSurface}) async {
  const size = ui.Size(100, 100);
  final recorder = ui.PictureRecorder();
  CanvasPainter(
    state: CanvasRenderState.empty(),
    transform: ViewportTransform(
      space: CanvasSpace(100, 100),
      viewportSize: size,
    ),
    paintSurface: paintSurface,
  ).paint(ui.Canvas(recorder), size);
  final picture = recorder.endRecording();
  final image = await picture.toImage(100, 100);
  picture.dispose();
  final bytes = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
  image.dispose();
  if (bytes == null) {
    throw StateError('CanvasPainter did not produce RGBA pixels');
  }
  return bytes.getUint8((50 * 100 + 50) * 4 + 3);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('Document overlay leaves the PDF raster visible', () async {
    expect(await _centerAlpha(paintSurface: false), 0);
    expect(await _centerAlpha(paintSurface: true), 255);
  });
}
