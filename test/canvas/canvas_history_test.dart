import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:orbitrelay_client_flutter/canvas/canvas_history.dart';
import 'package:orbitrelay_client_flutter/canvas/canvas_protocol.dart';
import 'package:orbitrelay_client_flutter/protocol/ids.dart';
import 'package:orbitrelay_client_flutter/protocol/message.dart';
import 'package:orbitrelay_client_flutter/protocol/query.dart';
import 'package:orbitrelay_client_flutter/session/orbitrelay_session.dart';

final _actor = ActorId.parse('11111111-1111-4111-8111-111111111111');
final _session = SessionId.parse('22222222-2222-4222-8222-222222222222');
final _canvas = CanvasId.parse('33333333-3333-4333-8333-333333333333');
final _layer = LayerId.parse('44444444-4444-4444-8444-444444444444');

final class FakeQuerySession implements OrbitRelayQuerySession {
  FakeQuerySession(this.pages);

  final List<Map<String, Object?>> pages;
  int generation = 1;
  int? subscription = 1;
  int calls = 0;
  Completer<QueryResult>? queryGate;
  final List<Map<String, Object?>> requests = <Map<String, Object?>>[];

  @override
  SessionId get sessionId => _session;

  @override
  ProtocolVersion? get negotiatedVersion => orbitRelayProtocolV02;

  @override
  int get connectionGeneration => generation;

  @override
  int? get subscriptionGeneration => subscription;

  @override
  bool get subscriptionHealthy => subscription != null;

  @override
  Future<QueryResult> query(
    String queryType,
    Map<String, Object?> payload, {
    Duration? timeout,
  }) async {
    requests.add(payload);
    final gate = queryGate;
    if (gate != null) {
      return gate.future;
    }
    return QuerySuccessResult(pages[calls++]);
  }
}

Map<String, Object?> page({
  required bool complete,
  String? cursor,
  List<Map<String, Object?>> events = const <Map<String, Object?>>[],
}) => <String, Object?>{
  'canvas_id': _canvas.value,
  'checkpoint': 'opaque-checkpoint',
  'events': events,
  'next_cursor': cursor,
  'complete': complete,
};

Map<String, Object?> eventJson(String id) => <String, Object?>{
  'event_id': id,
  'session_id': _session.value,
  'actor_id': _actor.value,
  'action_id': id,
  'event_type': strokeBeganEventType,
  'occurred_at': '2023-11-14 22:13:20.0 +00:00:00',
  'payload': <String, Object?>{
    'canvas_id': _canvas.value,
    'layer_id': _layer.value,
    'stroke_id': id,
    'tool': 'pen',
    'style': <String, Object?>{
      'width': 2.0,
      'color': <String, Object?>{'red': 0, 'green': 0, 'blue': 0, 'alpha': 255},
    },
    'chunk_index': 0,
    'points': <Object?>[
      <String, Object?>{'x': 1.0, 'y': 1.0},
    ],
  },
  'metadata': <String, Object?>{},
};

EventMessage realtime(String id) {
  final event = HistoryEventDto.fromJson(eventJson(id));
  return event.toEventMessage();
}

void main() {
  test('loader continues across an empty incomplete page', () async {
    final session = FakeQuerySession(<Map<String, Object?>>[
      page(complete: false, cursor: 'cursor-1'),
      page(
        complete: true,
        events: <Map<String, Object?>>[
          eventJson('55555555-5555-4555-8555-555555555555'),
        ],
      ),
    ]);
    final events = await CanvasHistoryLoader(session: session).load(_canvas);
    expect(events, hasLength(1));
    expect(session.requests[1]['checkpoint'], 'opaque-checkpoint');
    expect(session.requests[1]['cursor'], 'cursor-1');
  });

  test(
    'replay deduplicates overlap and flushes post-checkpoint events',
    () async {
      final overlapId = '55555555-5555-4555-8555-555555555555';
      final history = page(
        complete: true,
        events: <Map<String, Object?>>[eventJson(overlapId)],
      );
      final session = FakeQuerySession(<Map<String, Object?>>[history]);
      final applied = <String>[];
      final replay = CanvasReplayController(
        session: session,
        canvasId: _canvas,
        loader: CanvasHistoryLoader(session: session),
        onIngest: (event) => applied.add(event.id.value),
      );
      final start = replay.start();
      replay.receiveRealtime(realtime(overlapId));
      final afterId = '66666666-6666-4666-8666-666666666666';
      replay.receiveRealtime(realtime(afterId));
      await start;
      expect(replay.state, CanvasReplayState.live);
      expect(applied, <String>[overlapId, afterId]);
    },
  );

  test(
    'buffer overflow desynchronizes replay without dropping to Live',
    () async {
      final session = FakeQuerySession(<Map<String, Object?>>[
        page(complete: true),
      ]);
      session.queryGate = Completer<QueryResult>();
      final replay = CanvasReplayController(
        session: session,
        canvasId: _canvas,
        loader: CanvasHistoryLoader(session: session),
        onIngest: (_) {},
        maxBufferedEvents: 1,
      );
      final start = replay.start();
      replay.receiveRealtime(realtime('77777777-7777-4777-8777-777777777777'));
      replay.receiveRealtime(realtime('88888888-8888-4888-8888-888888888888'));
      expect(replay.state, CanvasReplayState.desynced);
      session.queryGate!.complete(QuerySuccessResult(page(complete: true)));
      await start;
      expect(replay.state, CanvasReplayState.desynced);
      replay.dispose();
    },
  );

  test(
    'connection generation change invalidates an in-flight replay',
    () async {
      final session = FakeQuerySession(<Map<String, Object?>>[
        page(complete: true),
      ]);
      session.queryGate = Completer<QueryResult>();
      final applied = <String>[];
      final replay = CanvasReplayController(
        session: session,
        canvasId: _canvas,
        loader: CanvasHistoryLoader(session: session),
        onIngest: (event) => applied.add(event.id.value),
      );

      final start = replay.start();
      expect(replay.state, CanvasReplayState.loadingHistory);
      session.generation += 1;
      session.queryGate!.complete(
        QuerySuccessResult(
          page(
            complete: true,
            events: <Map<String, Object?>>[
              eventJson('99999999-9999-4999-8999-999999999999'),
            ],
          ),
        ),
      );
      await start;

      expect(replay.state, CanvasReplayState.desynced);
      expect(replay.canDraw, isFalse);
      expect(applied, isEmpty);
      replay.dispose();
    },
  );

  test('realtime arriving during buffer flush remains ordered', () async {
    const first = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
    const second = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb';
    const duringFlush = 'cccccccc-cccc-4ccc-8ccc-cccccccccccc';
    final session = FakeQuerySession(<Map<String, Object?>>[
      page(complete: true),
    ]);
    session.queryGate = Completer<QueryResult>();
    final applied = <String>[];
    late CanvasReplayController replay;
    replay = CanvasReplayController(
      session: session,
      canvasId: _canvas,
      loader: CanvasHistoryLoader(session: session),
      onIngest: (event) {
        applied.add(event.id.value);
        if (event.id.value == first) {
          replay.receiveRealtime(realtime(duringFlush));
        }
      },
    );

    final start = replay.start();
    replay.receiveRealtime(realtime(first));
    replay.receiveRealtime(realtime(second));
    session.queryGate!.complete(QuerySuccessResult(page(complete: true)));
    await start;

    expect(replay.state, CanvasReplayState.live);
    expect(applied, <String>[first, second, duringFlush]);
    replay.dispose();
  });

  test('retry after desync starts a clean full replay', () async {
    const stale = 'dddddddd-dddd-4ddd-8ddd-dddddddddddd';
    const history = 'eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee';
    final session = FakeQuerySession(<Map<String, Object?>>[
      page(complete: true, events: <Map<String, Object?>>[eventJson(history)]),
    ]);
    session.queryGate = Completer<QueryResult>();
    final applied = <String>[];
    var resets = 0;
    final replay = CanvasReplayController(
      session: session,
      canvasId: _canvas,
      loader: CanvasHistoryLoader(session: session),
      onIngest: (event) => applied.add(event.id.value),
      onReset: () {
        resets += 1;
        applied.clear();
      },
      maxBufferedEvents: 1,
    );

    final firstAttempt = replay.start();
    replay.receiveRealtime(realtime(stale));
    replay.receiveRealtime(realtime('ffffffff-ffff-4fff-8fff-ffffffffffff'));
    session.queryGate!.complete(QuerySuccessResult(page(complete: true)));
    await firstAttempt;
    expect(replay.state, CanvasReplayState.desynced);

    session.queryGate = null;
    await replay.retryFullReplay();
    expect(replay.state, CanvasReplayState.live);
    expect(applied, <String>[history]);
    expect(resets, 2);
    replay.dispose();
  });
}
