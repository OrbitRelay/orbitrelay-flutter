import '../protocol/ids.dart';
import '../protocol/message.dart';
import 'canvas_protocol.dart';

enum ClientStrokeLifecycle { active, completed, cancelled, removed }

final class CanvasDesynchronizedError implements Exception {
  const CanvasDesynchronizedError(this.message);

  final String message;

  @override
  String toString() => 'CanvasDesynchronizedError: $message';
}

final class ClientStrokeChunk {
  ClientStrokeChunk(this.index, Iterable<CanvasPoint> points)
    : points = List<CanvasPoint>.unmodifiable(points);

  final int index;
  final List<CanvasPoint> points;
}

final class ClientStrokeProjection {
  ClientStrokeProjection({
    required this.strokeId,
    required this.canvasId,
    required this.layerId,
    required this.sessionId,
    required this.creatorActorId,
    required this.tool,
    required this.style,
    required List<ClientStrokeChunk> chunks,
    required this.lifecycle,
    required this.createdAt,
  }) : chunks = List<ClientStrokeChunk>.unmodifiable(chunks);

  final StrokeId strokeId;
  final CanvasId canvasId;
  final LayerId layerId;
  final SessionId sessionId;
  final ActorId creatorActorId;
  final StrokeTool tool;
  final StrokeStyle style;
  final List<ClientStrokeChunk> chunks;
  final ClientStrokeLifecycle lifecycle;
  final OrbitRelayTimestamp createdAt;

  int get lastChunkIndex => chunks.last.index;

  ClientStrokeChunk? chunk(int index) {
    if (index < 0 || index >= chunks.length) {
      return null;
    }
    final candidate = chunks[index];
    return candidate.index == index ? candidate : null;
  }

  ClientStrokeProjection copyWith({
    List<ClientStrokeChunk>? chunks,
    ClientStrokeLifecycle? lifecycle,
  }) => ClientStrokeProjection(
    strokeId: strokeId,
    canvasId: canvasId,
    layerId: layerId,
    sessionId: sessionId,
    creatorActorId: creatorActorId,
    tool: tool,
    style: style,
    chunks: chunks ?? this.chunks,
    lifecycle: lifecycle ?? this.lifecycle,
    createdAt: createdAt,
  );
}

final class CanvasProjection {
  CanvasProjection({
    required this.sessionId,
    required this.canvasId,
    required this.layerId,
    required this.space,
  });

  final SessionId sessionId;
  final CanvasId canvasId;
  final LayerId layerId;
  final CanvasSpace space;
  final Map<StrokeId, ClientStrokeProjection> _strokes =
      <StrokeId, ClientStrokeProjection>{};

  Map<StrokeId, ClientStrokeProjection> get strokes =>
      Map<StrokeId, ClientStrokeProjection>.unmodifiable(_strokes);

  ClientStrokeProjection? stroke(StrokeId id) => _strokes[id];

  void clear() => _strokes.clear();

  void apply(CanvasEvent canvasEvent) {
    final event = canvasEvent.event;
    if (event.sessionId != sessionId) {
      throw const CanvasDesynchronizedError('Event belongs to another Session');
    }
    if (canvasEvent.payload.canvasId != canvasId) {
      throw const CanvasDesynchronizedError('Event belongs to another Canvas');
    }
    switch (canvasEvent.kind) {
      case CanvasEventKind.strokeBegan:
        _applyBegan(event, canvasEvent.payload as StrokeBeginPayload);
      case CanvasEventKind.strokePointsAppended:
        _applyAppend(canvasEvent.payload as StrokeAppendPayload);
      case CanvasEventKind.strokeCompleted:
        _applyCompleted(canvasEvent.payload as StrokeEndPayload);
      case CanvasEventKind.strokeCancelled:
        _applyCancelled(canvasEvent.payload as StrokeCancelPayload);
      case CanvasEventKind.strokeRemoved:
        _applyRemoved(canvasEvent.payload as StrokeRemovePayload);
    }
  }

  void _applyBegan(EventMessage event, StrokeBeginPayload payload) {
    if (payload.layerId != layerId) {
      throw const CanvasDesynchronizedError('Stroke began on an unknown Layer');
    }
    _validatePoints(payload.points);
    final existing = _strokes[payload.strokeId];
    if (existing != null) {
      final same =
          existing.canvasId == payload.canvasId &&
          existing.layerId == payload.layerId &&
          existing.creatorActorId == event.actorId &&
          existing.tool == payload.tool &&
          existing.style == payload.style &&
          _samePoints(existing.chunk(0)?.points, payload.points);
      if (same) {
        return;
      }
      throw const CanvasDesynchronizedError(
        'Duplicate Stroke began fact conflicts with local history',
      );
    }
    _strokes[payload.strokeId] = ClientStrokeProjection(
      strokeId: payload.strokeId,
      canvasId: payload.canvasId,
      layerId: payload.layerId,
      sessionId: event.sessionId,
      creatorActorId: event.actorId,
      tool: payload.tool,
      style: payload.style,
      chunks: <ClientStrokeChunk>[
        ClientStrokeChunk(payload.chunkIndex, payload.points),
      ],
      lifecycle: ClientStrokeLifecycle.active,
      createdAt: event.occurredAt,
    );
  }

  void _applyAppend(StrokeAppendPayload payload) {
    final existing = _requireStroke(payload.strokeId);
    final oldChunk = existing.chunk(payload.chunkIndex);
    if (oldChunk != null) {
      if (_samePoints(oldChunk.points, payload.points)) {
        return;
      }
      throw const CanvasDesynchronizedError(
        'Duplicate chunk contains different points',
      );
    }
    if (existing.lifecycle != ClientStrokeLifecycle.active) {
      throw const CanvasDesynchronizedError(
        'A new chunk arrived after the Stroke became terminal',
      );
    }
    if (payload.chunkIndex != existing.lastChunkIndex + 1) {
      throw CanvasDesynchronizedError(
        'Expected chunk ${existing.lastChunkIndex + 1}, received ${payload.chunkIndex}',
      );
    }
    _validatePoints(payload.points);
    _strokes[payload.strokeId] = existing.copyWith(
      chunks: <ClientStrokeChunk>[
        ...existing.chunks,
        ClientStrokeChunk(payload.chunkIndex, payload.points),
      ],
    );
  }

  void _applyCompleted(StrokeEndPayload payload) {
    final existing = _requireStroke(payload.strokeId);
    _validateTerminalIndex(existing, payload.finalChunkIndex);
    if (existing.lifecycle == ClientStrokeLifecycle.completed ||
        existing.lifecycle == ClientStrokeLifecycle.removed) {
      return;
    }
    if (existing.lifecycle != ClientStrokeLifecycle.active) {
      throw const CanvasDesynchronizedError(
        'Completed fact conflicts with the Stroke lifecycle',
      );
    }
    _strokes[payload.strokeId] = existing.copyWith(
      lifecycle: ClientStrokeLifecycle.completed,
    );
  }

  void _applyCancelled(StrokeCancelPayload payload) {
    final existing = _requireStroke(payload.strokeId);
    _validateTerminalIndex(existing, payload.finalChunkIndex);
    if (existing.lifecycle == ClientStrokeLifecycle.cancelled) {
      return;
    }
    if (existing.lifecycle != ClientStrokeLifecycle.active) {
      throw const CanvasDesynchronizedError(
        'Cancelled fact conflicts with the Stroke lifecycle',
      );
    }
    _strokes[payload.strokeId] = existing.copyWith(
      lifecycle: ClientStrokeLifecycle.cancelled,
    );
  }

  void _applyRemoved(StrokeRemovePayload payload) {
    final existing = _requireStroke(payload.strokeId);
    if (existing.lifecycle == ClientStrokeLifecycle.removed) {
      return;
    }
    if (existing.lifecycle != ClientStrokeLifecycle.completed) {
      throw const CanvasDesynchronizedError(
        'Only a completed Stroke can be removed',
      );
    }
    _strokes[payload.strokeId] = existing.copyWith(
      lifecycle: ClientStrokeLifecycle.removed,
    );
  }

  ClientStrokeProjection _requireStroke(StrokeId strokeId) {
    final existing = _strokes[strokeId];
    if (existing == null) {
      throw const CanvasDesynchronizedError(
        'Stroke fact arrived before Stroke began',
      );
    }
    if (existing.canvasId != canvasId || existing.sessionId != sessionId) {
      throw const CanvasDesynchronizedError('Stroke identity scope changed');
    }
    return existing;
  }

  void _validateTerminalIndex(ClientStrokeProjection stroke, int finalIndex) {
    if (finalIndex != stroke.lastChunkIndex) {
      throw CanvasDesynchronizedError(
        'Terminal index $finalIndex does not match ${stroke.lastChunkIndex}',
      );
    }
  }

  void _validatePoints(List<CanvasPoint> points) {
    if (points.any((point) => !space.contains(point))) {
      throw const CanvasDesynchronizedError(
        'Authoritative point is outside CanvasSpace',
      );
    }
  }
}

bool _samePoints(List<CanvasPoint>? left, List<CanvasPoint> right) {
  if (left == null || left.length != right.length) {
    return false;
  }
  for (var index = 0; index < left.length; index += 1) {
    if (left[index] != right[index]) {
      return false;
    }
  }
  return true;
}
