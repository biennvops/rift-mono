# ADR 0005: Clipboard Offer Hash Purpose

## Status

Accepted

## Context

Clipboard offers carry a `sha256` field. Its purpose could be integrity verification after fetch, deduplication, or offer identity — each implying different algorithm requirements and security properties.

## Decision

The clipboard hash is SHA-256 over the exact raw bytes before Base64 encoding. Its primary purpose is **integrity verification after fetch**. A receiver MUST verify both `byteSize` and `sha256` after decoding `contentBase64`. A mismatch fails with `HashMismatch` and MUST be logged.

See protocol specification Sections 3.3 and 11.

## Consequences

- SHA-256 is mandatory; implementations cannot substitute a weaker hash.
- The hash protects against content tampering by a compromised-but-trusted peer.
- The hash is computed over raw bytes, not Base64, so both sides must agree on pre-encoding content.
- Deduplication can use the same hash as a secondary benefit.
