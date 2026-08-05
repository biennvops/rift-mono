# Rift Project Context

Rift is a security-first, local-first, cross-platform device continuity platform. It follows a protocol-first model: `spec/doc/protocol.md` is authoritative, and both daemon implementations must conform independently.

## Agent Verification

- Run `tools/verify.sh <daemon-cs|daemon-dart|app-flutter|tests-conformance|tests-interop|changed|all>` from the repository root.
- The script prints concise status/errors and overwrites complete logs under `logs/agent/`. `changed` uses the `origin/main` merge base; override with `RIFT_VERIFY_BASE`. Override the log directory with `RIFT_AGENT_LOG_DIR`.
- Inspect logs with focused `rg` or `tail` commands; never dump an entire log into the agent conversation.

## Canonical Sources

- `spec/doc/protocol.md` — normative peer protocol specification; start here for protocol or security changes.
- `spec/doc/ipc.md` — normative local JSON-RPC IPC specification.
- `spec/decisions/` — architecture decision records and their index.
- `spec/vectors/` — deterministic cross-implementation test vectors.

## Repository Map

- `daemon-cs/` — shared C#/.NET daemon core, desktop platform hosts, tests, and tools.
- `daemon-dart/` — Dart daemon used by Android and shared mobile flows.
- `app-flutter/` — cross-platform Flutter client consuming daemon JSON-RPC IPC.
- `tests-conformance/` — protocol conformance harness.
- `tests-interop/` — cross-platform interoperability harness and procedures.
- `docs/` — curated project documentation and governance.

## Architecture Constraints

- Keep the C# desktop daemon family and Dart Android daemon as independent implementations of the same protocol.
- Keep Flutter daemon access transport-agnostic; UI code must not branch on named pipes, Unix sockets, or mobile in-process transports.
- On Windows, the service owns background core behavior while the user-session process owns clipboard, tray, and notification integration.
- Use "Operation" for cross-device protocol actions; avoid unqualified "Intent" because of Android terminology.

## Documentation

- Treat `README.md`, `AGENTS.md`, `spec/doc/*.md`, `spec/decisions/*.md`, curated `docs/` files, and concise component `README.md` files as the canonical documentation surface.
- Current delivery status, roadmap, and task ownership belong in GitHub Projects, not repository markdown.
