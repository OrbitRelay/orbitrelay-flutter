import 'dart:async';

import 'package:web_socket_channel/web_socket_channel.dart';

import '../protocol/error.dart';

abstract interface class TextTransport {
  Stream<String> get messages;

  Future<void> connect(Uri uri);

  Future<void> sendText(String value);

  Future<void> close();
}

typedef TextTransportFactory = TextTransport Function();

final class WebSocketTransport implements TextTransport {
  WebSocketChannel? _channel;
  StreamSubscription<Object?>? _subscription;
  final StreamController<String> _messages = StreamController<String>.broadcast(
    sync: true,
  );
  bool _closed = false;

  @override
  Stream<String> get messages => _messages.stream;

  @override
  Future<void> connect(Uri uri) async {
    if (_channel != null || _closed) {
      throw const ClientTransportError('Transport cannot be connected twice');
    }
    try {
      final channel = WebSocketChannel.connect(uri);
      _channel = channel;
      await channel.ready;
      _subscription = channel.stream.listen(
        (Object? frame) {
          if (frame is String) {
            _messages.add(frame);
          } else {
            _messages.addError(
              const ClientProtocolError(
                ClientProtocolErrorCode.binaryFrame,
                'OrbitRelay JSON protocol accepts WebSocket text frames only',
              ),
            );
          }
        },
        onError: (Object error, StackTrace stackTrace) {
          _messages.addError(
            ClientTransportError('WebSocket receive failed', error),
            stackTrace,
          );
        },
        onDone: _messages.close,
      );
    } on Object catch (error) {
      throw ClientTransportError('WebSocket connection failed', error);
    }
  }

  @override
  Future<void> sendText(String value) async {
    final channel = _channel;
    if (channel == null || _closed) {
      throw const ClientTransportError('WebSocket is not open');
    }
    try {
      channel.sink.add(value);
    } on Object catch (error) {
      throw ClientTransportError('WebSocket send failed', error);
    }
  }

  @override
  Future<void> close() async {
    if (_closed) {
      return;
    }
    _closed = true;
    await _subscription?.cancel();
    await _channel?.sink.close();
    if (!_messages.isClosed) {
      await _messages.close();
    }
  }
}
