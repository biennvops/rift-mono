# Rift Flutter App

`app-flutter` is the shared Flutter client for Rift. It consumes the daemon IPC
contract over transport-specific local channels while keeping one UI/client
surface across platforms.

## Scope

- pairing and trusted-device management UI
- security event log and settings views
- clipboard and operation workflow UI
- transport-agnostic JSON-RPC client for desktop, Android, and iOS

Normative behavior lives in:

- `../spec/doc/ipc.md`
- `../spec/doc/protocol.md`

## Platforms

- Windows: named-pipe transport to `daemon-cs`
- macOS and Linux: Unix-domain-socket transport to `daemon-cs`
- Android 10 (API 29) or later: isolate transport to `daemon-dart`
- iOS: in-process transport to `daemon-dart`

Windows notes:

- file arguments from Explorer are routed into the durable send queue; when
  Rift is already open, a short-lived second process forwards the selection to
  the running window
- after `flutter build windows`, register the current release executable as a
  per-user **Send with Rift** Explorer action (no administrator access needed):

  ```powershell
  powershell -ExecutionPolicy Bypass -File windows\tools\register_send_with_rift.ps1
  ```

  Remove the action with:

  ```powershell
  powershell -ExecutionPolicy Bypass -File windows\tools\unregister_send_with_rift.ps1
  ```

  Pass `-ExecutablePath C:\path\to\Rift.exe` to the registration script
  when registering an installed build instead of the default local release
  build. On Windows 11, the action may appear under **Show more options** in
  Explorer's context menu.

iOS sideload build:

```bash
RIFT_DEV_BACKGROUND_LOCATION=1 \
RIFT_DEV_REMOTE_MEDIA_SESSION=1 \
RIFT_DEV_PRIVATE_DEVICE_NAME=1 \
tool/build_unsigned_ios_ipa.sh
```

The script creates `build/ios/ipa/Rift-unsigned-release.ipa` for signing and
installation with Sideloadly. `RIFT_DEV_PRIVATE_DEVICE_NAME=1` compiles the
unsupported MobileGestalt lookup; normal builds exclude that code.

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

Build and install the Linux release bundle, desktop entry, and login autostart
for the current user:

```bash
linux/tools/build_linux_app.sh
linux/tools/install_user_app.sh
```

The Linux build pins the SQLite amalgamation to an official mirror with a
checksum because the upstream plugin download can intermittently return
truncated archives. Validate the published daemon and app installers together
with:

```bash
linux/tools/smoke_test_installed_stack.sh
```

The Linux desktop entry forwards supported files opened with Rift to the
existing process and adds them to the durable send queue.

Desktop targets expect a compatible daemon endpoint to be available. Android
starts the Dart daemon through the isolate bridge; iOS hosts it in-process.

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
