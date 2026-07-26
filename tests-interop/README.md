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

## Usage

Run from `tests-interop/`:

```bash
dart pub get
dart test
```

Use this directory for reproducible interop procedures and evidence templates.
Do not treat it as the project roadmap or source of current completion status.
