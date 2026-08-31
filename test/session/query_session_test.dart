import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:orbitrelay_client_flutter/protocol/ids.dart';
import 'package:orbitrelay_client_flutter/protocol/message.dart';
import 'package:orbitrelay_client_flutter/protocol/query.dart';
import 'package:orbitrelay_client_flutter/session/orbitrelay_session.dart';
import 'package:orbitrelay_client_flutter/transport/websocket_transport.dart';

final _actor = ActorId.parse('11111111-1111-4111-8111-111111111111');
final _session = SessionId.parse('22222222-2222-4222-8222-222222222222');

final class QueryTransport implements TextTransport {
  final StreamController<String> incoming = StreamController<String>.broadcast(
    sync: true,
  );
  final List<String> sent = <String>[];

  @override
  Stream<String> get messages => incoming.stream;

  @override
  Future<void> connect(Uri uri) async {}

  @override
  Future<void> sendText(String value) async => sent.add(value);

  @override
  Future<void> close() async {
    if (!incoming.isClosed) {
      await incoming.close();
    }
  }
}

Future<void> settle() async {
  for (var i = 0; i < 8; i += 1) {
    await Future<void>.delayed(Duration.zero);
  }
}

Map<String, Object?> frame(String source) =>
    (jsonDecode(source) as Map<Object?, Object?>).cast<String, Object?>();

Future<OrbitRelaySession> readySession(QueryTransport transport) async {
  final session = OrbitRelaySession(
    config: OrbitRelaySessionConfig(
      serverUri: Uri.parse('ws://127.0.0.1:8080/ws'),
      actorId: _actor,
      sessionId: _session,
      queryTimeout: const Duration(seconds: 2),
    ),
    transportFactory: () => transport,
  );
  final connected = session.connect();
  await settle();
  transport.incoming.add(
    jsonEncode(<String, Object?>{
      'kind': 'hello_accepted',
      'payload': <String, Object?>{
        'selected_version': orbitRelayProtocolV02.toJson(),
        'codec': 'json',
      },
    }),
  );
  await settle();
  final subscribe = transport.sent
      .map(frame)
      .firstWhere((value) => value['kind'] == 'subscribe');
  final payload = (subscribe['payload'] as Map<Object?, Object?>)
      .cast<String, Object?>();
  transport.incoming.add(
    jsonEncode(<String, Object?>{
      'kind': 'subscription_accepted',
      'payload': <String, Object?>{
        'request_id': payload['request_id'],
        'subscription_id': 'd0000000-0000-4000-8000-000000000001',
      },
    }),
  );
  await connected;
  return session;
}

String response(String requestId, String queryType, String value) =>
    jsonEncode(<String, Object?>{
      'kind': 'query_response',
      'payload': <String, Object?>{
        'version': orbitRelayProtocolV02.toJson(),
        'request_id': requestId,
        'query_type': queryType,
        'result': <String, Object?>{
          'status': 'success',
          'payload': <String, Object?>{'value': value},
        },
      },
    });

void main() {
  test('correlates concurrent Query responses by MessageId', () async {
    final transport = QueryTransport();
    final session = await readySession(transport);
    final first = session.query('document.list', <String, Object?>{
      'session_id': _session.value,
    });
    final second = session.query('document.get', <String, Object?>{
      'document_id': '33333333-3333-4333-8333-333333333333',
    });
    await settle();
    final queries = transport.sent
        .map(frame)
        .where((value) => value['kind'] == 'query')
        .toList();
    expect(queries, hasLength(2));
    String requestId(Map<String, Object?> value) =>
        ((value['payload'] as Map<Object?, Object?>)
                .cast<String, Object?>())['message_id']!
            as String;
    String queryType(Map<String, Object?> value) =>
        ((value['payload'] as Map<Object?, Object?>)
                .cast<String, Object?>())['message_type']!
            as String;
    transport.incoming.add(
      response(requestId(queries[1]), queryType(queries[1]), 'B'),
    );
    transport.incoming.add(
      response(requestId(queries[0]), queryType(queries[0]), 'A'),
    );
    final firstResult = await first as QuerySuccessResult;
    final secondResult = await second as QuerySuccessResult;
    expect(firstResult.payload['value'], 'A');
    expect(secondResult.payload['value'], 'B');
    await session.close();
    session.dispose();
  });

  test('disconnect fails all pending Queries', () async {
    final transport = QueryTransport();
    final session = await readySession(transport);
    final first = session.query('document.list', <String, Object?>{
      'session_id': _session.value,
    });
    final second = session.query('document.get', <String, Object?>{
      'document_id': '33333333-3333-4333-8333-333333333333',
    });
    final firstFailure = expectLater(first, throwsA(isA<QueryException>()));
    final secondFailure = expectLater(second, throwsA(isA<QueryException>()));
    await session.close();
    await firstFailure;
    await secondFailure;
    session.dispose();
  });
}
