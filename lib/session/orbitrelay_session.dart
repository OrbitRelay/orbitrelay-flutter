import 'dart:async';
import 'dart:collection';

import 'package:flutter/foundation.dart';

import '../canvas/canvas_protocol.dart';
import '../protocol/codec.dart';
import '../protocol/error.dart';
import '../protocol/ids.dart';
import '../protocol/message.dart';
import '../protocol/query.dart';
import '../transport/connection_state.dart';
import '../transport/websocket_transport.dart';
import 'outbound_queue.dart';
import 'pending_action.dart';

final class OrbitRelaySessionConfig {
  const OrbitRelaySessionConfig({
    required this.serverUri,
    required this.actorId,
    required this.sessionId,
    this.queryTimeout = const Duration(seconds: 15),
  });

  final Uri serverUri;
  final ActorId actorId;
  final SessionId sessionId;
  final Duration queryTimeout;
}

abstract interface class OrbitRelayCanvasSession {
  OrbitRelayConnectionState get connectionState;
  ValueListenable<OrbitRelayConnectionState> get connectionStateListenable;
  Stream<EventMessage> get events;
  Stream<ActionFailure> get actionFailures;

  PendingAction enqueueCanvasAction(CanvasActionPayload payload);
  void cancelQueuedActionsForStroke(StrokeId strokeId, {int? fromChunkIndex});
  Future<void> close();
  void dispose();
}

abstract interface class OrbitRelayQuerySession {
  SessionId get sessionId;
  ProtocolVersion? get negotiatedVersion;
  int get connectionGeneration;
  int? get subscriptionGeneration;
  bool get subscriptionHealthy;

  Future<QueryResult> query(
    String queryType,
    Map<String, Object?> payload, {
    Duration? timeout,
  });
}

abstract interface class OrbitRelayCollaborationSession
    implements OrbitRelayCanvasSession, OrbitRelayQuerySession {}

final class OrbitRelaySession extends ChangeNotifier
    implements OrbitRelayCollaborationSession {
  OrbitRelaySession({
    required this.config,
    TextTransportFactory? transportFactory,
    OrbitRelayJsonCodec codec = const OrbitRelayJsonCodec(),
  }) : _transportFactory = transportFactory ?? WebSocketTransport.new,
       _codec = codec;

  final OrbitRelaySessionConfig config;
  final TextTransportFactory _transportFactory;
  final OrbitRelayJsonCodec _codec;
  final ValueNotifier<OrbitRelayConnectionState> _connectionState =
      ValueNotifier<OrbitRelayConnectionState>(
        OrbitRelayConnectionState.disconnected,
      );
  final StreamController<EventMessage> _events =
      StreamController<EventMessage>.broadcast(sync: true);
  final StreamController<ActionFailure> _actionFailures =
      StreamController<ActionFailure>.broadcast(sync: true);
  final Map<MessageId, PendingAction> _pending = <MessageId, PendingAction>{};
  final Map<MessageId, _PendingQuery> _pendingQueries =
      <MessageId, _PendingQuery>{};

  TextTransport? _transport;
  StreamSubscription<String>? _reader;
  OutboundActionQueue? _actionQueue;
  Completer<void>? _handshake;
  MessageId? _subscriptionRequestId;
  Future<void> _inboundSerial = Future<void>.value();
  Future<void> _querySendSerial = Future<void>.value();
  ProtocolVersion? _negotiatedVersion;
  int _connectionGeneration = 0;
  int _subscriptionGenerationCounter = 0;
  int? _subscriptionGeneration;
  bool _disposed = false;

  @override
  SessionId get sessionId => config.sessionId;

  @override
  OrbitRelayConnectionState get connectionState => _connectionState.value;

  @override
  ValueListenable<OrbitRelayConnectionState> get connectionStateListenable =>
      _connectionState;

  @override
  Stream<EventMessage> get events => _events.stream;

  @override
  Stream<ActionFailure> get actionFailures => _actionFailures.stream;

  @override
  ProtocolVersion? get negotiatedVersion => _negotiatedVersion;

  @override
  int get connectionGeneration => _connectionGeneration;

  @override
  int? get subscriptionGeneration => _subscriptionGeneration;

  @override
  bool get subscriptionHealthy =>
      connectionState == OrbitRelayConnectionState.ready &&
      _subscriptionGeneration != null;

  UnmodifiableMapView<MessageId, PendingAction> get pendingActions =>
      UnmodifiableMapView<MessageId, PendingAction>(_pending);

  int get pendingQueryCount => _pendingQueries.length;

  Future<void> connect() async {
    if (connectionState != OrbitRelayConnectionState.disconnected) {
      throw StateError('Session can only connect from Disconnected');
    }
    _connectionGeneration += 1;
    _negotiatedVersion = null;
    _subscriptionGeneration = null;
    _setState(OrbitRelayConnectionState.connecting);
    final transport = _transportFactory();
    _transport = transport;
    try {
      await transport.connect(config.serverUri);
      final generation = _connectionGeneration;
      _reader = transport.messages.listen(
        (source) => _scheduleInbound(source, generation),
        onError: (Object error, StackTrace stackTrace) {
          _fail('Connection receive failed', error, stackTrace);
        },
        onDone: _handleTransportDone,
      );
      _actionQueue = OutboundActionQueue(
        transport: transport,
        onStatusChanged: notifyListeners,
        onFatalFailure: (Object error) => _fail('Action send failed', error),
      );
      _handshake = Completer<void>();
      _setState(OrbitRelayConnectionState.negotiating);
      await transport.sendText(_codec.encodeHello());
      await _handshake!.future.timeout(const Duration(seconds: 15));
    } on Object catch (error, stackTrace) {
      _fail('Connection setup failed', error, stackTrace);
      rethrow;
    }
  }

  @override
  PendingAction enqueueCanvasAction(CanvasActionPayload payload) {
    if (connectionState != OrbitRelayConnectionState.ready) {
      throw StateError('Canvas Actions require a Ready session');
    }
    final queue = _actionQueue;
    if (queue == null || !queue.isOpen) {
      throw StateError('Outbound Action queue is unavailable');
    }
    final messageId = MessageId.generate();
    final actionId = ActionId.generate();
    final pending = PendingAction(
      messageId: messageId,
      actionId: actionId,
      strokeId: payload.strokeId,
      actionKind: payload.actionType,
      chunkIndex: payload.correlationChunkIndex,
      sentAt: DateTime.now().toUtc(),
    );
    final encoded = _codec.encodeActionForVersion(
      messageId,
      ActionRequest(
        id: actionId,
        sessionId: config.sessionId,
        actorId: config.actorId,
        actionType: payload.actionType,
        requestedAt: OrbitRelayTimestamp.now(),
        payload: payload.toJson(),
      ),
      _negotiatedVersion ?? orbitRelayProtocolV01,
    );
    _pending[messageId] = pending;
    try {
      queue.enqueue(pending, encoded);
    } on Object {
      _pending.remove(messageId);
      rethrow;
    }
    notifyListeners();
    return pending;
  }

  @override
  Future<QueryResult> query(
    String queryType,
    Map<String, Object?> payload, {
    Duration? timeout,
  }) {
    final version = _negotiatedVersion;
    debugPrint(
      'OrbitRelay query requested type=$queryType '
      'connection_generation=$_connectionGeneration '
      'subscription_generation=$_subscriptionGeneration '
      'state=${connectionState.name} negotiated=$version',
    );
    if (version == null || !version.supportsQueries) {
      return Future<QueryResult>.error(
        QueryException.client(
          queryType: queryType,
          failure: QueryClientFailure.unsupportedVersion,
          message: 'Queries require negotiated Protocol 0.2',
        ),
      );
    }
    if (connectionState != OrbitRelayConnectionState.ready ||
        !subscriptionHealthy) {
      return Future<QueryResult>.error(
        QueryException.client(
          queryType: queryType,
          failure: QueryClientFailure.disconnected,
          message: 'Queries require a healthy Ready session',
        ),
      );
    }
    final requestId = MessageId.generate();
    final completer = Completer<QueryResult>();
    final entry = _PendingQuery(
      queryType: queryType,
      generation: _connectionGeneration,
      subscriptionGeneration: _subscriptionGeneration!,
      completer: completer,
    );
    final duration = timeout ?? config.queryTimeout;
    entry.timer = Timer(duration, () {
      if (_pendingQueries.remove(requestId) != null && !completer.isCompleted) {
        completer.completeError(
          QueryException.client(
            queryType: queryType,
            failure: QueryClientFailure.timeout,
            message: 'Query timed out',
          ),
        );
      }
    });
    _pendingQueries[requestId] = entry;
    final encoded = _codec.encodeQuery(
      requestId,
      queryType,
      payload,
      version: version,
    );
    _querySendSerial = _querySendSerial
        .then((_) async {
          if (_pendingQueries[requestId] == null ||
              _connectionGeneration != entry.generation ||
              !subscriptionHealthy) {
            debugPrint(
              'OrbitRelay query not sent request_id=${requestId.value} '
              'type=$queryType connection_generation=$_connectionGeneration '
              'subscription_generation=$_subscriptionGeneration '
              'state=${connectionState.name}',
            );
            return;
          }
          try {
            debugPrint(
              'OrbitRelay query sent request_id=${requestId.value} '
              'type=$queryType version=$version '
              'connection_generation=${entry.generation} '
              'subscription_generation=${entry.subscriptionGeneration}',
            );
            await _transport!.sendText(encoded);
          } on Object catch (error, stackTrace) {
            if (_pendingQueries.remove(requestId) != null &&
                !completer.isCompleted) {
              entry.timer?.cancel();
              completer.completeError(
                QueryException.client(
                  queryType: queryType,
                  failure: QueryClientFailure.disconnected,
                  message: 'Query could not be sent',
                ),
                stackTrace,
              );
            }
            _fail('Query send failed', error, stackTrace);
          }
        })
        .catchError((Object error, StackTrace stackTrace) {
          if (_pendingQueries.remove(requestId) != null &&
              !completer.isCompleted) {
            entry.timer?.cancel();
            completer.completeError(error, stackTrace);
          }
        });
    return completer.future;
  }

  @override
  void cancelQueuedActionsForStroke(StrokeId strokeId, {int? fromChunkIndex}) {
    _actionQueue?.cancelUnsentForStroke(
      strokeId,
      fromChunkIndex: fromChunkIndex,
    );
  }

  @override
  Future<void> close() async {
    if (connectionState == OrbitRelayConnectionState.disconnected ||
        _disposed) {
      return;
    }
    _setState(OrbitRelayConnectionState.closing);
    _markOutstandingUnknown();
    _failPendingQueries();
    _invalidateSubscription();
    _actionQueue?.close();
    await _reader?.cancel();
    await _transport?.close();
    if (!_disposed) {
      _setState(OrbitRelayConnectionState.disconnected);
    }
  }

  void _scheduleInbound(String source, int generation) {
    if (generation != _connectionGeneration) {
      return;
    }
    _inboundSerial = _inboundSerial
        .then((_) => _handleInbound(source, generation))
        .catchError((Object error, StackTrace stackTrace) {
          _fail('Protocol processing failed', error, stackTrace);
        });
  }

  Future<void> _handleInbound(String source, int generation) async {
    if (generation != _connectionGeneration) {
      return;
    }
    final message = _codec.decodeServerMessage(source);
    debugPrint(
      'OrbitRelay inbound kind=${message.runtimeType} '
      'connection_generation=$generation '
      'subscription_generation=$_subscriptionGeneration',
    );
    switch (message) {
      case HelloAcceptedMessage():
        await _handleHelloAccepted(message);
      case SubscriptionAcceptedMessage():
        _handleSubscriptionAccepted(message);
      case ActionAcknowledgementMessage():
        _handleAcknowledgement(message);
      case EventServerMessage():
        _events.add(message.event);
      case QueryResponseMessage():
        _handleQueryResponse(message);
      case ServerErrorMessage():
        _handleServerError(message);
      case PongServerMessage():
        break;
      case CloseServerMessage():
        await close();
      case SubscriptionClosedMessage():
        _fail('The realtime subscription closed');
    }
  }

  Future<void> _handleHelloAccepted(HelloAcceptedMessage message) async {
    if (connectionState != OrbitRelayConnectionState.negotiating) {
      throw const ClientProtocolError(
        ClientProtocolErrorCode.invalidEnvelope,
        'hello_accepted arrived outside negotiation',
      );
    }
    if (!message.selectedVersion.isSupported || message.codec != 'json') {
      throw ClientProtocolError(
        ClientProtocolErrorCode.unsupportedVersion,
        'Server selected ${message.selectedVersion}/${message.codec}',
      );
    }
    _negotiatedVersion = message.selectedVersion;
    final transport = _transport!;
    _setState(OrbitRelayConnectionState.authenticating);
    await transport.sendText(
      _codec.encodeAuthenticate(MessageId.generate(), config.actorId),
    );

    // The current protocol deliberately has no AuthenticationAccepted message.
    _setState(OrbitRelayConnectionState.subscribing);
    final requestId = MessageId.generate();
    _subscriptionRequestId = requestId;
    await transport.sendText(
      _codec.encodeSubscribe(requestId, config.sessionId, canvasEventTypes),
    );
  }

  void _handleSubscriptionAccepted(SubscriptionAcceptedMessage message) {
    if (connectionState != OrbitRelayConnectionState.subscribing ||
        message.requestId != _subscriptionRequestId) {
      throw const ClientProtocolError(
        ClientProtocolErrorCode.invalidEnvelope,
        'subscription_accepted does not match the active request',
      );
    }
    _setState(OrbitRelayConnectionState.ready);
    _subscriptionGeneration = ++_subscriptionGenerationCounter;
    debugPrint(
      'OrbitRelay subscription accepted request_id=${message.requestId.value} '
      'subscription_generation=$_subscriptionGeneration '
      'connection_generation=$_connectionGeneration',
    );
    if (!(_handshake?.isCompleted ?? true)) {
      _handshake!.complete();
    }
  }

  void _handleAcknowledgement(ActionAcknowledgementMessage message) {
    final pending = _pending[message.requestId];
    if (pending == null || pending.actionId != message.actionId) {
      throw const ClientProtocolError(
        ClientProtocolErrorCode.invalidEnvelope,
        'Action acknowledgement correlation does not match',
      );
    }
    pending.acknowledge(message.generatedEventIds);
    notifyListeners();
  }

  void _handleServerError(ServerErrorMessage message) {
    final requestId = message.requestId;
    final pending = requestId == null ? null : _pending[requestId];
    if (pending != null) {
      pending.reject(message.message);
      _actionFailures.add(
        ActionFailure(action: pending, safeMessage: message.message),
      );
      notifyListeners();
      return;
    }
    if (requestId == _subscriptionRequestId ||
        message.code == 'lagged' ||
        message.code == 'subscription_error') {
      _invalidateSubscription();
      _fail('Realtime subscription failed: ${message.code}');
      return;
    }
    if (connectionState != OrbitRelayConnectionState.ready) {
      _fail('${message.code}: ${message.message}');
    }
  }

  void _handleQueryResponse(QueryResponseMessage message) {
    final entry = _pendingQueries[message.requestId];
    if (entry == null) {
      debugPrint(
        'OrbitRelay query response ignored request_id=${message.requestId.value} '
        'type=${message.queryType}: no pending entry',
      );
      return;
    }
    final generationMatches = entry.generation == _connectionGeneration;
    final subscriptionMatches =
        entry.subscriptionGeneration == _subscriptionGeneration;
    final versionMatches = message.version == _negotiatedVersion;
    final queryTypeMatches = message.queryType == entry.queryType;
    if (!generationMatches ||
        !subscriptionMatches ||
        !versionMatches ||
        !queryTypeMatches) {
      debugPrint(
        'OrbitRelay query response ignored request_id=${message.requestId.value} '
        'type=${message.queryType} expected_type=${entry.queryType} '
        'generation=$generationMatches subscription=$subscriptionMatches '
        'version=$versionMatches response_version=${message.version} '
        'negotiated=$_negotiatedVersion type_match=$queryTypeMatches',
      );
      return;
    }
    _pendingQueries.remove(message.requestId);
    entry.timer?.cancel();
    if (entry.completer.isCompleted) {
      return;
    }
    final result = message.result;
    debugPrint(
      'OrbitRelay query response completed request_id=${message.requestId.value} '
      'type=${entry.queryType} result=${result.runtimeType}',
    );
    if (result is QueryErrorResult) {
      entry.completer.completeError(
        QueryException.server(
          queryType: entry.queryType,
          code: result.code,
          message: result.message,
          retryable: result.retryable,
        ),
      );
    } else {
      entry.completer.complete(result);
    }
  }

  void _handleTransportDone() {
    if (connectionState == OrbitRelayConnectionState.closing || _disposed) {
      return;
    }
    _markOutstandingUnknown();
    _invalidateSubscription();
    _failPendingQueries();
    _actionQueue?.close();
    _setState(OrbitRelayConnectionState.disconnected);
  }

  void _markOutstandingUnknown() {
    for (final action in _pending.values) {
      action.markUnknown();
    }
    notifyListeners();
  }

  void _invalidateSubscription() {
    _subscriptionGeneration = null;
  }

  void _failPendingQueries() {
    final entries = _pendingQueries.values.toList(growable: false);
    _pendingQueries.clear();
    for (final entry in entries) {
      entry.timer?.cancel();
      if (!entry.completer.isCompleted) {
        entry.completer.completeError(
          QueryException.client(
            queryType: entry.queryType,
            failure: QueryClientFailure.disconnected,
            message: 'Session disconnected while Query was pending',
          ),
        );
      }
    }
  }

  void _fail(String message, [Object? error, StackTrace? stackTrace]) {
    if (_disposed || connectionState == OrbitRelayConnectionState.failed) {
      return;
    }
    debugPrint(
      'OrbitRelay session failure: $message${error == null ? '' : ': $error'}',
    );
    _markOutstandingUnknown();
    _invalidateSubscription();
    _failPendingQueries();
    _actionQueue?.close();
    _setState(OrbitRelayConnectionState.failed);
    if (!(_handshake?.isCompleted ?? true)) {
      _handshake!.completeError(
        error ?? ClientTransportError(message),
        stackTrace,
      );
    }
  }

  void _setState(OrbitRelayConnectionState next) {
    if (_disposed || _connectionState.value == next) {
      return;
    }
    _connectionState.value = next;
    debugPrint('OrbitRelay connection state: ${next.name}');
    notifyListeners();
  }

  @override
  void dispose() {
    if (_disposed) {
      return;
    }
    _disposed = true;
    _failPendingQueries();
    _invalidateSubscription();
    _actionQueue?.close();
    unawaited(_reader?.cancel());
    unawaited(_transport?.close());
    unawaited(_events.close());
    unawaited(_actionFailures.close());
    _connectionState.dispose();
    super.dispose();
  }
}

final class _PendingQuery {
  _PendingQuery({
    required this.queryType,
    required this.generation,
    required this.subscriptionGeneration,
    required this.completer,
  });

  final String queryType;
  final int generation;
  final int subscriptionGeneration;
  final Completer<QueryResult> completer;
  Timer? timer;
}
