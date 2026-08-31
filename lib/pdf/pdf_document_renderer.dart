import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:pdfrx/pdfrx.dart' as pdfrx;

import '../asset/asset_downloader.dart';

const int defaultMaxRenderPixels = 16 * 1000 * 1000;

enum PdfRendererFailure {
  invalidDocument,
  encryptedDocument,
  pageCountMismatch,
  pageOutOfRange,
  renderFailed,
  disposed,
}

final class PdfRendererException implements Exception {
  const PdfRendererException(this.failure, this.message);

  final PdfRendererFailure failure;
  final String message;

  @override
  String toString() => 'PdfRendererException(${failure.name}: $message)';
}

final class PdfPageInfo {
  const PdfPageInfo({
    required this.pageIndex,
    required this.width,
    required this.height,
    required this.rotationDegrees,
  });

  final int pageIndex;
  final double width;
  final double height;
  final int rotationDegrees;
}

final class RenderedPdfPage {
  RenderedPdfPage({
    required this.pageIndex,
    required this.image,
    required this.pixelWidth,
    required this.pixelHeight,
  });

  final int pageIndex;
  final ui.Image image;
  final int pixelWidth;
  final int pixelHeight;
  bool _disposed = false;

  bool get isDisposed => _disposed;

  void dispose() {
    if (_disposed) {
      return;
    }
    _disposed = true;
    image.dispose();
  }
}

abstract interface class PdfDocumentRenderer {
  Future<RenderedPdfDocument> open({
    required DownloadedAsset asset,
    required int expectedPageCount,
  });
}

abstract interface class RenderedPdfDocument {
  int get pageCount;
  bool get isDisposed;

  PdfPageInfo pageInfo(int pageIndex);

  Future<RenderedPdfPage> renderPage({
    required int pageIndex,
    required ui.Size targetPixelSize,
  });

  void cancelRender();
  Future<void> dispose();
}

final class PdfrxPdfDocumentRenderer implements PdfDocumentRenderer {
  const PdfrxPdfDocumentRenderer({
    this.maxRenderPixels = defaultMaxRenderPixels,
    this.initialize = pdfrx.pdfrxFlutterInitialize,
  }) : assert(maxRenderPixels > 0);

  final int maxRenderPixels;
  final Future<void> Function() initialize;

  @override
  Future<RenderedPdfDocument> open({
    required DownloadedAsset asset,
    required int expectedPageCount,
  }) async {
    if (!_hasPdfHeader(asset.bytes)) {
      throw const PdfRendererException(
        PdfRendererFailure.invalidDocument,
        'Verified Asset bytes are not a supported PDF document',
      );
    }
    await initialize();
    pdfrx.PdfDocument document;
    try {
      document = await pdfrx.PdfDocument.openData(
        asset.bytes,
        sourceName: 'orbitrelay:${asset.assetId.value}:${asset.contentHash}',
        firstAttemptByEmptyPassword: true,
      );
    } on pdfrx.PdfPasswordException {
      throw const PdfRendererException(
        PdfRendererFailure.encryptedDocument,
        'Encrypted PDF documents are not supported',
      );
    } on Object {
      throw const PdfRendererException(
        PdfRendererFailure.invalidDocument,
        'Verified Asset bytes are not a supported PDF document',
      );
    }
    if (document.isEncrypted) {
      await document.dispose();
      throw const PdfRendererException(
        PdfRendererFailure.encryptedDocument,
        'Encrypted PDF documents are not supported',
      );
    }
    if (document.pages.length != expectedPageCount) {
      await document.dispose();
      throw PdfRendererException(
        PdfRendererFailure.pageCountMismatch,
        'Renderer reported ${document.pages.length} pages; expected '
        '$expectedPageCount',
      );
    }
    return _PdfrxRenderedDocument(document, maxRenderPixels);
  }

  bool _hasPdfHeader(List<int> bytes) {
    const header = <int>[0x25, 0x50, 0x44, 0x46, 0x2d];
    final lastStart = math.min(bytes.length - header.length, 1024);
    for (var start = 0; start <= lastStart; start += 1) {
      var matches = true;
      for (var offset = 0; offset < header.length; offset += 1) {
        if (bytes[start + offset] != header[offset]) {
          matches = false;
          break;
        }
      }
      if (matches) {
        return true;
      }
    }
    return false;
  }
}

final class _PdfrxRenderedDocument implements RenderedPdfDocument {
  _PdfrxRenderedDocument(this._document, this._maxRenderPixels);

  final pdfrx.PdfDocument _document;
  final int _maxRenderPixels;
  pdfrx.PdfPageRenderCancellationToken? _renderCancellation;
  bool _disposed = false;

  @override
  int get pageCount => _document.pages.length;

  @override
  bool get isDisposed => _disposed;

  @override
  PdfPageInfo pageInfo(int pageIndex) {
    final page = _pageAt(pageIndex);
    return PdfPageInfo(
      pageIndex: pageIndex,
      width: page.width,
      height: page.height,
      rotationDegrees: page.rotation.index * 90,
    );
  }

  @override
  Future<RenderedPdfPage> renderPage({
    required int pageIndex,
    required ui.Size targetPixelSize,
  }) async {
    final page = _pageAt(pageIndex);
    if (!targetPixelSize.width.isFinite ||
        !targetPixelSize.height.isFinite ||
        targetPixelSize.width <= 0 ||
        targetPixelSize.height <= 0) {
      throw const PdfRendererException(
        PdfRendererFailure.renderFailed,
        'PDF render target must be finite and positive',
      );
    }
    cancelRender();
    final dimensions = _boundedDimensions(
      targetPixelSize,
      page.width / page.height,
    );
    final cancellation = page.createCancellationToken();
    _renderCancellation = cancellation;
    pdfrx.PdfImage? rawImage;
    try {
      rawImage = await page.render(
        width: dimensions.$1,
        height: dimensions.$2,
        fullWidth: dimensions.$1.toDouble(),
        fullHeight: dimensions.$2.toDouble(),
        cancellationToken: cancellation,
      );
      if (_disposed || cancellation.isCanceled || rawImage == null) {
        throw const PdfRendererException(
          PdfRendererFailure.renderFailed,
          'PDF page render was cancelled or returned no image',
        );
      }
      final image = await rawImage.createImage();
      if (_disposed || cancellation.isCanceled) {
        image.dispose();
        throw const PdfRendererException(
          PdfRendererFailure.renderFailed,
          'PDF page render was superseded',
        );
      }
      return RenderedPdfPage(
        pageIndex: pageIndex,
        image: image,
        pixelWidth: rawImage.width,
        pixelHeight: rawImage.height,
      );
    } on PdfRendererException {
      rethrow;
    } on Object {
      throw const PdfRendererException(
        PdfRendererFailure.renderFailed,
        'PDF page could not be rendered',
      );
    } finally {
      rawImage?.dispose();
      if (identical(_renderCancellation, cancellation)) {
        _renderCancellation = null;
      }
    }
  }

  (int, int) _boundedDimensions(ui.Size requested, double pageAspect) {
    var width = requested.width;
    var height = width / pageAspect;
    if (height > requested.height) {
      height = requested.height;
      width = height * pageAspect;
    }
    final pixels = width * height;
    if (pixels > _maxRenderPixels) {
      final scale = math.sqrt(_maxRenderPixels / pixels);
      width *= scale;
      height *= scale;
    }
    return (width.floor().clamp(1, 1 << 30), height.floor().clamp(1, 1 << 30));
  }

  pdfrx.PdfPage _pageAt(int pageIndex) {
    if (_disposed) {
      throw const PdfRendererException(
        PdfRendererFailure.disposed,
        'PDF document is disposed',
      );
    }
    if (pageIndex < 0 || pageIndex >= _document.pages.length) {
      throw const PdfRendererException(
        PdfRendererFailure.pageOutOfRange,
        'PDF page index is out of range',
      );
    }
    // OrbitRelay indexes pages from zero; pdfrx stores page N at N - 1 and
    // exposes the matching one-based pageNumber on the returned page.
    final page = _document.pages[pageIndex];
    if (page.pageNumber != pageIndex + 1) {
      throw const PdfRendererException(
        PdfRendererFailure.pageOutOfRange,
        'PDF renderer page numbering is inconsistent',
      );
    }
    return page;
  }

  @override
  void cancelRender() {
    _renderCancellation?.cancel();
    _renderCancellation = null;
  }

  @override
  Future<void> dispose() async {
    if (_disposed) {
      return;
    }
    _disposed = true;
    cancelRender();
    await _document.dispose();
  }
}
