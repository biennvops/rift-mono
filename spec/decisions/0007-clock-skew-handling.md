# ADR 0007: Clock Skew Handling

## Status

Accepted

## Context

The protocol uses time for clipboard offer expiry (TTL) and presence tracking. Devices on the same local network may have significantly skewed wall clocks. Options: (1) Relative TTLs with monotonic timers. (2) Absolute timestamps requiring clock synchronization. (3) Hybrid.

## Decision

Durations and expiries use integer milliseconds interpreted with local monotonic timers. Wall-clock timestamps are RFC 3339 UTC and are audit-only — they MUST NOT be used for protocol state decisions.

See protocol specification Section 1.

## Consequences

- Clock skew between devices does not affect protocol correctness.
- Audit timestamps may show minor inconsistencies between devices, acceptable for debugging.
- Presence offline detection uses configurable monotonic timeout thresholds.
- No NTP synchronization or clock-tolerance negotiation is needed.
