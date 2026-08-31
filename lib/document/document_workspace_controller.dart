import 'dart:async';
import 'dart:ui';

import 'package:flutter/foundation.dart';

import '../asset/asset_downloader.dart';
import '../asset/document_asset_loader.dart';
import '../canvas/canvas_controller.dart';
import '../canvas/canvas_history.dart';
import '../canvas/canvas_protocol.dart';
import '../canvas/canvas_render_state.dart';
import '../canvas/viewport_transform.dart';
import '../pdf/pdf_document_renderer.dart';
import '../protocol/ids.dart';
import '../session/orbitrelay_session.dart';
import '../transport/connection_state.dart';
import 'document_client.dart';
import 'document_dto.dart';

enum DocumentWorkspaceStatus {
  idle,
  loadingDocuments,
  loadingDocument,
  downloadingAsset,
  openingPdf,
  loadingPage,
  replayingCanvas,
  ready,
  error,
}

final class DocumentWorkspaceController extends ChangeNotifier {
  DocumentWorkspaceController({
    required this.session,
    required this.documentClient,
    required this.assetLoader,
    required this.pdfRenderer,
  }) {
    session.connectionStateListenable.addListener(_handleSessionState);
  }

  final OrbitRelayCollaborationSession session;
  final DocumentClient documentClient;
  final DocumentAssetLoader assetLoader;
  final PdfDocumentRenderer pdfRenderer;

  DocumentWorkspaceStatus _status = DocumentWorkspaceStatus.idle;
  List<DocumentSummaryDto> _documents = const <DocumentSummaryDto>[];
  DocumentViewDto? _documentView;
  DownloadedAsset? _downloadedAsset;
  RenderedPdfDocument? _pdfDocument;
  RenderedPdfPage? _renderedPage;
  CanvasReplayController? _replayController;
  CanvasController? _canvasController;
  AssetDownloadCancellation? _downloadCancellation;
  Object? _error;
  int _documentGeneration = 0;
  int _pageGeneration = 0;
  int _renderGeneration = 0;
  int? _selectedPageIndex;
  Size? _lastViewportSize;
  double _lastDevicePixelRatio = 1;
  (int, int)? _activeRenderBucket;
  bool _loadingDocuments = false;
  bool _loadingDocument = false;
  bool _downloadingAsset = false;
  bool _openingPdf = false;
  bool _renderingPage = false;
  bool _disposed = false;

  DocumentWorkspaceStatus get status => _status;
  List<DocumentSummaryDto> get documents => _documents;
  DocumentViewDto? get documentView => _documentView;
  DocumentPageDto? get selectedPage {
    final view = _documentView;
    final index = _selectedPageIndex;
    if (view == null || index == null) {
      return null;
    }
    return view.document.pages[index];
  }

  int? get selectedPageIndex => _selectedPageIndex;
  bool get hasVerifiedAsset => _downloadedAsset != null;
  RenderedPdfPage? get renderedPage => _renderedPage;
  CanvasSpace? get currentCanvasSpace => _canvasController?.descriptor.space;
  CanvasRenderState get canvasRenderState =>
      _canvasController?.renderState.value ?? CanvasRenderState.empty();
  Object? get error => _error;
  CanvasReplayState get replayState =>
      _replayController?.state ?? CanvasReplayState.idle;

  bool get canAnnotate {
    final page = _renderedPage;
    return !_disposed &&
        _status == DocumentWorkspaceStatus.ready &&
        session.connectionState == OrbitRelayConnectionState.ready &&
        session.subscriptionHealthy &&
        _replayController?.state == CanvasReplayState.live &&
        _canvasController?.canDraw == true &&
        page != null &&
        !page.isDisposed &&
        page.pageIndex == _selectedPageIndex;
  }

  Future<void> initialize() async {
    if (_disposed || _loadingDocuments) {
      return;
    }
    _loadingDocuments = true;
    debugPrint(
      'OrbitRelay workspace initialize '
      'connection_generation=${session.connectionGeneration} '
      'subscription_generation=${session.subscriptionGeneration} '
      'state=${session.connectionState.name}',
    );
    _error = null;
    _recomputeStatus();
    try {
      final result = await documentClient.listDocuments();
      if (_disposed) {
        return;
      }
      _documents = List<DocumentSummaryDto>.unmodifiable(result.documents);
      debugPrint(
        'OrbitRelay workspace document.list completed count=${_documents.length}',
      );
    } on Object catch (error) {
      debugPrint('OrbitRelay workspace document.list failed: $error');
      _setError(error);
    } finally {
      _loadingDocuments = false;
      _recomputeStatus();
    }
  }

  Future<void> selectDocument(DocumentId documentId) async {
    final generation = ++_documentGeneration;
    _pageGeneration += 1;
    _renderGeneration += 1;
    await _releaseDocumentResources();
    if (_disposed || generation != _documentGeneration) {
      return;
    }
    _loadingDocument = true;
    _error = null;
    _recomputeStatus();
    try {
      final view = await documentClient.getDocument(documentId);
      if (!_isCurrentDocument(generation)) {
        return;
      }
      if (view.document.pages.isEmpty) {
        throw StateError('Document has no pages');
      }
      _documentView = view;
      _selectedPageIndex = 0;
      _loadingDocument = false;
      _recomputeStatus();

      final replay = _activateCanvas(
        pageIndex: 0,
        documentGeneration: generation,
      );
      final asset = _loadAndOpenPdf(view, generation);
      await Future.wait<void>(<Future<void>>[replay, asset]);
      if (_isCurrentDocument(generation)) {
        _recomputeStatus();
        _requestLastRenderTarget();
      }
    } on Object catch (error) {
      if (_isCurrentDocument(generation)) {
        _setError(error);
      }
    } finally {
      if (_isCurrentDocument(generation)) {
        _loadingDocument = false;
        _recomputeStatus();
      }
    }
  }

  Future<void> _loadAndOpenPdf(DocumentViewDto view, int generation) async {
    _downloadingAsset = true;
    _recomputeStatus();
    final cancellation = AssetDownloadCancellation();
    _downloadCancellation = cancellation;
    try {
      final asset = await assetLoader.load(
        documentId: view.document.documentId,
        sourceAsset: view.sourceAsset,
        cancellation: cancellation,
      );
      if (!_isCurrentDocument(generation)) {
        return;
      }
      _downloadedAsset = asset;
      _downloadingAsset = false;
      _openingPdf = true;
      _recomputeStatus();
      final document = await pdfRenderer.open(
        asset: asset,
        expectedPageCount: view.document.pages.length,
      );
      if (!_isCurrentDocument(generation)) {
        await document.dispose();
        return;
      }
      try {
        _validatePdfMetadata(document, view);
      } on Object {
        await document.dispose();
        rethrow;
      }
      _pdfDocument = document;
      _openingPdf = false;
      _recomputeStatus();
    } finally {
      if (identical(_downloadCancellation, cancellation)) {
        _downloadCancellation = null;
      }
      if (_isCurrentDocument(generation)) {
        _downloadingAsset = false;
        _openingPdf = false;
        _recomputeStatus();
      }
    }
  }

  void _validatePdfMetadata(
    RenderedPdfDocument document,
    DocumentViewDto view,
  ) {
    for (var index = 0; index < view.document.pages.length; index += 1) {
      final expected = view.document.pages[index].displayGeometry;
      final actual = document.pageInfo(index);
      final expectedAspect = expected.width / expected.height;
      final actualAspect = actual.width / actual.height;
      if (actual.rotationDegrees != expected.rotation ||
          (actualAspect - expectedAspect).abs() > 0.000001) {
        throw PdfRendererException(
          PdfRendererFailure.invalidDocument,
          'PDF page ${index + 1} geometry does not match DocumentView',
        );
      }
    }
  }

  Future<void> selectPage(int pageIndex) async {
    final view = _documentView;
    if (view == null ||
        pageIndex < 0 ||
        pageIndex >= view.document.pages.length) {
      throw RangeError.index(pageIndex, view?.document.pages ?? const []);
    }
    if (pageIndex == _selectedPageIndex &&
        _replayController?.state == CanvasReplayState.live) {
      return;
    }
    final documentGeneration = _documentGeneration;
    _selectedPageIndex = pageIndex;
    _pageGeneration += 1;
    _renderGeneration += 1;
    _renderedPage?.dispose();
    _renderedPage = null;
    _activeRenderBucket = null;
    _pdfDocument?.cancelRender();
    _releaseCanvas();
    _error = null;
    _recomputeStatus();
    try {
      await _activateCanvas(
        pageIndex: pageIndex,
        documentGeneration: documentGeneration,
      );
      _requestLastRenderTarget();
    } on Object catch (error) {
      if (_isCurrentDocument(documentGeneration)) {
        _setError(error);
      }
    }
  }

  Future<void> _activateCanvas({
    required int pageIndex,
    required int documentGeneration,
  }) async {
    final view = _documentView!;
    final pageGeneration = _pageGeneration;
    final page = view.document.pages[pageIndex];
    final mapping = view.pageCanvases.firstWhere(
      (candidate) => candidate.pageId == page.pageId,
    );
    final loader = CanvasHistoryLoader(session: session);
    final replay = CanvasReplayController(
      session: session,
      canvasId: mapping.canvas.canvasId,
      loader: loader,
    );
    final controller = CanvasController(
      session: session,
      descriptor: CanvasClientDescriptor(
        sessionId: mapping.canvas.sessionId,
        canvasId: mapping.canvas.canvasId,
        layerId: mapping.canvas.defaultLayerId,
        space: mapping.canvas.space.toCanvasSpace(),
      ),
      replayController: replay,
    );
    _replayController = replay;
    _canvasController = controller;
    controller.addListener(_handleCanvasState);
    _recomputeStatus();
    await replay.start();
    if (!_isCurrentPage(documentGeneration, pageGeneration)) {
      return;
    }
    if (replay.state != CanvasReplayState.live) {
      throw StateError('Canvas history replay did not reach Live');
    }
    _recomputeStatus();
  }

  Future<void> requestPageRender({
    required Size viewportSize,
    required double devicePixelRatio,
  }) async {
    if (_disposed ||
        !viewportSize.width.isFinite ||
        !viewportSize.height.isFinite ||
        viewportSize.isEmpty) {
      return;
    }
    _lastViewportSize = viewportSize;
    _lastDevicePixelRatio = devicePixelRatio;
    final pdf = _pdfDocument;
    final page = selectedPage;
    final canvas = _canvasController;
    final pageIndex = _selectedPageIndex;
    if (pdf == null || page == null || canvas == null || pageIndex == null) {
      return;
    }
    final transform = ViewportTransform(
      space: canvas.descriptor.space,
      viewportSize: viewportSize,
    );
    final requested = Size(
      transform.canvasRect.width * devicePixelRatio,
      transform.canvasRect.height * devicePixelRatio,
    );
    final bucket = (
      _resolutionBucket(requested.width),
      _resolutionBucket(requested.height),
    );
    final current = _renderedPage;
    if (current != null &&
        !current.isDisposed &&
        current.pageIndex == pageIndex &&
        current.pixelWidth >= requested.width * 0.9 &&
        current.pixelHeight >= requested.height * 0.9) {
      return;
    }
    if (_renderingPage && bucket == _activeRenderBucket) {
      return;
    }
    final documentGeneration = _documentGeneration;
    final pageGeneration = _pageGeneration;
    final renderGeneration = ++_renderGeneration;
    _renderingPage = true;
    _activeRenderBucket = bucket;
    _recomputeStatus();
    try {
      final rendered = await pdf.renderPage(
        pageIndex: pageIndex,
        targetPixelSize: Size(bucket.$1.toDouble(), bucket.$2.toDouble()),
      );
      if (!_isCurrentPage(documentGeneration, pageGeneration) ||
          renderGeneration != _renderGeneration) {
        rendered.dispose();
        return;
      }
      _renderedPage?.dispose();
      _renderedPage = rendered;
    } on Object catch (error) {
      if (_isCurrentPage(documentGeneration, pageGeneration) &&
          renderGeneration == _renderGeneration) {
        _setError(error);
      }
    } finally {
      if (_isCurrentPage(documentGeneration, pageGeneration) &&
          renderGeneration == _renderGeneration) {
        _renderingPage = false;
        _recomputeStatus();
      }
    }
  }

  int _resolutionBucket(double pixels) =>
      ((pixels.ceil().clamp(1, 1 << 30) + 127) ~/ 128) * 128;

  void _requestLastRenderTarget() {
    final viewport = _lastViewportSize;
    if (viewport != null) {
      unawaited(
        requestPageRender(
          viewportSize: viewport,
          devicePixelRatio: _lastDevicePixelRatio,
        ),
      );
    }
  }

  bool pointerDown(int pointer, Offset position, Size viewportSize) =>
      canAnnotate &&
      _canvasController!.pointerDown(pointer, position, viewportSize);

  void pointerMove(int pointer, Offset position, Size viewportSize) {
    if (canAnnotate) {
      _canvasController!.pointerMove(pointer, position, viewportSize);
    }
  }

  void pointerUp(int pointer) {
    if (canAnnotate || _canvasController?.hasActivePointer == true) {
      _canvasController?.pointerUp(pointer);
    }
  }

  void pointerCancel(int pointer) => _canvasController?.pointerCancel(pointer);

  Future<void> retry() async {
    final documentId = _documentView?.document.documentId;
    if (documentId == null) {
      await initialize();
    } else {
      await selectDocument(documentId);
    }
  }

  void _handleCanvasState() {
    if (_replayController?.state == CanvasReplayState.desynced &&
        _error == null) {
      _error =
          _replayController?.failure ??
          StateError('Canvas replay became desynchronized');
    }
    _recomputeStatus();
  }

  void _handleSessionState() {
    if (session.connectionState != OrbitRelayConnectionState.ready &&
        _documentView != null &&
        _error == null) {
      _error = StateError('Session is no longer Ready');
    }
    _recomputeStatus();
  }

  void _setError(Object error) {
    _error = error;
    _downloadCancellation?.cancel();
    _pdfDocument?.cancelRender();
    _replayController?.invalidate();
    _recomputeStatus();
  }

  void _recomputeStatus() {
    if (_disposed) {
      return;
    }
    final next = switch ((
      _error,
      _loadingDocuments,
      _loadingDocument,
      _downloadingAsset,
      _openingPdf,
      _renderedPage,
      _replayController?.state,
    )) {
      (Object(), _, _, _, _, _, _) => DocumentWorkspaceStatus.error,
      (_, true, _, _, _, _, _) => DocumentWorkspaceStatus.loadingDocuments,
      (_, _, true, _, _, _, _) => DocumentWorkspaceStatus.loadingDocument,
      (_, _, _, true, _, _, _) => DocumentWorkspaceStatus.downloadingAsset,
      (_, _, _, _, true, _, _) => DocumentWorkspaceStatus.openingPdf,
      (_, _, _, _, _, null, _) when _documentView != null =>
        DocumentWorkspaceStatus.loadingPage,
      (
        _,
        _,
        _,
        _,
        _,
        _,
        CanvasReplayState.loadingHistory || CanvasReplayState.replaying,
      ) =>
        DocumentWorkspaceStatus.replayingCanvas,
      (_, _, _, _, _, RenderedPdfPage(), CanvasReplayState.live) =>
        DocumentWorkspaceStatus.ready,
      _ => DocumentWorkspaceStatus.idle,
    };
    _status = next;
    notifyListeners();
  }

  bool _isCurrentDocument(int generation) =>
      !_disposed && generation == _documentGeneration;

  bool _isCurrentPage(int documentGeneration, int pageGeneration) =>
      _isCurrentDocument(documentGeneration) &&
      pageGeneration == _pageGeneration;

  Future<void> _releaseDocumentResources() async {
    _downloadCancellation?.cancel();
    _downloadCancellation = null;
    _pdfDocument?.cancelRender();
    _renderedPage?.dispose();
    _renderedPage = null;
    final pdf = _pdfDocument;
    _pdfDocument = null;
    if (pdf != null) {
      await pdf.dispose();
    }
    _downloadedAsset = null;
    _documentView = null;
    _selectedPageIndex = null;
    _activeRenderBucket = null;
    _releaseCanvas();
    _loadingDocument = false;
    _downloadingAsset = false;
    _openingPdf = false;
    _renderingPage = false;
  }

  void _releaseCanvas() {
    final controller = _canvasController;
    if (controller != null) {
      controller.removeListener(_handleCanvasState);
      controller.dispose();
    }
    _canvasController = null;
    _replayController?.dispose();
    _replayController = null;
  }

  Future<void> close() async {
    if (_disposed) {
      return;
    }
    _documentGeneration += 1;
    _pageGeneration += 1;
    _renderGeneration += 1;
    await _releaseDocumentResources();
    _error = null;
    _recomputeStatus();
  }

  @override
  void dispose() {
    if (_disposed) {
      return;
    }
    session.connectionStateListenable.removeListener(_handleSessionState);
    _disposed = true;
    _documentGeneration += 1;
    _pageGeneration += 1;
    _renderGeneration += 1;
    _downloadCancellation?.cancel();
    _pdfDocument?.cancelRender();
    _renderedPage?.dispose();
    _renderedPage = null;
    _releaseCanvas();
    final pdf = _pdfDocument;
    _pdfDocument = null;
    if (pdf != null) {
      unawaited(pdf.dispose());
    }
    _downloadedAsset = null;
    super.dispose();
  }
}
