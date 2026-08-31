import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:orbitrelay_client_flutter/protocol/codec.dart';
import 'package:orbitrelay_client_flutter/protocol/query.dart';
import 'package:orbitrelay_client_flutter/protocol/ids.dart';

String fixture(String name) =>
    File('test/fixtures/v0.2/$name').readAsStringSync();

void main() {
  const codec = OrbitRelayJsonCodec();

  test('encodes strict Protocol 0.2 Query fixtures', () {
    final source = jsonDecode(
      codec.encodeQuery(
        MessageId.parse('33333333-3333-4333-8333-333333333333'),
        'document.get',
        <String, Object?>{
          'document_id': '44444444-4444-4444-8444-444444444444',
        },
      ),
    );
    expect(source, jsonDecode(fixture('query_document_get.json')));
  });

  test('decodes success and error Query responses', () {
    final success =
        codec.decodeServerMessage(
              fixture('query_response_canvas_history_page.json'),
            )
            as QueryResponseMessage;
    expect(success.queryType, 'canvas.history.page');
    expect(success.result, isA<QuerySuccessResult>());

    final error =
        codec.decodeServerMessage(
              fixture('query_response_canvas_history_invalid_cursor.json'),
            )
            as QueryResponseMessage;
    expect(error.result, isA<QueryErrorResult>());
    expect(
      (error.result as QueryErrorResult).code,
      QueryFailureCode.invalidQuery,
    );

    expect(
      codec.decodeServerMessage(
        fixture('query_response_document_list_success.json'),
      ),
      isA<QueryResponseMessage>(),
    );
    expect(
      codec.decodeServerMessage(
        fixture('query_response_asset_access_success.json'),
      ),
      isA<QueryResponseMessage>(),
    );
  });

  test('encodes every first-party Query request shape', () {
    final requests = <String, String>{
      'query_document_list.json': codec.encodeQuery(
        MessageId.parse('11111111-1111-4111-8111-111111111111'),
        'document.list',
        <String, Object?>{'session_id': '22222222-2222-4222-8222-222222222222'},
      ),
      'query_asset_access_resolve.json': codec.encodeQuery(
        MessageId.parse('33333333-3333-4333-8333-333333333333'),
        'asset.access.resolve',
        <String, Object?>{
          'document_id': '44444444-4444-4444-8444-444444444444',
        },
      ),
      'query_canvas_history_first.json': codec.encodeQuery(
        MessageId.parse('33333333-3333-4333-8333-333333333333'),
        'canvas.history.page',
        <String, Object?>{'canvas_id': '77777777-7777-4777-8777-777777777777'},
      ),
      'query_canvas_history_continue.json': codec.encodeQuery(
        MessageId.parse('33333333-3333-4333-8333-333333333334'),
        'canvas.history.page',
        <String, Object?>{
          'canvas_id': '77777777-7777-4777-8777-777777777777',
          'checkpoint': 'AQIAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA',
          'cursor': 'AQEAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA',
        },
      ),
    };
    for (final entry in requests.entries) {
      expect(jsonDecode(entry.value), jsonDecode(fixture(entry.key)));
    }
  });

  test('rejects unknown Query result fields', () {
    final root =
        jsonDecode(fixture('query_response_document_list_success.json'))
            as Map<String, Object?>;
    final result =
        (root['payload'] as Map<String, Object?>)['result']
            as Map<String, Object?>;
    result['unexpected'] = true;
    expect(
      () => codec.decodeServerMessage(jsonEncode(root)),
      throwsA(isA<Exception>()),
    );
  });
}
