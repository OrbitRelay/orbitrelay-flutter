import 'dart:async';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import '../asset/asset_access.dart';
import '../asset/asset_downloader.dart';
import '../asset/document_asset_loader.dart';
import '../canvas/viewport_transform.dart';
import '../document/document_client.dart';
import '../document/document_workspace_controller.dart';
import '../pdf/pdf_document_renderer.dart';
import '../protocol/ids.dart';
import '../session/orbitrelay_session.dart';
import '../transport/connection_state.dart';
import 'canvas_painter.dart';

final class DocumentWorkspacePage extends StatefulWidget {
  const DocumentWorkspacePage({
    required this.session,
    required this.actorId,
    super.key,
  });

  final OrbitRelaySession session;
  final ActorId actorId;

  @override
  State<DocumentWorkspacePage> createState() => _DocumentWorkspacePageState();
}

final class _DocumentWorkspacePageState extends State<DocumentWorkspacePage> {
  late final http.Client _httpClient;
  late final DocumentWorkspaceController _controller;

  @override
  void initState() {
    super.initState();
    _httpClient = http.Client();
    final documentClient = DocumentClient(session: widget.session);
    final accessClient = AssetAccessClient(session: widget.session);
    _controller = DocumentWorkspaceController(
      session: widget.session,
      documentClient: documentClient,
      assetLoader: DocumentAssetLoader(
        accessClient: accessClient,
        downloader: AssetDownloader(client: _httpClient),
      ),
      pdfRenderer: const PdfrxPdfDocumentRenderer(),
    )..addListener(_refresh);
    unawaited(_controller.initialize());
  }

  @override
  void dispose() {
    _controller.removeListener(_refresh);
    _controller.dispose();
    _httpClient.close();
    widget.session.dispose();
    super.dispose();
  }

  void _refresh() {
    if (mounted) {
      setState(() {});
    }
  }

  Future<void> _leave() async {
    await _controller.close();
    await widget.session.close();
    if (mounted) {
      Navigator.of(context).pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    final view = _controller.documentView;
    final pageIndex = _controller.selectedPageIndex;
    final pageCount = view?.document.pages.length ?? 0;
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop) {
          unawaited(_leave());
        }
      },
      child: Scaffold(
        appBar: AppBar(
          leading: IconButton(
            tooltip: 'Back to connection',
            onPressed: _leave,
            icon: const Icon(Icons.arrow_back),
          ),
          title: Text(view?.document.title ?? 'Document collaboration'),
          actions: <Widget>[
            _ConnectionIndicator(state: widget.session.connectionState),
            const SizedBox(width: 16),
          ],
        ),
        body: Column(
          children: <Widget>[
            _DocumentBar(
              controller: _controller,
              onSelected: (documentId) {
                if (documentId != null) {
                  unawaited(_controller.selectDocument(documentId));
                }
              },
            ),
            _PageBar(
              pageIndex: pageIndex,
              pageCount: pageCount,
              onPrevious: pageIndex != null && pageIndex > 0
                  ? () => unawaited(_controller.selectPage(pageIndex - 1))
                  : null,
              onNext: pageIndex != null && pageIndex + 1 < pageCount
                  ? () => unawaited(_controller.selectPage(pageIndex + 1))
                  : null,
            ),
            if (_controller.status != DocumentWorkspaceStatus.ready)
              _WorkspaceStatusBar(
                status: _controller.status,
                error: _controller.error,
                onRetry: _controller.status == DocumentWorkspaceStatus.error
                    ? () => unawaited(_controller.retry())
                    : null,
              ),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: const Color(0xFFCDD1CD),
                    border: Border.all(color: const Color(0xFFB9BFBA)),
                  ),
                  child: _DocumentSurface(controller: _controller),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

final class _DocumentBar extends StatelessWidget {
  const _DocumentBar({required this.controller, required this.onSelected});

  final DocumentWorkspaceController controller;
  final ValueChanged<DocumentId?> onSelected;

  @override
  Widget build(BuildContext context) {
    final selected = controller.documentView?.document.documentId;
    return Container(
      width: double.infinity,
      color: Colors.white,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(
        children: <Widget>[
          const Icon(Icons.description_outlined, size: 20),
          const SizedBox(width: 10),
          Expanded(
            child: DropdownButtonHideUnderline(
              child: DropdownButton<DocumentId>(
                key: const Key('document-selector'),
                value: selected,
                isExpanded: true,
                hint: Text(
                  controller.documents.isEmpty
                      ? 'No Documents available'
                      : 'Select a Document',
                ),
                items: controller.documents
                    .map(
                      (document) => DropdownMenuItem<DocumentId>(
                        value: document.documentId,
                        child: Text(
                          document.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    )
                    .toList(growable: false),
                onChanged: controller.documents.isEmpty ? null : onSelected,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

final class _PageBar extends StatelessWidget {
  const _PageBar({
    required this.pageIndex,
    required this.pageCount,
    required this.onPrevious,
    required this.onNext,
  });

  final int? pageIndex;
  final int pageCount;
  final VoidCallback? onPrevious;
  final VoidCallback? onNext;

  @override
  Widget build(BuildContext context) => Container(
    height: 48,
    padding: const EdgeInsets.symmetric(horizontal: 12),
    child: Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: <Widget>[
        IconButton(
          key: const Key('previous-page-button'),
          tooltip: 'Previous page',
          onPressed: onPrevious,
          icon: const Icon(Icons.chevron_left),
        ),
        SizedBox(
          width: 120,
          child: Text(
            pageIndex == null ? 'No page' : '${pageIndex! + 1} / $pageCount',
            textAlign: TextAlign.center,
          ),
        ),
        IconButton(
          key: const Key('next-page-button'),
          tooltip: 'Next page',
          onPressed: onNext,
          icon: const Icon(Icons.chevron_right),
        ),
      ],
    ),
  );
}

final class _WorkspaceStatusBar extends StatelessWidget {
  const _WorkspaceStatusBar({
    required this.status,
    required this.error,
    required this.onRetry,
  });

  final DocumentWorkspaceStatus status;
  final Object? error;
  final VoidCallback? onRetry;

  String get _label => switch (status) {
    DocumentWorkspaceStatus.idle => 'Select a Document',
    DocumentWorkspaceStatus.loadingDocuments => 'Loading Documents',
    DocumentWorkspaceStatus.loadingDocument => 'Loading Document metadata',
    DocumentWorkspaceStatus.downloadingAsset => 'Downloading and verifying PDF',
    DocumentWorkspaceStatus.openingPdf => 'Opening verified PDF',
    DocumentWorkspaceStatus.loadingPage => 'Rendering PDF page',
    DocumentWorkspaceStatus.replayingCanvas => 'Replaying Canvas history',
    DocumentWorkspaceStatus.ready => 'Ready',
    DocumentWorkspaceStatus.error => error?.toString() ?? 'Workspace error',
  };

  @override
  Widget build(BuildContext context) {
    final isError = status == DocumentWorkspaceStatus.error;
    final color = isError
        ? Theme.of(context).colorScheme.error
        : Theme.of(context).colorScheme.secondary;
    return Container(
      width: double.infinity,
      color: color.withValues(alpha: 0.08),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 9),
      child: Row(
        children: <Widget>[
          if (isError)
            Icon(Icons.error_outline, color: color, size: 20)
          else
            SizedBox.square(
              dimension: 16,
              child: CircularProgressIndicator(strokeWidth: 2, color: color),
            ),
          const SizedBox(width: 10),
          Expanded(child: Text(_label, maxLines: 2)),
          if (onRetry != null)
            TextButton.icon(
              key: const Key('workspace-retry-button'),
              onPressed: onRetry,
              icon: const Icon(Icons.refresh),
              label: const Text('Retry full load'),
            ),
        ],
      ),
    );
  }
}

final class _DocumentSurface extends StatelessWidget {
  const _DocumentSurface({required this.controller});

  final DocumentWorkspaceController controller;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final size = Size(constraints.maxWidth, constraints.maxHeight);
      final dpr = MediaQuery.devicePixelRatioOf(context);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        unawaited(
          controller.requestPageRender(
            viewportSize: size,
            devicePixelRatio: dpr,
          ),
        );
      });
      final space = controller.currentCanvasSpace;
      final rendered = controller.renderedPage;
      if (space == null) {
        return const Center(child: Text('Select a Document to begin'));
      }
      final transform = ViewportTransform(space: space, viewportSize: size);
      return MouseRegion(
        cursor: controller.canAnnotate
            ? SystemMouseCursors.precise
            : SystemMouseCursors.forbidden,
        child: Listener(
          key: const Key('document-canvas-input-surface'),
          behavior: HitTestBehavior.opaque,
          onPointerDown: (event) =>
              controller.pointerDown(event.pointer, event.localPosition, size),
          onPointerMove: (event) =>
              controller.pointerMove(event.pointer, event.localPosition, size),
          onPointerUp: (event) => controller.pointerUp(event.pointer),
          onPointerCancel: (event) => controller.pointerCancel(event.pointer),
          child: Stack(
            fit: StackFit.expand,
            children: <Widget>[
              if (rendered != null && !rendered.isDisposed)
                Positioned.fromRect(
                  rect: transform.canvasRect,
                  child: RawImage(
                    key: const Key('pdf-raster-layer'),
                    image: rendered.image,
                    fit: BoxFit.fill,
                    filterQuality: FilterQuality.medium,
                  ),
                ),
              CustomPaint(
                key: const Key('canvas-overlay-layer'),
                painter: CanvasPainter(
                  state: controller.canvasRenderState,
                  transform: transform,
                  paintSurface: false,
                ),
                size: Size.infinite,
              ),
            ],
          ),
        ),
      );
    },
  );
}

final class _ConnectionIndicator extends StatelessWidget {
  const _ConnectionIndicator({required this.state});

  final OrbitRelayConnectionState state;

  @override
  Widget build(BuildContext context) {
    final ready = state == OrbitRelayConnectionState.ready;
    return Tooltip(
      message: 'Connection ${state.label}',
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Icon(
            ready ? Icons.cloud_done_outlined : Icons.cloud_off_outlined,
            size: 19,
            color: ready
                ? Theme.of(context).colorScheme.secondary
                : Theme.of(context).colorScheme.error,
          ),
          const SizedBox(width: 7),
          Text(state.label),
        ],
      ),
    );
  }
}
