import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:orbitrelay_client_flutter/canvas/canvas_controller.dart';
import 'package:orbitrelay_client_flutter/canvas/canvas_protocol.dart';
import 'package:orbitrelay_client_flutter/canvas/canvas_render_state.dart';
import 'package:orbitrelay_client_flutter/protocol/ids.dart';
import 'package:orbitrelay_client_flutter/protocol/message.dart';
import 'package:orbitrelay_client_flutter/session/pending_action.dart';

import '../support/fake_canvas_session.dart';

const _viewport = Size(100, 100);
final _sessionId = SessionId.parse('22222222-2222-4222-8222-222222222222');
final _canvasId = CanvasId.parse('33333333-3333-4333-8333-333333333333');
final _layerId = LayerId.parse('44444444-4444-4444-8444-444444444444');
final _actorId = ActorId.parse('11111111-1111-4111-8111-111111111111');

CanvasClientDescriptor descriptor() => CanvasClientDescriptor(
  sessionId: _sessionId,
  canvasId: _canvasId,
  layerId: _layerId,
  space: CanvasSpace(100, 100),
);

EventMessage eventFor(String eventType, CanvasActionPayload payload) =>
    EventMessage(
      messageId: MessageId.generate(),
      id: EventId.parse('99999999-9999-4999-8999-999999999999'),
      sessionId: _sessionId,
      actorId: _actorId,
      actionId: ActionId.generate(),
      eventType: eventType,
      occurredAt: OrbitRelayTimestamp.parse('2023-11-14 22:13:21.0 +00:00:00'),
      payload: payload.toJson(),
    );

Future<void> settleEvents() async {
  for (var index = 0; index < 4; index += 1) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  test('PointerUp queues remaining Append before End', () {
    final session = FakeCanvasSession();
    final controller = CanvasController(
      session: session,
      descriptor: descriptor(),
    );
    expect(controller.pointerDown(1, const Offset(10, 10), _viewport), isTrue);
    controller.pointerMove(1, const Offset(20, 20), _viewport);
    controller.pointerUp(1);
    expect(session.actions.map((action) => action.actionType), <String>[
      strokeBeginActionType,
      strokeAppendActionType,
      strokeEndActionType,
    ]);
    final append = session.actions[1] as StrokeAppendPayload;
    final end = session.actions[2] as StrokeEndPayload;
    expect(append.chunkIndex, 1);
    expect(end.finalChunkIndex, append.chunkIndex);
    controller.dispose();
    session.dispose();
  });

  test('PointerCancel queues remaining Append before Cancel', () {
    final session = FakeCanvasSession();
    final controller = CanvasController(
      session: session,
      descriptor: descriptor(),
    );
    expect(controller.pointerDown(1, const Offset(10, 10), _viewport), isTrue);
    controller.pointerMove(1, const Offset(20, 20), _viewport);
    controller.pointerCancel(1);
    expect(session.actions.map((action) => action.actionType), <String>[
      strokeBeginActionType,
      strokeAppendActionType,
      strokeCancelActionType,
    ]);
    final append = session.actions[1] as StrokeAppendPayload;
    final cancel = session.actions[2] as StrokeCancelPayload;
    expect(cancel.finalChunkIndex, append.chunkIndex);
    controller.dispose();
    session.dispose();
  });

  test('own authoritative chunk replaces optimistic geometry once', () async {
    final session = FakeCanvasSession();
    final controller = CanvasController(
      session: session,
      descriptor: descriptor(),
    );
    expect(controller.pointerDown(1, const Offset(10, 10), _viewport), isTrue);
    final begin = session.actions.single as StrokeBeginPayload;
    session.emitEvent(eventFor(strokeBeganEventType, begin));
    await settleEvents();

    expect(controller.projection.stroke(begin.strokeId), isNotNull);
    expect(controller.optimistic.stroke(begin.strokeId)!.chunks, isEmpty);
    expect(controller.renderState.value.strokes, hasLength(1));
    expect(controller.renderState.value.strokes.single.points, hasLength(1));

    session.emitEvent(
      eventFor(
        strokeCompletedEventType,
        StrokeEndPayload(
          canvasId: _canvasId,
          strokeId: begin.strokeId,
          finalChunkIndex: 0,
        ),
      ),
    );
    await settleEvents();
    expect(controller.optimistic.stroke(begin.strokeId), isNull);
    expect(controller.renderState.value.strokes, hasLength(1));
    controller.dispose();
    session.dispose();
  });

  test('remote Stroke grows as began and append Events arrive', () async {
    final session = FakeCanvasSession();
    final controller = CanvasController(
      session: session,
      descriptor: descriptor(),
    );
    final strokeId = StrokeId.parse('55555555-5555-4555-8555-555555555555');
    session.emitEvent(
      eventFor(
        strokeBeganEventType,
        StrokeBeginPayload(
          canvasId: _canvasId,
          layerId: _layerId,
          strokeId: strokeId,
          tool: StrokeTool.pen,
          style: StrokeStyle(width: 4, color: const RgbaColor.black()),
          points: <CanvasPoint>[CanvasPoint(1, 1)],
        ),
      ),
    );
    await settleEvents();
    expect(controller.renderState.value.strokes.single.points, hasLength(1));

    for (var index = 1; index <= 2; index += 1) {
      session.emitEvent(
        eventFor(
          strokePointsAppendedEventType,
          StrokeAppendPayload(
            canvasId: _canvasId,
            strokeId: strokeId,
            chunkIndex: index,
            points: <CanvasPoint>[
              CanvasPoint(index * 10, index * 10),
              CanvasPoint(index * 10 + 1, index * 10 + 1),
            ],
          ),
        ),
      );
      await settleEvents();
      expect(
        controller.renderState.value.strokes.single.points,
        hasLength(1 + index * 2),
      );
    }
    controller.dispose();
    session.dispose();
  });

  test('projection error desynchronizes and disables pointer input', () async {
    final session = FakeCanvasSession();
    final controller = CanvasController(
      session: session,
      descriptor: descriptor(),
    );
    session.emitEvent(
      eventFor(
        strokePointsAppendedEventType,
        StrokeAppendPayload(
          canvasId: _canvasId,
          strokeId: StrokeId.generate(),
          chunkIndex: 1,
          points: <CanvasPoint>[CanvasPoint(1, 1)],
        ),
      ),
    );
    await settleEvents();
    expect(controller.health, CanvasHealth.desynchronized);
    expect(controller.pointerDown(1, const Offset(10, 10), _viewport), isFalse);
    expect(session.actions, isEmpty);
    controller.dispose();
    session.dispose();
  });

  test('rejected Begin stops input before later pointer events', () {
    final session = FakeCanvasSession();
    final controller = CanvasController(
      session: session,
      descriptor: descriptor(),
    );
    expect(controller.pointerDown(1, const Offset(10, 10), _viewport), isTrue);
    final begin = session.actions.single as StrokeBeginPayload;
    final rejected = PendingAction(
      messageId: MessageId.generate(),
      actionId: ActionId.generate(),
      strokeId: begin.strokeId,
      actionKind: strokeBeginActionType,
      chunkIndex: 0,
      sentAt: DateTime.now().toUtc(),
    );

    session.failureController.add(
      ActionFailure(action: rejected, safeMessage: 'The action was rejected.'),
    );

    expect(controller.hasActivePointer, isFalse);
    expect(controller.optimistic.stroke(begin.strokeId), isNull);
    expect(
      () => controller.pointerMove(1, const Offset(20, 20), _viewport),
      returnsNormally,
    );
    expect(session.actions, hasLength(1));
    expect(controller.message, 'The action was rejected.');
    controller.dispose();
    session.dispose();
  });
}
