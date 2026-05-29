# ADR 0009: mDNS Service Identity Disclosure

## Status

Accepted

## Context

mDNS-SD discovery records are broadcast before any authentication. The amount of information disclosed determines pre-authentication attack surface and device spoofing risk (CVE-2025-32900).

## Decision

Discovery records expose only the minimum metadata needed to initiate a TLS connection. Allowed: service type (`_rift._tcp`), TCP port, version hints (`minV`, `maxV`), optional device ID hint (`did`), optional fingerprint prefix (`fp`). Prohibited: device display names, icons, capability lists, trust state, clipboard metadata, any content exchanged only over authenticated channels.

The service type `_rift._tcp` is not registered with IANA per RFC 6763 §7. The nearby IANA registrations `rift-lies` (port 914) and `rift-ties` (port 915) are for the unrelated IETF RIFT protocol (RFC 9692) with no naming conflict.

See protocol specification Section 4.

## Consequences

- Attackers on the local network can see Rift daemons and approximate version but not device names, capabilities, or trust relationships.
- Users identify peers by device ID or fingerprint prefix, not display name.
- Directly addresses CVE-2025-32900 (unauthenticated device name spoofing).
