import 'dart:async';
import 'dart:collection';

import '../protocol/ids.dart';
import '../transport/websocket_transport.dart';
import 'pending_action.dart';

typedef QueueStatusCallback = void Function();
typedef QueueFailureCallback = void Function(Object error);

final class OutboundActionQueue {
  OutboundActionQueue({
    required TextTransport transport,
    required QueueStatusCallback onStatusChanged,
    required QueueFailureCallback onFatalFailure,
  }) : _transport = transport,
       _onStatusChanged = onStatusChanged,
       _onFatalFailure = onFatalFailure;

  final TextTransport _transport;
  final QueueStatusCallback _onStatusChanged;
  final QueueFailureCallback _onFatalFailure;
  final Queue<_OutboundEntry> _entries = Queue<_OutboundEntry>();

  bool _open = true;
  bool _draining = false;

  bool get isOpen => _open;

  void enqueue(PendingAction action, String encodedMessage) {
    if (!_open) {
      throw StateError('Outbound Action queue is closed');
    }
    _entries.add(_OutboundEntry(action, encodedMessage));
    if (!_draining) {
      scheduleMicrotask(() => unawaited(_drain()));
    }
  }

  List<PendingAction> cancelUnsentForStroke(
    StrokeId strokeId, {
    int? fromChunkIndex,
  }) {
    final cancelled = <PendingAction>[];
    final retained = Queue<_OutboundEntry>();
    while (_entries.isNotEmpty) {
      final entry = _entries.removeFirst();
      final chunk = entry.action.chunkIndex;
      final shouldCancel =
          entry.action.strokeId == strokeId &&
          (fromChunkIndex == null || chunk == null || chunk >= fromChunkIndex);
      if (shouldCancel) {
        entry.action.markUnknown();
        cancelled.add(entry.action);
      } else {
        retained.add(entry);
      }
    }
    _entries.addAll(retained);
    if (cancelled.isNotEmpty) {
      _onStatusChanged();
    }
    return cancelled;
  }

  List<PendingAction> close() {
    if (!_open) {
      return const <PendingAction>[];
    }
    _open = false;
    final abandoned = <PendingAction>[];
    while (_entries.isNotEmpty) {
      final action = _entries.removeFirst().action;
      action.markUnknown();
      abandoned.add(action);
    }
    _onStatusChanged();
    return abandoned;
  }

  Future<void> _drain() async {
    if (_draining) {
      return;
    }
    _draining = true;
    try {
      while (_open && _entries.isNotEmpty) {
        final entry = _entries.removeFirst();
        try {
          await _transport.sendText(entry.encodedMessage);
          entry.action.markSent();
          _onStatusChanged();
        } on Object catch (error) {
          entry.action.markUnknown();
          _onStatusChanged();
          close();
          _onFatalFailure(error);
          break;
        }
      }
    } finally {
      _draining = false;
      if (_open && _entries.isNotEmpty) {
        scheduleMicrotask(() => unawaited(_drain()));
      }
    }
  }
}

final class _OutboundEntry {
  const _OutboundEntry(this.action, this.encodedMessage);

  final PendingAction action;
  final String encodedMessage;
}
