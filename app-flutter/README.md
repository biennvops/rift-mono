# Flutter App

This directory contains the Flutter app shell and IPC client for Android and Windows used in Week 2.

Installation and running (requires Flutter SDK installed):

```bash
flutter pub get
flutter run -d windows   # on Windows
flutter run -d linux     # on Linux
flutter run -d <device>  # on Android/emulator
```

**Expected Runtime Behavior (Week 2 State):**
- **UI:** The Flutter application will successfully boot and display the core navigation screens (Pairing, Trusted Devices, Event Log). The UI components are decoupled and will not crash.
- **Linux/macOS (`UnixSocketTransport`):** You will see background warnings in the console (e.g., `SocketException: Connection failed`) as the IPC client actively attempts to connect to `/tmp/rift-daemon.sock`. This is **expected** because the standalone native daemon is not running. The JSON-RPC client will automatically manage this via its exponential backoff reconnection loop.
- **Android/Windows (`IsolateTransport` / `NamedPipeTransport`):** The IPC connection attempt will intentionally throw an `UnimplementedError`. This is a strict fail-fast mechanism to prevent incorrect transport assumptions pending the native daemon implementations.

Run tests:

```bash
flutter test
```

Verified output (local run, 2026-06-09):

```
00:04 +14: All tests passed!
```

The core tests that passed (now expanded to 14):

| Test file | Test name | What it checks |
| --- | --- | --- |
| `test/widget_test.dart` | `RiftApp shows home title` | Home screen renders `AppStrings.appTitle` and `AppStrings.homeSubtitle` |
| `test/pairing_screen_test.dart` | `PairingScreen shows title` | `PairingScreen` renders `AppStrings.pairingTitle` |
| `test/trusted_devices_screen_test.dart` | `TrustedDevicesScreen shows title` | `TrustedDevicesScreen` renders `AppStrings.trustedDevicesTitle` |
| `test/event_log_screen_test.dart` | `EventLogScreen shows title` | `EventLogScreen` renders `AppStrings.eventLogTitle` |
| `test/app_shell_test.dart` | `App shell boots up...` | Wraps app in `Provider` with mocked IPC client to verify decoupled UI. |
| `test/app_shell_test.dart` | `MockClient getDeviceInfo...` | Tests `getDeviceInfo` method through Mocktail (converted to pure logic test). |
| `test/ipc_test.dart` | `...connect via transport` | Validates `JsonRpcRiftClient` successfully completes connect cycle over generic transport. |
| `test/ipc_test.dart` | `...get device info...` | Validates exact JSON-RPC `rift.getDeviceInfo` payload exchange. |
| `test/ipc_test.dart` | `...attempt reconnection...` | Uses `fake_async` to validate exponential backoff timers and automatic connection recovery. |
| `test/bounded_line_splitter_test.dart` | `...yields lines...` | Exhaustively tests OOM byte guard, Unicode codepoint-accurate byte counting via `runes.fold`, and NDJSON boundary parsing. |

Notes:
- UI strings are centralized in `lib/constants.dart` to avoid hardcoding.
- The UI stubs intentionally do not use icons as requested.

## Directory Structure by Component

This project is structured using a clean, scalable, and testable architecture. The codebase is strictly split between presentation UI (`lib/screens/`) and core logic (`lib/src/`).

```text
app-flutter/
├── lib/
│   ├── constants.dart                    # Centralized UI strings to prevent hardcoding
│   ├── main.dart                         # App entry point, DI Provider setup, and MaterialApp
│   ├── screens/                          # Presentation Layer (Week 1 UI stubs)
│   │   ├── event_log_screen.dart
│   │   ├── pairing_screen.dart
│   │   └── trusted_devices_screen.dart
│   └── src/                              # Core Domain Logic (Week 2 Additions)
│       └── ipc/                          # IPC Communication Layer
│           ├── bounded_line_splitter.dart # Security: OOM guard, strictly limits NDJSON frames to 32MiB
│           ├── ipc_transport.dart         # Interface: Standardizes platform-agnostic transport layer
│           ├── isolate_transport.dart     # Android: SendPort/ReceivePort spike (Stub)
│           ├── json_rpc_client.dart       # Core RPC logic: Manages reconnection, requests, and timeouts
│           ├── named_pipe_transport.dart  # Windows: Named Pipe spike (Stub)
│           ├── transport_factory.dart     # Dependency Injection: Resolves the correct transport per OS
│           └── unix_socket_transport.dart # Linux/macOS: Active Unix Domain Socket transport
├── test/
│   ├── app_shell_test.dart               # Tests App boot and Provider injection
│   ├── bounded_line_splitter_test.dart   # Exhaustive testing of NDJSON limits and Unicode codepoints
│   ├── event_log_screen_test.dart        # Screen UI test
│   ├── ipc_test.dart                     # JSON-RPC testing via `fake_async` for connection lifecycle
│   ├── pairing_screen_test.dart          # Screen UI test
│   ├── trusted_devices_screen_test.dart  # Screen UI test
│   └── widget_test.dart                  # Smoke test for main app widget
├── android/, ios/, windows/, macos/, linux/  # Flutter platform-specific generated directories
└── pubspec.yaml                          # Dart dependencies (provider, json_rpc_2, stream_channel, etc.)
```

## Risk Assessment (Summary)

A short, non-exhaustive list of risks related to Week 1 & 2 deliverables and their mitigations:

- Flaky or missing CI: **Resolved.** CI uses `channel: stable` (correct key for `subosito/flutter-action@v2`), and all three steps (`pub get`, `analyze`, `test`) use `working-directory: app-flutter`.
- Accidental commits of platform artifacts: **Resolved.** `app-flutter/.gitignore` correctly covers `android/local.properties`, `ios/Flutter/Generated.xcconfig`, `ios/Flutter/ephemeral/`, `ios/Flutter/flutter_export_environment.sh`, and `macos/Flutter/ephemeral/`. Confirmed none of these are tracked in git.
- Brittle tests due to hardcoded strings or platform resources: Low. Mitigation: centralize strings in `constants.dart` and avoid using platform resources in tests.
- Spec drift between UI and IPC daemon: Medium. Mitigation: treat `spec/doc/ipc.md` as the authoritative source; only update IPC after multi-member review.
- Missing Platform Transports (Android/Windows): **Known Risk.** `IsolateTransport` and `NamedPipeTransport` are currently unimplemented stubs. Any IPC calls on these platforms will throw `UnimplementedError` at runtime pending native daemon completion.
- Reconnection Double-Triggering: **Resolved.** Added `_isReconnecting` lock guard in `_handleDisconnect()` to prevent concurrent error streams from spawning duplicate timers.

## Week 1 File Review

| File | Assessment | Comments |
| --- | --- | --- |
| `lib/main.dart` | Good | Clean entry point, default template removed, no icons used. Trailing newline fixed. |
| `lib/constants.dart` | Good | Centralizes UI strings, preventing hardcoding. |
| `lib/screens/pairing_screen.dart` | Good | Clear stub, fits week 1 goals. |
| `lib/screens/trusted_devices_screen.dart` | Good | Clear stub, easy to expand later. |
| `lib/screens/event_log_screen.dart` | Good | Clear stub, used for test flows. |
| `test/widget_test.dart` | Good | Changed from counter template to testing `RiftApp`. |
| `test/pairing_screen_test.dart` | Good | Tests the current pairing screen correctly. |
| `test/trusted_devices_screen_test.dart` | Good | Tests the current trusted devices screen correctly. |
| `test/event_log_screen_test.dart` | Good | Tests the current event log screen correctly. |
| `pubspec.yaml` | Mandatory | Makes `app-flutter` a valid Flutter project to run `flutter pub get` and `flutter run`. |
| `analysis_options.yaml` | Good | Keeps code quality and linting consistent. |
| `.gitignore` | Good | Covers all Flutter ephemeral/local files; confirmed none are tracked in git. |
| `.github/workflows/flutter-ci.yml` | Good | Uses `channel: stable` (correct key); all steps scoped to `app-flutter/`. |
| `windows/` | Valid | Desktop configuration needed to run on Windows. |
| `android/` | Valid | Platform configuration needed for Android. `android/local.properties` is gitignored and not tracked. |
| `ios/`, `macos/`, `linux/` | Valid but not currently used | Generated by Flutter; ephemeral subdirectories are gitignored and not tracked. |

## Week 1 Plan (app-flutter deliverables)

Goal: provide a clean, testable app shell for pairing/trust UI and a minimal CI to validate tests.

Day 1 (done)
- Created app shell and added stubs in `screens/` (Pairing, Trusted Devices, Event Log).
- Added `constants.dart` for UI strings.

Day 2 (done)
- Added widget tests for the 3 screens.
- Added GitHub Actions workflow (`.github/workflows/flutter-ci.yml`) running `flutter analyze` and `flutter test --coverage`, scoped to `app-flutter/`.

Day 3 (done)
- Reviewed and confirmed `.gitignore` — all ephemeral/local platform files are correctly excluded and not tracked in git.
- Fixed CI: switched from deprecated `flutter-version` to `channel: stable` for `subosito/flutter-action@v2`.
- Fixed `lib/main.dart`: added missing trailing newline.

## Post-Review Fixes (PR feedback addressed)

| Issue | Status | Action taken |
| --- | --- | --- |
| CI `working-directory` missing | Was already correct | All 3 steps already had `working-directory: app-flutter` |
| CI `flutter-version` → `channel` | Fixed | Switched to `channel: stable` (correct key for `subosito/flutter-action@v2`) |
| `local.properties` tracked | Never tracked | Covered by `app-flutter/.gitignore` line 49 |
| iOS/macOS ephemeral files tracked | Never tracked | Covered by `app-flutter/.gitignore` lines 52–55 |
| `main.dart` missing trailing newline | Fixed | Added final `\n` |
| ADR 0001–0006 duplicate headers | Not present | No duplicates found in any ADR file |
| `フィナーレ.md` at repo root | Already deleted | File was removed before this fix pass |
| `daemon-dart` matcher downgrade | Not present | `matcher` is at `0.12.20` — no downgrade |
| `kim-week1` branch in CI trigger | Was already removed | Workflow only triggers on `main` |

## Acceptance Criteria

- `flutter analyze` and `flutter test` run successfully on CI for the added tests.
  Verified locally: `00:04 +14: All tests passed!` (14 tests, 2026-06-09).
- Screens display basic titles and tests check against values in `constants.dart` (no hardcoded strings in tests).
- README updated with run/test instructions, directory structure, file review, and Week 1 plan.
- No machine-specific or ephemeral files committed to the repository.

## Week 2 Plan & Progress (app-flutter deliverables)

Goal: Implement transport-agnostic IPC spike, dependency injection for JSON-RPC client, and integrate conformance testing CI.

- **[x] IPC Spike**: Created `IpcTransport` interface. Android and Windows currently throw `UnimplementedError` to cleanly avoid fake/leaky sockets, while Linux/macOS use `UnixSocketTransport`.
- **[x] Anti-OOM Framing**: Integrated NDJSON framing via a custom `BoundedLineSplitter`. Features strict UTF-8 Unicode decoding via `runes.fold` (refined after code review) to precisely bound at 32 MiB and prevent memory leaks.
- **[x] JSON-RPC Client**: Implemented `JsonRpcRiftClient` supporting reconnection and exponential backoff. Includes asynchronous disconnects, concurrent trigger locks, and accurate timer resets validated with `fake_async`.
- **[x] Dependency Injection & Factory**: Added `provider` package. `JsonRpcRiftClient` uses `TransportFactory.create()` to dynamically inject the correct platform transport at runtime without cluttering the UI code.
- **[x] Widget Test Skeleton**: Updated `app_shell_test.dart`, `ipc_test.dart`, and added `bounded_line_splitter_test.dart`. Synced the mock schema to strictly match the 5 mandatory keys for `rift.getDeviceInfo` per protocol spec, achieving robust 100% stable CI logic.
- **[ ] CI Conformance**: Created `.github/workflows/conformance.yml` to automatically build standalone C# and Dart daemons. CI is correctly configured to explicitly fail (`exit 1`) pending the integration of the test runner harness.

## Week 2 File Review

| File | Assessment | Comments |
| --- | --- | --- |
| `lib/src/ipc/ipc_transport.dart` | Good | Abstract interface for all platforms. |
| `lib/src/ipc/transport_factory.dart` | Good | Centralized OS platform detection; strictly fails fast for unimplemented ports. |
| `lib/src/ipc/json_rpc_client.dart` | Good | Full JSON-RPC 2.0 with backoff, async locks, and automatic recovery. |
| `lib/src/ipc/bounded_line_splitter.dart` | Good | Highly optimized memory guard using `runes.fold` UTF-8 counting. |
| `lib/src/ipc/named_pipe_transport.dart` | Stub | Throws `UnimplementedError` to prevent incorrect Unix socket assumptions on Windows. |
| `lib/src/ipc/unix_socket_transport.dart` | Good | Linux/macOS Unix Socket with integrated stream error propagation (`_socket?.destroy()`). |
| `test/ipc_test.dart` | Good | Validates Client behavior with simulated protocol streams via `fake_async`. |
| `test/app_shell_test.dart` | Good | Wraps App in `Provider` and injects `mocktail` client. Uses proper test methods. |
| `test/bounded_line_splitter_test.dart` | Good | Dedicated test file for NDJSON boundaries and UTF-8 encoding checks. |
| `../.github/workflows/conformance.yml` | Good | Explicitly fails pending full runner implementation to maintain CI integrity. |
| `../daemon-dart/bin/daemon.dart` | Stub | Placeholder with clear TODO for Android team to prevent fake CI passes. |

## Week 2 Acceptance Criteria

- `flutter test` completes successfully with mock JSON-RPC payloads mapping correctly to the Widget tree.
- The IPC Transport adheres to the `protocol.md` and `ipc.md` security constraints (uses proper NDJSON framing bounded at 32 MiB).
- The CI Conformance workflow passes validation without missing entry points for Dart/C#.
