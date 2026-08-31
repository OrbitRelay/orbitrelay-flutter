import '../protocol/ids.dart';
import 'canvas_projection.dart';
import 'canvas_protocol.dart';
import 'optimistic_canvas.dart';

enum CanvasHealth { healthy, desynchronized }

final class CanvasRenderStroke {
  CanvasRenderStroke({
    required this.strokeId,
    required this.tool,
    required this.style,
    required Iterable<CanvasPoint> points,
    required this.authoritative,
  }) : points = List<CanvasPoint>.unmodifiable(points);

  final StrokeId strokeId;
  final StrokeTool tool;
  final StrokeStyle style;
  final List<CanvasPoint> points;
  final bool authoritative;
}

final class CanvasRenderState {
  CanvasRenderState({
    required Iterable<CanvasRenderStroke> strokes,
    required this.health,
    this.message,
  }) : strokes = List<CanvasRenderStroke>.unmodifiable(strokes);

  factory CanvasRenderState.empty() => CanvasRenderState(
    strokes: const <CanvasRenderStroke>[],
    health: CanvasHealth.healthy,
  );

  factory CanvasRenderState.compose({
    required CanvasProjection projection,
    required OptimisticCanvas optimistic,
    required CanvasHealth health,
    String? message,
  }) {
    final renderStrokes = <CanvasRenderStroke>[];
    final authoritativeIds = <StrokeId>{};

    for (final stroke in projection.strokes.values) {
      authoritativeIds.add(stroke.strokeId);
      if (stroke.lifecycle == ClientStrokeLifecycle.cancelled ||
          stroke.lifecycle == ClientStrokeLifecycle.removed) {
        continue;
      }
      final points = <CanvasPoint>[
        for (final chunk in stroke.chunks) ...chunk.points,
      ];
      final local = optimistic.stroke(stroke.strokeId);
      if (local != null) {
        final chunkIndexes = local.chunks.keys.toList()..sort();
        for (final index in chunkIndexes) {
          if (index > stroke.lastChunkIndex) {
            points.addAll(local.chunks[index]!);
          }
        }
        points.addAll(local.pendingPoints);
      }
      renderStrokes.add(
        CanvasRenderStroke(
          strokeId: stroke.strokeId,
          tool: stroke.tool,
          style: stroke.style,
          points: points,
          authoritative: local == null,
        ),
      );
    }

    for (final local in optimistic.strokes.values) {
      if (authoritativeIds.contains(local.strokeId)) {
        continue;
      }
      final indexes = local.chunks.keys.toList()..sort();
      renderStrokes.add(
        CanvasRenderStroke(
          strokeId: local.strokeId,
          tool: local.tool,
          style: local.style,
          points: <CanvasPoint>[
            for (final index in indexes) ...local.chunks[index]!,
            ...local.pendingPoints,
          ],
          authoritative: false,
        ),
      );
    }
    renderStrokes.sort(
      (left, right) => left.strokeId.value.compareTo(right.strokeId.value),
    );
    return CanvasRenderState(
      strokes: renderStrokes,
      health: health,
      message: message,
    );
  }

  final List<CanvasRenderStroke> strokes;
  final CanvasHealth health;
  final String? message;
}
