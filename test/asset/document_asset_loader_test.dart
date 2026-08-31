import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:orbitrelay_client_flutter/asset/asset_access.dart';
import 'package:orbitrelay_client_flutter/asset/asset_downloader.dart';
import 'package:orbitrelay_client_flutter/asset/document_asset_loader.dart';
import 'package:orbitrelay_client_flutter/document/document_dto.dart';
import 'package:orbitrelay_client_flutter/protocol/ids.dart';
import 'package:orbitrelay_client_flutter/protocol/message.dart';
import 'package:orbitrelay_client_flutter/protocol/query.dart';
import 'package:orbitrelay_client_flutter/session/orbitrelay_session.dart';

final _sessionId = SessionId.parse('11111111-1111-4111-8111-111111111111');
final _documentId = DocumentId.parse('22222222-2222-4222-8222-222222222222');
final _assetId = AssetId.parse('33333333-3333-4333-8333-333333333333');
final _bytes = utf8.encode('verified');
final _hash = sha256.convert(_bytes).toString();

final class FakeAccessSession implements OrbitRelayQuerySession {
  int resolveCalls = 0;

  @override
  SessionId get sessionId => _sessionId;

  @override
  ProtocolVersion? get negotiatedVersion => orbitRelayProtocolV02;

  @override
  int get connectionGeneration => 1;

  @override
  int? get subscriptionGeneration => 1;

  @override
  bool get subscriptionHealthy => true;

  @override
  Future<QueryResult> query(
    String queryType,
    Map<String, Object?> payload, {
    Duration? timeout,
  }) async {
    expect(queryType, assetAccessResolveQueryType);
    resolveCalls += 1;
    return QuerySuccessResult(<String, Object?>{
      'asset_id': _assetId.value,
      'delivery_kind': 'http',
      'url': 'https://assets.example.test/document.pdf',
      'authorization': <String, Object?>{
        'type': 'bearer',
        'token': 'grant-$resolveCalls',
      },
      'expires_at': '2099-01-01T00:00:00Z',
      'supports_range': true,
    });
  }
}

SourceAssetDto source() => SourceAssetDto.fromJson(<String, Object?>{
  'asset_id': _assetId.value,
  'media_type': 'application/pdf',
  'byte_length': _bytes.length,
  'content_hash': _hash,
  'original_filename': 'document.pdf',
});

void main() {
  test('re-resolves a Grant exactly once after HTTP 401', () async {
    final session = FakeAccessSession();
    var sends = 0;
    final client = MockClient.streaming((request, body) async {
      sends += 1;
      if (sends == 1) {
        expect(request.headers['authorization'], 'Bearer grant-1');
        return http.StreamedResponse(const Stream<List<int>>.empty(), 401);
      }
      expect(request.headers['authorization'], 'Bearer grant-2');
      return http.StreamedResponse(
        http.ByteStream(Stream<List<int>>.value(_bytes)),
        200,
      );
    });
    final result = await DocumentAssetLoader(
      accessClient: AssetAccessClient(session: session),
      downloader: AssetDownloader(client: client),
    ).load(documentId: _documentId, sourceAsset: source());

    expect(result.bytes, _bytes);
    expect(session.resolveCalls, 2);
    expect(sends, 2);
  });

  test('does not retry a second rejected Grant', () async {
    final session = FakeAccessSession();
    var sends = 0;
    final client = MockClient.streaming((request, body) async {
      sends += 1;
      return http.StreamedResponse(const Stream<List<int>>.empty(), 401);
    });
    await expectLater(
      DocumentAssetLoader(
        accessClient: AssetAccessClient(session: session),
        downloader: AssetDownloader(client: client),
      ).load(documentId: _documentId, sourceAsset: source()),
      throwsA(
        isA<AssetDownloadException>().having(
          (error) => error.failure,
          'failure',
          AssetDownloadFailure.accessUnauthorized,
        ),
      ),
    );
    expect(session.resolveCalls, 2);
    expect(sends, 2);
  });
}
