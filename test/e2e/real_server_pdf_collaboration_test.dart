import 'dart:async';
import 'dart:io';
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';
import 'package:orbitrelay_client_flutter/asset/asset_access.dart';
import 'package:orbitrelay_client_flutter/asset/asset_downloader.dart';
import 'package:orbitrelay_client_flutter/asset/document_asset_loader.dart';
import 'package:orbitrelay_client_flutter/document/document_client.dart';
import 'package:orbitrelay_client_flutter/document/document_workspace_controller.dart';
import 'package:orbitrelay_client_flutter/pdf/pdf_document_renderer.dart';
import 'package:orbitrelay_client_flutter/protocol/ids.dart';
import 'package:orbitrelay_client_flutter/session/orbitrelay_session.dart';

import '../pdf/pdfrx_test_initializer.dart';

const _enabled = bool.fromEnvironment('ORBITRELAY_REAL_E2E');
const _crossPlatformEnabled = bool.fromEnvironment(
  'ORBITRELAY_CROSS_PLATFORM_E2E',
);
const _soakEnabled = bool.fromEnvironment('ORBITRELAY_SOAK');
const _soakSeconds = int.fromEnvironment(
  'ORBITRELAY_SOAK_SECONDS',
  defaultValue: 30 * 60,
);
const _webSocketUrl = String.fromEnvironment(
  'ORBITRELAY_E2E_WS_URL',
  defaultValue: 'ws://127.0.0.1:18080/ws',
);
final _sessionId = SessionId.parse('22222222-2222-4222-8222-222222222222');
final _sameActor = ActorId.parse('11111111-1111-4111-8111-111111111111');
final _differentActor = ActorId.parse('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa');

Future<void> waitUntil(
  bool Function() condition, {
  Duration timeout = const Duration(seconds: 10),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      throw TimeoutException('Real Server E2E condition did not converge');
    }
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}

final class _ClientHarness {
  _ClientHarness(this.session, this.httpClient, this.workspace);

  final OrbitRelaySession session;
  final http.Client httpClient;
  final DocumentWorkspaceController workspace;

  static Future<_ClientHarness> connect({ActorId? actorId}) async {
    final session = OrbitRelaySession(
      config: OrbitRelaySessionConfig(
        serverUri: Uri.parse(_webSocketUrl),
        actorId: actorId ?? _sameActor,
        sessionId: _sessionId,
      ),
    );
    await session.connect();
    final httpClient = IOClient(HttpClient());
    final workspace = DocumentWorkspaceController(
      session: session,
      documentClient: DocumentClient(session: session),
      assetLoader: DocumentAssetLoader(
        accessClient: AssetAccessClient(session: session),
        downloader: AssetDownloader(client: httpClient),
      ),
      pdfRenderer: PdfrxPdfDocumentRenderer(initialize: initializePdfrxForTest),
    );
    await workspace.initialize();
    expect(workspace.documents, isNotEmpty);
    await workspace.selectDocument(workspace.documents.first.documentId);
    await workspace.requestPageRender(
      viewportSize: const Size(800, 600),
      devicePixelRatio: 1,
    );
    expect(
      workspace.status,
      DocumentWorkspaceStatus.ready,
      reason: workspace.error?.toString(),
    );
    return _ClientHarness(session, httpClient, workspace);
  }

  Future<void> close() async {
    await workspace.close();
    workspace.dispose();
    httpClient.close();
    await session.close();
    session.dispose();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'real Server closes download, render, replay, realtime, and late-join loop',
    () async {
      HttpOverrides.global = null;
      final clientA = await _ClientHarness.connect();
      final clientB = await _ClientHarness.connect();
      addTearDown(clientA.close);
      addTearDown(clientB.close);
      final baselineStrokeIds = clientA.workspace.canvasRenderState.strokes
          .map((stroke) => stroke.strokeId)
          .toSet();
      expect(
        clientB.workspace.canvasRenderState.strokes
            .map((stroke) => stroke.strokeId)
            .toSet(),
        baselineStrokeIds,
      );

      expect(
        clientA.workspace.pointerDown(
          1,
          const Offset(300, 200),
          const Size(800, 600),
        ),
        isTrue,
      );
      clientA.workspace.pointerMove(
        1,
        const Offset(330, 230),
        const Size(800, 600),
      );
      clientA.workspace.pointerMove(
        1,
        const Offset(360, 260),
        const Size(800, 600),
      );
      await waitUntil(
        () => clientB.workspace.canvasRenderState.strokes.any(
          (stroke) =>
              !baselineStrokeIds.contains(stroke.strokeId) &&
              stroke.points.length >= 3,
        ),
      );
      clientA.workspace.pointerUp(1);
      await waitUntil(
        () =>
            clientB.workspace.canvasRenderState.strokes.length ==
            baselineStrokeIds.length + 1,
      );
      final expectedStrokeIds = clientB.workspace.canvasRenderState.strokes
          .map((stroke) => stroke.strokeId)
          .toSet();

      for (var stroke = 0; stroke < 20; stroke += 1) {
        final pointer = 100 + stroke;
        final x = 240.0 + stroke * 8;
        expect(
          clientA.workspace.pointerDown(
            pointer,
            Offset(x, 320),
            const Size(800, 600),
          ),
          isTrue,
        );
        clientA.workspace.pointerMove(
          pointer,
          Offset(x + 4, 324),
          const Size(800, 600),
        );
        clientA.workspace.pointerUp(pointer);
      }
      await waitUntil(
        () =>
            clientB.workspace.canvasRenderState.strokes.length ==
            expectedStrokeIds.length + 20,
      );
      final afterRapidStrokeIds = clientB.workspace.canvasRenderState.strokes
          .map((stroke) => stroke.strokeId)
          .toSet();

      expect(
        clientB.workspace.pointerDown(
          200,
          const Offset(420, 360),
          const Size(800, 600),
        ),
        isTrue,
      );
      clientB.workspace.pointerMove(
        200,
        const Offset(440, 380),
        const Size(800, 600),
      );
      clientB.workspace.pointerUp(200);
      await waitUntil(
        () =>
            clientA.workspace.canvasRenderState.strokes.length ==
            afterRapidStrokeIds.length + 1,
      );
      final bidirectionalStrokeIds = clientA.workspace.canvasRenderState.strokes
          .map((stroke) => stroke.strokeId)
          .toSet();

      final lateJoin = await _ClientHarness.connect(actorId: _differentActor);
      addTearDown(lateJoin.close);
      expect(
        lateJoin.workspace.canvasRenderState.strokes
            .map((stroke) => stroke.strokeId)
            .toSet(),
        bidirectionalStrokeIds,
      );
      expect(
        lateJoin.workspace.canvasRenderState.strokes.every(
          (stroke) => stroke.authoritative,
        ),
        isTrue,
      );

      expect(
        lateJoin.workspace.pointerDown(
          300,
          const Offset(460, 400),
          const Size(800, 600),
        ),
        isTrue,
      );
      lateJoin.workspace.pointerMove(
        300,
        const Offset(480, 420),
        const Size(800, 600),
      );
      lateJoin.workspace.pointerUp(300);
      await waitUntil(
        () =>
            clientA.workspace.canvasRenderState.strokes.length ==
            bidirectionalStrokeIds.length + 1,
      );
      final allStrokeIds = clientA.workspace.canvasRenderState.strokes
          .map((stroke) => stroke.strokeId)
          .toSet();

      await clientA.workspace.selectPage(1);
      await clientA.workspace.requestPageRender(
        viewportSize: const Size(800, 600),
        devicePixelRatio: 1,
      );
      await waitUntil(
        () => clientA.workspace.status == DocumentWorkspaceStatus.ready,
      );
      expect(clientA.workspace.status, DocumentWorkspaceStatus.ready);
      expect(clientA.workspace.canvasRenderState.strokes, isEmpty);

      await clientA.workspace.selectPage(0);
      await clientA.workspace.requestPageRender(
        viewportSize: const Size(800, 600),
        devicePixelRatio: 1,
      );
      await waitUntil(
        () => clientA.workspace.status == DocumentWorkspaceStatus.ready,
      );
      expect(clientA.workspace.status, DocumentWorkspaceStatus.ready);
      expect(
        clientA.workspace.canvasRenderState.strokes
            .map((stroke) => stroke.strokeId)
            .toSet(),
        allStrokeIds,
      );

      await clientA.session.close();
      expect(clientA.workspace.canAnnotate, isFalse);
      await clientA.session.connect();
      await clientA.workspace.retry();
      await clientA.workspace.requestPageRender(
        viewportSize: const Size(800, 600),
        devicePixelRatio: 1,
      );
      await waitUntil(
        () => clientA.workspace.status == DocumentWorkspaceStatus.ready,
      );
      expect(
        clientA.workspace.canvasRenderState.strokes
            .map((stroke) => stroke.strokeId)
            .toSet(),
        allStrokeIds,
      );
    },
    skip: !_enabled,
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test(
    'external Web and native client exchange incremental realtime Strokes',
    () async {
      HttpOverrides.global = null;
      final client = await _ClientHarness.connect(actorId: _differentActor);
      addTearDown(client.close);
      final baselineStrokeIds = client.workspace.canvasRenderState.strokes
          .map((stroke) => stroke.strokeId)
          .toSet();

      await waitUntil(
        () => client.workspace.canvasRenderState.strokes.any(
          (stroke) =>
              !baselineStrokeIds.contains(stroke.strokeId) &&
              stroke.points.length >= 3,
        ),
        timeout: const Duration(minutes: 2),
      );
      final afterWebStrokeIds = client.workspace.canvasRenderState.strokes
          .map((stroke) => stroke.strokeId)
          .toSet();

      expect(
        client.workspace.pointerDown(
          900,
          const Offset(520, 300),
          const Size(800, 600),
        ),
        isTrue,
      );
      client.workspace.pointerMove(
        900,
        const Offset(550, 330),
        const Size(800, 600),
      );
      client.workspace.pointerMove(
        900,
        const Offset(580, 360),
        const Size(800, 600),
      );
      client.workspace.pointerUp(900);
      await waitUntil(
        () => client.workspace.canvasRenderState.strokes.any(
          (stroke) =>
              !afterWebStrokeIds.contains(stroke.strokeId) &&
              stroke.points.length >= 3 &&
              stroke.authoritative,
        ),
      );
    },
    skip: !_crossPlatformEnabled,
    timeout: const Timeout(Duration(minutes: 3)),
  );

  test(
    'manual Phase 4 workspace soak remains bounded and reconnectable',
    () async {
      HttpOverrides.global = null;
      var client = await _ClientHarness.connect();
      addTearDown(() => client.close());
      final deadline = DateTime.now().add(
        Duration(seconds: _soakSeconds.clamp(1, 24 * 60 * 60)),
      );
      var iteration = 0;
      do {
        final pageCount =
            client.workspace.documentView?.document.pages.length ?? 0;
        if (pageCount > 1) {
          await client.workspace.selectPage(1);
          await client.workspace.requestPageRender(
            viewportSize: const Size(640, 480),
            devicePixelRatio: 1,
          );
          await client.workspace.selectPage(0);
        }
        await client.workspace.requestPageRender(
          viewportSize: const Size(800, 600),
          devicePixelRatio: 1,
        );
        await waitUntil(
          () => client.workspace.status == DocumentWorkspaceStatus.ready,
        );
        expect(
          client.workspace.pointerDown(
            iteration + 1,
            Offset(240 + (iteration % 20) * 8, 300),
            const Size(800, 600),
          ),
          isTrue,
        );
        client.workspace.pointerMove(
          iteration + 1,
          Offset(244 + (iteration % 20) * 8, 304),
          const Size(800, 600),
        );
        client.workspace.pointerUp(iteration + 1);
        iteration += 1;

        if (iteration % 10 == 0) {
          final documentId = client.workspace.documentView!.document.documentId;
          await client.workspace.selectDocument(documentId);
          await client.workspace.requestPageRender(
            viewportSize: const Size(800, 600),
            devicePixelRatio: 1,
          );
          await waitUntil(
            () => client.workspace.status == DocumentWorkspaceStatus.ready,
          );
        }
        if (iteration % 25 == 0) {
          await client.session.close();
          await client.session.connect();
          await client.workspace.retry();
          await client.workspace.requestPageRender(
            viewportSize: const Size(800, 600),
            devicePixelRatio: 1,
          );
          await waitUntil(
            () => client.workspace.status == DocumentWorkspaceStatus.ready,
          );
        }
        expect(client.workspace.status, DocumentWorkspaceStatus.ready);
        await Future<void>.delayed(const Duration(milliseconds: 100));
      } while (DateTime.now().isBefore(deadline));

      expect(iteration, greaterThan(0));
      expect(client.session.pendingQueryCount, 0);
      expect(client.workspace.canAnnotate, isTrue);
    },
    skip: !_soakEnabled,
    timeout: Timeout(Duration(seconds: _soakSeconds + 120)),
  );
}
