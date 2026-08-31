import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:orbitrelay_client_flutter/canvas/canvas_protocol.dart';
import 'package:orbitrelay_client_flutter/protocol/ids.dart';
import 'package:orbitrelay_client_flutter/protocol/message.dart';
import 'package:orbitrelay_client_flutter/session/orbitrelay_session.dart';
import 'package:orbitrelay_client_flutter/session/pending_action.dart';
import 'package:orbitrelay_client_flutter/transport/connection_state.dart';

final class FakeCanvasSession implements OrbitRelayCanvasSession {
  FakeCanvasSession({
    OrbitRelayConnectionState initialState = OrbitRelayConnectionState.ready,
  }) : state = ValueNotifier<OrbitRelayConnectionState>(initialState);

  final ValueNotifier<OrbitRelayConnectionState> state;
  final List<CanvasActionPayload> actions = <CanvasActionPayload>[];
  final StreamController<EventMessage> eventController =
      StreamController<EventMessage>.broadcast(sync: true);
  final StreamController<ActionFailure> failureController =
      StreamController<ActionFailure>.broadcast(sync: true);

  bool disposed = false;

  @override
  OrbitRelayConnectionState get connectionState => state.value;

  @override
  ValueListenable<OrbitRelayConnectionState> get connectionStateListenable =>
      state;

  @override
  Stream<EventMessage> get events => eventController.stream;

  @override
  Stream<ActionFailure> get actionFailures => failureController.stream;

  @override
  PendingAction enqueueCanvasAction(CanvasActionPayload payload) {
    if (connectionState != OrbitRelayConnectionState.ready) {
      throw StateError('Session is not Ready');
    }
    actions.add(payload);
    return PendingAction(
      messageId: MessageId.generate(),
      actionId: ActionId.generate(),
      strokeId: payload.strokeId,
      actionKind: payload.actionType,
      chunkIndex: payload.correlationChunkIndex,
      sentAt: DateTime.now().toUtc(),
    );
  }

  @override
  void cancelQueuedActionsForStroke(StrokeId strokeId, {int? fromChunkIndex}) {}

  void emitEvent(EventMessage event) => eventController.add(event);

  void setConnectionState(OrbitRelayConnectionState value) {
    state.value = value;
  }

  @override
  Future<void> close() async {
    if (!disposed) {
      state.value = OrbitRelayConnectionState.disconnected;
    }
  }

  @override
  void dispose() {
    if (disposed) {
      return;
    }
    disposed = true;
    unawaited(eventController.close());
    unawaited(failureController.close());
    state.dispose();
  }
}
