import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:orbitrelay_client_flutter/asset/asset_access.dart';
import 'package:orbitrelay_client_flutter/asset/asset_downloader.dart';
import 'package:orbitrelay_client_flutter/document/document_dto.dart';

const _assetId = '11111111-1111-4111-8111-111111111111';
const _token = 'secret-bearer-value';
final _bytes = utf8.encode('verified-pdf-bytes');
final _hash = sha256.convert(_bytes).toString();

AssetAccessDescriptorDto access({String token = _token}) =>
    AssetAccessDescriptorDto.fromJson(<String, Object?>{
      'asset_id': _assetId,
      'delivery_kind': 'http',
      'url': 'https://assets.example.test/v0/assets/$_assetId',
      'authorization': <String, Object?>{'type': 'bearer', 'token': token},
      'expires_at': '2099-01-01T00:00:00Z',
      'supports_range': true,
    });

SourceAssetDto source({
  int? byteLength,
  String? contentHash,
  String mediaType = 'application/pdf',
}) => SourceAssetDto.fromJson(<String, Object?>{
  'asset_id': _assetId,
  'media_type': mediaType,
  'byte_length': byteLength ?? _bytes.length,
  'content_hash': contentHash ?? _hash,
  'original_filename': 'fixture.pdf',
});

http.StreamedResponse response(
  Iterable<List<int>> chunks, {
  int status = 200,
  Map<String, String>? headers,
}) => http.StreamedResponse(
  http.ByteStream(Stream<List<int>>.fromIterable(chunks)),
  status,
  headers: headers ?? const <String, String>{},
);

Matcher failure(AssetDownloadFailure expected) => isA<AssetDownloadException>()
    .having((error) => error.failure, 'failure', expected);

void main() {
  test(
    'streams a verified full download with a redacted bearer header',
    () async {
      late http.BaseRequest captured;
      final client = MockClient.streaming((request, body) async {
        captured = request;
        return response(
          <List<int>>[_bytes.sublist(0, 5), _bytes.sublist(5)],
          headers: <String, String>{
            'content-length': '${_bytes.length}',
            'content-type': 'application/pdf; charset=binary',
            'etag': '"sha256-$_hash"',
          },
        );
      });
      final downloaded = await AssetDownloader(
        client: client,
      ).downloadFull(access: access(), sourceAsset: source());

      expect(downloaded.bytes, _bytes);
      expect(downloaded.contentHash, _hash);
      expect(captured.followRedirects, isFalse);
      expect(captured.headers['authorization'], 'Bearer $_token');
      expect(captured.url.query, isEmpty);
      expect(downloaded.toString(), isNot(contains(_token)));
      expect(access().toString(), isNot(contains(_token)));
    },
  );

  test('maps 401 and 404 without reflecting response bytes', () async {
    for (final entry in <(int, AssetDownloadFailure)>[
      (401, AssetDownloadFailure.accessUnauthorized),
      (404, AssetDownloadFailure.notFound),
    ]) {
      final client = MockClient.streaming(
        (request, body) async => response(<List<int>>[
          utf8.encode('sensitive error page'),
        ], status: entry.$1),
      );
      await expectLater(
        AssetDownloader(
          client: client,
        ).downloadFull(access: access(), sourceAsset: source()),
        throwsA(failure(entry.$2)),
      );
    }
  });

  test('rejects redirects before reading a body', () async {
    final client = MockClient.streaming(
      (request, body) async => response(
        const <List<int>>[],
        status: 302,
        headers: const <String, String>{
          'location': 'https://other.example.test/document.pdf',
        },
      ),
    );
    await expectLater(
      AssetDownloader(
        client: client,
      ).downloadFull(access: access(), sourceAsset: source()),
      throwsA(failure(AssetDownloadFailure.redirectRejected)),
    );
  });

  test('rejects mismatched HTTP metadata', () async {
    final cases = <(Map<String, String>, AssetDownloadFailure)>[
      (
        <String, String>{'content-length': '${_bytes.length + 1}'},
        AssetDownloadFailure.contentLengthMismatch,
      ),
      (
        const <String, String>{'content-type': 'text/html'},
        AssetDownloadFailure.contentTypeMismatch,
      ),
      (
        const <String, String>{'etag': '"sha256-not-the-source-hash"'},
        AssetDownloadFailure.etagMismatch,
      ),
    ];
    for (final entry in cases) {
      final client = MockClient.streaming(
        (request, body) async =>
            response(<List<int>>[_bytes], headers: entry.$1),
      );
      await expectLater(
        AssetDownloader(
          client: client,
        ).downloadFull(access: access(), sourceAsset: source()),
        throwsA(failure(entry.$2)),
      );
    }
  });

  test('rejects an oversized streamed body', () async {
    final expected = source(byteLength: _bytes.length - 1);
    final client = MockClient.streaming(
      (request, body) async => response(<List<int>>[_bytes]),
    );
    await expectLater(
      AssetDownloader(
        client: client,
      ).downloadFull(access: access(), sourceAsset: expected),
      throwsA(failure(AssetDownloadFailure.sizeExceeded)),
    );
  });

  test('rejects a truncated body and a SHA-256 mismatch', () async {
    final truncatedClient = MockClient.streaming(
      (request, body) async =>
          response(<List<int>>[_bytes.sublist(0, _bytes.length - 1)]),
    );
    await expectLater(
      AssetDownloader(
        client: truncatedClient,
      ).downloadFull(access: access(), sourceAsset: source()),
      throwsA(failure(AssetDownloadFailure.contentLengthMismatch)),
    );

    final hashClient = MockClient.streaming(
      (request, body) async => response(<List<int>>[_bytes]),
    );
    await expectLater(
      AssetDownloader(client: hashClient).downloadFull(
        access: access(),
        sourceAsset: source(contentHash: '0' * 64),
      ),
      throwsA(failure(AssetDownloadFailure.hashMismatch)),
    );
  });

  test('enforces the size policy before sending a request', () async {
    var sends = 0;
    final client = MockClient.streaming((request, body) async {
      sends += 1;
      return response(<List<int>>[_bytes]);
    });
    await expectLater(
      AssetDownloader(
        client: client,
        maxAssetBytes: 4,
      ).downloadFull(access: access(), sourceAsset: source()),
      throwsA(failure(AssetDownloadFailure.sizeExceeded)),
    );
    expect(sends, 0);
  });

  test('cancels an in-flight streamed response', () async {
    final started = Completer<void>();
    final client = MockClient.streaming((request, body) async {
      final abortable = request as http.AbortableRequest;
      return http.StreamedResponse(
        http.ByteStream(
          (() async* {
            started.complete();
            yield _bytes.sublist(0, 2);
            await abortable.abortTrigger;
            throw http.RequestAbortedException(request.url);
          })(),
        ),
        200,
      );
    });
    final cancellation = AssetDownloadCancellation();
    final future = AssetDownloader(client: client).downloadFull(
      access: access(),
      sourceAsset: source(),
      cancellation: cancellation,
    );
    await started.future;
    cancellation.cancel();
    await expectLater(future, throwsA(failure(AssetDownloadFailure.cancelled)));
  });

  test('download failures and state never include the bearer token', () {
    const error = AssetDownloadException(
      AssetDownloadFailure.networkUnavailable,
      'Asset request failed before the verified response completed',
    );
    expect(error.toString(), isNot(contains(_token)));
    expect(access().authorization.toString(), isNot(contains(_token)));
  });
}
