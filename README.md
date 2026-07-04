# Rift

Rift is a security-first cross-platform device continuity platform.

This repository contains the protocol specification, daemon implementations, Flutter app, and conformance/interop tests. The protocol specification is the source of truth for compatible implementations.

## Repository Layout

- `spec/` - language-independent Rift protocol specification and supporting materials.
- `daemon-cs/` - multi-platform C#/.NET daemon core with Windows, macOS, and Linux hosts.
- `daemon-dart/` - Android daemon implementation in Dart.
- `app-flutter/` - Flutter app and IPC client for Android and the active desktop targets in this repository.
- `tests-conformance/` - tests for implementation conformance to the written protocol.
- `tests-interop/` - cross-implementation interoperability tests.

## Protocol Specification

Start with `spec/doc/protocol.md`.

Architecture decisions live in `spec/decisions/`.

Local reference documents may be placed in `spec/references/`; this directory is intentionally not committed.

## Status

Active monorepo under development. The protocol/specification remains the
source of truth; implementations and docs may advance in stages, so milestone
plans in older documents can lag behind newer platform work captured deeper in
the repo.
