import '../protocol/ids.dart';
import 'canvas_projection.dart';
import 'canvas_protocol.dart';

enum TerminalIntent { complete, cancel }

final class LocalOptimisticStroke {
  LocalOptimisticStroke({
    required this.strokeId,
    required this.canvasId,
    required this.layerId,
    required this.tool,
    required this.style,
    required this.chunks,
  });

  final StrokeId strokeId;
  final CanvasId canvasId;
  final LayerId layerId;
  final StrokeTool tool;
  final StrokeStyle style;
  final Map<int, List<CanvasPoint>> chunks;
  final List<CanvasPoint> pendingPoints = <CanvasPoint>[];
  TerminalIntent? terminalIntent;
}

final class OptimisticCanvas {
  final Map<StrokeId, LocalOptimisticStroke> _strokes =
      <StrokeId, LocalOptimisticStroke>{};

  Map<StrokeId, LocalOptimisticStroke> get strokes =>
      Map<StrokeId, LocalOptimisticStroke>.unmodifiable(_strokes);

  LocalOptimisticStroke? stroke(StrokeId id) => _strokes[id];

  void begin(StrokeBeginPayload payload) {
    if (_strokes.containsKey(payload.strokeId)) {
      throw StateError('Optimistic Stroke already exists');
    }
    _strokes[payload.strokeId] = LocalOptimisticStroke(
      strokeId: payload.strokeId,
      canvasId: payload.canvasId,
      layerId: payload.layerId,
      tool: payload.tool,
      style: payload.style,
      chunks: <int, List<CanvasPoint>>{
        0: List<CanvasPoint>.unmodifiable(payload.points),
      },
    );
  }

  void appendPending(StrokeId strokeId, CanvasPoint point) {
    _require(strokeId).pendingPoints.add(point);
  }

  void promotePending(
    StrokeId strokeId,
    int chunkIndex,
    List<CanvasPoint> points,
  ) {
    final stroke = _require(strokeId);
    if (stroke.pendingPoints.length < points.length ||
        !_samePointPrefix(stroke.pendingPoints, points)) {
      throw StateError('Optimistic pending points do not match flushed chunk');
    }
    stroke.pendingPoints.removeRange(0, points.length);
    stroke.chunks[chunkIndex] = List<CanvasPoint>.unmodifiable(points);
  }

  void markTerminal(StrokeId strokeId, TerminalIntent intent) {
    _require(strokeId).terminalIntent = intent;
  }

  void reconcileChunk(StrokeId strokeId, int index, List<CanvasPoint> points) {
    final stroke = _strokes[strokeId];
    if (stroke == null) {
      return;
    }
    final optimistic = stroke.chunks[index];
    if (optimistic == null) {
      return;
    }
    if (!_samePointLists(optimistic, points)) {
      throw CanvasDesynchronizedError(
        'Authoritative chunk $index conflicts with optimistic geometry '
        '(local points: ${optimistic.length}, authoritative points: '
        '${points.length}, first mismatch: '
        '${_firstPointMismatch(optimistic, points)})',
      );
    }
    stroke.chunks.remove(index);
  }

  void reconcileTerminal(StrokeId strokeId) {
    final stroke = _strokes[strokeId];
    if (stroke == null) {
      return;
    }
    stroke.terminalIntent = null;
    _strokes.remove(strokeId);
  }

  void failFrom(StrokeId strokeId, int chunkIndex) {
    final stroke = _strokes[strokeId];
    if (stroke == null) {
      return;
    }
    stroke.chunks.removeWhere((index, _) => index >= chunkIndex);
    stroke.pendingPoints.clear();
    stroke.terminalIntent = null;
    if (stroke.chunks.isEmpty) {
      _strokes.remove(strokeId);
    }
  }

  void remove(StrokeId strokeId) => _strokes.remove(strokeId);

  void clear() => _strokes.clear();

  LocalOptimisticStroke _require(StrokeId id) {
    final stroke = _strokes[id];
    if (stroke == null) {
      throw StateError('Optimistic Stroke does not exist');
    }
    return stroke;
  }
}

bool _samePointPrefix(List<CanvasPoint> available, List<CanvasPoint> prefix) {
  for (var index = 0; index < prefix.length; index += 1) {
    if (available[index] != prefix[index]) {
      return false;
    }
  }
  return true;
}

bool _samePointLists(List<CanvasPoint> left, List<CanvasPoint> right) {
  if (left.length != right.length) {
    return false;
  }
  for (var index = 0; index < left.length; index += 1) {
    if (!_sameWireNumber(left[index].x, right[index].x) ||
        !_sameWireNumber(left[index].y, right[index].y)) {
      return false;
    }
  }
  return true;
}

// Rust and Dart can choose adjacent decimal spellings for the same f64 after
// a JSON parse/serialize round trip. Keep reconciliation tolerant to that
// wire-level noise while still rejecting meaningful geometry changes.
bool _sameWireNumber(double left, double right) {
  final difference = (left - right).abs();
  final scale = left.abs() > right.abs() ? left.abs() : right.abs();
  return difference <= 1e-12 * (scale > 1 ? scale : 1);
}

String _firstPointMismatch(List<CanvasPoint> left, List<CanvasPoint> right) {
  final sharedLength = left.length < right.length ? left.length : right.length;
  for (var index = 0; index < sharedLength; index += 1) {
    if (left[index] != right[index]) {
      return index.toString();
    }
  }
  return left.length == right.length ? 'none' : sharedLength.toString();
}
