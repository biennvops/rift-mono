# ADR 0010: JSON-RPC Error Model

## Status

Accepted

## Context

Rift has two error boundaries: (1) peer protocol errors using the 15 typed failure reasons from Section 14, and (2) IPC errors between daemon and Flutter client using JSON-RPC 2.0 error objects. The model must bridge these boundaries without losing type information.

## Decision

IPC errors use the standard JSON-RPC 2.0 error object. Standard JSON-RPC errors use the reserved range `-32700` to `-32600`. Rift application errors use `-32000` to `-32099`, with each protocol failure reason mapped to a specific code (e.g., `-32000` = `PeerUnreachable`, `-32004` = `Unauthorized`). IPC-only errors use codes in the same range (e.g., `-32009` = `NotFound`, `-32012` = `IdentityNotInitialized`). The `data` field MAY carry diagnostics but MUST NOT contain private keys or clipboard content.

See IPC API Specification (`ipc.md`) Section 3.

## Consequences

- The Flutter client can distinguish protocol-originated from IPC-layer errors by code.
- Protocol failure reasons are preserved across the IPC boundary.
- The code range provides room for future application errors without JSON-RPC collisions.
- Both daemon implementations must map failure reasons to the same IPC error codes.
