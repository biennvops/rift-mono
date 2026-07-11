# Rift

Rift is a security-first, local-first, cross-platform device continuity platform.

This repository is protocol-first. The written specifications are the source of
truth; daemon implementations and the Flutter client are expected to conform to
them.

## Start Here

- Protocol specification: `spec/doc/protocol.md`
- Local IPC specification: `spec/doc/ipc.md`
- ADR index: `spec/decisions/README.md`
- Documentation index: `docs/README.md`
- Agent guidance: `AGENTS.md`

Current delivery status, roadmap, and task ownership live in GitHub Projects,
not in repo markdown.

## Repository Layout

- `spec/` - normative protocol, IPC, ADRs, ASN.1, vectors, and examples
- `daemon-cs/` - shared C#/.NET daemon core with Windows, macOS, and Linux hosts
- `daemon-dart/` - Android daemon implementation in Dart
- `app-flutter/` - Flutter client and transport-agnostic JSON-RPC consumer
- `tests-conformance/` - cross-implementation protocol conformance harness
- `tests-interop/` - interoperability harness and runbook material
- `docs/` - curated project documentation

## Documentation Rules

The canonical documentation surface for engineers and agents is:

- `README.md`
- `AGENTS.md`
- `spec/doc/*.md`
- `spec/decisions/*.md`
- curated files under `docs/`
- concise component `README.md` files

Historical plans, reviews, milestone notes, and audit writeups are archived
under `docs/archive/` and are not current source of truth.
