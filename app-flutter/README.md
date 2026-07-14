# Rift Flutter App

`app-flutter` is the shared Flutter client for Rift. It consumes the daemon IPC
contract over transport-specific local channels while keeping one UI/client
surface across platforms.

## Scope

- pairing and trusted-device management UI
- security event log and settings views
- clipboard and operation workflow UI
- transport-agnostic JSON-RPC client for desktop and Android

Normative behavior lives in:

- `../spec/doc/ipc.md`
- `../spec/doc/protocol.md`

## Platforms

- Windows: named-pipe transport to `daemon-cs`
- macOS and Linux: Unix-domain-socket transport to `daemon-cs`
- Android: isolate transport to `daemon-dart`

The Flutter layer should not duplicate authoritative trust or identity state.
That data lives in the daemon.

## Development

```bash
flutter pub get
flutter analyze
flutter test
```

Run locally:

```bash
flutter run -d windows
flutter run -d macos
flutter run -d linux
flutter run -d <android-device>
```

Desktop targets expect a compatible daemon endpoint to be available. Android
starts the Dart daemon through the isolate bridge.

## Structure

```text
app-flutter/
├── lib/screens/    # user-facing views
├── lib/src/ipc/    # transport and JSON-RPC client
├── lib/src/clipboard/
├── test/           # widget and IPC tests
└── DESIGN.md       # design system guidance
```

## Related Docs

- `DESIGN.md`
- `../tests-interop/README.md`
- `../docs/macos-permissions.md`
