# Rift Mobile Daemon (Dart)

`daemon-dart` is the shared mobile daemon implementation for Rift. It owns
identity, peer transport, trust, and the Flutter-facing JSON-RPC bridge through
an Android isolate or an iOS in-process channel.

## Scope

- Ed25519 identity and P-256 certificate handling
- fail-closed X.509 extension parsing
- peer discovery, mTLS session bootstrap, and pairing
- clipboard and operation lifecycle handling
- local JSON-RPC IPC through the platform-specific mobile bridge

Normative behavior lives in:

- `../spec/doc/protocol.md`
- `../spec/doc/ipc.md`
- `../spec/decisions/README.md`

## Structure

```text
daemon-dart/
├── bin/              # standalone/dev entrypoints
├── lib/src/crypto/   # identity, certs, PoP, parsing
├── lib/src/network/  # framing, discovery, transport, sessions
├── lib/src/pairing/  # pairing state machine
├── lib/src/clipboard/
├── lib/src/operation/
├── lib/src/storage/
└── test/             # unit and integration-style tests
```

## Development

Run commands from `daemon-dart/`.

```bash
flutter pub get
dart analyze
dart test
```

The standalone runner at `bin/daemon.dart` is for local IPC smoke tests and
development workflows. Android production hosting uses the foreground-service
plus isolate model; iOS hosts the daemon in-process through the Flutter app.

## Security Notes

- The custom X.509 parser is a high-risk component and must fail closed.
- Dart currently uses the spec-approved Tier 3 `app-nonce` channel binding
  path because `dart:io` does not expose stronger TLS exporter material.

## Related Docs

- `CHANGELOG.md`
- `../spec/vectors/README.md`
- `../tests-conformance/README.md`
- `../tests-interop/README.md`
