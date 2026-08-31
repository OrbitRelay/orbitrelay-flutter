import '../protocol/error.dart';
import '../protocol/ids.dart';
import '../protocol/message.dart';

const int maxPointsPerChunk = 256;

const String strokeBeginActionType = 'canvas.stroke.begin';
const String strokeAppendActionType = 'canvas.stroke.append';
const String strokeEndActionType = 'canvas.stroke.end';
const String strokeCancelActionType = 'canvas.stroke.cancel';
const String strokeRemoveActionType = 'canvas.stroke.remove';

const String strokeBeganEventType = 'canvas.stroke.began';
const String strokePointsAppendedEventType = 'canvas.stroke.points_appended';
const String strokeCompletedEventType = 'canvas.stroke.completed';
const String strokeCancelledEventType = 'canvas.stroke.cancelled';
const String strokeRemovedEventType = 'canvas.stroke.removed';

const List<String> canvasEventTypes = <String>[
  strokeBeganEventType,
  strokeCancelledEventType,
  strokeCompletedEventType,
  strokePointsAppendedEventType,
  strokeRemovedEventType,
];

enum StrokeTool { pen }

enum CanvasEventKind {
  strokeBegan,
  strokePointsAppended,
  strokeCompleted,
  strokeCancelled,
  strokeRemoved,
}

final class CanvasSpace {
  CanvasSpace(this.width, this.height) {
    if (!width.isFinite || width <= 0 || !height.isFinite || height <= 0) {
      throw ArgumentError('Canvas dimensions must be finite and positive');
    }
  }

  final double width;
  final double height;

  bool contains(CanvasPoint point) =>
      point.x >= 0 && point.x <= width && point.y >= 0 && point.y <= height;
}

final class CanvasPoint {
  CanvasPoint(this.x, this.y) {
    if (!x.isFinite || !y.isFinite) {
      throw ArgumentError('Canvas coordinates must be finite');
    }
  }

  final double x;
  final double y;

  Map<String, Object?> toJson() => <String, Object?>{'x': x, 'y': y};

  @override
  bool operator ==(Object other) =>
      other is CanvasPoint && other.x == x && other.y == y;

  @override
  int get hashCode => Object.hash(x, y);
}

final class RgbaColor {
  const RgbaColor({
    required this.red,
    required this.green,
    required this.blue,
    required this.alpha,
  }) : assert(red >= 0 && red <= 255),
       assert(green >= 0 && green <= 255),
       assert(blue >= 0 && blue <= 255),
       assert(alpha >= 0 && alpha <= 255);

  const RgbaColor.black() : this(red: 18, green: 20, blue: 24, alpha: 255);

  final int red;
  final int green;
  final int blue;
  final int alpha;

  Map<String, Object?> toJson() => <String, Object?>{
    'red': red,
    'green': green,
    'blue': blue,
    'alpha': alpha,
  };

  @override
  bool operator ==(Object other) =>
      other is RgbaColor &&
      other.red == red &&
      other.green == green &&
      other.blue == blue &&
      other.alpha == alpha;

  @override
  int get hashCode => Object.hash(red, green, blue, alpha);
}

final class StrokeStyle {
  StrokeStyle({required this.width, required this.color}) {
    if (!width.isFinite || width <= 0) {
      throw ArgumentError.value(width, 'width', 'must be finite and positive');
    }
  }

  final double width;
  final RgbaColor color;

  Map<String, Object?> toJson() => <String, Object?>{
    'width': width,
    'color': color.toJson(),
  };

  @override
  bool operator ==(Object other) =>
      other is StrokeStyle && other.width == width && other.color == color;

  @override
  int get hashCode => Object.hash(width, color);
}

sealed class CanvasActionPayload {
  const CanvasActionPayload();

  CanvasId get canvasId;
  StrokeId get strokeId;
  String get actionType;
  int? get correlationChunkIndex;
  Map<String, Object?> toJson();
}

final class StrokeBeginPayload extends CanvasActionPayload {
  StrokeBeginPayload({
    required this.canvasId,
    required this.layerId,
    required this.strokeId,
    required this.tool,
    required this.style,
    required Iterable<CanvasPoint> points,
    this.chunkIndex = 0,
  }) : points = List<CanvasPoint>.unmodifiable(points) {
    if (chunkIndex != 0) {
      throw ArgumentError.value(
        chunkIndex,
        'chunkIndex',
        'begin must use zero',
      );
    }
    _validatePointCount(this.points);
  }

  @override
  final CanvasId canvasId;
  final LayerId layerId;
  @override
  final StrokeId strokeId;
  final StrokeTool tool;
  final StrokeStyle style;
  final int chunkIndex;
  final List<CanvasPoint> points;

  @override
  String get actionType => strokeBeginActionType;

  @override
  int get correlationChunkIndex => chunkIndex;

  @override
  Map<String, Object?> toJson() => <String, Object?>{
    'canvas_id': canvasId.value,
    'layer_id': layerId.value,
    'stroke_id': strokeId.value,
    'tool': tool.name,
    'style': style.toJson(),
    'chunk_index': chunkIndex,
    'points': points.map((point) => point.toJson()).toList(growable: false),
  };
}

final class StrokeAppendPayload extends CanvasActionPayload {
  StrokeAppendPayload({
    required this.canvasId,
    required this.strokeId,
    required this.chunkIndex,
    required Iterable<CanvasPoint> points,
  }) : points = List<CanvasPoint>.unmodifiable(points) {
    if (chunkIndex < 1) {
      throw ArgumentError.value(
        chunkIndex,
        'chunkIndex',
        'append must be positive',
      );
    }
    _validatePointCount(this.points);
  }

  @override
  final CanvasId canvasId;
  @override
  final StrokeId strokeId;
  final int chunkIndex;
  final List<CanvasPoint> points;

  @override
  String get actionType => strokeAppendActionType;

  @override
  int get correlationChunkIndex => chunkIndex;

  @override
  Map<String, Object?> toJson() => <String, Object?>{
    'canvas_id': canvasId.value,
    'stroke_id': strokeId.value,
    'chunk_index': chunkIndex,
    'points': points.map((point) => point.toJson()).toList(growable: false),
  };
}

final class StrokeEndPayload extends CanvasActionPayload {
  const StrokeEndPayload({
    required this.canvasId,
    required this.strokeId,
    required this.finalChunkIndex,
  });

  @override
  final CanvasId canvasId;
  @override
  final StrokeId strokeId;
  final int finalChunkIndex;

  @override
  String get actionType => strokeEndActionType;

  @override
  int get correlationChunkIndex => finalChunkIndex;

  @override
  Map<String, Object?> toJson() => <String, Object?>{
    'canvas_id': canvasId.value,
    'stroke_id': strokeId.value,
    'final_chunk_index': finalChunkIndex,
  };
}

final class StrokeCancelPayload extends CanvasActionPayload {
  const StrokeCancelPayload({
    required this.canvasId,
    required this.strokeId,
    required this.finalChunkIndex,
  });

  @override
  final CanvasId canvasId;
  @override
  final StrokeId strokeId;
  final int finalChunkIndex;

  @override
  String get actionType => strokeCancelActionType;

  @override
  int get correlationChunkIndex => finalChunkIndex;

  @override
  Map<String, Object?> toJson() => <String, Object?>{
    'canvas_id': canvasId.value,
    'stroke_id': strokeId.value,
    'final_chunk_index': finalChunkIndex,
  };
}

final class StrokeRemovePayload extends CanvasActionPayload {
  const StrokeRemovePayload({required this.canvasId, required this.strokeId});

  @override
  final CanvasId canvasId;
  @override
  final StrokeId strokeId;

  @override
  String get actionType => strokeRemoveActionType;

  @override
  int? get correlationChunkIndex => null;

  @override
  Map<String, Object?> toJson() => <String, Object?>{
    'canvas_id': canvasId.value,
    'stroke_id': strokeId.value,
  };
}

final class CanvasEvent {
  const CanvasEvent({
    required this.kind,
    required this.event,
    required this.payload,
  });

  final CanvasEventKind kind;
  final EventMessage event;
  final CanvasActionPayload payload;

  static CanvasEvent? fromEvent(EventMessage event) {
    final kind = switch (event.eventType) {
      strokeBeganEventType => CanvasEventKind.strokeBegan,
      strokePointsAppendedEventType => CanvasEventKind.strokePointsAppended,
      strokeCompletedEventType => CanvasEventKind.strokeCompleted,
      strokeCancelledEventType => CanvasEventKind.strokeCancelled,
      strokeRemovedEventType => CanvasEventKind.strokeRemoved,
      _ => null,
    };
    if (kind == null) {
      return null;
    }
    try {
      final payload = switch (kind) {
        CanvasEventKind.strokeBegan => _decodeBegin(event.payload),
        CanvasEventKind.strokePointsAppended => _decodeAppend(event.payload),
        CanvasEventKind.strokeCompleted => _decodeEnd(event.payload),
        CanvasEventKind.strokeCancelled => _decodeCancel(event.payload),
        CanvasEventKind.strokeRemoved => _decodeRemove(event.payload),
      };
      return CanvasEvent(kind: kind, event: event, payload: payload);
    } on ClientProtocolError {
      rethrow;
    } on Object catch (error) {
      throw ClientProtocolError(
        ClientProtocolErrorCode.invalidCanvasPayload,
        'Invalid ${event.eventType} payload: $error',
      );
    }
  }
}

StrokeBeginPayload _decodeBegin(Map<String, Object?> value) {
  _exact(value, const {
    'canvas_id',
    'layer_id',
    'stroke_id',
    'tool',
    'style',
    'chunk_index',
    'points',
  });
  return StrokeBeginPayload(
    canvasId: CanvasId.parse(_string(value, 'canvas_id')),
    layerId: LayerId.parse(_string(value, 'layer_id')),
    strokeId: StrokeId.parse(_string(value, 'stroke_id')),
    tool: _tool(_string(value, 'tool')),
    style: _style(_object(value, 'style')),
    chunkIndex: _integer(value, 'chunk_index'),
    points: _points(value),
  );
}

StrokeAppendPayload _decodeAppend(Map<String, Object?> value) {
  _exact(value, const {'canvas_id', 'stroke_id', 'chunk_index', 'points'});
  return StrokeAppendPayload(
    canvasId: CanvasId.parse(_string(value, 'canvas_id')),
    strokeId: StrokeId.parse(_string(value, 'stroke_id')),
    chunkIndex: _integer(value, 'chunk_index'),
    points: _points(value),
  );
}

StrokeEndPayload _decodeEnd(Map<String, Object?> value) {
  _exact(value, const {'canvas_id', 'stroke_id', 'final_chunk_index'});
  return StrokeEndPayload(
    canvasId: CanvasId.parse(_string(value, 'canvas_id')),
    strokeId: StrokeId.parse(_string(value, 'stroke_id')),
    finalChunkIndex: _integer(value, 'final_chunk_index'),
  );
}

StrokeCancelPayload _decodeCancel(Map<String, Object?> value) {
  _exact(value, const {'canvas_id', 'stroke_id', 'final_chunk_index'});
  return StrokeCancelPayload(
    canvasId: CanvasId.parse(_string(value, 'canvas_id')),
    strokeId: StrokeId.parse(_string(value, 'stroke_id')),
    finalChunkIndex: _integer(value, 'final_chunk_index'),
  );
}

StrokeRemovePayload _decodeRemove(Map<String, Object?> value) {
  _exact(value, const {'canvas_id', 'stroke_id'});
  return StrokeRemovePayload(
    canvasId: CanvasId.parse(_string(value, 'canvas_id')),
    strokeId: StrokeId.parse(_string(value, 'stroke_id')),
  );
}

StrokeStyle _style(Map<String, Object?> value) {
  _exact(value, const {'width', 'color'});
  final color = _object(value, 'color');
  _exact(color, const {'red', 'green', 'blue', 'alpha'});
  return StrokeStyle(
    width: _number(value, 'width'),
    color: RgbaColor(
      red: _byte(color, 'red'),
      green: _byte(color, 'green'),
      blue: _byte(color, 'blue'),
      alpha: _byte(color, 'alpha'),
    ),
  );
}

StrokeTool _tool(String value) {
  if (value != 'pen') {
    throw ClientProtocolError(
      ClientProtocolErrorCode.invalidCanvasPayload,
      'Unsupported Stroke tool "$value"',
    );
  }
  return StrokeTool.pen;
}

List<CanvasPoint> _points(Map<String, Object?> value) {
  final points = value['points'];
  if (points is! List<Object?>) {
    throw const ClientProtocolError(
      ClientProtocolErrorCode.invalidCanvasPayload,
      'points must be an array',
    );
  }
  return points
      .map((point) {
        if (point is! Map<String, Object?>) {
          throw const ClientProtocolError(
            ClientProtocolErrorCode.invalidCanvasPayload,
            'Each point must be an object',
          );
        }
        _exact(point, const {'x', 'y'});
        return CanvasPoint(_number(point, 'x'), _number(point, 'y'));
      })
      .toList(growable: false);
}

void _validatePointCount(List<CanvasPoint> points) {
  if (points.isEmpty || points.length > maxPointsPerChunk) {
    throw ArgumentError.value(
      points.length,
      'points',
      'must contain 1..=$maxPointsPerChunk points',
    );
  }
}

void _exact(Map<String, Object?> value, Set<String> fields) {
  if (value.length != fields.length || !value.keys.every(fields.contains)) {
    throw const ClientProtocolError(
      ClientProtocolErrorCode.invalidCanvasPayload,
      'Canvas payload fields do not match the expected schema',
    );
  }
}

String _string(Map<String, Object?> value, String field) {
  final result = value[field];
  if (result is! String) {
    throw ClientProtocolError(
      ClientProtocolErrorCode.invalidCanvasPayload,
      '$field must be a string',
    );
  }
  return result;
}

int _integer(Map<String, Object?> value, String field) {
  final result = value[field];
  if (result is! int || result < 0) {
    throw ClientProtocolError(
      ClientProtocolErrorCode.invalidCanvasPayload,
      '$field must be a non-negative integer',
    );
  }
  return result;
}

double _number(Map<String, Object?> value, String field) {
  final result = value[field];
  if (result is! num || !result.isFinite) {
    throw ClientProtocolError(
      ClientProtocolErrorCode.invalidCanvasPayload,
      '$field must be a finite number',
    );
  }
  return result.toDouble();
}

int _byte(Map<String, Object?> value, String field) {
  final result = _integer(value, field);
  if (result > 255) {
    throw ClientProtocolError(
      ClientProtocolErrorCode.invalidCanvasPayload,
      '$field must be in 0..=255',
    );
  }
  return result;
}

Map<String, Object?> _object(Map<String, Object?> value, String field) {
  final result = value[field];
  if (result is! Map<String, Object?>) {
    throw ClientProtocolError(
      ClientProtocolErrorCode.invalidCanvasPayload,
      '$field must be an object',
    );
  }
  return result;
}
