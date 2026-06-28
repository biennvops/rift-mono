# Interoperability Tests

This directory tracks recorded real-device interop evidence across the active
Rift platform pairs. The goal is to separate:

- code health and automated coverage
- real pairing/trust behavior observed on actual platform combinations

## Sign-off rule

Interop is considered complete for a platform pair only when both layers are
satisfied:

- **Code health:** platform transports, app analysis, and automated tests are green.
- **Interop evidence:** real-device pairing/trust behavior has been exercised and recorded.

This file tracks the second layer.

## Automated coverage in this directory

The Dart tests currently checked in under `tests-interop/test/` are a
lightweight harness around in-memory `SessionManager` instances from
`daemon-dart`. They are useful for:

- validating message-shape assumptions around presence updates
- exercising disconnect cleanup logic in a controlled environment
- keeping the Week 6 harness package alive in CI

They are **not** a substitute for real host-to-host or daemon-to-daemon interop
evidence, and they do not by themselves satisfy the sign-off matrix below.

## Latest update

- Date: 2026-06-24
- Branch: `kim-week5`
- Scope: Android <-> Linux pairing, trust transition, and IPC/app-state fixes;
  prior Windows <-> Android IPC readiness evidence retained below

## Platform-pair matrix

Legend:

- `PASS`: recorded and verified manually
- `PARTIAL`: some real-device evidence exists, but not enough for sign-off
- `READY`: code path is prepared, but no recorded real-device evidence yet
- `FAIL`: reproduced failure remains open
- `UNKNOWN`: not evaluated in this directory yet

| Pair | Transport / discovery readiness | Pairing A -> B | Pairing B -> A | Trust sync | Presence Sync | Notes |
| --- | --- | --- | --- | --- | --- | --- |
| Windows <-> Android | PARTIAL | UNKNOWN | UNKNOWN | UNKNOWN | UNKNOWN | Windows Flutter <-> `daemon-cs` IPC readiness verified; Android Flutter <-> `daemon-dart` IPC readiness verified; real peer discovery observed. Full pairing evidence still missing. |
| Linux <-> Android | PARTIAL | PARTIAL | PARTIAL | PARTIAL | UNKNOWN | Real pairing work was exercised on devices on 2026-06-23 and 2026-06-24. Both directions established secure sessions and reached `trusted` in active debugging, but the full regression matrix below is not yet recorded cleanly enough for sign-off. |
| macOS <-> Android | UNKNOWN | UNKNOWN | UNKNOWN | UNKNOWN | UNKNOWN | Week 6 expansion scope: Evaluate macOS launchd daemon with Android. |
| Linux <-> Windows | READY | UNKNOWN | UNKNOWN | UNKNOWN | UNKNOWN | Both sides now share the same C# pairing/session core, but no recorded real-device run is captured here yet. |

## Recorded evidence by platform

### Windows

- Windows Flutter <-> `daemon-cs`: PASS
  - Named pipe connection established successfully.
  - `rift.getDeviceInfo` returned populated values.
  - Settings / Debug screen loaded without infinite loading.
  - Trusted Devices screen loaded without crashes or IPC errors.

### Android

- Android Flutter <-> `daemon-dart`: PASS for IPC readiness
  - App launched on a physical Android device.
  - Daemon isolate reached ready state after transport fixes.
  - `rift.getDeviceInfo`, `rift.startDiscovery`, and `rift.stopDiscovery`
    succeeded in the verified run.

### Discovery

- Real peer discovery: PASS
  - Android/Windows observed a real peer in the discovered/trusted-device flow
    during manual verification.

### Linux

- Linux `daemon-cs` host readiness: PASS
  - Real IPC socket binding works.
  - mDNS advertising and discovery startup work.
  - TLS transport startup works.
  - Writable local state under the user data directory works.

## Linux <-> Android status

The Linux <-> Android path has moved past simple host readiness. The following
was observed during active manual debugging on 2026-06-23 and 2026-06-24:

- secure session establishment succeeded in both directions
- capability negotiation succeeded
- pairing request / approve flows reached the point where both sides could
  transition to `trusted`
- trust-state cleanup and IPC propagation bugs were identified and fixed during
  the run

However, this directory still does **not** contain a clean recorded pass for the
full manual matrix below, so Linux <-> Android remains `PARTIAL` rather than
fully signed off.

## Manual validation matrix still required for sign-off

The following runs still need a clean recorded result before Milestone M3 can be
considered complete for each relevant pair:

| Case | Windows <-> Android | Linux <-> Android | macOS <-> Android | Linux <-> Windows |
| --- | --- | --- | --- | --- |
| Pairing happy path A -> B | TODO | TODO | TODO | TODO |
| Pairing happy path B -> A | TODO | TODO | TODO | TODO |
| Reject flow | TODO | TODO | TODO | TODO |
| Cancel / timeout flow | TODO | TODO | TODO | TODO |
| Trust persistence after app / daemon restart | TODO | TODO | TODO | TODO |
| Revoke / untrust flow | TODO | TODO | TODO | TODO |
| Disconnect behavior after `trusted` | TODO | TODO | TODO | TODO |
| Disconnect behavior during `pairing_pending` | TODO | TODO | TODO | TODO |
| **Week 6:** Heartbeat latency within threshold | TODO | TODO | TODO | TODO |
| **Week 6:** Presence sync (offline to online) | TODO | TODO | TODO | TODO |
| **Week 6:** Presence sync (online to offline) | TODO | TODO | TODO | TODO |
| **Week 6:** Capability awareness (Unsupported op fails) | TODO | TODO | TODO | TODO |

## Current conclusion

Interop transport and discovery are validated well enough to support active
pairing work on real devices. Windows <-> Android has IPC readiness evidence.
Linux <-> Android has partial real pairing evidence from hands-on debugging, but
not yet a clean sign-off matrix. Linux <-> Windows remains code-ready but
unevaluated in this directory.

## Follow-up engineering work

These items are no longer milestone blockers, but they remain worthwhile
follow-ups after M3 if profiling or future regressions justify the work:

- Replace or reduce Windows named-pipe polling if power/CPU traces show overhead.
- Add deeper transport-level tests for Windows named pipes and Android isolate lifecycle.
