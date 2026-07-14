---
title: "Rift Monorepo Wiki"
description: "Local wiki for the Rift security-first device continuity monorepo."
created: 2026-07-11
freshness_threshold: 70
---

# Wiki Configuration

## Scope

This wiki covers the canonical documentation surface of the Rift monorepo:
protocol and IPC specifications, ADRs, curated repository docs, component
READMEs, and future synthesized articles derived from those sources.

## Conventions

- Prefer the written specifications under `spec/doc/` as the primary source of
  truth.
- Treat `docs/archive/` as historical context only, not active source material.
- Use `docs/wiki-input.txt` and `docs/wiki-ingestion.md` as the inclusion and
  exclusion contract for future ingestion work.
- Keep implementation status and roadmap claims out of wiki synthesis unless
  they are anchored in the canonical docs rather than GitHub Projects state.
