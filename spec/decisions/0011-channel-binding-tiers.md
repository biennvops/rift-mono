# ADR 0011: Three-Tier Channel Binding Hierarchy

## Status

Accepted

## Context

The protocol specification (Section 5.3.1) requires TLS channel binding via `tls-exporter` (RFC 9266), with `tls-unique` (RFC 5929) as a TLS 1.2 fallback. Both binding types require platform APIs that expose TLS session internals.

Neither target platform fully satisfies the preferred requirement:

- **Dart (`dart:io`)**: `SecureSocket` does not expose `tls-exporter`, `tls-unique`, or any channel binding primitive. The tracking issue `dart-lang/sdk#49581` remains open with no indication of progress. The Dart daemon currently uses a non-conforming Application Nonce fallback.
- **C# (.NET `SslStream`)**: Exposes `ChannelBindingKind.Unique` (`tls-unique`) but not `tls-exporter`. The API proposal `dotnet/runtime#112529` for `ExportKeyingMaterial` is still in `api-suggestion` status and did not ship in .NET 10. On macOS, even `tls-unique` may be unavailable depending on the Secure Transport backend.

The native FFI escape hatch (calling BoringSSL's `SSL_export_keying_material` or Schannel's `SECPKG_ATTR_KEYING_MATERIAL` directly) is technically feasible but architecturally expensive: the platform TLS wrappers do not expose their underlying `SSL*` / security context handles, so the FFI route requires managing the entire TLS handshake natively rather than bolting an exporter onto the existing managed socket.

The result is that the two daemon implementations use incompatible channel binding methods — C# uses `tls-unique`, Dart uses an Application Nonce — and cannot interoperate during the PoP handshake. The Dart signing input format also diverges (113 bytes with length prefixes vs. the spec's 107-byte raw concatenation).

## Decision

The specification adopts a three-tier channel binding hierarchy with mandatory negotiation:

| Tier | Method | Binding type string | Source | Per-session | TLS-bound |
|------|--------|---------------------|--------|-------------|-----------|
| 1 | `tls-exporter` (RFC 9266) | `tls-exporter` | TLS keying material export | Yes | Yes |
| 2 | `tls-unique` (RFC 5929) with EMS | `tls-unique` | TLS Finished message | Yes | Yes |
| 3 | Mutual Application Nonce | `app-nonce` | Both peers' 32-byte random nonces | Yes | No |

Tier selection rules:

1. Each peer includes a `bindingType` field in `session.hello` and `session.accept` indicating the tier it used for its PoP signature.
2. Implementations MUST use the highest tier available on their platform.
3. A verifier MUST accept any tier at or above its own minimum — i.e., a Tier 2 implementation MUST accept Tier 1 proofs from peers. All implementations MUST accept Tier 3.
4. The `bindingType` field is REQUIRED. A message without it MUST be rejected with `AuthenticationFailed`.

### Tier 3 Construction

When neither `tls-exporter` nor `tls-unique` is available:

1. The signer generates a cryptographically random 32-byte `sessionNonce`.
2. The signer includes `sessionNonce` (base64-encoded) in its `session.hello` or `session.accept` payload.
3. Both peers compute the channel binding value as:

```
channelBinding = SHA-256(signerNonce || signerCertDER || verifierCertDER)
```

The concatenation order is always from the signer's perspective: the signer's nonce, the signer's certificate, then the peer's certificate. The verifier reconstructs the same input by reversing its local/peer roles.

### Signing Input Alignment

All tiers use the same 107-byte signing input format defined in Section 5.3.1 (raw concatenation, no length prefixes):

```
RiftPoP-v2: || channelBinding[32] || ed25519PubKey[32] || SHA-256(certDER)[32]
```

Length prefixes are unnecessary because all fields are fixed-size.

## Consequences

- Both daemon implementations can interoperate immediately using Tier 3.
- The Dart `pop_manager.dart` signing input must be aligned to the spec's 107-byte format (remove 2-byte length prefixes).
- The C# daemon must implement Tier 3 negotiation as a fallback for interop with Dart and for macOS environments where `tls-unique` may be unavailable.
- Tier 3 does not bind the PoP signature to the TLS session itself. The residual risk is documented: an active MitM who controls the TLS layer could inject their own nonce. This risk is mitigated by Rift's use of self-signed pinned certificates — post-pairing, a TLS-layer MitM requires compromising a device's private ECDSA key, at which point stronger attacks are available anyway.
- When Dart or .NET gains `tls-exporter` support, implementations should upgrade to Tier 1 with no protocol changes required — only the `bindingType` value changes.
- The `sessionNonce` field is only present when `bindingType` is `app-nonce`. Implementations MUST ignore it for other binding types.
