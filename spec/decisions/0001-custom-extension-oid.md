# ADR 0001: Custom Extension OID

## Status

Accepted

## Context

The Rift dual-keypair identity model requires embedding the Ed25519 public key inside the ECDSA P-256 X.509 certificate. This embedding uses a custom non-critical X.509 extension, which requires a globally unique OID. The OID must be stable across protocol versions and unambiguous across both daemon implementations.

Options considered: (1) Register under an IANA Private Enterprise Number arc — requires a PEN. (2) Use the ITU-T 2.25 UUID-derived arc (ITU-T Rec. X.667) — globally unique from a UUID without registration. (3) Use a private-use OID — risks collisions.

## Decision

Use OID `2.25.293029629918709742181702189012786017422` under the ITU-T 2.25 UUID-derived arc. The OID is derived from a UUIDv5 (SHA-1 name-based, version nibble `5`), within the valid set per ITU-T X.667. The extension is non-critical. The `extnValue` contains a DER-encoded OCTET STRING of exactly 32 bytes (the raw Ed25519 public key), producing the inner encoding `04 20 <32 bytes>`.

See protocol specification Sections 3.5, Appendix A, and Section 16.2 for the DER test vector.

## Consequences

- Both implementations must encode and parse this exact OID. The OID value bytes are `69 83 b8 f3 ba 8c ba bf ca d1 cd 9a ab f7 88 88 95 fb e9 0e` (20 bytes).
- Byte-level DER compatibility of the extension is a normative conformance requirement.
- The Dart daemon's custom ASN.1 parser must locate the extension by this OID and is a security-sensitive component.
- No formal OID registration is needed; the 2.25 arc is self-allocating from valid UUIDs.
