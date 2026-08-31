# OrbitRelay Flutter

OrbitRelay Flutter is the official pure Dart/Flutter client for the OrbitRelay
protocol. It contains no Rust FFI and currently provides Windows and Web
targets.

## Capabilities

- Protocol 0.1 realtime Action/Event sessions
- Protocol 0.2 correlated Query/QueryResponse sessions
- Standalone Canvas collaboration
- Document discovery and page selection
- Bearer-authorized Asset download with length and SHA-256 verification
- PDFium rendering from verified bytes
- Canvas history replay with realtime handoff and EventId deduplication
- Optimistic local strokes reconciled against authoritative Events

## Verification

```bash
dart format --output=none --set-exit-if-changed lib test tool
flutter analyze
flutter test
flutter build web --no-web-resources-cdn
```

The wire contract is maintained in
[`orbitrelay-spec`](https://github.com/orbitrelay/orbitrelay-spec). Server-side
implementations are maintained independently in `orbitrelay-kernel` and
`orbitrelay-server`.

## License

Licensed under the Apache License, Version 2.0. See [LICENSE](LICENSE).
