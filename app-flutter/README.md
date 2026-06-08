# Flutter App

This directory contains the Flutter app shell and IPC client for Android and Windows used in Week 2.

Installation and running (requires Flutter SDK installed):

```bash
flutter pub get
flutter run -d windows   # on Windows
flutter run -d linux     # on Linux
flutter run -d <device>  # on Android/emulator
```

Run tests:

```bash
flutter test
```

Verified output (local run, Week 2):

```
00:06 +8: All tests passed!
```

The 8 tests that passed:

| Test file | Test name | What it checks |
| --- | --- | --- |
| `test/widget_test.dart` | `RiftApp shows home title` | Home screen renders `AppStrings.appTitle` and `AppStrings.homeSubtitle` |
| `test/pairing_screen_test.dart` | `PairingScreen shows title` | `PairingScreen` renders `AppStrings.pairingTitle` |
| `test/trusted_devices_screen_test.dart` | `TrustedDevicesScreen shows title` | `TrustedDevicesScreen` renders `AppStrings.trustedDevicesTitle` |
| `test/event_log_screen_test.dart` | `EventLogScreen shows title` | `EventLogScreen` renders `AppStrings.eventLogTitle` |
| `test/app_shell_test.dart` | `App shell boots up...` | Wraps app in `Provider` with mocked IPC client to verify decoupled UI. |
| `test/app_shell_test.dart` | `MockClient getDeviceInfo...` | Tests `getDeviceInfo` method through Mocktail. |
| `test/ipc_test.dart` | `...connect via transport` | Validates `JsonRpcRiftClient` successfully completes connect cycle over generic transport. |
| `test/ipc_test.dart` | `...get device info...` | Validates exact JSON-RPC `rift.getDeviceInfo` payload exchange. |

Notes:
- UI strings are centralized in `lib/constants.dart` to avoid hardcoding.
- The UI stubs intentionally do not use icons as requested.

## Directory Structure by Component

This is a minimal, testable structure intended for Week 1 development.

- `lib/`
	- `main.dart` - application entry point, creates `MaterialApp` and navigates to the main screens.
	- `constants.dart` - centralizes UI strings to avoid hardcoding.
	- `screens/` - Week 1 UI screens.
		- `pairing_screen.dart` - pairing screen.
		- `trusted_devices_screen.dart` - trusted devices screen.
		- `event_log_screen.dart` - event log screen.
- `test/` - widget tests for each screen and smoke tests for the application.
	- `widget_test.dart` - tests the root `RiftApp` screen.
	- `pairing_screen_test.dart` - tests the pairing screen.
	- `trusted_devices_screen_test.dart` - tests the trusted devices screen.
	- `event_log_screen_test.dart` - tests the event log screen.
- `android/`, `ios/`, `windows/`, `macos/`, `linux/` - platform directories managed by Flutter; may contain build artifacts and temporary files.
- `.github/workflows/` - CI workflows, e.g., `flutter-ci.yml`.

## Risk Assessment (Summary)

A short, non-exhaustive list of risks related to Week 1 deliverables and their mitigations:

- Flaky or missing CI: **Resolved.** CI uses `channel: stable` (correct key for `subosito/flutter-action@v2`), and all three steps (`pub get`, `analyze`, `test`) use `working-directory: app-flutter`.
- Accidental commits of platform artifacts: **Resolved.** `app-flutter/.gitignore` correctly covers `android/local.properties`, `ios/Flutter/Generated.xcconfig`, `ios/Flutter/ephemeral/`, `ios/Flutter/flutter_export_environment.sh`, and `macos/Flutter/ephemeral/`. Confirmed none of these are tracked in git.
- Brittle tests due to hardcoded strings or platform resources: Low. Mitigation: centralize strings in `constants.dart` and avoid using platform resources in tests.
- Spec drift between UI and IPC daemon: Medium. Mitigation: treat `spec/doc/ipc.md` as the authoritative source; only update IPC after multi-member review.

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
  Verified locally: `00:26 +4: All tests passed!` (4 widget tests, 2026-06-05).
- Screens display basic titles and tests check against values in `constants.dart` (no hardcoded strings in tests).
- README updated with run/test instructions, directory structure, file review, and Week 1 plan.
- No machine-specific or ephemeral files committed to the repository.

## Week 2 Plan & Progress (app-flutter deliverables)

Goal: Implement transport-agnostic IPC spike, dependency injection for JSON-RPC client, and integrate conformance testing CI.

- **[x] IPC Spike**: Created `IpcTransport` interface with `NamedPipeTransport` (Windows), `UnixSocketTransport` (Linux/macOS), and `IsolateTransport` (Android).
- **[x] Anti-OOM Framing**: Integrated NDJSON framing via a custom `BoundedLineSplitter` to strictly comply with `ipc.md` and prevent malicious 32+ MiB payloads from causing Out-Of-Memory crashes.
- **[x] JSON-RPC Client**: Implemented `JsonRpcRiftClient` supporting reconnection and exponential backoff to handle daemon downtimes.
- **[x] Dependency Injection & Factory**: Added `provider` package. `JsonRpcRiftClient` uses `TransportFactory.create()` to dynamically inject the correct platform transport at runtime without cluttering the UI code.
- **[x] Widget Test Skeleton**: Updated `app_shell_test.dart` and `ipc_test.dart` using `mocktail`. Synced the mock schema to strictly match the 5 mandatory keys for `rift.getDeviceInfo` per protocol spec, eliminating real Daemon dependencies during CI.
- **[x] CI Conformance**: Created `.github/workflows/conformance.yml` to automatically build standalone C# and Dart daemons and test against protocol vectors.

## Week 2 File Review

| File | Assessment | Comments |
| --- | --- | --- |
| `lib/src/ipc/ipc_transport.dart` | Good | Abstract interface for all platforms. |
| `lib/src/ipc/transport_factory.dart` | Good | Centralized OS platform detection and instantiation. |
| `lib/src/ipc/json_rpc_client.dart` | Good | Full JSON-RPC 2.0 with backoff and `getDeviceInfo`. |
| `lib/src/ipc/bounded_line_splitter.dart` | Good | Stream filter preventing JSON frame OOM crashes. |
| `lib/src/ipc/named_pipe_transport.dart` | Good | Windows Named Pipe using `BoundedLineSplitter`. |
| `lib/src/ipc/unix_socket_transport.dart` | Good | Linux/macOS Unix Socket using `BoundedLineSplitter`. |
| `lib/src/ipc/isolate_transport.dart` | Good | Android Isolate Send/Receive port spike. |
| `test/ipc_test.dart` | Good | Validates Client behavior with simulated protocol streams. |
| `test/app_shell_test.dart` | Good | Wraps App in `Provider` and injects `mocktail` client. |
| `../.github/workflows/conformance.yml` | Good | Compiles both daemons autonomously for CI tests. |
| `../daemon-dart/.gitignore` | Good | Blocks `daemon_runner` binary from leaking into Git. |

## Week 2 Acceptance Criteria

- `flutter test` completes successfully with mock JSON-RPC payloads mapping correctly to the Widget tree.
- The IPC Transport adheres to the `protocol.md` and `ipc.md` security constraints (no private keys exposed, uses proper NDJSON framing bounded at 32 MiB).
- The CI Conformance workflow passes validation without missing entry points for Dart/C#.
