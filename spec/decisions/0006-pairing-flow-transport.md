# ADR 0006: Pairing Flow Transport

## Status

Accepted

## Context

The pairing flow must establish mutual trust between two discovered devices. Options: (1) Pairing over mutual TLS — simplest, TLS handshake provides ephemeral key agreement. (2) Separate custom ECDH channel — complex, new attack surface. (3) Provisional one-sided TLS — requires additional bootstrap steps.

## Decision

Pairing occurs over mutual TLS. There is no separate custom key exchange outside TLS. Both peers present ECDSA P-256 self-signed certificates during the TLS handshake. After the handshake, each peer extracts the Ed25519 public key from the other's certificate extension and verifies Ed25519 Proof of Possession (protocol specification Section 5.3) via the `identityProof` field in `session.hello`. This proves the peer holds the Ed25519 private key, not just the public key embedded in the certificate. Both users confirm the matching fingerprint before the peer enters `trusted` state. For pairing candidates, the TLS layer MAY provisionally accept the self-signed certificate only to complete the handshake. Before pairing completes, only session and pairing messages are permitted.

See protocol specification Sections 5.1, 5.2, and 8.

## Consequences

- No separate "ephemeral key exchange" protocol is needed — TLS provides this.
- The security model is simpler to analyze: standard mutual TLS plus Ed25519 Proof of Possession plus explicit fingerprint verification.
- The fingerprint is derived from the full 32-byte Ed25519 public key, directly addressing CVE-2025-32898.
- Ed25519 PoP prevents identity misbinding attacks where an attacker embeds a victim's Ed25519 public key in their own ECDSA certificate.
