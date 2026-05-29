# ADR 0006: Pairing Flow Transport

## Status

Accepted

## Context

The pairing flow must establish mutual trust between two discovered devices. Options: (1) Pairing over mutual TLS — simplest, TLS handshake provides ephemeral key agreement. (2) Separate custom ECDH channel — complex, new attack surface. (3) Provisional one-sided TLS — requires additional bootstrap steps.

## Decision

Pairing occurs over mutual TLS. There is no separate custom key exchange outside TLS. Both peers present ECDSA P-256 self-signed certificates during the TLS handshake. After the handshake, each peer extracts the Ed25519 public key from the other's certificate extension and derives the fingerprint. Both users confirm the matching fingerprint before the peer enters `trusted` state. For pairing candidates, the TLS layer MAY provisionally accept the self-signed certificate only to complete the handshake. Before pairing completes, only session and pairing messages are permitted.

See protocol specification Sections 5.1, 5.2, and 8.

## Consequences

- No separate "ephemeral key exchange" protocol is needed — TLS provides this.
- The security model is simpler to analyze: standard mutual TLS plus explicit fingerprint verification.
- The fingerprint is derived from the full 32-byte Ed25519 public key, directly addressing CVE-2025-32898.
