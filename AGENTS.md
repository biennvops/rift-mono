# Rift engineering rules

## Verification
- After any code change, run the project's verification command, and show the output.
- Do not claim a task complete unless tests pass and lint is clean.
- If verification commands are unclear, ask before proceeding.
- Transform tasks into verifiable goals. 'Fix the bug' becomes 'write a test that reproduces it, then make it pass.' 'Refactor X' becomes 'ensure tests pass before and after.'

## Boundaries
- Ask before any of: destructive shell commands (rm -rf, git push --force, db drops), adding new dependencies, modifying CI/infrastructure, touching .env or secrets.
- Before destructive actions, ensure changes are committed to git first - git is the backup. If git isn't appropriate, ask before proceeding.
- Prefer editing existing files over creating new ones.
- Do not add comments that restate what the code does. Comments are only for *why* something non-obvious is done - never for *what* the code is doing. Generally, use as few comments as possible and keep the code as self-explanatory or self-documented as possible.

## Simplicity
- Write the minimum code that solves the problem. No features beyond what was asked. No abstractions for single-use code. No configurability that wasn't requested. No error handling for impossible scenarios. If you wrote 200 lines and it could be 50, rewrite it.

## Surgical changes
- Touch only what's needed for the task. Don't improve adjacent code, comments, or formatting. Don't refactor things that aren't broken. Match existing style even if you'd do it differently. If you notice unrelated dead code, mention it - don't delete it. Every changed line should trace to the user's request.

## Workflow
- For non-trivial tasks: restate the goal, ask one clarifying question only if a major ambiguity would change the implementation, write a short plan (3-7 bullets), wait for approval, then implement.
- If multiple interpretations of the request exist, present them and ask - don't pick silently. Push back when a simpler approach exists or when something seems wrong.
- If the task is exploratory or prototyping, prefer speed and don't over-clarify; if the task is production code, follow the simplicity and surgical-change rules strictly.
- Commit small. One logical change per commit. Follow the project's commit format if one exists; otherwise use conventional commits (feat:, fix:, refactor:, etc.).
- When adding native Android changes, prefer `flutter build apk` over raw Gradle.
- When creating PRs via shell, avoid unescaped backticks in CLI body text.
- When you finish, summarize what changed in plain text - do not cat or re-print files.
- At the end of non-trivial sessions, suggest 1-3 additions to the project AGENTS.md based on mistakes or rediscoveries from this session.

---

## Rift Overview

Rift is a security-first, local-first, cross-platform device continuity platform. It uses a protocol-first development approach: `spec/doc/protocol.md` defines the intended peer contract, while production code on `main` and executable tests are the evidence baseline for current implementation status. When older documentation disagrees with the implemented baseline, reconcile the documentation explicitly rather than reporting stale behavior as current.

## Repository Layout

- `spec/doc/protocol.md` — the normative protocol specification (v0.1-draft). Start here.
- `spec/doc/ipc.md` — the normative local JSON-RPC IPC specification.
- `spec/decisions/` — Architecture Decision Records (ADRs), currently `0001-*` through `0013-*`. See `spec/decisions/README.md`.
- `spec/asn1/` — ASN.1 module definitions for the custom X.509 extension.
- `spec/vectors/` — deterministic test vectors for cross-implementation conformance.
- `spec/examples/` — example certificates and message flows.
- `spec/references/` — gitignored directory for local copies of RFCs and reference documents.
- `daemon-cs/` — Multi-platform daemon (C#/.NET 10). Includes `Rift.Daemon.Core` (shared library), `Rift.Daemon.Windows`, `Rift.Daemon.macOS`, `Rift.Daemon.Linux`, `Rift.Daemon.Tests`, and `Tools/`. Uses BouncyCastle.NET + native .NET crypto, StreamJsonRpc for IPC, SQLite via Microsoft.Data.Sqlite.
- `daemon-dart/` — Mobile daemon (Dart), hosted in an Android background isolate and in-process on iOS. Uses PointyCastle for crypto, native TLS bridges on mobile, JSON-RPC 2.0, and SQLite. Includes a purpose-built ASN.1 parser for X.509 extension extraction (security-critical component).
- `app-flutter/` — Single Flutter/Dart codebase targeting Android, iOS, Windows, macOS, and Linux. Material 3. One `JsonRpcRiftClient` consumes both daemon implementations via JSON-RPC 2.0.
- `tests-conformance/` — Cross-implementation protocol conformance tests (one harness, two daemons).
- `tests-interop/` — Cross-platform interop tests (C# daemon paired with Dart daemon end-to-end).
- `docs/` — Curated project documentation, documentation governance, and archive.

## Architecture

**Dual-daemon model:** Two independent daemon implementations conform to one protocol spec: the shared C#/.NET daemon family for Windows, macOS, and Linux, and the Dart mobile daemon for Android and iOS. Both are runnable as standalone console processes for dev/CI and are hosted according to platform constraints. The C# daemon uses a shared core library (`Rift.Daemon.Core`) with platform-specific entry points for IPC and service hosting; Flutter hosts the Dart daemon in a background isolate on Android and in-process on iOS.

**Dual-keypair identity:** Ed25519 for permanent device identity (fingerprint, device ID, trust store). ECDSA P-256 for TLS certificates. The Ed25519 public key is embedded in the P-256 cert via a custom X.509 extension (OID `2.25.293029629918709742181702189012786017422`).

**Trust state machine:** discovered → pairing_pending → trusted → blocked → revoked. Only `trusted` peers access protected operations. Revocation keeps negative-trust evidence.

**Transport-agnostic IPC:** JSON-RPC 2.0 between daemon and Flutter client. Named pipes on Windows, Unix domain sockets on macOS/Linux, SendPort/ReceivePort on Android, and an in-process channel on iOS. The Flutter UI never distinguishes transports.

**Windows runtime split:** Windows Service owns background core (discovery, trust, transport, persistence, event log). User-session Flutter process owns clipboard, tray, notifications — because Session 0 isolation prevents services from accessing user clipboard.

**Protocol term:** "Operation" is the protocol-level term for cross-device actions. Avoid unqualified "Intent" on Android to prevent collision with `android.content.Intent`.

## Protocol Conventions

- Wire framing: 4-byte big-endian length prefix + UTF-8 JSON object, max 32 MiB
- IDs (message, operation, offer, event): lowercase RFC 4122 UUIDv4
- Device ID format: `rift-` + first 32 chars of lowercase Base32(SHA-256(Ed25519 pubkey)), no padding
- Timestamps: RFC 3339 UTC (audit only). Durations/expiries: integer milliseconds with monotonic timers
- Failure reasons are a closed vocabulary (20 values in the current v0.1-draft implementation profile) — implementations must not invent new peer-visible reasons
- Unknown optional fields must be ignored; unknown `requiredExtensions` values must cause `ProtocolError`

## Documentation Rules

- Treat `README.md`, `AGENTS.md`, `spec/doc/*.md`, `spec/decisions/*.md`, curated files under `docs/`, and concise component `README.md` files as the canonical documentation surface.
- Current delivery status, roadmap, and task ownership live in GitHub Projects, not repo markdown.
