import '../protocol/ids.dart';
import '../protocol/query.dart';
import '../session/orbitrelay_session.dart';

const String assetAccessResolveQueryType = 'asset.access.resolve';

sealed class AssetAuthorizationDto {
  const AssetAuthorizationDto();
}

final class BearerAuthorizationDto extends AssetAuthorizationDto {
  const BearerAuthorizationDto._(this._token);

  final String _token;

  String get token => _token;

  @override
  String toString() => 'BearerAuthorizationDto(<redacted>)';
}

final class AssetAccessDescriptorDto {
  const AssetAccessDescriptorDto({
    required this.assetId,
    required this.deliveryKind,
    required this.url,
    required this.authorization,
    required this.expiresAt,
    required this.supportsRange,
  });

  final AssetId assetId;
  final String deliveryKind;
  final Uri url;
  final AssetAuthorizationDto authorization;
  final DateTime expiresAt;
  final bool supportsRange;

  static final RegExp _rfc3339 = RegExp(
    r'^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+-]\d{2}:\d{2})$',
  );
  static final RegExp _rustTimestamp = RegExp(
    r'^(\d{4}-\d{2}-\d{2}) (\d{2}:\d{2}:\d{2}\.\d+) ([+-]\d{2}:\d{2}):00$',
  );

  bool get isExpired => !expiresAt.isAfter(DateTime.now().toUtc());

  factory AssetAccessDescriptorDto.fromJson(Map<String, Object?> value) {
    _exact(value, const {
      'asset_id',
      'delivery_kind',
      'url',
      'authorization',
      'expires_at',
      'supports_range',
    });
    final deliveryKind = _string(value, 'delivery_kind');
    if (deliveryKind != 'http') {
      throw FormatException('Unsupported asset delivery kind', deliveryKind);
    }
    final url = Uri.tryParse(_string(value, 'url'));
    if (url == null || !url.hasScheme || !url.hasAuthority) {
      throw FormatException('Asset URL is invalid');
    }
    final auth = _object(_required(value, 'authorization'), 'authorization');
    _exact(auth, const {'type', 'token'});
    if (_string(auth, 'type') != 'bearer') {
      throw FormatException('Unsupported asset authorization type');
    }
    final token = _string(auth, 'token');
    if (token.isEmpty) {
      throw FormatException('Asset bearer token is empty');
    }
    final expiresText = _string(value, 'expires_at');
    final rustTimestamp = _rustTimestamp.firstMatch(expiresText);
    final normalizedExpires = _rfc3339.hasMatch(expiresText)
        ? expiresText
        : rustTimestamp == null
        ? null
        : '${rustTimestamp.group(1)}T${rustTimestamp.group(2)}'
              '${rustTimestamp.group(3)}';
    final expires = normalizedExpires == null
        ? null
        : DateTime.tryParse(normalizedExpires)?.toUtc();
    if (expires == null) {
      throw FormatException('Asset expiry is not RFC3339');
    }
    return AssetAccessDescriptorDto(
      assetId: AssetId.parse(_string(value, 'asset_id')),
      deliveryKind: deliveryKind,
      url: url,
      authorization: BearerAuthorizationDto._(token),
      expiresAt: expires,
      supportsRange: _bool(value, 'supports_range'),
    );
  }

  @override
  String toString() =>
      'AssetAccessDescriptorDto(assetId: ${assetId.value}, deliveryKind: $deliveryKind, expiresAt: $expiresAt)';
}

final class AssetAccessClient {
  const AssetAccessClient({required this.session});

  final OrbitRelayQuerySession session;

  Future<AssetAccessDescriptorDto> resolveForDocument(
    DocumentId documentId,
  ) async {
    final result = await session.query(
      assetAccessResolveQueryType,
      <String, Object?>{'document_id': documentId.value},
    );
    if (result is! QuerySuccessResult) {
      throw StateError('Unexpected Query result for asset.access.resolve');
    }
    return AssetAccessDescriptorDto.fromJson(result.payload);
  }
}

void _exact(Map<String, Object?> value, Set<String> fields) {
  if (value.length != fields.length || !value.keys.every(fields.contains)) {
    throw FormatException(
      'Asset descriptor contains unknown or missing fields',
    );
  }
}

Object? _required(Map<String, Object?> value, String field) {
  if (!value.containsKey(field)) {
    throw FormatException('Missing asset descriptor field', field);
  }
  return value[field];
}

Map<String, Object?> _object(Object? value, String context) {
  if (value is! Map) {
    throw FormatException('$context must be an object');
  }
  return value.cast<String, Object?>();
}

String _string(Map<String, Object?> value, String field) {
  final result = _required(value, field);
  if (result is! String) {
    throw FormatException('$field must be a string');
  }
  return result;
}

bool _bool(Map<String, Object?> value, String field) {
  final result = _required(value, field);
  if (result is! bool) {
    throw FormatException('$field must be a boolean');
  }
  return result;
}
