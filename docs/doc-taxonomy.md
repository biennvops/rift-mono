# Documentation Taxonomy

Rift uses three documentation classes.

## Canonical

Canonical docs are current source of truth. They must be stable, durable, and
safe for agent ingestion.

Includes:

- `README.md`
- `AGENTS.md`
- `spec/doc/*.md`
- `spec/decisions/*.md`
- curated docs under `docs/`
- concise component `README.md` files

Canonical docs should contain:

- architecture and behavior that are expected to remain true
- normative protocol or API statements
- stable run/test entrypoints
- links to deeper reference material

Canonical docs should not contain:

- week-by-week progress logs
- frozen local verification snapshots
- task ownership or sprint status
- review notes or one-off planning content

## Supporting

Supporting docs are useful reference material but not the primary source of
truth.

Examples:

- `spec/asn1/README.md`
- `spec/vectors/README.md`
- `spec/examples/README.md`
- `tests-conformance/README.md`
- `tests-interop/README.md`
- `app-flutter/DESIGN.md`

They may describe structure, workflows, and constraints, but should defer
normative statements to the spec and ADR layers.

## Archival

Archival docs are retained historical context and must not be treated as
current guidance.

Examples:

- plans
- spike reports
- code reviews
- milestone notes
- audit writeups

Archival material lives under `docs/archive/` and should be clearly labeled as
non-canonical.
