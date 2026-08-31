import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:orbitrelay_client_flutter/canvas/canvas_protocol.dart';
import 'package:orbitrelay_client_flutter/protocol/codec.dart';
import 'package:orbitrelay_client_flutter/protocol/error.dart';
import 'package:orbitrelay_client_flutter/protocol/ids.dart';
import 'package:orbitrelay_client_flutter/protocol/message.dart';

String fixture(String name) => File('test/fixtures/$name').readAsStringSync();

void main() {
  const codec = OrbitRelayJsonCodec();
  const actor = '11111111-1111-4111-8111-111111111111';
  const session = '22222222-2222-4222-8222-222222222222';
  final actorId = ActorId.parse(actor);
  final sessionId = SessionId.parse(session);

  test('decodes Rust hello and negotiated messages', () {
    expect(
      codec.decodeServerMessage(fixture('hello_accepted.json')),
      isA<HelloAcceptedMessage>(),
    );
    final accepted =
        codec.decodeServerMessage(fixture('subscription_accepted.json'))
            as SubscriptionAcceptedMessage;
    expect(accepted.requestId.value, 'c0000000-0000-4000-8000-000000000003');
  });

  test('decodes Rust event, ack, and safe error fixtures', () {
    final event =
        codec.decodeServerMessage(fixture('event_canvas_began.json'))
            as EventServerMessage;
    expect(event.event.eventType, 'canvas.stroke.began');
    expect(event.event.occurredAt.raw, '2023-11-14 22:13:21.0 +00:00:00');
    final ack =
        codec.decodeServerMessage(fixture('action_ack.json'))
            as ActionAcknowledgementMessage;
    expect(ack.generatedEventIds, hasLength(1));
    final error =
        codec.decodeServerMessage(fixture('error.json')) as ServerErrorMessage;
    expect(error.code, 'execution_rejected');
    expect(error.retryable, isFalse);
  });

  test('decodes every Rust Canvas outbound event fixture', () {
    final appended =
        codec.decodeServerMessage(fixture('event_canvas_appended.json'))
            as EventServerMessage;
    final completed =
        codec.decodeServerMessage(fixture('event_canvas_completed.json'))
            as EventServerMessage;
    expect(appended.event.eventType, strokePointsAppendedEventType);
    expect(completed.event.eventType, strokeCompletedEventType);
  });

  test('encodes inbound messages with Rust wire names', () {
    final hello = jsonDecode(codec.encodeHello()) as Map<String, Object?>;
    expect(hello['payload'], <String, Object?>{
      'supported_versions': <Object?>[
        orbitRelayProtocolV02.toJson(),
        orbitRelayProtocolV01.toJson(),
      ],
      'codecs': <Object?>['json'],
    });
    final auth =
        jsonDecode(
              codec.encodeAuthenticate(
                MessageId.parse('c0000000-0000-4000-8000-000000000002'),
                actorId,
              ),
            )
            as Map<String, Object?>;
    expect(auth['kind'], 'authenticate');
    expect(auth, jsonDecode(fixture('authenticate.json')));
    final subscribe =
        jsonDecode(
              codec.encodeSubscribe(
                MessageId.parse('c0000000-0000-4000-8000-000000000003'),
                sessionId,
                canvasEventTypes,
              ),
            )
            as Map<String, Object?>;
    expect(subscribe, jsonDecode(fixture('subscribe.json')));
  });

  test('encodes Canvas Actions exactly like Rust fixtures', () {
    const requestedAt = '2023-11-14 22:13:20.0 +00:00:00';
    final canvasId = CanvasId.parse('33333333-3333-4333-8333-333333333333');
    final layerId = LayerId.parse('44444444-4444-4444-8444-444444444444');
    final strokeId = StrokeId.parse('55555555-5555-4555-8555-555555555555');
    final actions = <(String, MessageId, ActionRequest)>[
      (
        'action_canvas_begin.json',
        MessageId.parse('c0000000-0000-4000-8000-000000000004'),
        ActionRequest(
          id: ActionId.parse('66666666-6666-4666-8666-666666666666'),
          sessionId: sessionId,
          actorId: actorId,
          actionType: strokeBeginActionType,
          requestedAt: OrbitRelayTimestamp.parse(requestedAt),
          payload: StrokeBeginPayload(
            canvasId: canvasId,
            layerId: layerId,
            strokeId: strokeId,
            tool: StrokeTool.pen,
            style: StrokeStyle(width: 4, color: const RgbaColor.black()),
            points: <CanvasPoint>[CanvasPoint(120.5, 240.25)],
          ).toJson(),
        ),
      ),
      (
        'action_canvas_append.json',
        MessageId.parse('c0000000-0000-4000-8000-000000000005'),
        ActionRequest(
          id: ActionId.parse('77777777-7777-4777-8777-777777777777'),
          sessionId: sessionId,
          actorId: actorId,
          actionType: strokeAppendActionType,
          requestedAt: OrbitRelayTimestamp.parse(requestedAt),
          payload: StrokeAppendPayload(
            canvasId: canvasId,
            strokeId: strokeId,
            chunkIndex: 1,
            points: <CanvasPoint>[
              CanvasPoint(130.5, 248.25),
              CanvasPoint(141, 254),
            ],
          ).toJson(),
        ),
      ),
      (
        'action_canvas_end.json',
        MessageId.parse('c0000000-0000-4000-8000-000000000006'),
        ActionRequest(
          id: ActionId.parse('88888888-8888-4888-8888-888888888888'),
          sessionId: sessionId,
          actorId: actorId,
          actionType: strokeEndActionType,
          requestedAt: OrbitRelayTimestamp.parse(requestedAt),
          payload: StrokeEndPayload(
            canvasId: canvasId,
            strokeId: strokeId,
            finalChunkIndex: 1,
          ).toJson(),
        ),
      ),
    ];
    for (final action in actions) {
      expect(
        jsonDecode(codec.encodeAction(action.$2, action.$3)),
        jsonDecode(fixture(action.$1)),
      );
    }
  });

  test('rejects unknown kinds, binary-shaped payloads, and bad timestamps', () {
    expect(
      () => codec.decodeServerMessage('{"kind":"future","payload":{}}'),
      throwsA(isA<ClientProtocolError>()),
    );
    expect(
      () => OrbitRelayTimestamp.parse('2023-11-14T22:13:21Z'),
      throwsFormatException,
    );
    expect(
      () => codec.decodeServerMessage(
        fixture('event_canvas_began.json').replaceFirst(
          '2023-11-14 22:13:21.0 +00:00:00',
          '2023-11-14T22:13:21Z',
        ),
      ),
      throwsA(isA<ClientProtocolError>()),
    );
  });
}
