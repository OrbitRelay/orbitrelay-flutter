import 'package:flutter/foundation.dart';

import '../protocol/ids.dart';
import 'document_dto.dart';

/// Ephemeral Document-mode selection state. It intentionally has no disk
/// persistence and stores no Asset bearer credentials.
final class DocumentSessionState extends ChangeNotifier {
  List<DocumentSummaryDto> get documents =>
      List<DocumentSummaryDto>.unmodifiable(_documents);
  DocumentSummaryDto? get selectedDocument => _selectedDocument;
  DocumentViewDto? get documentView => _documentView;
  DocumentPageDto? get selectedPage => _selectedPage;

  final List<DocumentSummaryDto> _documents = <DocumentSummaryDto>[];
  DocumentSummaryDto? _selectedDocument;
  DocumentViewDto? _documentView;
  DocumentPageDto? _selectedPage;

  void setDocuments(Iterable<DocumentSummaryDto> documents) {
    _documents
      ..clear()
      ..addAll(documents);
    notifyListeners();
  }

  void selectDocument(DocumentSummaryDto? document) {
    _selectedDocument = document;
    _documentView = null;
    _selectedPage = null;
    notifyListeners();
  }

  void setDocumentView(DocumentViewDto view) {
    _documentView = view;
    _selectedDocument = _documents
        .where((item) => item.documentId == view.document.documentId)
        .firstOrNull;
    _selectedPage = null;
    notifyListeners();
  }

  void selectPage(PageId pageId) {
    final view = _documentView;
    if (view == null) {
      throw StateError('Document view is not loaded');
    }
    _selectedPage = view.document.pages
        .where((page) => page.pageId == pageId)
        .firstOrNull;
    if (_selectedPage == null) {
      throw StateError('Page does not belong to the selected Document');
    }
    notifyListeners();
  }

  void clear() {
    _documents.clear();
    _selectedDocument = null;
    _documentView = null;
    _selectedPage = null;
    notifyListeners();
  }
}
