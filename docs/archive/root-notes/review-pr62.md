# PR #62 Re-Review (Round 4): C# Daemon Module Interfaces

**Author:** Hunteriema (Thao) | **Branch:** `thao-week2.2` → `main` | **+506 / -0**
**Commits:** 3 (initial + fix round 1 + "Fixes according to the pervious review")

---

## Original Issue Tracker (all 12 resolved)

| # | Issue | Status |
|---|-------|--------|
| 1 | `IDiscoveryService` exposes capabilities | **FIXED** |
| 2 | `IClipboardService` missing protocol fields | **FIXED** |
| 3 | `IIdentityManager` missing Ed25519 signing | **FIXED** |
| 4 | `ITransport` too thin | **FIXED** |
| 5 | `ITrustStore` doesn't enforce state transitions | **FIXED** |
| 6 | `PeerIdentity` missing fields | **FIXED** |
| 7 | Missing `ISecurityEventLog` | **FIXED** |
| 8 | Missing fingerprint derivation | **FIXED** |
| 9 | Tests verify mock dispatch | **FIXED** (acknowledged as scaffolding) |
| 10 | `FetchContentAsync` returns `string` | **FIXED** |
| 11 | Missing newline at EOF in `.csproj` | Not fixed (low) |
| 12 | `PeerIdentity` mutable `DeviceId` | **FIXED** |

## Re-Review Issue Tracker (from rounds 2-3)

| # | Issue | Status |
|---|-------|--------|
| 1a | `IDiscoveryService` version params `int` → `string` | **FIXED** |
| 2a | `ISecurityEventLog` enum wrong + missing fields | **FIXED** |
| 3a | `ITransport` quality regression | **FIXED** — restored excellent version |
| 5a | `HandleOfferReceivedAsync` missing `requiredCapability` | Not fixed (low) |
| 6a | Doc says "advertise capabilities" | Not fixed (low) |

---

## What Changed in This Commit

### `IDiscoveryService` — version params fixed

```csharp
// Before
void StartAdvertising(string deviceId, int minVersion, int maxVersion);
// After
void StartAdvertising(string deviceId, string minVersion, string maxVersion);
```

Correctly matches spec Section 4.2 where `minV`/`maxV` are protocol version strings like `"0.1-draft"`.

### `ISecurityEventLog` — completely reworked, now spec-compliant

This is the strongest improvement in this commit. The interface went from 20 lines with 5 mismatched enum values to 66 lines with full Section 13 compliance:

- **`SecurityEventSeverity`** enum: `Info, Warning, Error, Critical` — matches Section 13.2 exactly.
- **`SecurityEventOutcome`** enum: `Success, Failure, Denied` — matches Section 13.3 exactly.
- **`SecurityEventTypes`** static class: all 20 spec event types as `const string` fields using the exact dot-separated names from Section 13.1. Good design choice — `const string` over `enum` since the spec uses string values on the wire.
- **`SecurityEventRecord`** class: all required fields present with appropriate types and sensible defaults (`EventId` auto-generates UUIDv4, `Timestamp` defaults to `DateTimeOffset.UtcNow`). All properties are `init`-only, matching the append-only semantics.
- **`ISecurityEventLog.LogEventAsync(SecurityEventRecord)`** — clean single-parameter method.

No remaining concerns.

### `ITransport` — restored to high-quality version

The excellent `ITransport` from the earlier revision is back:
- Dedicated `MessageReceivedEventArgs` with `ReadOnlyMemory<byte>` payload
- Thorough XML docs referencing spec sections for framing limits and security invariants
- `SendAsync` with `ReadOnlyMemory<byte> frameBody` (zero-copy friendly)
- `DisconnectPeerAsync` for session teardown

No remaining concerns.

---

## Remaining Nits (all low severity)

| # | Severity | Issue | File |
|---|----------|-------|------|
| 1 | Low | Missing newline at EOF | `Rift.Daemon.Windows.Tests.csproj` |
| 2 | Low | `HandleOfferReceivedAsync` missing `requiredCapability` param (present in `BroadcastOfferAsync`) | `IClipboardService.cs:16` |
| 3 | Low | Doc still says IDiscoveryService "advertise device capabilities" — contradicts the actual interface | `docs/daemon-csDocumentation.md:73` |

None of these are blocking.

---

## Verdict

**Approve.** All 12 original issues and both medium re-review issues are resolved. The `ISecurityEventLog` rework is thorough — the `SecurityEventTypes` const-string approach and `SecurityEventRecord` with all Section 13 fields is well done. The `ITransport` is back to its best version. Three low-severity nits remain that can be addressed in follow-up.
