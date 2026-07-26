# Architecture Decision Records

This directory contains Rift architecture decision records. ADRs capture
decisions that shape the protocol, IPC boundary, and implementation structure.

## Index

- `0001-custom-extension-oid.md` - custom X.509 extension OID for Ed25519 identity binding
- `0002-tls-version-policy.md` - TLS version policy and allowed fallback behavior
- `0003-protocol-versioning.md` - protocol versioning model
- `0004-intent-naming.md` - use `Operation` rather than unqualified `Intent`
- `0005-clipboard-offer-hash-purpose.md` - purpose of clipboard offer hashing
- `0006-pairing-flow-transport.md` - pairing flow transport model
- `0007-clock-skew-handling.md` - clock-skew handling for audit and expiry semantics
- `0008-device-fingerprint-canonicalization.md` - canonical fingerprint derivation
- `0009-mdns-service-identity-disclosure.md` - discovery identity disclosure policy
- `0010-json-rpc-error-model.md` - transport-agnostic JSON-RPC error model
- `0011-channel-binding-tiers.md` - channel-binding tier hierarchy
- `0012-mobile-native-tls-transport.md` - native TLS transport for mobile pairing

## Usage

- Treat accepted ADR decisions as part of the reference architecture.
- If an ADR conflicts with a README, the ADR and the specs win.
- If an ADR conflicts with `spec/doc/protocol.md` or `spec/doc/ipc.md`, update
  the stale document so the canonical surface is consistent.
