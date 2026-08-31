import '../protocol/ids.dart';
import '../protocol/message.dart';
import '../protocol/query.dart';
import '../session/orbitrelay_session.dart';
import 'canvas_protocol.dart';

const String canvasHistoryPageQueryType = 'canvas.history.page';

final class HistoryEventDto {
  const HistoryEventDto({
    required this.eventId,
    required this.sessionId,
    required this.actorId,
    required this.actionId,
    required this.eventType,
    required this.occurredAt,
    required this.payload,
    required this.metadata,
  });

  final EventId eventId;
  final SessionId sessionId;
  final ActorId actorId;
  final ActionId actionId;
  final String eventType;
  final OrbitRelayTimestamp occurredAt;
  final Map<String, Object?> payload;
  final Map<String, Object?> metadata;

  factory HistoryEventDto.fromJson(Map<String, Object?> value) {
    _exact(value, const {
      'event_id',
      'session_id',
      'actor_id',
      'action_id',
      'event_type',
      'occurred_at',
      'payload',
      'metadata',
    });
    return HistoryEventDto(
      eventId: EventId.parse(_string(value, 'event_id')),
      sessionId: SessionId.parse(_string(value, 'session_id')),
      actorId: ActorId.parse(_string(value, 'actor_id')),
      actionId: ActionId.parse(_string(value, 'action_id')),
      eventType: _string(value, 'event_type'),
      occurredAt: OrbitRelayTimestamp.parse(_string(value, 'occurred_at')),
      payload: _object(_required(value, 'payload'), 'payload'),
      metadata: _object(_required(value, 'metadata'), 'metadata'),
    );
  }

  EventMessage toEventMessage() => EventMessage(
    messageId: MessageId.generate(),
    id: eventId,
    sessionId: sessionId,
    actorId: actorId,
    actionId: actionId,
    eventType: eventType,
    occurredAt: occurredAt,
    payload: payload,
    metadata: metadata,
  );
}

final class CanvasHistoryPageDto {
  const CanvasHistoryPageDto({
    required this.canvasId,
    required this.checkpoint,
    required this.events,
    required this.nextCursor,
    required this.complete,
  });

  final CanvasId canvasId;
  final String checkpoint;
  final List<HistoryEventDto> events;
  final String? nextCursor;
  final bool complete;

  factory CanvasHistoryPageDto.fromJson(Map<String, Object?> value) {
    _exact(value, const {
      'canvas_id',
      'checkpoint',
      'events',
      'next_cursor',
      'complete',
    });
    final next = _required(value, 'next_cursor');
    if (next != null && next is! String) {
      throw FormatException('next_cursor must be a string or null');
    }
    final complete = _bool(value, 'complete');
    if (complete && next != null || !complete && next == null) {
      throw FormatException('History complete/next_cursor invariant violated');
    }
    return CanvasHistoryPageDto(
      canvasId: CanvasId.parse(_string(value, 'canvas_id')),
      checkpoint: _nonEmpty(_string(value, 'checkpoint'), 'checkpoint'),
      events: _list(value, 'events')
          .map(
            (item) => HistoryEventDto.fromJson(_object(item, 'history event')),
          )
          .toList(growable: false),
      nextCursor: next as String?,
      complete: complete,
    );
  }
}

final class CanvasHistoryLoader {
  const CanvasHistoryLoader({required this.session});

  final OrbitRelayQuerySession session;

  Future<List<HistoryEventDto>> load(CanvasId canvasId) async {
    final events = <HistoryEventDto>[];
    var result = await _page(canvasId, <String, Object?>{
      'canvas_id': canvasId.value,
    });
    final checkpoint = result.checkpoint;
    while (true) {
      if (result.canvasId != canvasId || result.checkpoint != checkpoint) {
        throw const FormatException('History page identity/checkpoint changed');
      }
      events.addAll(result.events);
      if (result.complete) {
        return List<HistoryEventDto>.unmodifiable(events);
      }
      final cursor = result.nextCursor;
      if (cursor == null) {
        throw const FormatException('Incomplete history page has no cursor');
      }
      result = await _page(canvasId, <String, Object?>{
        'canvas_id': canvasId.value,
        'checkpoint': checkpoint,
        'cursor': cursor,
      });
    }
  }

  Future<CanvasHistoryPageDto> _page(
    CanvasId canvasId,
    Map<String, Object?> payload,
  ) async {
    final result = await session.query(canvasHistoryPageQueryType, payload);
    if (result is! QuerySuccessResult) {
      throw StateError('Unexpected Query result for canvas.history.page');
    }
    final page = CanvasHistoryPageDto.fromJson(result.payload);
    if (page.canvasId != canvasId) {
      throw const FormatException(
        'History response Canvas does not match request',
      );
    }
    return page;
  }
}

enum CanvasReplayState { idle, loadingHistory, replaying, live, desynced }

typedef CanvasEventIngest = void Function(EventMessage event);
typedef CanvasReplayReset = void Function();
typedef CanvasReplayStateChanged = void Function(CanvasReplayState state);

final class CanvasReplayController {
  CanvasReplayController({
    required this.session,
    required this.canvasId,
    required this.loader,
    this.onIngest,
    this.onReset,
    this.onStateChanged,
    this.maxBufferedEvents = 2048,
    this.maxBufferedBytes = 8 * 1024 * 1024,
  }) {
    if (maxBufferedEvents <= 0 || maxBufferedBytes <= 0) {
      throw ArgumentError('Replay buffer limits must be positive');
    }
  }

  final OrbitRelayQuerySession session;
  final CanvasId canvasId;
  final CanvasHistoryLoader loader;
  CanvasEventIngest? onIngest;
  CanvasReplayReset? onReset;
  CanvasReplayStateChanged? onStateChanged;
  final int maxBufferedEvents;
  final int maxBufferedBytes;
  final Set<EventId> _seenEventIds = <EventId>{};
  final List<EventMessage> _buffer = <EventMessage>[];
  Future<void> _serial = Future<void>.value();
  int _attemptCounter = 0;
  int? _activeAttempt;
  CanvasReplayState _state = CanvasReplayState.idle;
  int? _generation;
  int? _subscriptionGeneration;
  Object? _failure;
  bool _disposed = false;
  int _bufferedBytes = 0;

  CanvasReplayState get state => _state;
  Object? get failure => _failure;
  bool get canDraw =>
      !_disposed &&
      _state == CanvasReplayState.live &&
      session.subscriptionHealthy;

  void attach({
    required CanvasEventIngest ingest,
    CanvasReplayReset? reset,
    CanvasReplayStateChanged? stateChanged,
  }) {
    onIngest = ingest;
    onReset = reset;
    onStateChanged = stateChanged;
  }

  Future<void> start() async {
    if (_disposed) {
      return;
    }
    final attempt = ++_attemptCounter;
    _activeAttempt = attempt;
    // A failed serial chain must not poison a later full replay. Operations
    // from the previous attempt carry their attempt token and cannot ingest.
    _serial = Future<void>.value();
    _generation = session.connectionGeneration;
    _subscriptionGeneration = session.subscriptionGeneration;
    if (_subscriptionGeneration == null || !session.subscriptionHealthy) {
      _desync(
        const QueryException.client(
          queryType: canvasHistoryPageQueryType,
          failure: QueryClientFailure.disconnected,
          message: 'Replay requires a healthy subscription',
        ),
      );
      return;
    }
    _resetForReplay();
    onReset?.call();
    _setState(CanvasReplayState.loadingHistory);
    try {
      final history = await loader.load(canvasId);
      if (_activeAttempt != attempt) {
        return;
      }
      if (_generation != session.connectionGeneration ||
          _subscriptionGeneration != session.subscriptionGeneration ||
          !session.subscriptionHealthy) {
        _desync(StateError('Canvas replay generation is no longer active'));
        return;
      }
      if (_activeAttempt != attempt || _state == CanvasReplayState.desynced) {
        return;
      }
      _ensureGeneration();
      _setState(CanvasReplayState.replaying);
      await _enqueue(() async {
        if (_activeAttempt != attempt) {
          return;
        }
        for (final event in history) {
          _applyIfNew(event.toEventMessage());
        }
        _drainBuffer();
        _ensureGeneration();
        _setState(CanvasReplayState.live);
      });
    } on Object catch (error) {
      if (_activeAttempt == attempt) {
        final generationChanged =
            _generation != session.connectionGeneration ||
            _subscriptionGeneration != session.subscriptionGeneration ||
            !session.subscriptionHealthy;
        _desync(
          generationChanged
              ? StateError('Canvas replay generation is no longer active')
              : error,
        );
      }
    }
  }

  void receiveRealtime(EventMessage event) {
    if (_disposed || event.sessionId != session.sessionId) {
      return;
    }
    if (!_isCanvasEvent(event.eventType)) {
      return;
    }
    if (_generation != null &&
        (session.connectionGeneration != _generation ||
            session.subscriptionGeneration != _subscriptionGeneration ||
            !session.subscriptionHealthy)) {
      _desync(StateError('Canvas replay generation is no longer active'));
      return;
    }
    if (_isCanvasEvent(event.eventType)) {
      final eventCanvasId = event.payload['canvas_id'];
      if (eventCanvasId is String && eventCanvasId != canvasId.value) {
        return;
      }
    }
    if (_state == CanvasReplayState.live) {
      final attempt = _activeAttempt;
      _enqueue(() async {
        if (attempt != _activeAttempt) {
          return;
        }
        _ensureGeneration();
        _applyIfNew(event);
      }).catchError((Object error) {
        if (attempt == _activeAttempt) {
          _desync(error);
        }
      });
      return;
    }
    if (_state == CanvasReplayState.loadingHistory ||
        _state == CanvasReplayState.replaying) {
      final estimated = event.payload.toString().length;
      if (_buffer.length + 1 > maxBufferedEvents ||
          _bufferedBytes + estimated > maxBufferedBytes) {
        _desync(StateError('Canvas realtime replay buffer exceeded its limit'));
        return;
      }
      _buffer.add(event);
      _bufferedBytes += estimated;
    }
  }

  Future<void> retryFullReplay() async {
    await start();
  }

  void invalidate() => _desync(StateError('Canvas replay generation changed'));

  Future<void> _enqueue(Future<void> Function() operation) {
    _serial = _serial.then((_) => operation());
    return _serial;
  }

  void _applyIfNew(EventMessage event) {
    if (!_seenEventIds.add(event.id)) {
      return;
    }
    final ingest = onIngest;
    if (ingest == null) {
      throw StateError('Canvas replay has no authoritative ingest callback');
    }
    ingest(event);
  }

  void _drainBuffer() {
    while (_buffer.isNotEmpty) {
      final event = _buffer.removeAt(0);
      _bufferedBytes = (_bufferedBytes - event.payload.toString().length).clamp(
        0,
        maxBufferedBytes,
      );
      _applyIfNew(event);
    }
  }

  void _ensureGeneration() {
    if (session.connectionGeneration != _generation ||
        session.subscriptionGeneration != _subscriptionGeneration ||
        !session.subscriptionHealthy) {
      throw StateError('Canvas replay generation is no longer active');
    }
  }

  void _resetForReplay() {
    _buffer.clear();
    _bufferedBytes = 0;
    _seenEventIds.clear();
    _failure = null;
  }

  void _desync(Object error) {
    _failure = error;
    _buffer.clear();
    _bufferedBytes = 0;
    _setState(CanvasReplayState.desynced);
  }

  void _setState(CanvasReplayState state) {
    if (!_disposed) {
      _state = state;
      onStateChanged?.call(state);
    }
  }

  bool _isCanvasEvent(String type) => canvasEventTypes.contains(type);

  void dispose() {
    _disposed = true;
    _buffer.clear();
    _seenEventIds.clear();
  }
}

void _exact(Map<String, Object?> value, Set<String> expected) {
  if (value.length != expected.length || !value.keys.every(expected.contains)) {
    throw const FormatException('History DTO fields do not match schema');
  }
}

Object? _required(Map<String, Object?> value, String field) {
  if (!value.containsKey(field)) {
    throw FormatException('Missing history field', field);
  }
  return value[field];
}

String _string(Map<String, Object?> value, String field) {
  final result = _required(value, field);
  if (result is! String) {
    throw FormatException('$field must be a string');
  }
  return result;
}

String _nonEmpty(String value, String field) {
  if (value.isEmpty) {
    throw FormatException('$field must not be empty');
  }
  return value;
}

Map<String, Object?> _object(Object? value, String context) {
  if (value is! Map) {
    throw FormatException('$context must be an object');
  }
  return value.cast<String, Object?>();
}

List<Object?> _list(Map<String, Object?> value, String field) {
  final result = _required(value, field);
  if (result is! List) {
    throw FormatException('$field must be an array');
  }
  return result.cast<Object?>();
}

bool _bool(Map<String, Object?> value, String field) {
  final result = _required(value, field);
  if (result is! bool) {
    throw FormatException('$field must be boolean');
  }
  return result;
}
