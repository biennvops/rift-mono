# Wiki Ingestion Contract

Future wiki builders should ingest only the canonical and selected supporting
documentation surface.

Use `docs/wiki-input.txt` as the explicit include manifest when the builder can
accept a file list.

## Include

- `README.md`
- `AGENTS.md`
- `docs/README.md`
- `docs/doc-taxonomy.md`
- `docs/known-issues.md`
- `docs/capstone-register.md`
- `docs/macos-permissions.md`
- `spec/doc/**`
- `spec/decisions/**`
- `spec/asn1/README.md`
- `spec/vectors/README.md`
- `spec/examples/README.md`
- `tests-conformance/README.md`
- `tests-conformance/schema.md`
- `tests-interop/README.md`
- `daemon-cs/README.md`
- `daemon-dart/README.md`
- `app-flutter/README.md`
- `app-flutter/DESIGN.md`

## Exclude

- `docs/archive/**`
- root-level scratch notes or review docs if any appear later
- `dist/**`
- `spec/vectors/.venv/**`
- generated platform output and package-manager caches
- any future status mirror that duplicates GitHub Projects

## Placement Rule

When adding a new document:

- put it in the canonical surface only if it is durable reference material
- put it in `docs/archive/` if it is a plan, review, spike, or dated status log
- avoid storing active roadmap/status in markdown when GitHub Projects is the
  real source of truth
