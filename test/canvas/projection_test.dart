import 'package:flutter_test/flutter_test.dart';
import 'package:orbitrelay_client_flutter/canvas/canvas_projection.dart';
import 'package:orbitrelay_client_flutter/canvas/canvas_protocol.dart';
import 'package:orbitrelay_client_flutter/protocol/ids.dart';
import 'package:orbitrelay_client_flutter/protocol/message.dart';

CanvasEvent eventFor({
  required String eventType,
  required Map<String, Object?> payload,
}) {
  final session = SessionId.parse('22222222-2222-4222-8222-222222222222');
  return CanvasEvent.fromEvent(
    EventMessage(
      messageId: MessageId.generate(),
      id: EventId.parse('99999999-9999-4999-8999-999999999999'),
      sessionId: session,
      actorId: ActorId.parse('11111111-1111-4111-8111-111111111111'),
      actionId: ActionId.generate(),
      eventType: eventType,
      occurredAt: OrbitRelayTimestamp.parse('2023-11-14 22:13:21.0 +00:00:00'),
      payload: payload,
    ),
  )!;
}

void main() {
  final session = SessionId.parse('22222222-2222-4222-8222-222222222222');
  final canvas = CanvasId.parse('33333333-3333-4333-8333-333333333333');
  final layer = LayerId.parse('44444444-4444-4444-8444-444444444444');
  final stroke = StrokeId.parse('55555555-5555-4555-8555-555555555555');
  final actor = ActorId.parse('11111111-1111-4111-8111-111111111111');
  final style = StrokeStyle(width: 4, color: const RgbaColor.black());
  Map<String, Object?> beginPayload() => StrokeBeginPayload(
    canvasId: canvas,
    layerId: layer,
    strokeId: stroke,
    tool: StrokeTool.pen,
    style: style,
    points: <CanvasPoint>[CanvasPoint(10, 10)],
  ).toJson();

  test('projection applies begin, append, complete and remove', () {
    final projection = CanvasProjection(
      sessionId: session,
      canvasId: canvas,
      layerId: layer,
      space: CanvasSpace(100, 100),
    );
    projection.apply(
      eventFor(eventType: strokeBeganEventType, payload: beginPayload()),
    );
    projection.apply(
      eventFor(
        eventType: strokePointsAppendedEventType,
        payload: StrokeAppendPayload(
          canvasId: canvas,
          strokeId: stroke,
          chunkIndex: 1,
          points: <CanvasPoint>[CanvasPoint(20, 20)],
        ).toJson(),
      ),
    );
    projection.apply(
      eventFor(
        eventType: strokeCompletedEventType,
        payload: StrokeEndPayload(
          canvasId: canvas,
          strokeId: stroke,
          finalChunkIndex: 1,
        ).toJson(),
      ),
    );
    expect(
      projection.stroke(stroke)!.lifecycle,
      ClientStrokeLifecycle.completed,
    );
    expect(projection.stroke(stroke)!.chunks, hasLength(2));
    projection.apply(
      eventFor(
        eventType: strokeRemovedEventType,
        payload: StrokeRemovePayload(
          canvasId: canvas,
          strokeId: stroke,
        ).toJson(),
      ),
    );
    expect(projection.stroke(stroke)!.lifecycle, ClientStrokeLifecycle.removed);
  });

  test('projection rejects gaps and allows exact duplicate chunks', () {
    final projection = CanvasProjection(
      sessionId: session,
      canvasId: canvas,
      layerId: layer,
      space: CanvasSpace(100, 100),
    );
    projection.apply(
      eventFor(eventType: strokeBeganEventType, payload: beginPayload()),
    );
    final append = StrokeAppendPayload(
      canvasId: canvas,
      strokeId: stroke,
      chunkIndex: 1,
      points: <CanvasPoint>[CanvasPoint(20, 20)],
    ).toJson();
    final exact = eventFor(
      eventType: strokePointsAppendedEventType,
      payload: append,
    );
    projection.apply(exact);
    projection.apply(exact);
    expect(
      () => projection.apply(
        eventFor(
          eventType: strokePointsAppendedEventType,
          payload: StrokeAppendPayload(
            canvasId: canvas,
            strokeId: stroke,
            chunkIndex: 3,
            points: <CanvasPoint>[CanvasPoint(30, 30)],
          ).toJson(),
        ),
      ),
      throwsA(isA<CanvasDesynchronizedError>()),
    );
  });

  test('projection rejects missing began and conflicting duplicate chunk', () {
    final projection = CanvasProjection(
      sessionId: session,
      canvasId: canvas,
      layerId: layer,
      space: CanvasSpace(100, 100),
    );
    final append = StrokeAppendPayload(
      canvasId: canvas,
      strokeId: stroke,
      chunkIndex: 1,
      points: <CanvasPoint>[CanvasPoint(20, 20)],
    );
    expect(
      () => projection.apply(
        eventFor(
          eventType: strokePointsAppendedEventType,
          payload: append.toJson(),
        ),
      ),
      throwsA(isA<CanvasDesynchronizedError>()),
    );
    projection.apply(
      eventFor(eventType: strokeBeganEventType, payload: beginPayload()),
    );
    projection.apply(
      eventFor(
        eventType: strokePointsAppendedEventType,
        payload: append.toJson(),
      ),
    );
    expect(
      () => projection.apply(
        eventFor(
          eventType: strokePointsAppendedEventType,
          payload: StrokeAppendPayload(
            canvasId: canvas,
            strokeId: stroke,
            chunkIndex: 1,
            points: <CanvasPoint>[CanvasPoint(21, 21)],
          ).toJson(),
        ),
      ),
      throwsA(isA<CanvasDesynchronizedError>()),
    );
  });

  test('projection rejects wrong Canvas and Layer identities', () {
    final projection = CanvasProjection(
      sessionId: session,
      canvasId: canvas,
      layerId: layer,
      space: CanvasSpace(100, 100),
    );
    final otherCanvas = CanvasId.parse('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa');
    final otherLayer = LayerId.parse('bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb');
    expect(
      () => projection.apply(
        eventFor(
          eventType: strokeBeganEventType,
          payload: StrokeBeginPayload(
            canvasId: otherCanvas,
            layerId: layer,
            strokeId: stroke,
            tool: StrokeTool.pen,
            style: style,
            points: <CanvasPoint>[CanvasPoint(10, 10)],
          ).toJson(),
        ),
      ),
      throwsA(isA<CanvasDesynchronizedError>()),
    );
    expect(
      () => projection.apply(
        eventFor(
          eventType: strokeBeganEventType,
          payload: StrokeBeginPayload(
            canvasId: canvas,
            layerId: otherLayer,
            strokeId: stroke,
            tool: StrokeTool.pen,
            style: style,
            points: <CanvasPoint>[CanvasPoint(10, 10)],
          ).toJson(),
        ),
      ),
      throwsA(isA<CanvasDesynchronizedError>()),
    );
  });

  test('projection rejects terminal mismatch and append after completion', () {
    final projection = CanvasProjection(
      sessionId: session,
      canvasId: canvas,
      layerId: layer,
      space: CanvasSpace(100, 100),
    );
    projection.apply(
      eventFor(eventType: strokeBeganEventType, payload: beginPayload()),
    );
    expect(
      () => projection.apply(
        eventFor(
          eventType: strokeCompletedEventType,
          payload: StrokeEndPayload(
            canvasId: canvas,
            strokeId: stroke,
            finalChunkIndex: 1,
          ).toJson(),
        ),
      ),
      throwsA(isA<CanvasDesynchronizedError>()),
    );
    projection.apply(
      eventFor(
        eventType: strokeCompletedEventType,
        payload: StrokeEndPayload(
          canvasId: canvas,
          strokeId: stroke,
          finalChunkIndex: 0,
        ).toJson(),
      ),
    );
    expect(
      () => projection.apply(
        eventFor(
          eventType: strokePointsAppendedEventType,
          payload: StrokeAppendPayload(
            canvasId: canvas,
            strokeId: stroke,
            chunkIndex: 1,
            points: <CanvasPoint>[CanvasPoint(20, 20)],
          ).toJson(),
        ),
      ),
      throwsA(isA<CanvasDesynchronizedError>()),
    );
  });

  test('projection keeps event actor as creator', () {
    final projection = CanvasProjection(
      sessionId: session,
      canvasId: canvas,
      layerId: layer,
      space: CanvasSpace(100, 100),
    );
    projection.apply(
      eventFor(eventType: strokeBeganEventType, payload: beginPayload()),
    );
    expect(projection.stroke(stroke)!.creatorActorId, actor);
  });
}
