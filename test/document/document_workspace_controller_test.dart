import 'dart:async';
import 'dart:convert';
import 'dart:ui' as ui;

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:orbitrelay_client_flutter/asset/asset_access.dart';
import 'package:orbitrelay_client_flutter/asset/asset_downloader.dart';
import 'package:orbitrelay_client_flutter/asset/document_asset_loader.dart';
import 'package:orbitrelay_client_flutter/canvas/canvas_history.dart';
import 'package:orbitrelay_client_flutter/canvas/canvas_protocol.dart';
import 'package:orbitrelay_client_flutter/document/document_client.dart';
import 'package:orbitrelay_client_flutter/document/document_workspace_controller.dart';
import 'package:orbitrelay_client_flutter/pdf/pdf_document_renderer.dart';
import 'package:orbitrelay_client_flutter/protocol/ids.dart';
import 'package:orbitrelay_client_flutter/protocol/message.dart';
import 'package:orbitrelay_client_flutter/protocol/query.dart';
import 'package:orbitrelay_client_flutter/session/orbitrelay_session.dart';
import 'package:orbitrelay_client_flutter/session/pending_action.dart';
import 'package:orbitrelay_client_flutter/transport/connection_state.dart';

final _sessionId = SessionId.parse('22222222-2222-4222-8222-222222222222');
final _documentId = DocumentId.parse('33333333-3333-4333-8333-333333333333');
final _assetId = AssetId.parse('44444444-4444-4444-8444-444444444444');
final _page0 = PageId.parse('55555555-5555-4555-8555-555555555555');
final _page1 = PageId.parse('66666666-6666-4666-8666-666666666666');
final _canvas0 = CanvasId.parse('77777777-7777-4777-8777-777777777777');
final _canvas1 = CanvasId.parse('88888888-8888-4888-8888-888888888888');
final _layer0 = LayerId.parse('99999999-9999-4999-8999-999999999999');
final _layer1 = LayerId.parse('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa');
final _pdfBytes = utf8.encode('workspace-verified-pdf');
final _pdfHash = sha256.convert(_pdfBytes).toString();

final class FakeCollaborationSession implements OrbitRelayCollaborationSession {
  final ValueNotifier<OrbitRelayConnectionState> state =
      ValueNotifier<OrbitRelayConnectionState>(OrbitRelayConnectionState.ready);
  final StreamController<EventMessage> eventController =
      StreamController<EventMessage>.broadcast(sync: true);
  final StreamController<ActionFailure> failureController =
      StreamController<ActionFailure>.broadcast(sync: true);
  final List<CanvasActionPayload> actions = <CanvasActionPayload>[];

  @override
  OrbitRelayConnectionState get connectionState => state.value;

  @override
  ValueListenable<OrbitRelayConnectionState> get connectionStateListenable =>
      state;

  @override
  Stream<EventMessage> get events => eventController.stream;

  @override
  Stream<ActionFailure> get actionFailures => failureController.stream;

  @override
  SessionId get sessionId => _sessionId;

  @override
  ProtocolVersion? get negotiatedVersion => orbitRelayProtocolV02;

  @override
  int get connectionGeneration => 1;

  @override
  int? get subscriptionGeneration => 1;

  @override
  bool get subscriptionHealthy =>
      state.value == OrbitRelayConnectionState.ready;

  @override
  PendingAction enqueueCanvasAction(CanvasActionPayload payload) {
    actions.add(payload);
    return PendingAction(
      messageId: MessageId.generate(),
      actionId: ActionId.generate(),
      strokeId: payload.strokeId,
      actionKind: payload.actionType,
      chunkIndex: payload.correlationChunkIndex,
      sentAt: DateTime.now().toUtc(),
    );
  }

  @override
  void cancelQueuedActionsForStroke(StrokeId strokeId, {int? fromChunkIndex}) {}

  @override
  Future<QueryResult> query(
    String queryType,
    Map<String, Object?> payload, {
    Duration? timeout,
  }) async {
    return switch (queryType) {
      documentListQueryType => QuerySuccessResult(<String, Object?>{
        'documents': <Object?>[
          <String, Object?>{
            'document_id': _documentId.value,
            'title': 'Fixture Document',
            'document_type': 'pdf',
            'page_count': 2,
            'source_asset_id': _assetId.value,
          },
        ],
      }),
      documentGetQueryType => QuerySuccessResult(_documentView()),
      assetAccessResolveQueryType => QuerySuccessResult(<String, Object?>{
        'asset_id': _assetId.value,
        'delivery_kind': 'http',
        'url': 'https://assets.example.test/document.pdf',
        'authorization': <String, Object?>{
          'type': 'bearer',
          'token': 'workspace-secret-token',
        },
        'expires_at': '2099-01-01T00:00:00Z',
        'supports_range': true,
      }),
      canvasHistoryPageQueryType => QuerySuccessResult(<String, Object?>{
        'canvas_id': payload['canvas_id'],
        'checkpoint': 'opaque-checkpoint',
        'events': <Object?>[],
        'next_cursor': null,
        'complete': true,
      }),
      _ => throw StateError('Unexpected Query $queryType'),
    };
  }

  @override
  Future<void> close() async =>
      state.value = OrbitRelayConnectionState.disconnected;

  @override
  void dispose() {
    unawaited(eventController.close());
    unawaited(failureController.close());
    state.dispose();
  }
}

Map<String, Object?> _documentView() => <String, Object?>{
  'document': <String, Object?>{
    'document_id': _documentId.value,
    'session_id': _sessionId.value,
    'document_type': 'pdf',
    'source_asset_id': _assetId.value,
    'title': 'Fixture Document',
    'pages': <Object?>[
      _pageJson(_page0, 0, 400, 600, 0, _canvas0),
      _pageJson(_page1, 1, 600, 400, 90, _canvas1),
    ],
  },
  'source_asset': <String, Object?>{
    'asset_id': _assetId.value,
    'media_type': 'application/pdf',
    'byte_length': _pdfBytes.length,
    'content_hash': _pdfHash,
    'original_filename': 'fixture.pdf',
  },
  'page_canvases': <Object?>[
    _pageCanvasJson(_page0, _canvas0, _layer0, 400, 600),
    _pageCanvasJson(_page1, _canvas1, _layer1, 600, 400),
  ],
};

Map<String, Object?> _pageJson(
  PageId pageId,
  int index,
  double width,
  double height,
  int rotation,
  CanvasId canvasId,
) => <String, Object?>{
  'page_id': pageId.value,
  'page_index': index,
  'display_geometry': <String, Object?>{
    'width': width,
    'height': height,
    'rotation': rotation,
  },
  'overlay_canvas_id': canvasId.value,
};

Map<String, Object?> _pageCanvasJson(
  PageId pageId,
  CanvasId canvasId,
  LayerId layerId,
  double width,
  double height,
) => <String, Object?>{
  'page_id': pageId.value,
  'canvas': <String, Object?>{
    'canvas_id': canvasId.value,
    'session_id': _sessionId.value,
    'space': <String, Object?>{'width': width, 'height': height},
    'layer_ids': <Object?>[layerId.value],
    'default_layer_id': layerId.value,
  },
};

final class FakePdfRenderer implements PdfDocumentRenderer {
  FakePdfRenderer({this.gated = false});

  final bool gated;
  late final FakePdfDocument document = FakePdfDocument(gated: gated);

  @override
  Future<RenderedPdfDocument> open({
    required DownloadedAsset asset,
    required int expectedPageCount,
  }) async {
    expect(asset.contentHash, _pdfHash);
    expect(expectedPageCount, 2);
    return document;
  }
}

final class FakePdfDocument implements RenderedPdfDocument {
  FakePdfDocument({required this.gated});

  final bool gated;
  final List<(int, Completer<RenderedPdfPage>)> pending =
      <(int, Completer<RenderedPdfPage>)>[];
  bool _disposed = false;

  @override
  int get pageCount => 2;

  @override
  bool get isDisposed => _disposed;

  @override
  PdfPageInfo pageInfo(int pageIndex) => pageIndex == 0
      ? const PdfPageInfo(
          pageIndex: 0,
          width: 400,
          height: 600,
          rotationDegrees: 0,
        )
      : const PdfPageInfo(
          pageIndex: 1,
          width: 600,
          height: 400,
          rotationDegrees: 90,
        );

  @override
  Future<RenderedPdfPage> renderPage({
    required int pageIndex,
    required ui.Size targetPixelSize,
  }) async {
    if (!gated) {
      return _rendered(pageIndex);
    }
    final completer = Completer<RenderedPdfPage>();
    pending.add((pageIndex, completer));
    return completer.future;
  }

  @override
  void cancelRender() {}

  @override
  Future<void> dispose() async => _disposed = true;
}

Future<RenderedPdfPage> _rendered(int pageIndex) async {
  final width = pageIndex == 0 ? 40 : 60;
  final height = pageIndex == 0 ? 60 : 40;
  final pixels = Uint8List(width * height * 4);
  for (var index = 3; index < pixels.length; index += 4) {
    pixels[index] = 255;
  }
  final completer = Completer<ui.Image>();
  ui.decodeImageFromPixels(
    pixels,
    width,
    height,
    ui.PixelFormat.rgba8888,
    completer.complete,
  );
  return RenderedPdfPage(
    pageIndex: pageIndex,
    image: await completer.future,
    pixelWidth: width,
    pixelHeight: height,
  );
}

DocumentWorkspaceController workspace(
  FakeCollaborationSession session,
  FakePdfRenderer renderer,
) {
  final httpClient = MockClient.streaming(
    (request, body) async => http.StreamedResponse(
      http.ByteStream(Stream<List<int>>.value(_pdfBytes)),
      200,
      headers: <String, String>{
        'content-length': '${_pdfBytes.length}',
        'content-type': 'application/pdf',
        'etag': '"sha256-$_pdfHash"',
      },
    ),
  );
  return DocumentWorkspaceController(
    session: session,
    documentClient: DocumentClient(session: session),
    assetLoader: DocumentAssetLoader(
      accessClient: AssetAccessClient(session: session),
      downloader: AssetDownloader(client: httpClient),
    ),
    pdfRenderer: renderer,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'gates pointer until verified raster and Canvas replay are ready',
    () async {
      final session = FakeCollaborationSession();
      final controller = workspace(session, FakePdfRenderer());
      addTearDown(() {
        controller.dispose();
        session.dispose();
      });

      await controller.initialize();
      await controller.selectDocument(_documentId);
      expect(controller.hasVerifiedAsset, isTrue);
      expect(controller.replayState, CanvasReplayState.live);
      expect(controller.canAnnotate, isFalse);

      await controller.requestPageRender(
        viewportSize: const ui.Size(800, 600),
        devicePixelRatio: 1,
      );
      expect(controller.status, DocumentWorkspaceStatus.ready);
      expect(controller.canAnnotate, isTrue);
      expect(
        controller.pointerDown(
          1,
          const ui.Offset(400, 300),
          const ui.Size(800, 600),
        ),
        isTrue,
      );
      controller.pointerUp(1);
      expect(session.actions, isNotEmpty);
    },
  );

  test('stale Page render cannot overwrite a newer Page generation', () async {
    final session = FakeCollaborationSession();
    final renderer = FakePdfRenderer(gated: true);
    final controller = workspace(session, renderer);
    addTearDown(() {
      controller.dispose();
      session.dispose();
    });
    await controller.selectDocument(_documentId);

    final firstRender = controller.requestPageRender(
      viewportSize: const ui.Size(800, 600),
      devicePixelRatio: 1,
    );
    await Future<void>.delayed(Duration.zero);
    expect(renderer.document.pending.single.$1, 0);

    await controller.selectPage(1);
    for (
      var attempt = 0;
      renderer.document.pending.length < 2 && attempt < 10;
      attempt += 1
    ) {
      await Future<void>.delayed(Duration.zero);
    }
    expect(renderer.document.pending.last.$1, 1);
    renderer.document.pending.last.$2.complete(await _rendered(1));
    await Future<void>.delayed(Duration.zero);
    renderer.document.pending.first.$2.complete(await _rendered(0));
    await firstRender;
    await Future<void>.delayed(Duration.zero);

    expect(controller.selectedPageIndex, 1);
    expect(controller.renderedPage?.pageIndex, 1);
  });

  test(
    'disconnect closes the pointer gate and desynchronizes replay',
    () async {
      final session = FakeCollaborationSession();
      final controller = workspace(session, FakePdfRenderer());
      addTearDown(() {
        controller.dispose();
        session.dispose();
      });
      await controller.selectDocument(_documentId);
      await controller.requestPageRender(
        viewportSize: const ui.Size(800, 600),
        devicePixelRatio: 1,
      );
      expect(controller.canAnnotate, isTrue);

      session.state.value = OrbitRelayConnectionState.disconnected;

      expect(controller.canAnnotate, isFalse);
      expect(controller.replayState, CanvasReplayState.desynced);
      expect(
        controller.pointerDown(
          2,
          const ui.Offset(400, 300),
          const ui.Size(800, 600),
        ),
        isFalse,
      );
    },
  );

  test('close disposes visual resources and returns to idle', () async {
    final session = FakeCollaborationSession();
    final renderer = FakePdfRenderer();
    final controller = workspace(session, renderer);
    addTearDown(() {
      controller.dispose();
      session.dispose();
    });
    await controller.selectDocument(_documentId);
    await controller.requestPageRender(
      viewportSize: const ui.Size(800, 600),
      devicePixelRatio: 1,
    );
    final rendered = controller.renderedPage!;

    await controller.close();

    expect(rendered.isDisposed, isTrue);
    expect(renderer.document.isDisposed, isTrue);
    expect(controller.renderedPage, isNull);
    expect(controller.hasVerifiedAsset, isFalse);
    expect(controller.replayState, CanvasReplayState.idle);
    expect(controller.status, DocumentWorkspaceStatus.idle);
    expect(controller.canAnnotate, isFalse);
  });
}
