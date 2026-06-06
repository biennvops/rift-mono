# Rift

Rift is a security-first cross-platform device continuity platform.

This repository contains the protocol specification, daemon implementations, Flutter app, and conformance/interop tests. The protocol specification is the source of truth for compatible implementations.

## Repository Layout

- `spec/` - language-independent Rift protocol specification and supporting materials.
- `daemon-cs/` - Windows daemon implementation in C#/.NET.
- `daemon-dart/` - Android daemon implementation in Dart.
- `app-flutter/` - Flutter app for Android and Windows.
- `tests-conformance/` - tests for implementation conformance to the written protocol.
- `tests-interop/` - cross-implementation interoperability tests.

## Protocol Specification

Start with `spec/doc/protocol.md`.

Architecture decisions live in `spec/decisions/`.

Local reference documents may be placed in `spec/references/`; this directory is intentionally not committed.

## Status

**Week 3 Complete (v0.1-draft MVP)**
- Core identity management, cryptography, and frame codecs are implemented for Android (Dart).
- Custom X.509 ASN.1 parser successfully extracts Ed25519 public keys with 100% fail-closed validation against 8 classes of malformed input.
- Cross-platform daemon communication interfaces are defined.
- 24/24 Security and Unit tests passing.
