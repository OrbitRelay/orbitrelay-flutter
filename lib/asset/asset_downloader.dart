import 'dart:async';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;

import '../document/document_dto.dart';
import '../protocol/ids.dart';
import 'asset_access.dart';

const int defaultMaxAssetBytes = 64 * 1024 * 1024;

enum AssetDownloadFailure {
  assetMismatch,
  grantExpired,
  accessUnauthorized,
  notFound,
  redirectRejected,
  unexpectedStatus,
  networkUnavailable,
  sizeExceeded,
  contentLengthMismatch,
  contentTypeMismatch,
  etagMismatch,
  hashMismatch,
  cancelled,
}

final class AssetDownloadException implements Exception {
  const AssetDownloadException(this.failure, this.message);

  final AssetDownloadFailure failure;
  final String message;

  @override
  String toString() => 'AssetDownloadException(${failure.name}: $message)';
}

final class AssetDownloadCancellation {
  final Completer<void> _abort = Completer<void>();

  Future<void> get whenCancelled => _abort.future;
  bool get isCancelled => _abort.isCompleted;

  void cancel() {
    if (!_abort.isCompleted) {
      _abort.complete();
    }
  }
}

final class DownloadedAsset {
  DownloadedAsset({
    required this.assetId,
    required Uint8List bytes,
    required this.contentHash,
    required this.mediaType,
  }) : bytes = Uint8List.fromList(bytes);

  final AssetId assetId;
  final Uint8List bytes;
  final String contentHash;
  final String mediaType;

  @override
  String toString() =>
      'DownloadedAsset(assetId: ${assetId.value}, bytes: ${bytes.length}, '
      'contentHash: $contentHash, mediaType: $mediaType)';
}

final class AssetDownloader {
  const AssetDownloader({
    required this.client,
    this.maxAssetBytes = defaultMaxAssetBytes,
  }) : assert(maxAssetBytes > 0);

  final http.Client client;
  final int maxAssetBytes;

  Future<DownloadedAsset> downloadFull({
    required AssetAccessDescriptorDto access,
    required SourceAssetDto sourceAsset,
    AssetDownloadCancellation? cancellation,
  }) async {
    _validateBeforeRequest(access, sourceAsset);
    final cancel = cancellation ?? AssetDownloadCancellation();
    if (cancel.isCancelled) {
      throw const AssetDownloadException(
        AssetDownloadFailure.cancelled,
        'Asset download was cancelled',
      );
    }

    final authorization = access.authorization;
    if (authorization is! BearerAuthorizationDto) {
      throw const AssetDownloadException(
        AssetDownloadFailure.accessUnauthorized,
        'Asset authorization is not supported',
      );
    }
    final request =
        http.AbortableRequest(
            'GET',
            access.url,
            abortTrigger: cancel.whenCancelled,
          )
          ..followRedirects = false
          ..headers['authorization'] = 'Bearer ${authorization.token}'
          ..headers['accept'] = sourceAsset.mediaType;

    try {
      final response = await client.send(request);
      _validateResponse(response, sourceAsset);

      final bytes = BytesBuilder(copy: false);
      final digestSink = _DigestSink();
      final hashInput = sha256.startChunkedConversion(digestSink);
      var received = 0;
      try {
        await for (final chunk in response.stream) {
          if (cancel.isCancelled) {
            throw const AssetDownloadException(
              AssetDownloadFailure.cancelled,
              'Asset download was cancelled',
            );
          }
          received += chunk.length;
          if (received > sourceAsset.byteLength || received > maxAssetBytes) {
            cancel.cancel();
            throw const AssetDownloadException(
              AssetDownloadFailure.sizeExceeded,
              'Asset response exceeded its declared or configured size',
            );
          }
          bytes.add(chunk);
          hashInput.add(chunk);
        }
      } finally {
        hashInput.close();
      }

      if (received != sourceAsset.byteLength) {
        throw const AssetDownloadException(
          AssetDownloadFailure.contentLengthMismatch,
          'Asset response length did not match source metadata',
        );
      }
      final actualHash = digestSink.digest?.toString();
      if (actualHash == null || actualHash != sourceAsset.contentHash) {
        throw const AssetDownloadException(
          AssetDownloadFailure.hashMismatch,
          'Asset SHA-256 did not match source metadata',
        );
      }
      return DownloadedAsset(
        assetId: sourceAsset.assetId,
        bytes: bytes.takeBytes(),
        contentHash: actualHash,
        mediaType: sourceAsset.mediaType,
      );
    } on AssetDownloadException {
      rethrow;
    } on http.RequestAbortedException {
      throw const AssetDownloadException(
        AssetDownloadFailure.cancelled,
        'Asset download was cancelled',
      );
    } on http.ClientException {
      if (cancel.isCancelled) {
        throw const AssetDownloadException(
          AssetDownloadFailure.cancelled,
          'Asset download was cancelled',
        );
      }
      throw const AssetDownloadException(
        AssetDownloadFailure.networkUnavailable,
        'Asset request failed before the verified response completed',
      );
    } on Object {
      if (cancel.isCancelled) {
        throw const AssetDownloadException(
          AssetDownloadFailure.cancelled,
          'Asset download was cancelled',
        );
      }
      throw const AssetDownloadException(
        AssetDownloadFailure.networkUnavailable,
        'Asset response stream failed before verification completed',
      );
    }
  }

  void _validateBeforeRequest(
    AssetAccessDescriptorDto access,
    SourceAssetDto sourceAsset,
  ) {
    if (access.assetId != sourceAsset.assetId) {
      throw const AssetDownloadException(
        AssetDownloadFailure.assetMismatch,
        'Asset access Grant does not match source metadata',
      );
    }
    if (access.isExpired) {
      throw const AssetDownloadException(
        AssetDownloadFailure.grantExpired,
        'Asset access Grant has expired',
      );
    }
    if (sourceAsset.byteLength > maxAssetBytes) {
      throw const AssetDownloadException(
        AssetDownloadFailure.sizeExceeded,
        'Asset exceeds the configured download size limit',
      );
    }
  }

  void _validateResponse(
    http.StreamedResponse response,
    SourceAssetDto sourceAsset,
  ) {
    if (response.statusCode >= 300 && response.statusCode < 400) {
      throw const AssetDownloadException(
        AssetDownloadFailure.redirectRejected,
        'Asset redirects are not allowed for bearer requests',
      );
    }
    if (response.statusCode == 401) {
      throw const AssetDownloadException(
        AssetDownloadFailure.accessUnauthorized,
        'Asset access Grant was rejected',
      );
    }
    if (response.statusCode == 404) {
      throw const AssetDownloadException(
        AssetDownloadFailure.notFound,
        'Authorized Asset locator was not found',
      );
    }
    if (response.statusCode != 200) {
      throw AssetDownloadException(
        AssetDownloadFailure.unexpectedStatus,
        'Asset server returned HTTP ${response.statusCode}',
      );
    }

    final contentLength = response.headers['content-length'];
    if (contentLength != null &&
        int.tryParse(contentLength) != sourceAsset.byteLength) {
      throw const AssetDownloadException(
        AssetDownloadFailure.contentLengthMismatch,
        'Content-Length did not match source metadata',
      );
    }
    final contentType = response.headers['content-type'];
    if (contentType != null &&
        contentType.split(';').first.trim().toLowerCase() !=
            sourceAsset.mediaType.toLowerCase()) {
      throw const AssetDownloadException(
        AssetDownloadFailure.contentTypeMismatch,
        'Content-Type did not match source metadata',
      );
    }
    final etag = response.headers['etag'];
    if (etag != null && etag != '"sha256-${sourceAsset.contentHash}"') {
      throw const AssetDownloadException(
        AssetDownloadFailure.etagMismatch,
        'ETag did not match source metadata',
      );
    }
  }
}

final class _DigestSink implements Sink<Digest> {
  Digest? digest;

  @override
  void add(Digest data) => digest = data;

  @override
  void close() {}
}
