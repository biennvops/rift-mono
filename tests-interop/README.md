# Interoperability Tests

This directory tracks recorded Windows <-> Android interop runs and the
remaining evidence required for Milestone M3 sign-off.

## Latest recorded run

- Date: 2026-06-22
- Branch: `kim-week5`
- Scope: Flutter app interop with platform daemons over real IPC transports

## Verified

- Windows Flutter <-> `daemon-cs`: PASS
  - Named pipe connection established successfully.
  - `rift.getDeviceInfo` returned populated values.
  - Settings / Debug screen loaded without infinite loading.
  - Trusted Devices screen loaded without crashes or IPC errors.
- Android Flutter <-> `daemon-dart`: PASS for IPC readiness
  - App launched on a physical Android device.
  - Daemon isolate reached ready state after transport fixes.
  - `rift.getDeviceInfo`, `rift.startDiscovery`, and `rift.stopDiscovery`
    succeeded in the verified run.
- Real peer discovery: PASS
  - Android/Windows observed a real peer in the discovered/trusted-device flow
    during manual verification.

## Not yet signed off

Milestone M3 is still pending final evidence for full pairing interoperability.
The following manual runs still need to be recorded in this directory before M3
can be marked complete:

- Pairing happy path end-to-end (Windows -> Android and Android -> Windows)
- Reject flow
- Cancel/timeout flow
- Trust persistence after app/daemon restart
- Revoke/untrust flow

## Current conclusion

Interop transport and discovery are now validated on real devices, but this
directory does not yet contain complete pairing evidence. Week 5 app-side IPC
work is in good shape; full M3 sign-off remains blocked on the remaining
pairing/trust validation runs above.
