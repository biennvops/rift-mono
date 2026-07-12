---
title: "Rift Canonical Documentation Surface"
source: "docs/wiki-ingestion.md"
type: repos
ingested: 2026-07-11
tags: [manifest, ingestion, governance]
summary: "Defines the canonical include and exclude boundaries for future wiki ingestion in the Rift monorepo."
---

# Rift Canonical Documentation Surface

This raw manifest records the canonical source boundary for this local wiki.
Future ingest operations should prefer `docs/wiki-input.txt` as the explicit
path manifest when a file list is needed.

## Include

- `README.md`
- `AGENTS.md`
- `docs/README.md`
- `docs/doc-taxonomy.md`
- `docs/wiki-ingestion.md`
- `docs/capstone-register.md`
- `docs/known-issues.md`
- `docs/macos-permissions.md`
- `spec/doc/protocol.md`
- `spec/doc/ipc.md`
- `spec/decisions/README.md`
- `spec/decisions/0001-custom-extension-oid.md`
- `spec/decisions/0002-tls-version-policy.md`
- `spec/decisions/0003-protocol-versioning.md`
- `spec/decisions/0004-intent-naming.md`
- `spec/decisions/0005-clipboard-offer-hash-purpose.md`
- `spec/decisions/0006-pairing-flow-transport.md`
- `spec/decisions/0007-clock-skew-handling.md`
- `spec/decisions/0008-device-fingerprint-canonicalization.md`
- `spec/decisions/0009-mdns-service-identity-disclosure.md`
- `spec/decisions/0010-json-rpc-error-model.md`
- `spec/decisions/0011-channel-binding-tiers.md`
- `spec/asn1/README.md`
- `spec/examples/README.md`
- `spec/vectors/README.md`
- `tests-conformance/README.md`
- `tests-conformance/schema.md`
- `tests-interop/README.md`
- `daemon-cs/README.md`
- `daemon-dart/README.md`
- `app-flutter/README.md`
- `app-flutter/DESIGN.md`

## Exclude

- `docs/archive/**`
- Root-level scratch notes or ad hoc review docs.
- Generated platform output and package-manager caches.
- Any future markdown that mirrors status or roadmap state from GitHub Projects.
