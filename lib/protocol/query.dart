import 'dart:collection';

import 'ids.dart';
import 'message.dart';

enum QueryFailureCode {
  unsupportedQuery('unsupported_query'),
  invalidQuery('invalid_query'),
  unauthorized('unauthorized'),
  notFound('not_found'),
  internal('internal'),
  unavailable('unavailable'),
  notReady('not_ready');

  const QueryFailureCode(this.wireValue);

  final String wireValue;

  static QueryFailureCode parse(String value) {
    for (final code in values) {
      if (code.wireValue == value) {
        return code;
      }
    }
    throw FormatException('Unknown Query failure code', value);
  }
}

enum QueryClientFailure { unsupportedVersion, timeout, disconnected, protocol }

final class QueryException implements Exception {
  const QueryException.server({
    required this.queryType,
    required QueryFailureCode code,
    required this.message,
    required this.retryable,
  }) : serverCode = code,
       clientFailure = null;

  const QueryException.client({
    required this.queryType,
    required QueryClientFailure failure,
    required this.message,
  }) : clientFailure = failure,
       serverCode = null,
       retryable = false;

  final String queryType;
  final QueryFailureCode? serverCode;
  final QueryClientFailure? clientFailure;
  final String message;
  final bool retryable;

  @override
  String toString() {
    final code = serverCode?.wireValue ?? clientFailure?.name ?? 'unknown';
    return 'QueryException($queryType, $code): $message';
  }
}

sealed class QueryResult {
  const QueryResult();
}

final class QuerySuccessResult extends QueryResult {
  QuerySuccessResult(Map<String, Object?> payload)
    : payload = UnmodifiableMapView<String, Object?>(payload);

  final Map<String, Object?> payload;
}

final class QueryErrorResult extends QueryResult {
  const QueryErrorResult({
    required this.code,
    required this.message,
    required this.retryable,
  });

  final QueryFailureCode code;
  final String message;
  final bool retryable;
}

final class QueryResponseMessage extends ServerMessage {
  const QueryResponseMessage({
    required this.version,
    required this.requestId,
    required this.queryType,
    required this.result,
  });

  final ProtocolVersion version;
  final MessageId requestId;
  final String queryType;
  final QueryResult result;
}
