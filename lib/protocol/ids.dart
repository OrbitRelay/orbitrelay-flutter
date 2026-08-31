import 'package:uuid/uuid.dart';

const Uuid _uuid = Uuid();
final RegExp _canonicalUuidPattern = RegExp(
  r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$',
);

String _validatedUuid(String value, String type) {
  if (!_canonicalUuidPattern.hasMatch(value)) {
    throw FormatException('$type must be a canonical lowercase UUID', value);
  }
  return value;
}

extension type const ActorId._(String value) {
  factory ActorId.parse(String value) =>
      ActorId._(_validatedUuid(value, 'ActorId'));

  factory ActorId.generate() => ActorId._(_uuid.v4());
}

extension type const SessionId._(String value) {
  factory SessionId.parse(String value) =>
      SessionId._(_validatedUuid(value, 'SessionId'));
}

extension type const CanvasId._(String value) {
  factory CanvasId.parse(String value) =>
      CanvasId._(_validatedUuid(value, 'CanvasId'));
}

extension type const DocumentId._(String value) {
  factory DocumentId.parse(String value) =>
      DocumentId._(_validatedUuid(value, 'DocumentId'));
}

extension type const PageId._(String value) {
  factory PageId.parse(String value) =>
      PageId._(_validatedUuid(value, 'PageId'));
}

extension type const AssetId._(String value) {
  factory AssetId.parse(String value) =>
      AssetId._(_validatedUuid(value, 'AssetId'));
}

extension type const LayerId._(String value) {
  factory LayerId.parse(String value) =>
      LayerId._(_validatedUuid(value, 'LayerId'));
}

extension type const StrokeId._(String value) {
  factory StrokeId.parse(String value) =>
      StrokeId._(_validatedUuid(value, 'StrokeId'));

  factory StrokeId.generate() => StrokeId._(_uuid.v4());
}

extension type const ActionId._(String value) {
  factory ActionId.parse(String value) =>
      ActionId._(_validatedUuid(value, 'ActionId'));

  factory ActionId.generate() => ActionId._(_uuid.v4());
}

extension type const EventId._(String value) {
  factory EventId.parse(String value) =>
      EventId._(_validatedUuid(value, 'EventId'));
}

extension type const MessageId._(String value) {
  factory MessageId.parse(String value) =>
      MessageId._(_validatedUuid(value, 'MessageId'));

  factory MessageId.generate() => MessageId._(_uuid.v4());
}
