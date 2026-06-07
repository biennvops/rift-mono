# AGENTS.md

This file provides guidance to AI agents when working with code in this repository.

## Project Overview

Rift is a security-first, local-first, cross-platform device continuity platform. It uses a protocol-first development approach: the written protocol specification (`spec/doc/protocol.md`) is the source of truth, and two independent daemon implementations must conform to it.

## Repository Layout

- `spec/doc/protocol.md` — the normative protocol specification (v0.1-draft). Start here.
- `spec/decisions/` — Architecture Decision Records (ADRs), numbered `0001-*` through `0010-*`. Template: Status/Context/Decision/Consequences.
- `spec/asn1/` — ASN.1 module definitions for the custom X.509 extension.
- `spec/vectors/` — deterministic test vectors for cross-implementation conformance.
- `spec/examples/` — example certificates and message flows.
- `spec/references/` — gitignored directory for local copies of RFCs and reference documents.
- `daemon-cs/` — Multi-platform daemon (C#/.NET 10). Three projects: `Rift.Daemon.Core` (shared library, cross-platform interfaces, Worker, JSON-RPC API), `Rift.Daemon.Windows` (Windows Service + Named Pipes), `Rift.Daemon.macOS` (launchd LaunchAgent + Unix Domain Sockets). Uses BouncyCastle.NET + native .NET crypto, StreamJsonRpc for IPC, SQLite via Microsoft.Data.Sqlite.
- `daemon-dart/` — Android daemon (Dart). Uses PointyCastle for crypto, SecureSocket for mTLS, json_rpc_2 over SendPort/ReceivePort, SQLite via sqflite. Includes a purpose-built ASN.1 parser for X.509 extension extraction (security-critical component).
- `app-flutter/` — Single Flutter/Dart codebase targeting Android + Windows. Material 3. One `JsonRpcRiftClient` consumes both daemons via JSON-RPC 2.0.
- `tests-conformance/` — Cross-implementation protocol conformance tests (one harness, two daemons).
- `tests-interop/` — Cross-platform interop tests (C# daemon paired with Dart daemon end-to-end).
- `docs/` — Project documentation (capstone register, known issues).

## Architecture

**Dual-daemon model:** Two independent daemon implementations (C#/.NET on Windows and macOS, Dart on Android) conform to one protocol spec. Both are runnable as standalone console processes for dev/CI and as platform services (Windows Service, macOS LaunchAgent, Android foreground service) in production. The C# daemon uses a shared core library (`Rift.Daemon.Core`) with platform-specific entry points for IPC and service hosting.

**Dual-keypair identity:** Ed25519 for permanent device identity (fingerprint, device ID, trust store). ECDSA P-256 for TLS certificates. The Ed25519 public key is embedded in the P-256 cert via a custom X.509 extension (OID `2.25.293029629918709742181702189012786017422`).

**Trust state machine:** discovered → pairing_pending → trusted → blocked → revoked. Only `trusted` peers access protected operations. Revocation keeps negative-trust evidence.

**Transport-agnostic IPC:** JSON-RPC 2.0 between daemon and Flutter client. Named pipes on Windows, SendPort/ReceivePort on Android. The Flutter UI never distinguishes transports.

**Windows runtime split:** Windows Service owns background core (discovery, trust, transport, persistence, event log). User-session Flutter process owns clipboard, tray, notifications — because Session 0 isolation prevents services from accessing user clipboard.

**Protocol term:** "Operation" is the protocol-level term for cross-device actions. Avoid unqualified "Intent" on Android to prevent collision with `android.content.Intent`.

## Security Model Context

The protocol design specifically mitigates three KDE Connect vulnerability classes:
- CVE-2025-66270 (identity switching) — device ID derived from Ed25519 key, validated on every message
- CVE-2025-32900 (device spoofing) — device info exchanged only over authenticated TLS
- CVE-2025-32898 (weak verification) — pairing uses full Ed25519 fingerprint, not short codes

The Dart daemon's custom X.509 ASN.1 parser is a known high-risk component (required because dart:io doesn't expose cert extensions). It must fail closed on all malformed input and is subject to dedicated fuzz testing.

## Protocol Conventions

- Wire framing: 4-byte big-endian length prefix + UTF-8 JSON object, max 32 MiB
- IDs (message, operation, offer, event): lowercase RFC 4122 UUIDv4
- Device ID format: `rift-` + first 32 chars of lowercase Base32(SHA-256(Ed25519 pubkey)), no padding
- Timestamps: RFC 3339 UTC (audit only). Durations/expiries: integer milliseconds with monotonic timers
- Failure reasons are a closed vocabulary (15 values in v0.1-draft) — implementations must not invent new peer-visible reasons
- Unknown optional fields must be ignored; unknown `requiredExtensions` values must cause `ProtocolError`
