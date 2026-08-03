# Rift

Rift is a security-first, local-first, cross-platform device continuity platform.

This repository is protocol-first: the specifications define the intended wire
and IPC contracts. For current implementation status, production code on
`main` and its executable tests are the evidence baseline; stale specification
or README text must be reconciled to the implemented behavior.

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
- `daemon-dart/` - shared mobile daemon implementation in Dart, hosted in an
  Android background isolate and in-process on iOS
- `app-flutter/` - Flutter client and transport-agnostic JSON-RPC consumer
- `tests-conformance/` - declarative protocol vectors with an executable Dart
  runner and a pending C# runner
- `tests-interop/` - in-memory Dart interoperability tests plus desktop/mobile
  runbook material
- `docs/` - curated project documentation

## Documentation Rules

The canonical documentation surface for engineers and agents is:

- `README.md`
- `AGENTS.md`
- `spec/doc/*.md`
- `spec/decisions/*.md`
- curated files under `docs/`
- concise component `README.md` files
