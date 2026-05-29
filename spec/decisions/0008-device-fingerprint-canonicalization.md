# ADR 0008: Device Fingerprint Canonicalization

## Status

Accepted

## Context

The pairing fingerprint must be deterministically derived from the Ed25519 public key so both devices and both daemon implementations produce identical fingerprints. The derivation must be unambiguous.

## Decision

The fingerprint derivation: (1) Take raw 32-byte Ed25519 public key. (2) Compute SHA-256. (3) Encode as Base32 per RFC 4648, strip padding, uppercase. (4) Truncate to 32 characters. (5) Format as eight groups of four separated by hyphens. Example: `CPGW-O6WE-FDKX-WXFU-GSVC-JBWJ-6MHP-4GFQ`.

The device ID uses the same digest but with lowercase Base32 and `rift-` prefix.

See protocol specification Sections 3.1, 3.2, and 15.1.

## Consequences

- Both device ID and fingerprint derive from the same SHA-256 digest.
- 32 Base32 characters (160 bits) provides strong brute-force resistance — addresses CVE-2025-32898.
- Base32 alphabet (A-Z, 2-7) avoids ambiguous characters.
- Implementations must use RFC 4648 Base32 exactly (not Base32hex) and strip padding before truncation.
