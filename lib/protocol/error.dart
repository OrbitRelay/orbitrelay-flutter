enum ClientProtocolErrorCode {
  invalidJson,
  unknownMessageKind,
  missingField,
  invalidFieldType,
  invalidEnvelope,
  unsupportedVersion,
  invalidCanvasPayload,
  invalidTimestamp,
  binaryFrame,
}

final class ClientProtocolError implements Exception {
  const ClientProtocolError(this.code, this.message);

  final ClientProtocolErrorCode code;
  final String message;

  @override
  String toString() => 'ClientProtocolError(${code.name}): $message';
}

final class ClientTransportError implements Exception {
  const ClientTransportError(this.message, [this.cause]);

  final String message;
  final Object? cause;

  @override
  String toString() => 'ClientTransportError: $message';
}
