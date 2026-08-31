import 'package:flutter/foundation.dart';

import '../protocol/ids.dart';
import '../protocol/query.dart';
import '../session/orbitrelay_session.dart';
import 'document_dto.dart';

const String documentListQueryType = 'document.list';
const String documentGetQueryType = 'document.get';

final class DocumentClient {
  const DocumentClient({required this.session});

  final OrbitRelayQuerySession session;

  Future<DocumentListResultDto> listDocuments([
    SessionId? requestedSessionId,
  ]) async {
    final sessionId = requestedSessionId ?? session.sessionId;
    if (sessionId != session.sessionId) {
      throw StateError(
        'Document listing Session does not match the active Session',
      );
    }
    final result = await session.query(documentListQueryType, <String, Object?>{
      'session_id': sessionId.value,
    });
    debugPrint(
      'OrbitRelay document.list result=${result.runtimeType} '
      'session=${sessionId.value}',
    );
    if (result is! QuerySuccessResult) {
      throw StateError('Unexpected Query result for document.list');
    }
    return DocumentListResultDto.fromJson(result.payload);
  }

  Future<DocumentViewDto> getDocument(DocumentId documentId) async {
    final result = await session.query(documentGetQueryType, <String, Object?>{
      'document_id': documentId.value,
    });
    if (result is! QuerySuccessResult) {
      throw StateError('Unexpected Query result for document.get');
    }
    return DocumentViewDto.fromJson(
      result.payload,
      activeSessionId: session.sessionId,
    );
  }
}
