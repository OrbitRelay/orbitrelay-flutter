# Rust wire fixtures

These JSON files are the compatibility boundary between the Flutter client and
the current Rust protocol. They were produced by a temporary Rust test harness
using the concrete types in `orbitrelay-transport`, `orbitrelay-protocol`, and
`orbitrelay-canvas`:

- client-to-server `InboundMessage` values were serialized with Serde and
  accepted by `JsonCodec::decode_inbound`;
- server-to-client `OutboundMessage` values were encoded by
  `JsonCodec::encode_outbound`;
- Canvas payloads were created from the Rust Canvas payload types rather than
  hand-authored JSON maps.

The temporary harness is intentionally not part of the Server production
source. When the Rust wire protocol changes, regenerate this complete fixture
set from Rust before updating Dart DTOs. Flutter tests must compare fixture
JSON structurally; Dart-to-Dart round trips are not sufficient evidence of
wire compatibility.
