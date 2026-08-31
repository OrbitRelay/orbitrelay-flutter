import 'package:flutter_test/flutter_test.dart';
import 'package:orbitrelay_client_flutter/canvas/canvas_protocol.dart';
import 'package:orbitrelay_client_flutter/protocol/error.dart';
import 'package:orbitrelay_client_flutter/protocol/ids.dart';
import 'package:orbitrelay_client_flutter/protocol/message.dart';

void main() {
  final canvasId = CanvasId.parse('33333333-3333-4333-8333-333333333333');
  final layerId = LayerId.parse('44444444-4444-4444-8444-444444444444');
  final strokeId = StrokeId.parse('55555555-5555-4555-8555-555555555555');

  test('Canvas payloads round-trip through typed JSON shapes', () {
    final begin = StrokeBeginPayload(
      canvasId: canvasId,
      layerId: layerId,
      strokeId: strokeId,
      tool: StrokeTool.pen,
      style: StrokeStyle(width: 4, color: const RgbaColor.black()),
      points: <CanvasPoint>[CanvasPoint(10, 12)],
    );
    expect(begin.toJson()['chunk_index'], 0);
    expect(begin.toJson()['tool'], 'pen');
    expect((begin.toJson()['style'] as Map<String, Object?>)['width'], 4.0);
    expect(
      () => StrokeAppendPayload(
        canvasId: canvasId,
        strokeId: strokeId,
        chunkIndex: 0,
        points: <CanvasPoint>[CanvasPoint(1, 1)],
      ),
      throwsArgumentError,
    );
  });

  test('recognized malformed Canvas event is a protocol error', () {
    final session = SessionId.parse('22222222-2222-4222-8222-222222222222');
    final event = EventMessage(
      messageId: MessageId.generate(),
      id: EventId.parse('99999999-9999-4999-8999-999999999999'),
      sessionId: session,
      actorId: ActorId.parse('11111111-1111-4111-8111-111111111111'),
      actionId: ActionId.generate(),
      eventType: strokeBeganEventType,
      occurredAt: OrbitRelayTimestamp.parse('2023-11-14 22:13:21.0 +00:00:00'),
      payload: const <String, Object?>{},
    );
    expect(
      () => CanvasEvent.fromEvent(event),
      throwsA(
        isA<ClientProtocolError>().having(
          (error) => error.code,
          'code',
          ClientProtocolErrorCode.invalidCanvasPayload,
        ),
      ),
    );
  });
}
