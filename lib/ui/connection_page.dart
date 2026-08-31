import 'package:flutter/material.dart';

import '../canvas/canvas_controller.dart';
import '../canvas/canvas_protocol.dart';
import '../protocol/ids.dart';
import '../session/orbitrelay_session.dart';
import '../transport/connection_state.dart';
import 'canvas_page.dart';
import 'document_workspace_page.dart';

enum _ClientMode { standaloneCanvas, document }

final class ConnectionPage extends StatefulWidget {
  const ConnectionPage({super.key});

  @override
  State<ConnectionPage> createState() => _ConnectionPageState();
}

final class _ConnectionPageState extends State<ConnectionPage> {
  final _formKey = GlobalKey<FormState>();
  final _serverController = TextEditingController(
    text: 'ws://127.0.0.1:8080/ws',
  );
  final _actorController = TextEditingController(
    text: ActorId.generate().value,
  );
  final _sessionController = TextEditingController();
  final _canvasController = TextEditingController();
  final _layerController = TextEditingController();
  final _widthController = TextEditingController(text: '1920');
  final _heightController = TextEditingController(text: '1080');

  OrbitRelaySession? _connectingSession;
  String? _connectionError;
  _ClientMode _mode = _ClientMode.standaloneCanvas;

  @override
  void dispose() {
    _connectingSession?.dispose();
    _serverController.dispose();
    _actorController.dispose();
    _sessionController.dispose();
    _canvasController.dispose();
    _layerController.dispose();
    _widthController.dispose();
    _heightController.dispose();
    super.dispose();
  }

  Future<void> _connect() async {
    if (!(_formKey.currentState?.validate() ?? false) ||
        _connectingSession != null) {
      return;
    }
    final uri = Uri.parse(_serverController.text.trim());
    final actorId = ActorId.parse(_actorController.text.trim());
    final sessionId = SessionId.parse(_sessionController.text.trim());
    final descriptor = _mode == _ClientMode.standaloneCanvas
        ? CanvasClientDescriptor(
            sessionId: sessionId,
            canvasId: CanvasId.parse(_canvasController.text.trim()),
            layerId: LayerId.parse(_layerController.text.trim()),
            space: CanvasSpace(
              double.parse(_widthController.text.trim()),
              double.parse(_heightController.text.trim()),
            ),
          )
        : null;
    final session = OrbitRelaySession(
      config: OrbitRelaySessionConfig(
        serverUri: uri,
        actorId: actorId,
        sessionId: sessionId,
      ),
    );
    setState(() {
      _connectingSession = session;
      _connectionError = null;
    });
    session.connectionStateListenable.addListener(_refresh);
    try {
      await session.connect();
      if (!mounted) {
        session.dispose();
        return;
      }
      session.connectionStateListenable.removeListener(_refresh);
      setState(() => _connectingSession = null);
      if (_mode == _ClientMode.document &&
          !(session.negotiatedVersion?.supportsQueries ?? false)) {
        await session.close();
        throw StateError('Document mode requires negotiated Protocol 0.2');
      }
      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => _mode == _ClientMode.document
              ? DocumentWorkspacePage(session: session, actorId: actorId)
              : CanvasPage(
                  session: session,
                  descriptor: descriptor!,
                  actorId: actorId,
                ),
        ),
      );
    } on Object catch (error) {
      session.connectionStateListenable.removeListener(_refresh);
      session.dispose();
      if (mounted) {
        setState(() {
          _connectingSession = null;
          _connectionError = 'Connection failed: $error';
        });
      }
    }
  }

  void _refresh() {
    if (mounted) {
      setState(() {});
    }
  }

  String? _validateWebSocketUrl(String? value) {
    final uri = Uri.tryParse(value?.trim() ?? '');
    if (uri == null ||
        (uri.scheme != 'ws' && uri.scheme != 'wss') ||
        uri.host.isEmpty) {
      return 'Enter a valid ws:// or wss:// URL.';
    }
    return null;
  }

  String? _validateUuid(String? value, String label) {
    try {
      ActorId.parse(value?.trim() ?? '');
      return null;
    } on FormatException {
      return '$label must be a canonical lowercase UUID.';
    }
  }

  String? _validateDimension(String? value) {
    final parsed = double.tryParse(value?.trim() ?? '');
    if (parsed == null || !parsed.isFinite || parsed <= 0) {
      return 'Enter a finite value greater than zero.';
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final session = _connectingSession;
    final state = session?.connectionState;
    return Scaffold(
      appBar: AppBar(
        title: const Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(Icons.hub_outlined, size: 22),
            SizedBox(width: 10),
            Text('OrbitRelay Canvas'),
          ],
        ),
      ),
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(10),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 760),
              child: Form(
                key: _formKey,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: <Widget>[
                    Text(
                      'Development session',
                      style: Theme.of(context).textTheme.headlineSmall,
                    ),
                    const SizedBox(height: 6),
                    Text(
                      _mode == _ClientMode.document
                          ? 'Discover Documents from the active Session.'
                          : 'Use the standalone Canvas descriptor printed by the server.',
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(height: 12),
                    SegmentedButton<_ClientMode>(
                      key: const Key('client-mode-selector'),
                      segments: const <ButtonSegment<_ClientMode>>[
                        ButtonSegment<_ClientMode>(
                          value: _ClientMode.standaloneCanvas,
                          icon: Icon(Icons.draw_outlined),
                          label: Text('Standalone Canvas'),
                        ),
                        ButtonSegment<_ClientMode>(
                          value: _ClientMode.document,
                          icon: Icon(Icons.description_outlined),
                          label: Text('Document'),
                        ),
                      ],
                      selected: <_ClientMode>{_mode},
                      style: const ButtonStyle(
                        visualDensity: VisualDensity.compact,
                      ),
                      onSelectionChanged: (selection) {
                        setState(() => _mode = selection.single);
                      },
                    ),
                    const SizedBox(height: 10),
                    TextFormField(
                      key: const Key('server-url-field'),
                      controller: _serverController,
                      decoration: const InputDecoration(
                        labelText: 'Server URL',
                        prefixIcon: Icon(Icons.dns_outlined),
                      ),
                      validator: _validateWebSocketUrl,
                    ),
                    const SizedBox(height: 14),
                    TextFormField(
                      key: const Key('actor-id-field'),
                      controller: _actorController,
                      decoration: const InputDecoration(
                        labelText: 'Actor ID',
                        prefixIcon: Icon(Icons.person_outline),
                      ),
                      validator: (value) => _validateUuid(value, 'Actor ID'),
                    ),
                    const SizedBox(height: 14),
                    TextFormField(
                      key: const Key('session-id-field'),
                      controller: _sessionController,
                      decoration: const InputDecoration(
                        labelText: 'Session ID',
                        prefixIcon: Icon(Icons.groups_outlined),
                      ),
                      validator: (value) => _validateUuid(value, 'Session ID'),
                    ),
                    if (_mode == _ClientMode.standaloneCanvas) ...<Widget>[
                      const SizedBox(height: 14),
                      _ResponsiveFields(
                        children: <Widget>[
                          TextFormField(
                            key: const Key('canvas-id-field'),
                            controller: _canvasController,
                            decoration: const InputDecoration(
                              labelText: 'Canvas ID',
                              prefixIcon: Icon(Icons.draw_outlined),
                            ),
                            validator: (value) =>
                                _validateUuid(value, 'Canvas ID'),
                          ),
                          TextFormField(
                            key: const Key('layer-id-field'),
                            controller: _layerController,
                            decoration: const InputDecoration(
                              labelText: 'Layer ID',
                              prefixIcon: Icon(Icons.layers_outlined),
                            ),
                            validator: (value) =>
                                _validateUuid(value, 'Layer ID'),
                          ),
                        ],
                      ),
                      const SizedBox(height: 14),
                      _ResponsiveFields(
                        children: <Widget>[
                          TextFormField(
                            controller: _widthController,
                            decoration: const InputDecoration(
                              labelText: 'Canvas width',
                              suffixText: 'units',
                            ),
                            keyboardType: const TextInputType.numberWithOptions(
                              decimal: true,
                            ),
                            validator: _validateDimension,
                          ),
                          TextFormField(
                            controller: _heightController,
                            decoration: const InputDecoration(
                              labelText: 'Canvas height',
                              suffixText: 'units',
                            ),
                            keyboardType: const TextInputType.numberWithOptions(
                              decimal: true,
                            ),
                            validator: _validateDimension,
                          ),
                        ],
                      ),
                    ],
                    if (_connectionError != null) ...<Widget>[
                      const SizedBox(height: 16),
                      _StatusBanner(message: _connectionError!),
                    ],
                    const SizedBox(height: 12),
                    SizedBox(
                      height: 48,
                      child: FilledButton.icon(
                        key: const Key('connect-button'),
                        onPressed: session == null ? _connect : null,
                        icon: session == null
                            ? const Icon(Icons.link)
                            : const SizedBox.square(
                                dimension: 18,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              ),
                        label: Text(state?.label ?? 'Connect'),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

final class _ResponsiveFields extends StatelessWidget {
  const _ResponsiveFields({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      if (constraints.maxWidth < 600) {
        return Column(
          children: <Widget>[
            children.first,
            const SizedBox(height: 14),
            children.last,
          ],
        );
      }
      return Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Expanded(child: children.first),
          const SizedBox(width: 14),
          Expanded(child: children.last),
        ],
      );
    },
  );
}

final class _StatusBanner extends StatelessWidget {
  const _StatusBanner({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    final color = Theme.of(context).colorScheme.error;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        border: Border(left: BorderSide(color: color, width: 3)),
      ),
      child: Row(
        children: <Widget>[
          Icon(Icons.error_outline, color: color, size: 20),
          const SizedBox(width: 10),
          Expanded(child: Text(message)),
        ],
      ),
    );
  }
}
