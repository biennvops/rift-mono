# Interoperability Harness

This directory contains cross-platform interoperability test material for Rift.
It is the place for harness code, repeatable validation procedures, and stored
evidence formats for daemon-to-daemon and app-to-daemon interoperability.

Active status and sign-off tracking belong in GitHub Projects, not in this
README.

## Purpose

- exercise cross-implementation behavior beyond single-daemon unit tests
- capture reusable validation workflows for real device pairs
- keep interoperability evidence separate from normative protocol docs

## Current Contents

- `test/` - lightweight automated interop-oriented tests and harness code
- `mobile-device-matrix.md` - manual real-device test matrix for mobile pairs
- `pubspec.*` - Dart package metadata for the harness

The tests in this package run two in-memory **Dart** daemon session stacks
against each other. They validate Android-side protocol behavior, not
desktop-to-desktop interoperability.

## Desktop-to-Desktop Interop

Desktop-to-desktop (Windows/macOS/Linux) interoperability is exercised by the
C# live-transport interop suites in
`daemon-cs/Rift.Daemon.Tests/Core/`:

- `TlsTransportTests` - mutual TLS bootstrap, capability negotiation, and
  bidirectional protected traffic between two live transports
- `PairingInteropTests` - pairing, trusted reconnect, and block enforcement
  between two full daemon-core stacks over loopback sockets
- `ClipboardFileInteropTests` - clipboard text/binary offer+fetch with hash
  verification, and the file transfer lifecycle (complete, reject, cancel,
  resume-after-disconnect) through the production message router

Run them on each desktop platform with:

```bash
dotnet test daemon-cs/Rift.Daemon.Tests/Rift.Daemon.Tests.csproj
```

## Usage

Run from `tests-interop/`:

```bash
flutter pub get
flutter test
```

Use this directory for reproducible interop procedures and evidence templates.
Do not treat it as the project roadmap or source of current completion status.
