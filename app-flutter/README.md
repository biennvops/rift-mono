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
- Android 10 (API 29) or later: isolate transport to `daemon-dart`

macOS notes:

- send-file picking uses the shared Flutter `file_picker` flow with
  multi-select enabled
- the app can accept files via `Open With Rift` / document-open on macOS and
  route them into the send queue / History -> Send screen
- a dedicated macOS share extension target (`RiftShareExtension`) is wired
  into `Runner.xcodeproj`, uses an App Group handoff via
  `SharedTransferInbox`, and wakes the host app through the `rift://` URL
  scheme; both `Open With` and the share extension route items into the
  send queue

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

Install the Linux app, desktop entry, and login autostart for the current user:

```bash
linux/tools/build_linux_app.sh
linux/tools/install_user_app.sh
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
