# Rift Flutter App (Android + Windows)

Flutter client shell for Rift v0.1-draft. This app hosts the Week 1 UI stubs and testing baseline for later pairing, trust, and clipboard features.

## 1) Prerequisites

- Flutter stable SDK installed and available in `PATH`
- Dart SDK comes with Flutter
- Android SDK (for Android target)
- Windows desktop support enabled (for Windows target)

Quick checks:

```powershell
flutter --version
flutter doctor
```

## 2) Setup

Run from the Flutter project root (`c:\doan\rift-mono-main\app-flutter`):

```powershell
Set-Location "c:\doan\rift-mono-main\app-flutter"
flutter pub get
```

Note: Dart package name is `app_flutter` (valid format with underscore).

## 3) Run

Windows desktop:

```powershell
Set-Location "c:\doan\rift-mono-main\app-flutter"
flutter run -d windows
```

Android device/emulator:

```powershell
Set-Location "c:\doan\rift-mono-main\app-flutter"
flutter run -d android
```

## 4) Static Analysis and Tests

```powershell
Set-Location "c:\doan\rift-mono-main\app-flutter"
flutter analyze
flutter test
```

Current Week 1 scope includes widget tests for:

- `lib/screens/pairing_screen.dart`
- `lib/screens/trusted_devices_screen.dart`
- `lib/screens/event_log_screen.dart`

## 5) CI Notes

Workflow file: `.github/workflows/flutter-ci.yml`

CI job currently runs:

1. `actions/checkout@v4`
2. `subosito/flutter-action@v2` (stable)
3. `flutter pub get`
4. `flutter analyze`
5. `flutter test --coverage`

## 6) Week 1 Deliverables (Kim)

- Wireframes: `design/wireframes.md`
- UI stubs: `lib/screens/*.dart`
- Widget tests: `test/*_screen_test.dart`
- CI baseline: `.github/workflows/flutter-ci.yml`

## 7) Common Pitfalls

- Running commands in the wrong folder (for example nested `app-flutter/app-flutter`) can cause `Test directory "test" not found`.
- Always run Flutter commands at the project root where `pubspec.yaml`, `lib`, and `test` are present.

## 8) Week 1 Issue List (Kim)

This section merges the Week 1 issue planning directly into this README.

### 8.1 Label Set

- Domain: `app-flutter`, `ci`, `tests-interop`, `docs`
- Type: `feature`, `infra`, `test`
- Priority: `P1-high`, `P2-medium`
- Status modifier: `needs-review`, `needs-qa-signoff`

### 8.2 Issues (Owner, Labels, Acceptance Criteria)

1. `[app-flutter][infra] Flutter app shell for Android and Windows targets`
- Owner: Kim
- Labels: `app-flutter`, `infra`, `feature`, `P1-high`, `needs-review`
- Acceptance criteria:
	- [x] `flutter pub get` runs successfully in `app-flutter/`
	- [x] `flutter analyze` returns no issues
	- [x] `flutter test` passes

2. `[app-flutter][docs] Wireframes: pairing, trusted devices, event log, clipboard status`
- Owner: Kim
- Labels: `app-flutter`, `docs`, `feature`, `P2-medium`, `needs-review`
- Acceptance criteria:
	- [x] `app-flutter/design/wireframes.md` exists
	- [x] File covers 4 screens (pairing, trusted devices, event log/operation history, clipboard transfer status)

3. `[app-flutter][feature] Create Week 1 UI stubs (3 screens)`
- Owner: Kim
- Labels: `app-flutter`, `feature`, `P1-high`, `needs-review`
- Acceptance criteria:
	- [x] 3 files exist in `app-flutter/lib/screens/`
	- [x] Each screen has a basic `Scaffold` with title and stub content

4. `[app-flutter][test] Widget test skeleton for Week 1 UI stubs`
- Owner: Kim
- Labels: `app-flutter`, `test`, `P1-high`, `needs-review`, `needs-qa-signoff`
- Acceptance criteria:
	- [x] 3 test files exist in `app-flutter/test/`
	- [x] `flutter test` passes

5. `[ci][infra] GitHub Actions skeleton for Flutter analyze and tests`
- Owner: Kim
- Labels: `ci`, `infra`, `test`, `P1-high`, `needs-review`
- Acceptance criteria:
	- [x] `.github/workflows/flutter-ci.yml` exists
	- [x] Workflow includes checkout, setup Flutter, `flutter pub get`, `flutter analyze`, `flutter test`

6. `[app-flutter][docs] README setup/run/test/CI notes for Week 1 baseline`
- Owner: Kim
- Labels: `app-flutter`, `docs`, `infra`, `P2-medium`, `needs-review`
- Acceptance criteria:
	- [x] README includes prerequisites, setup, run, analyze, test
	- [x] README includes CI notes and common pitfalls

## 9) Week 1 Task 1 Completion Evidence

Date: 2026-05-24

### 9.1 Completion Checklist

- [x] Flutter project shell for Android/Windows is available in `app-flutter/`
- [x] Package name fixed to valid Dart name: `app_flutter`
- [x] Wireframes document exists: `app-flutter/design/wireframes.md`
- [x] UI stubs exist in `app-flutter/lib/screens/`
- [x] Widget tests exist in `app-flutter/test/`
- [x] CI workflow exists: `.github/workflows/flutter-ci.yml`
- [x] `flutter pub get` succeeded
- [x] `flutter analyze` succeeded (`No issues found!`)
- [x] `flutter test` succeeded (`All tests passed!`)

### 9.2 Command Log Evidence

Project root used for commands:

```text
C:\doan\rift-mono-main\app-flutter
```

Executed commands:

```powershell
Set-Location "C:\doan\rift-mono-main\app-flutter"
flutter pub get
flutter analyze
flutter test
```

Output excerpts:

```text
Resolving dependencies...
Got dependencies!
...
Analyzing app-flutter...
No issues found! (ran in 1.5s)
00:10 +4: All tests passed!
```

Note: warnings about newer package versions are informational and do not block Week 1 completion.

### 9.3 Artifact Checklist

- [x] `app-flutter/design/wireframes.md`
- [x] `app-flutter/lib/screens/pairing_screen.dart`
- [x] `app-flutter/lib/screens/trusted_devices_screen.dart`
- [x] `app-flutter/lib/screens/event_log_screen.dart`
- [x] `app-flutter/test/pairing_screen_test.dart`
- [x] `app-flutter/test/trusted_devices_screen_test.dart`
- [x] `app-flutter/test/event_log_screen_test.dart`
- [x] `.github/workflows/flutter-ci.yml`
- [x] `app-flutter/README.md`

### 9.4 Screenshot Evidence

Store screenshots under `app-flutter/artifacts/week1/`.

Recommended captures:

- [ ] Terminal screenshot showing `No issues found!` and `All tests passed!`
- [ ] Editor screenshot of `design/wireframes.md`
- [ ] Editor screenshot of one screen stub (`pairing_screen.dart`)
- [ ] GitHub Actions screenshot showing CI workflow file and/or run result

Embed screenshots (replace file names when available):

```md
![Analyze and Test Pass](artifacts/week1/analyze-test-pass.png)
![Wireframes](artifacts/week1/wireframes.png)
![Pairing Screen Stub](artifacts/week1/pairing-screen-stub.png)
![CI Workflow](artifacts/week1/flutter-ci-workflow.png)
```

### 9.5 Reviewer Sign-off

- Reviewer: ___________________
- Date: ___________________
- Result: [ ] Pass  [ ] Needs fix
- Notes:

```text
[Add review notes here]
```
