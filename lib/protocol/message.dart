import 'ids.dart';

const ProtocolVersion orbitRelayProtocolV01 = ProtocolVersion(0, 1, 0);
const ProtocolVersion orbitRelayProtocolV02 = ProtocolVersion(0, 2, 0);
// Kept as the v0.1 wire default for standalone callers that predate negotiation.
const ProtocolVersion orbitRelayProtocolVersion = orbitRelayProtocolV01;
const List<ProtocolVersion> orbitRelaySupportedVersions = <ProtocolVersion>[
  orbitRelayProtocolV02,
  orbitRelayProtocolV01,
];

final class ProtocolVersion {
  const ProtocolVersion(this.major, this.minor, this.patch);

  final int major;
  final int minor;
  final int patch;

  Map<String, Object?> toJson() => <String, Object?>{
    'major': major,
    'minor': minor,
    'patch': patch,
  };

  bool get supportsQueries =>
      major > 0 || (major == 0 && minor >= orbitRelayProtocolV02.minor);

  bool get isSupported => orbitRelaySupportedVersions.contains(this);

  @override
  bool operator ==(Object other) =>
      other is ProtocolVersion &&
      other.major == major &&
      other.minor == minor &&
      other.patch == patch;

  @override
  int get hashCode => Object.hash(major, minor, patch);

  @override
  String toString() => '$major.$minor.$patch';
}

final class OrbitRelayTimestamp {
  OrbitRelayTimestamp._(this.raw, this.utcValue);

  static final RegExp _wirePattern = RegExp(
    r'^(\d{4})-(\d{2})-(\d{2}) (\d{2}):(\d{2}):(\d{2})\.(\d{1,9}) \+00:00:00$',
  );

  final String raw;
  final DateTime utcValue;

  factory OrbitRelayTimestamp.parse(String value) {
    final match = _wirePattern.firstMatch(value);
    if (match == null) {
      throw FormatException('Invalid OrbitRelay timestamp', value);
    }
    try {
      final fraction = match.group(7)!;
      final micros = int.parse(
        (fraction.length >= 6
            ? fraction.substring(0, 6)
            : fraction.padRight(6, '0')),
      );
      final parsed = DateTime.utc(
        int.parse(match.group(1)!),
        int.parse(match.group(2)!),
        int.parse(match.group(3)!),
        int.parse(match.group(4)!),
        int.parse(match.group(5)!),
        int.parse(match.group(6)!),
        micros ~/ 1000,
        micros % 1000,
      );
      if (parsed.year != int.parse(match.group(1)!) ||
          parsed.month != int.parse(match.group(2)!) ||
          parsed.day != int.parse(match.group(3)!) ||
          parsed.hour != int.parse(match.group(4)!) ||
          parsed.minute != int.parse(match.group(5)!) ||
          parsed.second != int.parse(match.group(6)!)) {
        throw const FormatException('Timestamp components are out of range');
      }
      return OrbitRelayTimestamp._(value, parsed);
    } on FormatException {
      rethrow;
    } on Object catch (error) {
      throw FormatException('Invalid OrbitRelay timestamp: $error', value);
    }
  }

  factory OrbitRelayTimestamp.now() {
    final now = DateTime.now().toUtc();
    final fractionValue = now.microsecondsSinceEpoch.remainder(1000000);
    var fraction = fractionValue.toString().padLeft(6, '0');
    fraction = fraction.replaceFirst(RegExp(r'0+$'), '');
    if (fraction.isEmpty) {
      fraction = '0';
    }
    return OrbitRelayTimestamp.parse(_formatParts(now, fraction));
  }

  static String _formatParts(DateTime value, String fraction) {
    String two(int number) => number.toString().padLeft(2, '0');
    return '${value.year.toString().padLeft(4, '0')}-'
        '${two(value.month)}-${two(value.day)} '
        '${two(value.hour)}:${two(value.minute)}:${two(value.second)}.'
        '$fraction +00:00:00';
  }

  @override
  String toString() => raw;
}

final class ActionRequest {
  const ActionRequest({
    required this.id,
    required this.sessionId,
    required this.actorId,
    required this.actionType,
    required this.requestedAt,
    required this.payload,
  });

  final ActionId id;
  final SessionId sessionId;
  final ActorId actorId;
  final String actionType;
  final OrbitRelayTimestamp requestedAt;
  final Map<String, Object?> payload;

  Map<String, Object?> toJson() => <String, Object?>{
    'id': id.value,
    'session_id': sessionId.value,
    'actor_id': actorId.value,
    'action_type': actionType,
    'requested_at': requestedAt.raw,
    'payload': payload,
    'metadata': <String, Object?>{},
  };
}

final class EventMessage {
  const EventMessage({
    required this.messageId,
    required this.id,
    required this.sessionId,
    required this.actorId,
    required this.actionId,
    required this.eventType,
    required this.occurredAt,
    required this.payload,
    this.metadata = const <String, Object?>{},
  });

  /// Transport envelope identity. Historical Events receive an internal
  /// non-authoritative envelope id when converted to this shared model.
  final MessageId messageId;
  final EventId id;
  final SessionId sessionId;
  final ActorId actorId;
  final ActionId actionId;
  final String eventType;
  final OrbitRelayTimestamp occurredAt;
  final Map<String, Object?> payload;
  final Map<String, Object?> metadata;
}

abstract class ServerMessage {
  const ServerMessage();
}

final class HelloAcceptedMessage extends ServerMessage {
  const HelloAcceptedMessage(this.selectedVersion, this.codec);

  final ProtocolVersion selectedVersion;
  final String codec;
}

final class SubscriptionAcceptedMessage extends ServerMessage {
  const SubscriptionAcceptedMessage(this.requestId, this.subscriptionId);

  final MessageId requestId;
  final String subscriptionId;
}

final class ActionAcknowledgementMessage extends ServerMessage {
  const ActionAcknowledgementMessage({
    required this.requestId,
    required this.actionId,
    required this.generatedEventIds,
  });

  final MessageId requestId;
  final ActionId actionId;
  final List<EventId> generatedEventIds;
}

final class EventServerMessage extends ServerMessage {
  const EventServerMessage(this.event);

  final EventMessage event;
}

final class ServerErrorMessage extends ServerMessage {
  const ServerErrorMessage({
    required this.requestId,
    required this.code,
    required this.message,
    required this.retryable,
  });

  final MessageId? requestId;
  final String code;
  final String message;
  final bool retryable;
}

final class PongServerMessage extends ServerMessage {
  const PongServerMessage(this.nonce);

  final int nonce;
}

final class CloseServerMessage extends ServerMessage {
  const CloseServerMessage(this.reason);

  final String? reason;
}

final class SubscriptionClosedMessage extends ServerMessage {
  const SubscriptionClosedMessage({
    required this.requestId,
    required this.subscriptionId,
  });

  final MessageId? requestId;
  final String subscriptionId;
}
