import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orbitrelay_client_flutter/canvas/canvas_controller.dart';
import 'package:orbitrelay_client_flutter/canvas/canvas_protocol.dart';
import 'package:orbitrelay_client_flutter/protocol/ids.dart';
import 'package:orbitrelay_client_flutter/protocol/message.dart';
import 'package:orbitrelay_client_flutter/transport/connection_state.dart';
import 'package:orbitrelay_client_flutter/ui/canvas_page.dart';

import '../support/fake_canvas_session.dart';

final _actorId = ActorId.parse('11111111-1111-4111-8111-111111111111');
final _sessionId = SessionId.parse('22222222-2222-4222-8222-222222222222');
final _canvasId = CanvasId.parse('33333333-3333-4333-8333-333333333333');
final _layerId = LayerId.parse('44444444-4444-4444-8444-444444444444');

CanvasClientDescriptor descriptor() => CanvasClientDescriptor(
  sessionId: _sessionId,
  canvasId: _canvasId,
  layerId: _layerId,
  space: CanvasSpace(1920, 1080),
);

Widget page(FakeCanvasSession session) => MaterialApp(
  home: CanvasPage(
    session: session,
    descriptor: descriptor(),
    actorId: _actorId,
  ),
);

void main() {
  testWidgets('Ready session shows the realtime Canvas surface', (
    tester,
  ) async {
    final session = FakeCanvasSession();
    await tester.pumpWidget(page(session));
    expect(find.text('Realtime Canvas'), findsOneWidget);
    expect(find.text('Realtime'), findsOneWidget);
    expect(find.byKey(const Key('canvas-input-surface')), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('Disconnected Canvas blocks pointer input', (tester) async {
    final session = FakeCanvasSession(
      initialState: OrbitRelayConnectionState.disconnected,
    );
    await tester.pumpWidget(page(session));
    expect(find.text('Disconnected'), findsOneWidget);
    final surface = find.byKey(const Key('canvas-input-surface'));
    final gesture = await tester.startGesture(tester.getCenter(surface));
    await gesture.moveBy(const Offset(20, 20));
    await gesture.up();
    await tester.pump();
    expect(session.actions, isEmpty);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('desynchronized Canvas displays error and blocks input', (
    tester,
  ) async {
    final session = FakeCanvasSession();
    await tester.pumpWidget(page(session));
    session.emitEvent(
      EventMessage(
        messageId: MessageId.generate(),
        id: EventId.parse('99999999-9999-4999-8999-999999999999'),
        sessionId: _sessionId,
        actorId: _actorId,
        actionId: ActionId.generate(),
        eventType: strokePointsAppendedEventType,
        occurredAt: OrbitRelayTimestamp.parse(
          '2023-11-14 22:13:21.0 +00:00:00',
        ),
        payload: StrokeAppendPayload(
          canvasId: _canvasId,
          strokeId: StrokeId.generate(),
          chunkIndex: 1,
          points: <CanvasPoint>[CanvasPoint(1, 1)],
        ).toJson(),
      ),
    );
    await tester.pump();
    await tester.pump();
    expect(
      find.text('Canvas realtime state is out of sync. Reconnect to continue.'),
      findsOneWidget,
    );
    final surface = find.byKey(const Key('canvas-input-surface'));
    final gesture = await tester.startGesture(tester.getCenter(surface));
    await gesture.up();
    expect(session.actions, isEmpty);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
