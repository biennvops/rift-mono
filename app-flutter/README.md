# Rift Flutter App

This directory contains the Flutter app shell and IPC client for the Rift
project. It provides the user interface for pairing, managing trusted devices,
viewing security logs, handling clipboard continuity flows, and adjusting
settings across Android and the active desktop targets in this repository.

## Installation and Running

Requires the Flutter SDK installed.

```bash
flutter pub get
flutter run -d windows   # on Windows
flutter run -d macos     # on macOS
flutter run -d linux     # on Linux
flutter run -d <device>  # on Android/emulator
```

**Expected Runtime Behavior (Current State):**
- **UI:** The application successfully boots and displays the current core navigation surfaces (Pairing, Trusted Devices, Event Log, Settings, Security Dashboard, Clipboard Transfer, and Operations), along with the active clipboard shell/debug flow. The UI components are decoupled from the transport layer.
- **Linux/macOS (`UnixSocketTransport`):** The app connects to a Unix domain socket and expects a running Rift daemon endpoint. If the daemon is absent, the JSON-RPC client logs reconnect attempts with exponential backoff.
- **Windows (`NamedPipeTransport`):** The app connects to `\\.\pipe\rift-daemon-v0.1` and speaks StreamJsonRpc-compatible `Content-Length` framing to `daemon-cs`.
- **Android (`AndroidDaemonIsolateTransport`):** The app spawns the Dart daemon in a background isolate and waits for `rift.daemonReady` before issuing JSON-RPC requests. In debug builds, discovery is intentionally disabled in the isolate to avoid plugin assertions.

IPC framing and size limits are transport-specific; see `spec/doc/ipc.md` for the IPC contract and framing-limit guidance.

## Testing

```bash
flutter test
```

*Latest focused IPC verification (2026-07-08): `flutter test test/ipc_test.dart` passed locally.*
*Latest broader local verification for the current app shell, clipboard, and network stabilization work: `flutter analyze` and `flutter test` passed locally.*

The core tests cover:
- UI rendering and screen-state checks (`pairing_screen_test.dart`, `trusted_devices_screen_test.dart`, `event_log_screen_test.dart`).
- IPC error handling in UI (`settings_screen_test.dart`).
- Decoupled UI injection via Provider (`app_shell_test.dart`).
- JSON-RPC connection lifecycle, exponential backoff, and timeouts using `fake_async` (`ipc_test.dart`).
- StreamJsonRpc framing coverage for partial headers, split chunks, malformed headers, and outgoing message serialization (`streamjsonrpc_framer_test.dart`).
- Pairing flow widget coverage for incoming requests, auto-start fingerprints, approve/reject actions, expiry countdown, and trust-management confirmation behavior.

## Directory Structure

This project enforces a strict separation between presentation UI and core domain logic.

```text
app-flutter/
├── lib/
│   ├── constants.dart                    # Centralized UI strings
│   ├── main.dart                         # App entry point, DI Provider setup
│   ├── screens/                          # Presentation Layer
│   │   ├── background_sync_screen.dart
│   │   ├── clipboard_debug_screen.dart   # Temporary clipboard evidence/debug panel
│   │   ├── clipboard_history_screen.dart
│   │   ├── clipboard_transfer_screen.dart
│   │   ├── device_detail_screen.dart
│   │   ├── event_log_screen.dart
│   │   ├── onboarding_screen.dart
│   │   ├── operations_screen.dart
│   │   ├── pairing_screen.dart
│   │   ├── security_dashboard_screen.dart
│   │   ├── settings_screen.dart          # Settings and device-info UI
│   │   └── trusted_devices_screen.dart
│   └── src/                              # Core Domain Logic
│       ├── clipboard/
│       │   └── desktop_clipboard_manager.dart # Desktop clipboard monitor + fetch/apply logic
│       └── ipc/                          # IPC Communication Layer
│           ├── android_daemon_isolate_entrypoint.dart # Flutter-side isolate bootstrap for daemon plugins
│           ├── android_daemon_isolate_transport.dart  # Android isolate IPC transport
│           ├── android_root_discovery_bridge.dart     # Android discovery bridge / desktop snapshot sync
│           ├── ipc_transport.dart         # Interface: Platform-agnostic transport
│           ├── isolate_transport.dart     # Base isolate transport primitives
│           ├── json_rpc_client.dart       # Core RPC logic (reconnection, requests)
│           ├── named_pipe_transport.dart  # Windows named pipe transport
│           ├── streamjsonrpc_framer.dart  # StreamJsonRpc Content-Length framing
│           ├── transport_factory.dart     # DI: Resolves transport per OS
│           └── unix_socket_transport.dart # Linux/macOS Socket implementation
├── test/
│   ├── android_root_discovery_bridge_test.dart
│   ├── app_shell_test.dart
│   ├── desktop_clipboard_manager_test.dart
│   ├── event_log_screen_test.dart
│   ├── ipc_test.dart
│   ├── pairing_screen_test.dart
│   ├── settings_screen_test.dart         # Settings data, loading, and error-state tests
│   ├── streamjsonrpc_framer_test.dart
│   ├── test_utils/                       # Shared fakes/helpers for widget and IPC tests
│   └── trusted_devices_screen_test.dart
├── DESIGN.md                                 # Architecture and design decisions
├── android/, ios/, windows/, macos/, linux/  # Flutter generated directories
├── pubspec.yaml
└── analysis_options.yaml
```

## Development Progress

### Week 1: App Shell & CI
- Created app shell and initial screens.
- Centralized UI strings into `constants.dart`.
- Established GitHub Actions CI workflow for linting and testing.
- Configured `.gitignore` to prevent tracking ephemeral platform artifacts.

### Week 2: IPC Spike & Transport Layer
- Implemented `IpcTransport` interface and `TransportFactory` for cross-platform support.
- Developed `JsonRpcRiftClient` supporting reconnection, exponential backoff, and async locks.
- Integrated `fake_async` to deterministically test the IPC timer logic.
- Added StreamJsonRpc-compatible framing for Windows and Unix socket transports.

### Week 3: Settings UI & Parser Security
- **Flutter Settings Screen:** Implemented a UI to fetch and display local daemon info (`Device ID`, `Fingerprint`, `Protocol Version`) via IPC. The screen also handles unavailable-feature and generic failure states without crashing.
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
- **Discovery Automation & Session Coverage (`daemon-dart` integration tests):**
  - Added a real-network discovery integration test in `daemon-dart` that advertises and discovers `_rift._tcp` over the local UDP/mDNS stack.
  - Kept separate session-level integration coverage for session establishment and simulated reconnect cleanup.
- **Simulated Network Drop Test:**
  - Emulated a harsh network failure by explicitly terminating the simulated `Transport` channel.
  - Validated that `SessionManager` detects the disconnection, safely unregisters the session, and throws `SessionException` on subsequent operations, preventing stale connections from persisting.

### Week 5: Pairing Flow & Trust Management
- **Pairing UI (`pairing_screen.dart`):**
  - Replaced the previous placeholder screen with a stateful pairing flow that supports explicit peer selection, incoming pairing requests, fingerprint display, approve/reject actions, and request expiry countdowns.
  - Added pairing status transitions for start, incoming request, approval sent, remote approval, completion, rejection, and expiry.
- **Expanded IPC Client (`json_rpc_client.dart`):**
  - Added `rift.startPairing`, `rift.approvePairing`, `rift.rejectPairing`, `rift.revokeTrust`, and `rift.unblockPeer`.
  - Added notification streams for `rift.onPairingRequest`, `rift.onPairingComplete`, and `rift.onTrustChanged`.
- **Trusted Devices Management (`trusted_devices_screen.dart`):**
  - Connected discovered peers to the pairing screen through the `Pair` action.
  - Added confirm dialogs for revoking trust, cancelling pending pairing, and unblocking peers.
  - Improved trust-state presentation for `trusted`, `pairing_pending`, `blocked`, `revoked`, and `discovered` peers.
- **Week 5 Test Coverage:**
  - Added widget coverage for pairing request notifications, auto-start fingerprint population, approve/reject action dispatch, trust-state transitions, countdown expiry, and trust-management confirmation flows.

### Week 6: Capability Negotiation & Presence
- **Trusted Devices Management (`trusted_devices_screen.dart`):**
  - Updated the UI to display capability summaries visually using badges (chips with icons) instead of raw strings.
  - Added periodic trusted-peer refresh so presence indicators do not stay stale when no other trust/discovery event fires.
- **Interop Harness Groundwork (`tests-interop`):**
  - Scaffolded the Dart test package for cross-platform interoperability testing.
  - Added a simulated session harness for presence-update propagation and disconnect cleanup.
  - Updated the test matrix in the interop documentation to cover macOS and capability-aware failure scenarios.
- **Week 6 Test Coverage:**
  - Extended widget tests to verify capability badges and presence status are accurately displayed on the trusted devices screen.

### Week 7: Clipboard Bridge, IPC Client, & Network Stabilization
- **Android Clipboard Bridge (`android/app/src/main/...`):**
  - Added `ClipboardForegroundService` with `foregroundServiceType="dataSync"` and the required Android foreground-service permissions so clipboard observation can remain alive while the app is backgrounded.
  - Added a dedicated Android `MethodChannel` (`com.biennvops.rift/clipboard`) to forward clipboard-change events into Flutter only on Android targets.
  - Guarded the clipboard channel bootstrap with `Platform.isAndroid` so Linux and Windows builds do not touch Android-only platform channels.
- **Desktop Clipboard Manager (`lib/src/clipboard/desktop_clipboard_manager.dart`):**
  - Replaced the earlier Windows-only clipboard manager with `DesktopClipboardManager`.
  - Windows now listens on the shared desktop event channel `rift/desktop/clipboard_events`, matching the Windows runner clipboard publisher.
  - macOS and Linux currently use a Dart polling fallback for local clipboard observation until native runner event channels are implemented on those platforms.
  - The polling fallback seeds the initial clipboard snapshot without rebroadcasting it as a new offer, then emits only when clipboard text changes after startup.
  - Added status updates for clipboard send/fetch outcomes so the Flutter shell can surface short-lived user feedback.
- **Clipboard IPC Client (`json_rpc_client.dart`):**
  - Added typed client helpers for `notifyClipboardChange`, `listClipboardOffers`, and `fetchClipboardContent`.
  - Added notification streams for `rift.onClipboardOffer` and `rift.onClipboardExpired`.
  - Extended result canonicalization so clipboard payload fields (`offerId`, `contentType`, `byteSize`, `sha256`, `expiresAt`, `contentBase64`, `verified`, `broadcastTo`) stay uniform across daemon implementations.
- **Flutter App Bootstrap (`main.dart`):**
  - The app now hashes copied Android text with SHA-256, base64-encodes the content, and forwards it to the daemon over JSON-RPC via `rift.notifyClipboardChange`.
  - Desktop clipboard changes are also forwarded through the same JSON-RPC method, keeping clipboard protocol logic inside the daemon while Flutter remains a transport/UI boundary.
  - The desktop shell now binds clipboard status updates so local users see short success/failure feedback for clipboard send/fetch flows.
- **Discovery Stabilization (`android_root_discovery_bridge.dart`):**
  - Enhanced the mDNS native bridge to properly inject the Device ID (`did`) and Fingerprint (`fp`) into the TXT record, resolving 'Unknown Device' artifacts during local network scanning.
- **UI State Freshness (`trusted_devices_screen.dart`):**
  - Bound the discovered peers view to the active `_isDiscovering` toggle state, ensuring stale network artifacts are purged when a new scan initiates.
  - Implemented a proactive capability-based presence refresh loop to maintain accurate active/inactive UI badging over long-running sessions.
- **Week 7 Test Coverage:**
  - Added `desktop_clipboard_manager_test.dart` to cover:
    - startup clipboard-offer resync
    - auto-fetch for `text/plain` offers
    - echo suppression after applying fetched content
    - reconnect/resync cleanup
    - polling fallback behavior on macOS/Linux
  - Added a simulated clipboard transfer harness under `../tests-interop/test/clipboard_transfer_test.dart` for protocol-slice verification of:
    - successful fetch flow
    - hash/size integrity preservation
    - oversized and empty payload rejection
    - UTF-8 / special-character handling



### Week 8: Operation Lifecycle IPC Alignment
- **Operation IPC client (`json_rpc_client.dart`):**
  - Added client support for `rift.listOperations` and `rift.getOperation`.
  - Added notification stream handling for `rift.onOperationTransition`.
  - Preserved spec casing for operation states (`Created`, `Pending`, `Dispatched`, `Active`, `Done`, `Failed`, `Expired`) instead of lowercasing them during canonicalization.
- **IPC regression coverage (`ipc_test.dart`):**
  - Added focused coverage for operation listing and detail retrieval.
  - Locked notification handling for `rift.onOperationTransition`, including optional `failureReason` pass-through.
  - Added a Flutter-side error-path test for `rift.getOperation` not found (`-32009`) to confirm JSON-RPC errors surface correctly to the client.

## Completion Criteria

To treat the Flutter client work as fully complete, the project needs both of
the following:

1. **Code health:** `flutter analyze` and `flutter test` remain green.
2. **Interop evidence:** `tests-interop` contains recorded pairing/trust runs on
   real devices, including happy path, reject, timeout/cancel, persistence, and
   revoke behavior.

At the moment, the first condition is satisfied. The second depends on the
remaining manual interop runs.

## Technical Debt & Known Limitations

While critical crashes and UI bugs have been resolved, the following areas require future attention:

1. **[Security] Missing Parser Fuzzing:** The custom Dart ASN.1 parser currently relies on 9 static test vectors. A proper fuzzing framework (e.g., AFL++) is required to comprehensively prevent out-of-bounds reads or infinite loops on adversarial DER structures.
2. **[Engineering] `nsd` Dependency Constraint:** The daemon side still depends on `nsd` for production discovery, while pure-Dart mDNS testing uses `mdns_dart`. This split should be revisited if the team later wants one shared discovery stack or stronger cross-platform discovery parity in tests.
3. **[UX] Reactive State for Settings Screen:** The `SettingsScreen` currently uses a `FutureBuilder` to fetch device info once upon initialization. It should be refactored to use `Stream` or `ChangeNotifier` so the UI automatically updates if the daemon restarts or the device fingerprint changes.
4. **[Engineering] Manual Interop Evidence Still Incomplete:** The transport implementations are now in place, but full milestone sign-off still depends on recorded manual pairing and clipboard evidence across platforms (happy path, reject, timeout, persistence, revoke, and clipboard transfer validation where applicable).
5. **[Performance] Windows Named Pipe Polling:** The current Windows client uses periodic polling in a dedicated isolate. This is acceptable for now, but if power or CPU profiling shows overhead on laptops, the next step is moving toward overlapped I/O or a less chatty readiness strategy.
6. **[Testing] Transport-Level Hardening:** Widget and client-layer coverage are in good shape, but deeper transport-specific tests for Windows named pipes and Android isolate lifecycle would further harden IPC against platform regressions.
7. **[UX] Clipboard Offer UI Still Partial:** The client now has clipboard status plumbing, auto-fetch handling, and protocol-facing clipboard wiring, but a richer end-user clipboard-offer/fetch workflow remains a follow-up beyond the current milestone-oriented shell behavior.
8. **[Platform] macOS/Linux Clipboard Fallback Is Polling-Based:** Desktop clipboard monitoring now works on macOS/Linux through a Dart polling fallback, but those platforms do not yet have native runner clipboard event channels equivalent to the Windows implementation.
9. **[UX] Operation History UI Still Pending:** The Flutter client now consumes operation lifecycle IPC, but it does not yet expose a dedicated operation history / diagnostics screen for end users.
