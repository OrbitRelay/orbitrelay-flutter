import '../document/document_dto.dart';
import '../protocol/ids.dart';
import 'asset_access.dart';
import 'asset_downloader.dart';

final class DocumentAssetLoader {
  const DocumentAssetLoader({
    required this.accessClient,
    required this.downloader,
  });

  final AssetAccessClient accessClient;
  final AssetDownloader downloader;

  Future<DownloadedAsset> load({
    required DocumentId documentId,
    required SourceAssetDto sourceAsset,
    AssetDownloadCancellation? cancellation,
  }) async {
    var access = await accessClient.resolveForDocument(documentId);
    try {
      return await downloader.downloadFull(
        access: access,
        sourceAsset: sourceAsset,
        cancellation: cancellation,
      );
    } on AssetDownloadException catch (error) {
      if (error.failure != AssetDownloadFailure.accessUnauthorized ||
          (cancellation?.isCancelled ?? false)) {
        rethrow;
      }
      access = await accessClient.resolveForDocument(documentId);
      return downloader.downloadFull(
        access: access,
        sourceAsset: sourceAsset,
        cancellation: cancellation,
      );
    }
  }
}
