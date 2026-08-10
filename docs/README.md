# Documentation Index

This directory contains curated, durable documentation for the Rift repository.

Current implementation status, roadmap, and task ownership live in GitHub
Projects. Repo docs should explain stable architecture, constraints, and
reference material, not sprint history.

## Canonical Docs

- `../spec/doc/protocol.md` - normative peer protocol
- `../spec/doc/ipc.md` - normative local JSON-RPC IPC contract
- `../spec/decisions/README.md` - architecture decision record index
- `../AGENTS.md` - agent-facing repo guidance
- `macos-permissions.md` - focused platform notes for macOS runtime behavior
- `macOS`/`Windows`/`Linux` - useful tips and tricks for each platform
- `macOS/NotificationExtractor.md` - macOS Full Disk Access notification-extractor boundary
- `macOS/NotificationExtractorXpc.md` - authenticated extractor IPC prototype
- `Linux/NotificationObserver.md` - Linux session D-Bus notification-observer boundary

## Supporting Docs

- `../spec/asn1/README.md` - ASN.1 assets for the X.509 extension
- `../spec/vectors/README.md` - deterministic conformance vectors
- `clipboard-file-transfer-boundary.md` - implementation boundary and rollout order for clipboard, file transfer, and later continuity extensions
- `desktop-pair-runbook.md` - real two-machine desktop pair qualification procedure
- `../tests-conformance/README.md` - conformance harness overview
- `../tests-interop/README.md` - interoperability harness overview
- `../app-flutter/DESIGN.md` - Flutter design system guidance

## Governance

- `doc-taxonomy.md` - rules for canonical, supporting, and archival docs
