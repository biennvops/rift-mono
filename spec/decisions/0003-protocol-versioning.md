# ADR-0003: Protocol versioning

Status: proposed

Decision: Adopt semantic-like versioning for protocol profiles; v0.1-draft is initial.
# ADR 0003: Protocol Versioning

## Status

Accepted

## Context

The protocol needs a versioning scheme from day one to support future evolution and version negotiation between peers. KDE Connect's CVE-2025-66270 affected "protocol version 8" — having a version number enabled them to issue a fixed version.

Considerations: version string format, negotiation mechanism, backward compatibility rules, and when version negotiation occurs relative to TLS establishment.

## Decision

Protocol versions are string identifiers. The initial version is `0.1-draft`.

Version negotiation occurs during session establishment: `session.hello` includes a `supportedVersions` array, and `session.accept` confirms the `selectedVersion`. The selected version is the highest mutually supported version. If no mutually supported version exists, the session fails with `VersionMismatch`.

Discovery advertises `minVersion` and `maxVersion` as unauthenticated hints only. Authoritative version negotiation occurs over the encrypted TLS channel.

See protocol specification Sections 1 and 6.

## Consequences

- Every peer message carries a `rift` field with the protocol version string.
- Version negotiation adds one round-trip during session establishment but ensures both peers agree before exchanging protected messages.
- Future protocol versions can be introduced without breaking existing peers, as long as one mutually supported version exists.
- The string format allows semantic qualifiers like `draft` without encoding version semantics into the protocol itself.
