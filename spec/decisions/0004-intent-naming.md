# ADR 0004: Intent Naming

## Status

Accepted

## Context

The project originally used "Intent" for cross-device actions. Android has a first-class `android.content.Intent` class used for IPC, creating naming confusion in the Kotlin platform-channel shim and code review.

## Decision

The protocol-level term is "Operation." The protocol specification, IPC API, and both daemon implementations use "Operation" exclusively. "Intent" is retained only as a historical synonym in documentation. On Android, implementations SHOULD avoid unqualified `Intent` names to prevent confusion with `android.content.Intent`.

See protocol specification Sections 2 and 10.

## Consequences

- The operation lifecycle uses `operation.*` message types and `operationId` fields.
- The IPC API uses `rift.listOperations` and `rift.getOperation`.
- No `Intent` type name appears in implementation code.
- Existing documents using "Intent" should be read as synonymous with "Operation."
