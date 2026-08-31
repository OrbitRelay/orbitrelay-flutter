import 'dart:convert';

import 'error.dart';
import 'ids.dart';
import 'message.dart';
import 'query.dart';

final class OrbitRelayJsonCodec {
  const OrbitRelayJsonCodec();

  String encodeHello() => _encode(<String, Object?>{
    'kind': 'hello',
    'payload': <String, Object?>{
      'supported_versions': orbitRelaySupportedVersions
          .map((version) => version.toJson())
          .toList(growable: false),
      'codecs': <Object?>['json'],
    },
  });

  String encodeAuthenticate(MessageId requestId, ActorId actorId) =>
      _encode(<String, Object?>{
        'kind': 'authenticate',
        'payload': <String, Object?>{
          'request_id': requestId.value,
          'credentials': <String, Object?>{
            'scheme': 'development',
            'credential': actorId.value,
          },
        },
      });

  String encodeSubscribe(
    MessageId requestId,
    SessionId sessionId,
    Iterable<String> eventTypes,
  ) => _encode(<String, Object?>{
    'kind': 'subscribe',
    'payload': <String, Object?>{
      'request_id': requestId.value,
      'session_id': sessionId.value,
      'event_types': eventTypes.toList()..sort(),
    },
  });

  String encodeAction(MessageId messageId, ActionRequest action) =>
      encodeActionForVersion(messageId, action, orbitRelayProtocolV01);

  String encodeActionForVersion(
    MessageId messageId,
    ActionRequest action,
    ProtocolVersion version,
  ) => _encode(<String, Object?>{
    'kind': 'action',
    'payload': <String, Object?>{
      'version': version.toJson(),
      'message_id': messageId.value,
      'message_type': 'action',
      'payload': action.toJson(),
    },
  });

  String encodeQuery(
    MessageId messageId,
    String queryType,
    Map<String, Object?> payload, {
    ProtocolVersion version = orbitRelayProtocolV02,
  }) => _encode(<String, Object?>{
    'kind': 'query',
    'payload': <String, Object?>{
      'version': version.toJson(),
      'message_id': messageId.value,
      'message_type': queryType,
      'payload': payload,
    },
  });

  String encodePing(int nonce) => _encode(<String, Object?>{
    'kind': 'ping',
    'payload': <String, Object?>{'nonce': nonce},
  });

  ServerMessage decodeServerMessage(String source) {
    final Object? decoded;
    try {
      decoded = jsonDecode(source);
    } on FormatException catch (error) {
      throw ClientProtocolError(
        ClientProtocolErrorCode.invalidJson,
        'Server frame is not valid JSON: ${error.message}',
      );
    }
    final root = _object(decoded, 'message');
    _exactFields(root, const {'kind', 'payload'}, 'message');
    final kind = _string(root, 'kind');
    final payload = _object(_required(root, 'payload'), '$kind payload');

    return switch (kind) {
      'hello_accepted' => _decodeHelloAccepted(payload),
      'subscription_accepted' => _decodeSubscriptionAccepted(payload),
      'action_acknowledgement' => _decodeAcknowledgement(payload),
      'event' => EventServerMessage(_decodeEventEnvelope(payload)),
      'query_response' => _decodeQueryResponse(payload),
      'error' => _decodeError(payload),
      'pong' => _decodePong(payload),
      'close' => _decodeClose(payload),
      'subscription_closed' => _decodeSubscriptionClosed(payload),
      _ => throw ClientProtocolError(
        ClientProtocolErrorCode.unknownMessageKind,
        'Unsupported server message kind "$kind"',
      ),
    };
  }

  String _encode(Map<String, Object?> value) => jsonEncode(value);

  HelloAcceptedMessage _decodeHelloAccepted(Map<String, Object?> payload) {
    _exactFields(payload, const {
      'selected_version',
      'codec',
    }, 'hello_accepted');
    return HelloAcceptedMessage(
      _version(
        _object(_required(payload, 'selected_version'), 'selected_version'),
      ),
      _string(payload, 'codec'),
    );
  }

  SubscriptionAcceptedMessage _decodeSubscriptionAccepted(
    Map<String, Object?> payload,
  ) {
    _exactFields(payload, const {
      'request_id',
      'subscription_id',
    }, 'subscription_accepted');
    return SubscriptionAcceptedMessage(
      _messageId(payload, 'request_id'),
      _string(payload, 'subscription_id'),
    );
  }

  ActionAcknowledgementMessage _decodeAcknowledgement(
    Map<String, Object?> payload,
  ) {
    _exactFields(payload, const {
      'request_id',
      'action_id',
      'generated_event_ids',
    }, 'action_acknowledgement');
    final ids = _list(payload, 'generated_event_ids')
        .map(
          (value) =>
              EventId.parse(_typedString(value, 'generated_event_ids item')),
        )
        .toList(growable: false);
    return ActionAcknowledgementMessage(
      requestId: _messageId(payload, 'request_id'),
      actionId: ActionId.parse(_string(payload, 'action_id')),
      generatedEventIds: ids,
    );
  }

  EventMessage _decodeEventEnvelope(Map<String, Object?> envelope) {
    _exactFields(envelope, const {
      'version',
      'message_id',
      'message_type',
      'payload',
    }, 'event envelope');
    final version = _version(
      _object(_required(envelope, 'version'), 'event version'),
    );
    if (!version.isSupported) {
      throw ClientProtocolError(
        ClientProtocolErrorCode.unsupportedVersion,
        'Event uses unsupported protocol version $version',
      );
    }
    if (_string(envelope, 'message_type') != 'event') {
      throw const ClientProtocolError(
        ClientProtocolErrorCode.invalidEnvelope,
        'Server event envelope has a non-event message_type',
      );
    }
    final event = _object(_required(envelope, 'payload'), 'event');
    _exactFields(event, const {
      'id',
      'session_id',
      'actor_id',
      'action_id',
      'event_type',
      'occurred_at',
      'payload',
      'metadata',
    }, 'event');
    final metadata = _object(_required(event, 'metadata'), 'event metadata');
    final timestampSource = _string(event, 'occurred_at');
    final OrbitRelayTimestamp timestamp;
    try {
      timestamp = OrbitRelayTimestamp.parse(timestampSource);
    } on FormatException catch (error) {
      throw ClientProtocolError(
        ClientProtocolErrorCode.invalidTimestamp,
        error.message,
      );
    }
    return EventMessage(
      messageId: _messageId(envelope, 'message_id'),
      id: EventId.parse(_string(event, 'id')),
      sessionId: SessionId.parse(_string(event, 'session_id')),
      actorId: ActorId.parse(_string(event, 'actor_id')),
      actionId: ActionId.parse(_string(event, 'action_id')),
      eventType: _string(event, 'event_type'),
      occurredAt: timestamp,
      payload: _object(_required(event, 'payload'), 'event payload'),
      metadata: metadata,
    );
  }

  QueryResponseMessage _decodeQueryResponse(Map<String, Object?> payload) {
    _exactFields(payload, const {
      'version',
      'request_id',
      'query_type',
      'result',
    }, 'query_response');
    final version = _version(
      _object(_required(payload, 'version'), 'query_response version'),
    );
    if (!version.isSupported) {
      throw ClientProtocolError(
        ClientProtocolErrorCode.unsupportedVersion,
        'Query response uses unsupported protocol version $version',
      );
    }
    final result = _object(_required(payload, 'result'), 'query result');
    _exactFields(result, const {'status', 'payload'}, 'query result');
    final status = _string(result, 'status');
    final resultPayload = _object(
      _required(result, 'payload'),
      'query result payload',
    );
    final queryType = _string(payload, 'query_type');
    if (status == 'success') {
      return QueryResponseMessage(
        version: version,
        requestId: _messageId(payload, 'request_id'),
        queryType: queryType,
        result: QuerySuccessResult(resultPayload),
      );
    }
    if (status == 'error') {
      _exactFields(resultPayload, const {
        'code',
        'message',
        'retryable',
      }, 'query error');
      return QueryResponseMessage(
        version: version,
        requestId: _messageId(payload, 'request_id'),
        queryType: queryType,
        result: QueryErrorResult(
          code: QueryFailureCode.parse(_string(resultPayload, 'code')),
          message: _string(resultPayload, 'message'),
          retryable: _bool(resultPayload, 'retryable'),
        ),
      );
    }
    throw ClientProtocolError(
      ClientProtocolErrorCode.invalidEnvelope,
      'Query result status must be success or error',
    );
  }

  ServerErrorMessage _decodeError(Map<String, Object?> payload) {
    _exactFields(payload, const {
      'request_id',
      'code',
      'message',
      'retryable',
    }, 'error');
    final requestValue = _required(payload, 'request_id');
    return ServerErrorMessage(
      requestId: requestValue == null
          ? null
          : MessageId.parse(_typedString(requestValue, 'request_id')),
      code: _string(payload, 'code'),
      message: _string(payload, 'message'),
      retryable: _bool(payload, 'retryable'),
    );
  }

  PongServerMessage _decodePong(Map<String, Object?> payload) {
    _exactFields(payload, const {'nonce'}, 'pong');
    return PongServerMessage(_integer(payload, 'nonce'));
  }

  CloseServerMessage _decodeClose(Map<String, Object?> payload) {
    _exactFields(payload, const {'reason'}, 'close');
    final reason = _required(payload, 'reason');
    return CloseServerMessage(
      reason == null ? null : _typedString(reason, 'reason'),
    );
  }

  SubscriptionClosedMessage _decodeSubscriptionClosed(
    Map<String, Object?> payload,
  ) {
    _exactFields(payload, const {
      'request_id',
      'subscription_id',
    }, 'subscription_closed');
    final requestId = _required(payload, 'request_id');
    return SubscriptionClosedMessage(
      requestId: requestId == null
          ? null
          : MessageId.parse(_typedString(requestId, 'request_id')),
      subscriptionId: _string(payload, 'subscription_id'),
    );
  }

  ProtocolVersion _version(Map<String, Object?> value) {
    _exactFields(value, const {'major', 'minor', 'patch'}, 'version');
    return ProtocolVersion(
      _integer(value, 'major'),
      _integer(value, 'minor'),
      _integer(value, 'patch'),
    );
  }

  MessageId _messageId(Map<String, Object?> value, String field) =>
      MessageId.parse(_string(value, field));
}

Object? _required(Map<String, Object?> value, String field) {
  if (!value.containsKey(field)) {
    throw ClientProtocolError(
      ClientProtocolErrorCode.missingField,
      'Missing required field "$field"',
    );
  }
  return value[field];
}

Map<String, Object?> _object(Object? value, String context) {
  if (value is! Map<String, Object?>) {
    throw ClientProtocolError(
      ClientProtocolErrorCode.invalidFieldType,
      '$context must be a JSON object',
    );
  }
  return value;
}

String _typedString(Object? value, String context) {
  if (value is! String) {
    throw ClientProtocolError(
      ClientProtocolErrorCode.invalidFieldType,
      '$context must be a string',
    );
  }
  return value;
}

String _string(Map<String, Object?> value, String field) =>
    _typedString(_required(value, field), field);

bool _bool(Map<String, Object?> value, String field) {
  final result = _required(value, field);
  if (result is! bool) {
    throw ClientProtocolError(
      ClientProtocolErrorCode.invalidFieldType,
      '$field must be a boolean',
    );
  }
  return result;
}

int _integer(Map<String, Object?> value, String field) {
  final result = _required(value, field);
  if (result is! int) {
    throw ClientProtocolError(
      ClientProtocolErrorCode.invalidFieldType,
      '$field must be an integer',
    );
  }
  return result;
}

List<Object?> _list(Map<String, Object?> value, String field) {
  final result = _required(value, field);
  if (result is! List<Object?>) {
    throw ClientProtocolError(
      ClientProtocolErrorCode.invalidFieldType,
      '$field must be an array',
    );
  }
  return result;
}

void _exactFields(
  Map<String, Object?> value,
  Set<String> expected,
  String context,
) {
  for (final field in expected) {
    if (!value.containsKey(field)) {
      throw ClientProtocolError(
        ClientProtocolErrorCode.missingField,
        '$context is missing "$field"',
      );
    }
  }
  for (final field in value.keys) {
    if (!expected.contains(field)) {
      throw ClientProtocolError(
        ClientProtocolErrorCode.invalidEnvelope,
        '$context contains unknown field "$field"',
      );
    }
  }
}
