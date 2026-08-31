import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:orbitrelay_client_flutter/canvas/canvas_controller.dart';
import 'package:orbitrelay_client_flutter/canvas/canvas_protocol.dart';
import 'package:orbitrelay_client_flutter/canvas/canvas_render_state.dart';
import 'package:orbitrelay_client_flutter/protocol/ids.dart';
import 'package:orbitrelay_client_flutter/session/orbitrelay_session.dart';
import 'package:orbitrelay_client_flutter/session/pending_action.dart';
import 'package:orbitrelay_client_flutter/transport/connection_state.dart';
import 'package:orbitrelay_client_flutter/transport/websocket_transport.dart';

final _actorId = ActorId.parse('11111111-1111-4111-8111-111111111111');
final _sessionId = SessionId.parse('22222222-2222-4222-8222-222222222222');
final _canvasId = CanvasId.parse('33333333-3333-4333-8333-333333333333');
final _layerId = LayerId.parse('44444444-4444-4444-8444-444444444444');

final class FakeTextTransport implements TextTransport {
  final StreamController<String> controller =
      StreamController<String>.broadcast(sync: true);
  final List<String> sent = <String>[];

  @override
  Stream<String> get messages => controller.stream;

  @override
  Future<void> connect(Uri uri) async {}

  @override
  Future<void> sendText(String value) async {
    sent.add(value);
  }

  void serverSend(String value) => controller.add(value);

  @override
  Future<void> close() => controller.close();
}

Map<String, Object?> decodeObject(String source) =>
    (jsonDecode(source) as Map<Object?, Object?>).cast<String, Object?>();

String fixture(String name) => File('test/fixtures/$name').readAsStringSync();

Future<void> settle() async {
  for (var index = 0; index < 6; index += 1) {
    await Future<void>.delayed(Duration.zero);
  }
}

Future<void> waitFor(bool Function() condition) async {
  for (var index = 0; index < 50; index += 1) {
    if (condition()) {
      return;
    }
    await Future<void>.delayed(Duration.zero);
  }
  fail('Timed out waiting for fake transport activity');
}

Future<OrbitRelaySession> connectReady(
  FakeTextTransport transport, {
  List<OrbitRelayConnectionState>? observedStates,
}) async {
  final session = OrbitRelaySession(
    config: OrbitRelaySessionConfig(
      serverUri: Uri.parse('ws://127.0.0.1:8080/ws'),
      actorId: _actorId,
      sessionId: _sessionId,
    ),
    transportFactory: () => transport,
  );
  if (observedStates != null) {
    session.connectionStateListenable.addListener(
      () => observedStates.add(session.connectionState),
    );
  }
  final connected = session.connect();
  await waitFor(() => transport.sent.isNotEmpty);
  expect(decodeObject(transport.sent.first)['kind'], 'hello');
  transport.serverSend(fixture('hello_accepted.json'));
  await waitFor(
    () => transport.sent.any(
      (message) => decodeObject(message)['kind'] == 'subscribe',
    ),
  );
  final subscribe = transport.sent
      .map(decodeObject)
      .firstWhere((message) => message['kind'] == 'subscribe');
  final subscribePayload = (subscribe['payload'] as Map<Object?, Object?>)
      .cast<String, Object?>();
  transport.serverSend(
    jsonEncode(<String, Object?>{
      'kind': 'subscription_accepted',
      'payload': <String, Object?>{
        'request_id': subscribePayload['request_id'],
        'subscription_id': 'd0000000-0000-4000-8000-000000000001',
      },
    }),
  );
  await connected;
  return session;
}

String eventForAction(Map<String, Object?> actionFrame, String eventId) {
  final envelope = (actionFrame['payload'] as Map<Object?, Object?>)
      .cast<String, Object?>();
  final action = (envelope['payload'] as Map<Object?, Object?>)
      .cast<String, Object?>();
  return jsonEncode(<String, Object?>{
    'kind': 'event',
    'payload': <String, Object?>{
      'version': <String, Object?>{'major': 0, 'minor': 1, 'patch': 0},
      'message_id': 'c1000000-0000-4000-8000-000000000001',
      'message_type': 'event',
      'payload': <String, Object?>{
        'id': eventId,
        'session_id': action['session_id'],
        'actor_id': action['actor_id'],
        'action_id': action['id'],
        'event_type': strokeBeganEventType,
        'occurred_at': '2023-11-14 22:13:21.0 +00:00:00',
        'payload': action['payload'],
        'metadata': <String, Object?>{},
      },
    },
  });
}

String acknowledgementForAction(
  Map<String, Object?> actionFrame,
  List<String> eventIds,
) {
  final envelope = (actionFrame['payload'] as Map<Object?, Object?>)
      .cast<String, Object?>();
  final action = (envelope['payload'] as Map<Object?, Object?>)
      .cast<String, Object?>();
  return jsonEncode(<String, Object?>{
    'kind': 'action_acknowledgement',
    'payload': <String, Object?>{
      'request_id': envelope['message_id'],
      'action_id': action['id'],
      'generated_event_ids': eventIds,
    },
  });
}

void main() {
  test('handshake observes every explicit connection state', () async {
    final transport = FakeTextTransport();
    final states = <OrbitRelayConnectionState>[];
    final session = await connectReady(transport, observedStates: states);
    expect(
      states,
      containsAllInOrder(<OrbitRelayConnectionState>[
        OrbitRelayConnectionState.connecting,
        OrbitRelayConnectionState.negotiating,
        OrbitRelayConnectionState.authenticating,
        OrbitRelayConnectionState.subscribing,
        OrbitRelayConnectionState.ready,
      ]),
    );
    await session.close();
    session.dispose();
  });

  for (final eventFirst in <bool>[true, false]) {
    test(
      '${eventFirst ? 'Event then Ack' : 'Ack then Event'} converges to the same Canvas state',
      () async {
        final transport = FakeTextTransport();
        final session = await connectReady(transport);
        final controller = CanvasController(
          session: session,
          descriptor: CanvasClientDescriptor(
            sessionId: _sessionId,
            canvasId: _canvasId,
            layerId: _layerId,
            space: CanvasSpace(100, 100),
          ),
        );
        expect(
          controller.pointerDown(1, const Offset(10, 10), const Size(100, 100)),
          isTrue,
        );
        await waitFor(
          () => transport.sent.any(
            (message) => decodeObject(message)['kind'] == 'action',
          ),
        );
        final actionFrame = transport.sent
            .map(decodeObject)
            .firstWhere((message) => message['kind'] == 'action');
        const eventId = '99999999-9999-4999-8999-999999999999';
        final event = eventForAction(actionFrame, eventId);
        final ack = acknowledgementForAction(
          actionFrame,
          eventFirst ? <String>[] : <String>[eventId],
        );
        if (eventFirst) {
          transport.serverSend(event);
          transport.serverSend(ack);
        } else {
          transport.serverSend(ack);
          transport.serverSend(event);
        }
        await settle();

        final pending = session.pendingActions.values.single;
        expect(pending.status, PendingActionStatus.acknowledged);
        expect(pending.generatedEventIds, hasLength(eventFirst ? 0 : 1));
        expect(controller.health, CanvasHealth.healthy);
        expect(controller.projection.strokes, hasLength(1));
        expect(controller.renderState.value.strokes, hasLength(1));
        expect(
          controller.renderState.value.strokes.single.points,
          hasLength(1),
        );
        expect(controller.optimistic.stroke(pending.strokeId)!.chunks, isEmpty);

        controller.dispose();
        await session.close();
        session.dispose();
      },
    );
  }
}
