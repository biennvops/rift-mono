---
title: "Rift Monorepo Wiki Topic Guide"
schema_state: advisory
created: 2026-07-11
updated: 2026-07-11
summary: "Human-owned topic guide for Rift monorepo vocabulary and conventions."
---

# Rift Monorepo Wiki Topic Guide

> This is not a database schema and it does not make existing wiki content invalid.

## State

- `schema_state`: `advisory`

## Entity Types

| Type | Meaning |
|------|---------|
| `specification` | Normative protocol or IPC document. |
| `decision` | Architecture Decision Record that constrains implementation. |
| `implementation` | Concrete daemon, client, or test harness component. |
| `security-property` | Security invariant, threat mitigation, or trust rule. |
| `test-artifact` | Vector set, schema, fixture, or harness-level contract. |

## Relationship Verbs

- `cites`
- `supports`
- `contradicts`
- `supersedes`
- `depends-on`
- `implements`
- `tests`
- `constrains`

## Source Conventions

- Canonical sources are limited to the repo documentation surface defined in
  `AGENTS.md`, `README.md`, and `docs/wiki-ingestion.md`.
- `spec/doc/protocol.md` and `spec/doc/ipc.md` are normative before any daemon
  implementation note or derived article.
- ADRs under `spec/decisions/` define durable architecture choices and should
  be linked when explaining why behavior exists.
- Avoid ingesting `docs/archive/` unless the task is explicitly historical.
- Treat the Dart daemon ASN.1 parser and security-model material as
  high-scrutiny topics when compiling security-sensitive articles.
