import 'dart:async';
import 'dart:ui';

import 'package:flutter/foundation.dart';

import '../protocol/ids.dart';
import '../protocol/message.dart';
import '../session/orbitrelay_session.dart';
import '../session/pending_action.dart';
import '../transport/connection_state.dart';
import 'canvas_projection.dart';
import 'canvas_protocol.dart';
import 'canvas_history.dart';
import 'canvas_render_state.dart';
import 'optimistic_canvas.dart';
import 'stroke_writer.dart';
import 'viewport_transform.dart';

final class CanvasClientDescriptor {
  const CanvasClientDescriptor({
    required this.sessionId,
    required this.canvasId,
    required this.layerId,
    required this.space,
  });

  final SessionId sessionId;
  final CanvasId canvasId;
  final LayerId layerId;
  final CanvasSpace space;
}

final class CanvasController extends ChangeNotifier {
  CanvasController({
    required this.session,
    required this.descriptor,
    StrokeStyle? style,
    Duration flushInterval = const Duration(milliseconds: 16),
    this.replayController,
  }) : style = style ?? StrokeStyle(width: 4, color: const RgbaColor.black()),
       _flushInterval = flushInterval,
       projection = CanvasProjection(
         sessionId: descriptor.sessionId,
         canvasId: descriptor.canvasId,
         layerId: descriptor.layerId,
         space: descriptor.space,
       ) {
    _eventSubscription = session.events.listen(_scheduleEvent);
    _failureSubscription = session.actionFailures.listen(_handleActionFailure);
    session.connectionStateListenable.addListener(_handleConnectionState);
    replayController?.attach(
      ingest: _handleEvent,
      reset: _resetForReplay,
      stateChanged: _handleReplayState,
    );
    _publishRenderState();
  }

  final OrbitRelayCanvasSession session;
  final CanvasReplayController? replayController;
  final CanvasClientDescriptor descriptor;
  final StrokeStyle style;
  final Duration _flushInterval;
  final CanvasProjection projection;
  final OptimisticCanvas optimistic = OptimisticCanvas();
  final ValueNotifier<CanvasRenderState> renderState =
      ValueNotifier<CanvasRenderState>(CanvasRenderState.empty());

  StreamSubscription<EventMessage>? _eventSubscription;
  StreamSubscription<ActionFailure>? _failureSubscription;
  Future<void> _eventSerial = Future<void>.value();
  Timer? _flushTimer;
  int? _activePointer;
  StrokeWriter? _writer;
  CanvasHealth _health = CanvasHealth.healthy;
  String? _message;
  bool _disposed = false;

  CanvasHealth get health => _health;
  String? get message => _message;
  bool get hasActivePointer => _activePointer != null;
  bool get canDraw =>
      !_disposed &&
      _health == CanvasHealth.healthy &&
      session.connectionState == OrbitRelayConnectionState.ready &&
      (replayController == null || replayController!.canDraw);

  void _resetForReplay() {
    projection.clear();
    optimistic.clear();
    _stopActiveInput();
    _health = CanvasHealth.healthy;
    _message = null;
    _publishRenderState();
  }

  void _handleReplayState(CanvasReplayState state) {
    if (state == CanvasReplayState.desynced) {
      _health = CanvasHealth.desynchronized;
      _stopActiveInput();
      _message = 'Canvas history replay is out of sync. Retry to continue.';
    } else if (state == CanvasReplayState.live) {
      _health = CanvasHealth.healthy;
      _message = null;
    }
    _publishRenderState();
  }

  bool pointerDown(int pointer, Offset localPosition, Size viewportSize) {
    if (!canDraw || _activePointer != null) {
      return false;
    }
    final transform = ViewportTransform(
      space: descriptor.space,
      viewportSize: viewportSize,
    );
    if (!transform.containsViewportPoint(localPosition)) {
      return false;
    }
    final point = transform.viewportToCanvas(localPosition);
    if (!descriptor.space.contains(point)) {
      return false;
    }
    final strokeId = StrokeId.generate();
    final begin = StrokeBeginPayload(
      canvasId: descriptor.canvasId,
      layerId: descriptor.layerId,
      strokeId: strokeId,
      tool: StrokeTool.pen,
      style: style,
      points: <CanvasPoint>[point],
    );
    _activePointer = pointer;
    _writer = StrokeWriter(strokeId: strokeId);
    optimistic.begin(begin);
    _publishRenderState();
    try {
      session.enqueueCanvasAction(begin);
    } on Object catch (error) {
      optimistic.remove(strokeId);
      _stopActiveInput();
      _message = 'Could not queue Stroke begin: $error';
      _publishRenderState();
      return false;
    }
    _flushTimer = Timer.periodic(_flushInterval, (_) => flushNow());
    return true;
  }

  void pointerMove(int pointer, Offset localPosition, Size viewportSize) {
    final writer = _writer;
    if (_activePointer != pointer || writer == null || !canDraw) {
      return;
    }
    final transform = ViewportTransform(
      space: descriptor.space,
      viewportSize: viewportSize,
    );
    if (!transform.containsViewportPoint(localPosition)) {
      return;
    }
    final point = transform.viewportToCanvas(localPosition);
    writer.addPoint(point);
    optimistic.appendPending(writer.strokeId, point);
    _publishRenderState();
    if (writer.pendingPoints.length >= maxPointsPerChunk) {
      flushNow();
    }
  }

  void pointerUp(int pointer) {
    if (_activePointer != pointer || _writer == null) {
      return;
    }
    _flushTimer?.cancel();
    _flushTimer = null;
    final writer = _writer!;
    if (flushNow()) {
      try {
        session.enqueueCanvasAction(
          StrokeEndPayload(
            canvasId: descriptor.canvasId,
            strokeId: writer.strokeId,
            finalChunkIndex: writer.lastSubmittedChunkIndex,
          ),
        );
        optimistic.markTerminal(writer.strokeId, TerminalIntent.complete);
      } on Object catch (error) {
        _message = 'Could not queue Stroke completion: $error';
      }
    }
    _activePointer = null;
    _writer = null;
    _publishRenderState();
  }

  void pointerCancel(int pointer) {
    if (_activePointer != pointer || _writer == null) {
      return;
    }
    _flushTimer?.cancel();
    _flushTimer = null;
    final writer = _writer!;
    if (flushNow()) {
      try {
        session.enqueueCanvasAction(
          StrokeCancelPayload(
            canvasId: descriptor.canvasId,
            strokeId: writer.strokeId,
            finalChunkIndex: writer.lastSubmittedChunkIndex,
          ),
        );
        optimistic.markTerminal(writer.strokeId, TerminalIntent.cancel);
      } on Object catch (error) {
        _message = 'Could not queue Stroke cancellation: $error';
      }
    }
    _activePointer = null;
    _writer = null;
    _publishRenderState();
  }

  bool flushNow() {
    final writer = _writer;
    if (writer == null || writer.pendingPoints.isEmpty) {
      return true;
    }
    final success = writer.flush((index, points) {
      try {
        session.enqueueCanvasAction(
          StrokeAppendPayload(
            canvasId: descriptor.canvasId,
            strokeId: writer.strokeId,
            chunkIndex: index,
            points: points,
          ),
        );
        optimistic.promotePending(writer.strokeId, index, points);
        return true;
      } on Object catch (error) {
        _message = 'Could not queue Stroke points: $error';
        return false;
      }
    });
    if (!success) {
      _stopActiveInput();
    }
    _publishRenderState();
    return success;
  }

  void _scheduleEvent(EventMessage event) {
    if (replayController != null) {
      replayController!.receiveRealtime(event);
      return;
    }
    _eventSerial = _eventSerial
        .then((_) async {
          _handleEvent(event);
        })
        .catchError((Object error) {
          _desynchronize(error.toString());
        });
  }

  void _handleEvent(EventMessage event) {
    final canvasEvent = CanvasEvent.fromEvent(event);
    if (canvasEvent == null) {
      return;
    }
    projection.apply(canvasEvent);
    switch (canvasEvent.kind) {
      case CanvasEventKind.strokeBegan:
        final payload = canvasEvent.payload as StrokeBeginPayload;
        optimistic.reconcileChunk(payload.strokeId, 0, payload.points);
      case CanvasEventKind.strokePointsAppended:
        final payload = canvasEvent.payload as StrokeAppendPayload;
        optimistic.reconcileChunk(
          payload.strokeId,
          payload.chunkIndex,
          payload.points,
        );
      case CanvasEventKind.strokeCompleted:
      case CanvasEventKind.strokeCancelled:
      case CanvasEventKind.strokeRemoved:
        optimistic.reconcileTerminal(canvasEvent.payload.strokeId);
    }
    _publishRenderState();
  }

  void _handleActionFailure(ActionFailure failure) {
    final action = failure.action;
    if (action.actionKind == strokeBeginActionType) {
      if (projection.stroke(action.strokeId) == null) {
        optimistic.remove(action.strokeId);
        session.cancelQueuedActionsForStroke(action.strokeId);
        if (_writer?.strokeId == action.strokeId) {
          _stopActiveInput();
        }
      }
    } else if (action.actionKind == strokeAppendActionType) {
      final chunkIndex = action.chunkIndex ?? 0;
      optimistic.failFrom(action.strokeId, chunkIndex);
      session.cancelQueuedActionsForStroke(
        action.strokeId,
        fromChunkIndex: chunkIndex,
      );
      if (_writer?.strokeId == action.strokeId) {
        _stopActiveInput();
      }
    }
    _message = failure.safeMessage;
    _publishRenderState();
  }

  void _handleConnectionState() {
    if (replayController != null &&
        session.connectionState != OrbitRelayConnectionState.ready &&
        replayController!.state != CanvasReplayState.idle &&
        replayController!.state != CanvasReplayState.desynced) {
      replayController!.invalidate();
    }
    if (session.connectionState != OrbitRelayConnectionState.ready) {
      _stopActiveInput();
      if (session.connectionState == OrbitRelayConnectionState.disconnected ||
          session.connectionState == OrbitRelayConnectionState.failed) {
        _message =
            'Disconnected. Reconnect from the connection page to continue.';
      }
      _publishRenderState();
    }
    notifyListeners();
  }

  void _desynchronize(String reason) {
    if (_health == CanvasHealth.desynchronized) {
      return;
    }
    _health = CanvasHealth.desynchronized;
    _message = 'Canvas realtime state is out of sync. Reconnect to continue.';
    _stopActiveInput();
    debugPrint('Canvas desynchronized: $reason');
    _publishRenderState();
  }

  void _stopActiveInput() {
    _flushTimer?.cancel();
    _flushTimer = null;
    _activePointer = null;
    _writer = null;
  }

  void _publishRenderState() {
    if (_disposed) {
      return;
    }
    renderState.value = CanvasRenderState.compose(
      projection: projection,
      optimistic: optimistic,
      health: _health,
      message: _message,
    );
    notifyListeners();
  }

  @override
  void dispose() {
    if (_disposed) {
      return;
    }
    _disposed = true;
    _stopActiveInput();
    session.connectionStateListenable.removeListener(_handleConnectionState);
    unawaited(_eventSubscription?.cancel());
    unawaited(_failureSubscription?.cancel());
    renderState.dispose();
    super.dispose();
  }
}
