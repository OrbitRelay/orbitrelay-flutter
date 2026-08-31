import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:orbitrelay_client_flutter/asset/asset_access.dart';
import 'package:orbitrelay_client_flutter/document/document_dto.dart';
import 'package:orbitrelay_client_flutter/protocol/ids.dart';

Map<String, Object?> fixture(String name) =>
    (jsonDecode(File('test/fixtures/v0.2/$name').readAsStringSync())
            as Map<Object?, Object?>)
        .cast<String, Object?>();

Map<String, Object?> resultPayload(Map<String, Object?> root) =>
    ((root['payload'] as Map<Object?, Object?>)
                    .cast<String, Object?>()['result']
                as Map<Object?, Object?>)
            .cast<String, Object?>()['payload']
        as Map<String, Object?>;

void main() {
  final sessionId = SessionId.parse('22222222-2222-4222-8222-222222222222');

  test('decodes and validates Rust DocumentView DTO', () {
    final view = DocumentViewDto.fromJson(
      resultPayload(fixture('query_response_document_get_success.json')),
      activeSessionId: sessionId,
    );
    expect(view.document.sessionId, sessionId);
    expect(view.document.pages, hasLength(1));
    expect(view.pageCanvases.single.canvas.space.width, 612);
    expect(
      view.pageCanvases.single.canvas.defaultLayerId.value,
      '88888888-8888-4888-8888-888888888888',
    );
  });

  test('rejects inconsistent DocumentView relationships', () {
    final payload = resultPayload(
      fixture('query_response_document_get_success.json'),
    );
    final document = (payload['document'] as Map<Object?, Object?>)
        .cast<String, Object?>();
    document['session_id'] = '99999999-9999-4999-8999-999999999999';
    expect(
      () => DocumentViewDto.fromJson(payload, activeSessionId: sessionId),
      throwsA(isA<Exception>()),
    );
  });

  test('parses Asset access and never exposes bearer token', () {
    final descriptor = AssetAccessDescriptorDto.fromJson(
      resultPayload(fixture('query_response_asset_access_success.json')),
    );
    expect(descriptor.deliveryKind, 'http');
    expect(descriptor.expiresAt.isUtc, isTrue);
    expect(descriptor.toString(), isNot(contains('AAAA')));
    expect(descriptor.authorization.toString(), isNot(contains('AAAA')));
    expect(
      (descriptor.authorization as BearerAuthorizationDto).token,
      isNotEmpty,
    );
  });

  test('parses the live Rust human-readable UTC Timestamp form', () {
    final descriptor = AssetAccessDescriptorDto.fromJson(<String, Object?>{
      'asset_id': '55555555-5555-4555-8555-555555555555',
      'delivery_kind': 'http',
      'url':
          'http://127.0.0.1:8081/assets/55555555-5555-4555-8555-555555555555',
      'authorization': <String, Object?>{
        'type': 'bearer',
        'token': 'redacted-in-test',
      },
      'expires_at': '2026-08-28 10:30:45.123456789 +00:00:00',
      'supports_range': true,
    });
    expect(descriptor.expiresAt, DateTime.parse('2026-08-28T10:30:45.123456Z'));
  });
}
