import 'package:flutter_test/flutter_test.dart';
import 'package:orbitrelay_client_flutter/canvas/canvas_projection.dart';
import 'package:orbitrelay_client_flutter/canvas/canvas_protocol.dart';
import 'package:orbitrelay_client_flutter/canvas/optimistic_canvas.dart';
import 'package:orbitrelay_client_flutter/protocol/ids.dart';

void main() {
  final canvas = CanvasId.parse('33333333-3333-4333-8333-333333333333');
  final layer = LayerId.parse('44444444-4444-4444-8444-444444444444');
  final stroke = StrokeId.parse('55555555-5555-4555-8555-555555555555');

  test(
    'own authoritative chunks reconcile without a duplicate local chunk',
    () {
      final optimistic = OptimisticCanvas();
      final begin = StrokeBeginPayload(
        canvasId: canvas,
        layerId: layer,
        strokeId: stroke,
        tool: StrokeTool.pen,
        style: StrokeStyle(width: 4, color: const RgbaColor.black()),
        points: <CanvasPoint>[CanvasPoint(1, 1)],
      );
      optimistic.begin(begin);
      optimistic.reconcileChunk(stroke, 0, begin.points);
      expect(optimistic.stroke(stroke), isNotNull);
      optimistic.reconcileTerminal(stroke);
      expect(optimistic.stroke(stroke), isNull);
    },
  );

  test('failed append removes only the optimistic suffix', () {
    final optimistic = OptimisticCanvas();
    final begin = StrokeBeginPayload(
      canvasId: canvas,
      layerId: layer,
      strokeId: stroke,
      tool: StrokeTool.pen,
      style: StrokeStyle(width: 4, color: const RgbaColor.black()),
      points: <CanvasPoint>[CanvasPoint(1, 1)],
    );
    optimistic.begin(begin);
    optimistic.appendPending(stroke, CanvasPoint(2, 2));
    optimistic.promotePending(stroke, 1, <CanvasPoint>[CanvasPoint(2, 2)]);
    optimistic.failFrom(stroke, 1);
    expect(optimistic.stroke(stroke)!.chunks, hasLength(1));
    expect(optimistic.stroke(stroke)!.chunks.containsKey(1), isFalse);
  });

  test('reconciliation accepts adjacent Rust/Dart f64 spellings', () {
    final optimistic = OptimisticCanvas();
    final begin = StrokeBeginPayload(
      canvasId: canvas,
      layerId: layer,
      strokeId: stroke,
      tool: StrokeTool.pen,
      style: StrokeStyle(width: 4, color: const RgbaColor.black()),
      points: <CanvasPoint>[CanvasPoint(963.0769230769231, 246.16370567908652)],
    );
    optimistic.begin(begin);
    expect(
      () => optimistic.reconcileChunk(stroke, 0, <CanvasPoint>[
        CanvasPoint(963.0769230769232, 246.16370567908652),
      ]),
      returnsNormally,
    );
    expect(optimistic.stroke(stroke)!.chunks, isEmpty);
  });

  test('reconciliation still rejects meaningful geometry changes', () {
    final optimistic = OptimisticCanvas();
    final begin = StrokeBeginPayload(
      canvasId: canvas,
      layerId: layer,
      strokeId: stroke,
      tool: StrokeTool.pen,
      style: StrokeStyle(width: 4, color: const RgbaColor.black()),
      points: <CanvasPoint>[CanvasPoint(1, 1)],
    );
    optimistic.begin(begin);
    expect(
      () => optimistic.reconcileChunk(stroke, 0, <CanvasPoint>[
        CanvasPoint(1.01, 1),
      ]),
      throwsA(isA<CanvasDesynchronizedError>()),
    );
  });
}
