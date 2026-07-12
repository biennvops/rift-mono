# Rift Android Daemon (Dart)

`daemon-dart` is the Android daemon implementation for Rift. It owns device
identity, peer transport, trust, and the Flutter-facing isolate/JSON-RPC
bridge on Android.

## Scope

- Ed25519 identity and P-256 certificate handling
- fail-closed X.509 extension parsing
- peer discovery, mTLS session bootstrap, and pairing
- clipboard and operation lifecycle handling
- local JSON-RPC IPC through the Android isolate bridge

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
development workflows. Android production hosting remains the foreground-service
plus isolate model used by the Flutter app.

## Security Notes

- The custom X.509 parser is a high-risk component and must fail closed.
- Dart currently uses the spec-approved Tier 3 `app-nonce` channel binding
  path because `dart:io` does not expose stronger TLS exporter material.

## Related Docs

- `CHANGELOG.md`
- `../spec/vectors/README.md`
- `../tests-conformance/README.md`
- `../tests-interop/README.md`
