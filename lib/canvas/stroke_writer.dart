import '../protocol/ids.dart';
import 'canvas_protocol.dart';

typedef ChunkSubmitter = bool Function(int index, List<CanvasPoint> points);

final class StrokeWriter {
  StrokeWriter({required this.strokeId});

  final StrokeId strokeId;
  final List<CanvasPoint> _pending = <CanvasPoint>[];
  int _nextChunkIndex = 1;

  List<CanvasPoint> get pendingPoints =>
      List<CanvasPoint>.unmodifiable(_pending);
  int get nextChunkIndex => _nextChunkIndex;
  int get lastSubmittedChunkIndex => _nextChunkIndex - 1;

  void addPoint(CanvasPoint point) => _pending.add(point);

  bool flush(ChunkSubmitter submit) {
    while (_pending.isNotEmpty) {
      final count = _pending.length.clamp(1, maxPointsPerChunk);
      final batch = List<CanvasPoint>.unmodifiable(_pending.take(count));
      if (!submit(_nextChunkIndex, batch)) {
        return false;
      }
      _pending.removeRange(0, count);
      _nextChunkIndex += 1;
    }
    return true;
  }
}
