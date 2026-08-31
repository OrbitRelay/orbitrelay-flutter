import 'dart:async';

import 'package:flutter/material.dart';

import '../canvas/canvas_controller.dart';
import '../canvas/canvas_render_state.dart';
import '../canvas/viewport_transform.dart';
import '../protocol/ids.dart';
import '../session/orbitrelay_session.dart';
import '../transport/connection_state.dart';
import 'canvas_painter.dart';

final class CanvasPage extends StatefulWidget {
  const CanvasPage({
    required this.session,
    required this.descriptor,
    required this.actorId,
    super.key,
  });

  final OrbitRelayCanvasSession session;
  final CanvasClientDescriptor descriptor;
  final ActorId actorId;

  @override
  State<CanvasPage> createState() => _CanvasPageState();
}

final class _CanvasPageState extends State<CanvasPage> {
  late final CanvasController _controller;

  @override
  void initState() {
    super.initState();
    _controller = CanvasController(
      session: widget.session,
      descriptor: widget.descriptor,
    );
    _controller.addListener(_refresh);
    widget.session.connectionStateListenable.addListener(_refresh);
  }

  @override
  void dispose() {
    widget.session.connectionStateListenable.removeListener(_refresh);
    _controller.removeListener(_refresh);
    _controller.dispose();
    widget.session.dispose();
    super.dispose();
  }

  void _refresh() {
    if (mounted) {
      setState(() {});
    }
  }

  Future<void> _leave() async {
    await widget.session.close();
    if (mounted) {
      Navigator.of(context).pop();
    }
  }

  String _short(String value) =>
      value.length <= 8 ? value : value.substring(0, 8);

  @override
  Widget build(BuildContext context) {
    final connectionState = widget.session.connectionState;
    final renderState = _controller.renderState.value;
    final unavailable =
        connectionState != OrbitRelayConnectionState.ready ||
        renderState.health == CanvasHealth.desynchronized;
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
          title: const Text('Realtime Canvas'),
          actions: <Widget>[
            _ConnectionBadge(state: connectionState),
            const SizedBox(width: 16),
          ],
        ),
        body: Column(
          children: <Widget>[
            _ContextBar(
              actor: _short(widget.actorId.value),
              canvas: _short(widget.descriptor.canvasId.value),
              width: widget.descriptor.space.width,
              height: widget.descriptor.space.height,
            ),
            if (renderState.message != null)
              _CanvasBanner(
                message: renderState.message!,
                error: unavailable,
                onBack: unavailable ? _leave : null,
              ),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    border: Border.all(color: const Color(0xFFB9BFBA)),
                  ),
                  child: LayoutBuilder(
                    builder: (context, constraints) {
                      final size = Size(
                        constraints.maxWidth,
                        constraints.maxHeight,
                      );
                      final transform = ViewportTransform(
                        space: widget.descriptor.space,
                        viewportSize: size,
                      );
                      return MouseRegion(
                        cursor: unavailable
                            ? SystemMouseCursors.forbidden
                            : SystemMouseCursors.precise,
                        child: Listener(
                          key: const Key('canvas-input-surface'),
                          behavior: HitTestBehavior.opaque,
                          onPointerDown: (event) => _controller.pointerDown(
                            event.pointer,
                            event.localPosition,
                            size,
                          ),
                          onPointerMove: (event) => _controller.pointerMove(
                            event.pointer,
                            event.localPosition,
                            size,
                          ),
                          onPointerUp: (event) =>
                              _controller.pointerUp(event.pointer),
                          onPointerCancel: (event) =>
                              _controller.pointerCancel(event.pointer),
                          child: CustomPaint(
                            painter: CanvasPainter(
                              state: renderState,
                              transform: transform,
                            ),
                            size: Size.infinite,
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ),
            ),
            const _ToolBar(),
          ],
        ),
      ),
    );
  }
}

final class _ConnectionBadge extends StatelessWidget {
  const _ConnectionBadge({required this.state});

  final OrbitRelayConnectionState state;

  @override
  Widget build(BuildContext context) {
    final ready = state == OrbitRelayConnectionState.ready;
    final color = ready
        ? Theme.of(context).colorScheme.secondary
        : Theme.of(context).colorScheme.error;
    return Semantics(
      label: 'Connection ${state.label}',
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          ),
          const SizedBox(width: 7),
          Text(state.label),
        ],
      ),
    );
  }
}

final class _ContextBar extends StatelessWidget {
  const _ContextBar({
    required this.actor,
    required this.canvas,
    required this.width,
    required this.height,
  });

  final String actor;
  final String canvas;
  final double width;
  final double height;

  @override
  Widget build(BuildContext context) => Container(
    width: double.infinity,
    color: const Color(0xFFE8ECE8),
    padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 9),
    child: Wrap(
      spacing: 22,
      runSpacing: 6,
      children: <Widget>[
        Text('Actor $actor'),
        Text('Canvas $canvas'),
        Text('${width.toStringAsFixed(0)} × ${height.toStringAsFixed(0)}'),
        const Text('Realtime only'),
      ],
    ),
  );
}

final class _CanvasBanner extends StatelessWidget {
  const _CanvasBanner({
    required this.message,
    required this.error,
    required this.onBack,
  });

  final String message;
  final bool error;
  final VoidCallback? onBack;

  @override
  Widget build(BuildContext context) {
    final color = error
        ? Theme.of(context).colorScheme.error
        : Theme.of(context).colorScheme.secondary;
    return Container(
      width: double.infinity,
      color: color.withValues(alpha: 0.08),
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
      child: Row(
        children: <Widget>[
          Icon(error ? Icons.warning_amber : Icons.info_outline, color: color),
          const SizedBox(width: 10),
          Expanded(child: Text(message)),
          if (onBack != null)
            TextButton.icon(
              onPressed: onBack,
              icon: const Icon(Icons.arrow_back),
              label: const Text('Reconnect'),
            ),
        ],
      ),
    );
  }
}

final class _ToolBar extends StatelessWidget {
  const _ToolBar();

  @override
  Widget build(BuildContext context) => Container(
    height: 54,
    padding: const EdgeInsets.symmetric(horizontal: 18),
    child: const Row(
      children: <Widget>[
        Icon(Icons.edit_outlined, size: 20),
        SizedBox(width: 9),
        Text('Pen'),
        SizedBox(width: 18),
        DecoratedBox(
          decoration: BoxDecoration(
            color: Color(0xFF121418),
            shape: BoxShape.circle,
          ),
          child: SizedBox.square(dimension: 16),
        ),
        SizedBox(width: 9),
        Text('4 logical units'),
      ],
    ),
  );
}
