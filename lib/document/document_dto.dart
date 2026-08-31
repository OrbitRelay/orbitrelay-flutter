import '../canvas/canvas_protocol.dart';
import '../protocol/error.dart';
import '../protocol/ids.dart';

final class DocumentSummaryDto {
  const DocumentSummaryDto({
    required this.documentId,
    required this.title,
    required this.documentType,
    required this.pageCount,
    required this.sourceAssetId,
  });

  final DocumentId documentId;
  final String title;
  final String documentType;
  final int pageCount;
  final AssetId sourceAssetId;

  factory DocumentSummaryDto.fromJson(Map<String, Object?> value) {
    _exact(value, const {
      'document_id',
      'title',
      'document_type',
      'page_count',
      'source_asset_id',
    });
    final pageCount = _int(value, 'page_count');
    if (pageCount < 0) {
      throw _invalid('page_count must be non-negative');
    }
    return DocumentSummaryDto(
      documentId: DocumentId.parse(_string(value, 'document_id')),
      title: _string(value, 'title'),
      documentType: _string(value, 'document_type'),
      pageCount: pageCount,
      sourceAssetId: AssetId.parse(_string(value, 'source_asset_id')),
    );
  }
}

final class DocumentListResultDto {
  const DocumentListResultDto(this.documents);

  final List<DocumentSummaryDto> documents;

  factory DocumentListResultDto.fromJson(Map<String, Object?> value) {
    _exact(value, const {'documents'});
    return DocumentListResultDto(
      _list(value, 'documents')
          .map(
            (item) =>
                DocumentSummaryDto.fromJson(_object(item, 'document summary')),
          )
          .toList(growable: false),
    );
  }
}

final class DocumentDto {
  const DocumentDto({
    required this.documentId,
    required this.sessionId,
    required this.documentType,
    required this.sourceAssetId,
    required this.title,
    required this.pages,
  });

  final DocumentId documentId;
  final SessionId sessionId;
  final String documentType;
  final AssetId sourceAssetId;
  final String title;
  final List<DocumentPageDto> pages;

  factory DocumentDto.fromJson(Map<String, Object?> value) {
    _exact(value, const {
      'document_id',
      'session_id',
      'document_type',
      'source_asset_id',
      'title',
      'pages',
    });
    return DocumentDto(
      documentId: DocumentId.parse(_string(value, 'document_id')),
      sessionId: SessionId.parse(_string(value, 'session_id')),
      documentType: _string(value, 'document_type'),
      sourceAssetId: AssetId.parse(_string(value, 'source_asset_id')),
      title: _string(value, 'title'),
      pages: _list(value, 'pages')
          .map(
            (item) => DocumentPageDto.fromJson(_object(item, 'document page')),
          )
          .toList(growable: false),
    );
  }
}

final class DocumentPageDto {
  const DocumentPageDto({
    required this.pageId,
    required this.pageIndex,
    required this.displayGeometry,
    required this.overlayCanvasId,
  });

  final PageId pageId;
  final int pageIndex;
  final PageDisplayGeometryDto displayGeometry;
  final CanvasId overlayCanvasId;

  factory DocumentPageDto.fromJson(Map<String, Object?> value) {
    _exact(value, const {
      'page_id',
      'page_index',
      'display_geometry',
      'overlay_canvas_id',
    });
    final index = _int(value, 'page_index');
    if (index < 0) {
      throw _invalid('page_index must be non-negative');
    }
    return DocumentPageDto(
      pageId: PageId.parse(_string(value, 'page_id')),
      pageIndex: index,
      displayGeometry: PageDisplayGeometryDto.fromJson(
        _object(_required(value, 'display_geometry'), 'display_geometry'),
      ),
      overlayCanvasId: CanvasId.parse(_string(value, 'overlay_canvas_id')),
    );
  }
}

final class PageDisplayGeometryDto {
  const PageDisplayGeometryDto({
    required this.width,
    required this.height,
    required this.rotation,
  });

  final double width;
  final double height;
  final int rotation;

  factory PageDisplayGeometryDto.fromJson(Map<String, Object?> value) {
    _exact(value, const {'width', 'height', 'rotation'});
    final width = _number(value, 'width');
    final height = _number(value, 'height');
    final rotation = _int(value, 'rotation');
    if (width <= 0 ||
        height <= 0 ||
        !const <int>{0, 90, 180, 270}.contains(rotation)) {
      throw _invalid('Page display geometry is invalid');
    }
    return PageDisplayGeometryDto(
      width: width,
      height: height,
      rotation: rotation,
    );
  }
}

final class SourceAssetDto {
  const SourceAssetDto({
    required this.assetId,
    required this.mediaType,
    required this.byteLength,
    required this.contentHash,
    required this.originalFilename,
  });

  final AssetId assetId;
  final String mediaType;
  final int byteLength;
  final String contentHash;
  final String? originalFilename;

  factory SourceAssetDto.fromJson(Map<String, Object?> value) {
    _exact(value, const {
      'asset_id',
      'media_type',
      'byte_length',
      'content_hash',
      'original_filename',
    });
    final length = _int(value, 'byte_length');
    if (length < 0) {
      throw _invalid('byte_length must be non-negative');
    }
    final filename = _required(value, 'original_filename');
    if (filename != null && filename is! String) {
      throw _invalid('original_filename must be string or null');
    }
    return SourceAssetDto(
      assetId: AssetId.parse(_string(value, 'asset_id')),
      mediaType: _string(value, 'media_type'),
      byteLength: length,
      contentHash: _string(value, 'content_hash'),
      originalFilename: filename as String?,
    );
  }
}

final class CanvasSpaceDto {
  const CanvasSpaceDto({required this.width, required this.height});

  final double width;
  final double height;

  CanvasSpace toCanvasSpace() => CanvasSpace(width, height);

  factory CanvasSpaceDto.fromJson(Map<String, Object?> value) {
    _exact(value, const {'width', 'height'});
    final width = _number(value, 'width');
    final height = _number(value, 'height');
    if (width <= 0 || height <= 0) {
      throw _invalid('Canvas space must be positive');
    }
    return CanvasSpaceDto(width: width, height: height);
  }
}

final class CanvasDto {
  const CanvasDto({
    required this.canvasId,
    required this.sessionId,
    required this.space,
    required this.layerIds,
    required this.defaultLayerId,
  });

  final CanvasId canvasId;
  final SessionId sessionId;
  final CanvasSpaceDto space;
  final List<LayerId> layerIds;
  final LayerId defaultLayerId;

  factory CanvasDto.fromJson(Map<String, Object?> value) {
    _exact(value, const {
      'canvas_id',
      'session_id',
      'space',
      'layer_ids',
      'default_layer_id',
    });
    final layers = _list(value, 'layer_ids')
        .map((item) => LayerId.parse(_typedString(item, 'layer id')))
        .toList(growable: false);
    final defaultLayer = LayerId.parse(_string(value, 'default_layer_id'));
    if (!layers.contains(defaultLayer)) {
      throw _invalid('default_layer_id is not in layer_ids');
    }
    return CanvasDto(
      canvasId: CanvasId.parse(_string(value, 'canvas_id')),
      sessionId: SessionId.parse(_string(value, 'session_id')),
      space: CanvasSpaceDto.fromJson(
        _object(_required(value, 'space'), 'space'),
      ),
      layerIds: layers,
      defaultLayerId: defaultLayer,
    );
  }
}

final class PageCanvasDto {
  const PageCanvasDto({required this.pageId, required this.canvas});

  final PageId pageId;
  final CanvasDto canvas;

  factory PageCanvasDto.fromJson(Map<String, Object?> value) {
    _exact(value, const {'page_id', 'canvas'});
    return PageCanvasDto(
      pageId: PageId.parse(_string(value, 'page_id')),
      canvas: CanvasDto.fromJson(_object(_required(value, 'canvas'), 'canvas')),
    );
  }
}

final class DocumentViewDto {
  const DocumentViewDto({
    required this.document,
    required this.sourceAsset,
    required this.pageCanvases,
  });

  final DocumentDto document;
  final SourceAssetDto sourceAsset;
  final List<PageCanvasDto> pageCanvases;

  factory DocumentViewDto.fromJson(
    Map<String, Object?> value, {
    SessionId? activeSessionId,
  }) {
    _exact(value, const {'document', 'source_asset', 'page_canvases'});
    final document = DocumentDto.fromJson(
      _object(_required(value, 'document'), 'document'),
    );
    final sourceAsset = SourceAssetDto.fromJson(
      _object(_required(value, 'source_asset'), 'source_asset'),
    );
    final pageCanvases = _list(value, 'page_canvases')
        .map((item) => PageCanvasDto.fromJson(_object(item, 'page canvas')))
        .toList(growable: false);
    if (activeSessionId != null && document.sessionId != activeSessionId) {
      throw _invalid('Document belongs to another Session');
    }
    if (document.sourceAssetId != sourceAsset.assetId) {
      throw _invalid('Document source Asset does not match source_asset');
    }
    final byPage = <PageId, DocumentPageDto>{
      for (final page in document.pages) page.pageId: page,
    };
    final seenPages = <PageId>{};
    for (final mapping in pageCanvases) {
      final page = byPage[mapping.pageId];
      if (page == null || !seenPages.add(mapping.pageId)) {
        throw _invalid('page_canvases does not match Document pages');
      }
      final canvas = mapping.canvas;
      if (canvas.sessionId != document.sessionId ||
          canvas.canvasId != page.overlayCanvasId) {
        throw _invalid('Page Canvas identity does not match Document');
      }
      if (canvas.space.width != page.displayGeometry.width ||
          canvas.space.height != page.displayGeometry.height) {
        throw _invalid('CanvasSpace does not match page display geometry');
      }
    }
    if (seenPages.length != document.pages.length) {
      throw _invalid('Document page canvas mapping is incomplete');
    }
    return DocumentViewDto(
      document: document,
      sourceAsset: sourceAsset,
      pageCanvases: pageCanvases,
    );
  }
}

ClientProtocolError _invalid(String message) =>
    ClientProtocolError(ClientProtocolErrorCode.invalidEnvelope, message);

void _exact(Map<String, Object?> value, Set<String> fields) {
  if (value.length != fields.length || !value.keys.every(fields.contains)) {
    throw _invalid('DTO fields do not match the expected schema');
  }
}

Object? _required(Map<String, Object?> value, String field) {
  if (!value.containsKey(field)) {
    throw _invalid('Missing field "$field"');
  }
  return value[field];
}

Map<String, Object?> _object(Object? value, String context) {
  if (value is! Map) {
    throw _invalid('$context must be an object');
  }
  return value.cast<String, Object?>();
}

List<Object?> _list(Map<String, Object?> value, String field) {
  final result = _required(value, field);
  if (result is! List) {
    throw _invalid('$field must be an array');
  }
  return result.cast<Object?>();
}

String _typedString(Object? value, String field) {
  if (value is! String) {
    throw _invalid('$field must be a string');
  }
  return value;
}

String _string(Map<String, Object?> value, String field) =>
    _typedString(_required(value, field), field);

int _int(Map<String, Object?> value, String field) {
  final valueAtField = _required(value, field);
  if (valueAtField is! int) {
    throw _invalid('$field must be an integer');
  }
  return valueAtField;
}

double _number(Map<String, Object?> value, String field) {
  final valueAtField = _required(value, field);
  if (valueAtField is! num || !valueAtField.isFinite) {
    throw _invalid('$field must be a finite number');
  }
  return valueAtField.toDouble();
}
