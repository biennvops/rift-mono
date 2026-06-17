# Rift Flutter App

This directory contains the Flutter app shell and IPC client for the Rift project. It provides the user interface for pairing, managing trusted devices, viewing security logs, and adjusting settings.

## Installation and Running

Requires the Flutter SDK installed.

```bash
flutter pub get
flutter run -d windows   # on Windows
flutter run -d linux     # on Linux
flutter run -d <device>  # on Android/emulator
```

**Expected Runtime Behavior (Week 3 State):**
- **UI:** The application successfully boots and displays all core navigation screens (Pairing, Trusted Devices, Event Log, Settings). The UI components are decoupled from the transport layer.
- **Linux/macOS (`UnixSocketTransport`):** You will see background warnings in the console (e.g., `SocketException: Connection failed`) as the IPC client actively attempts to connect to `/tmp/rift-daemon.sock`. This is **expected** because the standalone native daemon is not running. The JSON-RPC client will automatically manage this via its exponential backoff reconnection loop.
- **Android/Windows (`IsolateTransport` / `NamedPipeTransport`):** The transport layers currently throw an `UnimplementedError` as a strict fail-fast mechanism pending native daemon completion. When accessing screens that call IPC (like `SettingsScreen`), the app gracefully catches this error and displays a safe fallback message (`Feature not available on this platform`) instead of crashing.

## Testing

```bash
flutter test
```

*Latest test result (2026-06-14): `00:03 +19: All tests passed!`*

The core tests (19 total) cover:
- UI rendering and stub checks (`widget_test.dart`, `pairing_screen_test.dart`, `trusted_devices_screen_test.dart`, `event_log_screen_test.dart`).
- IPC error handling in UI (`settings_screen_test.dart`).
- Decoupled UI injection via Provider (`app_shell_test.dart`).
- JSON-RPC connection lifecycle, exponential backoff, and timeouts using `fake_async` (`ipc_test.dart`).
- Strict NDJSON boundary parsing and OOM byte guard (`bounded_line_splitter_test.dart`).

## Directory Structure

This project enforces a strict separation between presentation UI and core domain logic.

```text
app-flutter/
├── lib/
│   ├── constants.dart                    # Centralized UI strings
│   ├── main.dart                         # App entry point, DI Provider setup
│   ├── screens/                          # Presentation Layer
│   │   ├── event_log_screen.dart
│   │   ├── pairing_screen.dart
│   │   ├── settings_screen.dart          # [WEEK 3] Debug & Settings UI
│   │   └── trusted_devices_screen.dart
│   └── src/                              # Core Domain Logic
│       └── ipc/                          # IPC Communication Layer
│           ├── bounded_line_splitter.dart # Security: OOM guard (32MiB limit)
│           ├── ipc_transport.dart         # Interface: Platform-agnostic transport
│           ├── isolate_transport.dart     # Android stub
│           ├── json_rpc_client.dart       # Core RPC logic (reconnection, requests)
│           ├── named_pipe_transport.dart  # Windows stub
│           ├── transport_factory.dart     # DI: Resolves transport per OS
│           └── unix_socket_transport.dart # Linux/macOS Socket implementation
├── test/
│   ├── app_shell_test.dart
│   ├── bounded_line_splitter_test.dart
│   ├── event_log_screen_test.dart
│   ├── ipc_test.dart
│   ├── pairing_screen_test.dart
│   ├── settings_screen_test.dart         # [WEEK 3] Success & UnimplementedError tests
│   ├── trusted_devices_screen_test.dart
│   └── widget_test.dart
├── android/, ios/, windows/, macos/, linux/  # Flutter generated directories
├── pubspec.yaml
└── analysis_options.yaml
```

## Development Progress

### Week 1: App Shell & CI
- Created app shell and stub screens.
- Centralized UI strings into `constants.dart`.
- Established GitHub Actions CI workflow for linting and testing.
- Configured `.gitignore` to prevent tracking ephemeral platform artifacts.

### Week 2: IPC Spike & Transport Layer
- Implemented `IpcTransport` interface and `TransportFactory` for cross-platform support.
- Built `BoundedLineSplitter` with exact UTF-8 Unicode decoding (`runes.fold`) to enforce a strict 32 MiB OOM guard.
- Developed `JsonRpcRiftClient` supporting reconnection, exponential backoff, and async locks.
- Integrated `fake_async` to deterministically test the IPC timer logic.

### Week 3: Settings UI & Parser Security
- **Flutter Settings Screen:** Implemented a new UI to fetch and display local daemon info (`Device ID`, `Fingerprint`, `Protocol Version`) via IPC. Safely handles stubbed environments.
- **Parser Robustness:** Added 9 deterministic fail-closed security test classes to the Dart X.509 ASN.1 parser (`../daemon-dart/test/decoder_test.dart`) to reject malformed/oversized DER inputs.
- **Test Suite Fixes:** Resolved syntax errors in older screen tests and achieved a 100% green test suite.

### Week 4: Device Discovery & Network Drop Tests
- **Trusted / Discovered Devices UI (`trusted_devices_screen.dart`):**
  - Completely revamped into a reactive Material 3 interface that dynamically displays separate lists for `Trusted` (authenticated) and `Discovered` (unauthenticated/mDNS) peers, strictly adhering to the Trust State Machine (`protocol.md` Section 8).
  - Implemented real-time online/offline presence indicators via UI dots based on daemon events.
  - Added pull-to-refresh (`RefreshIndicator`) and floating action buttons for starting/stopping discovery.
- **IPC Event Streams (`json_rpc_client.dart`):**
  - Extended the JSON-RPC client to support unsolicited server-to-client notifications (`rift.onPeerDiscovered`, `rift.onPeerLost`, `rift.onTrustChanged`).
  - Upgraded architecture to use `json_rpc_2.Peer` to support bidirectional communication, ensuring the UI accurately reflects daemon state changes without polling.
  - Implemented rigorous stream cleanup and provider injection methods to prevent memory leaks in the UI and test suites.
- **Discovery Flow & Capability Negotiation Tests (`discovery_integration_test.dart`):**
  - Created end-to-end integration tests in `daemon-dart` verifying the full TLS and capability handshake sequence (`session.hello` -> `session.accept` -> `capability.advertise` -> `capability.selected`) across two mock daemon environments.
  - Confirmed the daemon strictly adheres to Section 6 and Section 9 of the Rift protocol during connection establishment.
- **Simulated Network Drop Test:**
  - Emulated a harsh network failure by explicitly terminating the simulated `Transport` channel.
  - Validated that `SessionManager` detects the disconnection, safely unregisters the session, and throws `SessionException` on subsequent operations, preventing stale connections from persisting.

## Technical Debt & Known Limitations

While critical crashes and UI bugs have been resolved, the following areas require future attention:

1. **[Security] Missing Parser Fuzzing:** The custom Dart ASN.1 parser currently relies on 9 static test vectors. A proper fuzzing framework (e.g., AFL++) is required to comprehensively prevent out-of-bounds reads or infinite loops on adversarial DER structures.
2. **[Engineering] `nsd` Dependency Downgrade:** The `nsd` package was downgraded to `^4.0.0` to bypass Flutter ecosystem version solving conflicts. This must be tracked and upgraded once compatible to ensure stability on newer OS versions (e.g., iOS 14+ local network privacy).
3. **[UX] Reactive State for Settings Screen:** The `SettingsScreen` currently uses a `FutureBuilder` to fetch device info once upon initialization. It should be refactored to use `Stream` or `ChangeNotifier` so the UI automatically updates if the daemon restarts or the device fingerprint changes.
4. **[Engineering] Incomplete Platform Transports:** Android (`IsolateTransport`) and Windows (`NamedPipeTransport`) remain stubs. Integration will require coordination with the native daemon implementations.
