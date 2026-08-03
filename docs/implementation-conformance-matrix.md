# Implementation and Conformance Matrix

This document records durable implementation boundaries and the evidence needed
to interpret Rift test results. It is not a roadmap or sprint tracker. Update it
whenever a platform binding, capability version, or verification surface
changes.

For current-state project reports, production code on `main` and its executable
tests are the implementation baseline. Protocol, IPC, ADR, and README text must
be updated when older wording disagrees with that baseline. Normative language
still defines the intended contract after it has been reconciled with the
current implementation.

## Evidence Levels

- **Implemented**: production code and focused automated tests exist.
- **Live-tested**: a real-device or real-machine run is recorded in the
  interoperability runbooks.
- **Limited**: implementation exists, but the operating system or current
  product surface prevents full bidirectional behavior.
- **Gap**: a normative or cross-implementation verification obligation is not
  yet satisfied.

Automated tests prove the exercised code paths; they do not replace
real-device qualification for native TLS, permissions, background lifecycle,
notification access, media integration, or cross-machine discovery.

## Daemon and IPC Bindings

| Platform | Daemon host | Local IPC | Identity protection |
| --- | --- | --- | --- |
| Windows | C# Windows Service plus user-session Flutter client | Named pipe | Windows platform protection in the C# host |
| macOS | C# launchd host plus user-session Flutter client | Unix domain socket | macOS platform-backed C# identity storage |
| Linux | C# systemd user service plus Flutter client | Unix domain socket | Secret Service when available, with permission-restricted file fallback |
| Android 10+ | Dart daemon in foreground-service/background isolate | `SendPort`/`ReceivePort` bridge | Android Keystore bridge |
| iOS 13+ | Dart daemon hosted in the Flutter application process | In-process JSON-RPC channel | iOS Keychain bridge |

Android and iOS peer TLS use native mobile bridges. Desktop peer TLS is owned
by the C# daemon family.

## Capability Versions

| Capability | C# daemon | Dart daemon | Contract status |
| --- | ---: | ---: | --- |
| `clipboard.offer_fetch` | 1 | 1 | Required clipboard-first capability |
| `file.transfer` | 2 | 1 | Optional; negotiation falls back to v1 for C#↔Dart sessions |
| `media.playback` | 1 | 1 | Optional |
| `notification.sync` | 1 | 1 | Optional |
| `presence.basic` | 1 | 1 | Required clipboard-first capability |
| `operation.lifecycle` | 1 | 1 | Required clipboard-first capability |
| `security.event_log` | 1 | 1 | Required clipboard-first capability |

`file.transfer@2` adds receiver-confirmed publication and daemon-backed desktop
send-queue/commit IPC. Mobile sessions currently use v1 completion semantics.

## Platform Capability Surface

| Surface | Windows | macOS | Linux | Android | iOS |
| --- | --- | --- | --- | --- | --- |
| Discovery, pairing, trust, reconnect | Implemented; desktop live runs recorded | Implemented; desktop live runs recorded | Implemented; desktop live runs recorded | Implemented; Android↔iOS live run recorded | Implemented; Android↔iOS live run recorded |
| Text and PNG clipboard | Implemented and live-tested | Implemented and live-tested | Implemented and live-tested | Implemented; Android↔iOS live-tested | Implemented; explicit user action required; Android↔iOS live-tested |
| File send/receive | Implemented; v2 desktop publication | Implemented; v2 desktop publication | Implemented; v2 desktop publication | Implemented with v1 semantics | Implemented with v1 semantics and iOS document export |
| Notification publishing | No configured OS notification observer in recorded runs | Implemented through Full Disk Access extractor; removal lifecycle is limited | No local notification observer | Implemented through notification-listener permission | Limited: cannot read other applications' notifications |
| Mirrored notification consumption | Implemented UI/native notification path | Implemented UI/native notification path | Implemented UI/native notification path | Implemented | Implemented |
| Media publishing and remote control | No system media publisher confirmed in the recorded Windows run | Implemented through the documented MediaRemote adapter | Implemented through MPRIS | Implemented through Android media sessions | Limited: cannot read unrelated applications' now-playing state |
| Background runtime | Windows Service plus user-session app split | launchd daemon plus user-session app/extractor | systemd user daemon plus user-session app | Foreground service | Limited by normal iOS application suspension rules |

The platform rows state implementation boundaries, not universal real-device
sign-off. Consult `desktop-pair-runbook.md` and
`../tests-interop/mobile-device-matrix.md` for recorded executions.

## Automated Verification Surface

| Layer | Current evidence | Interpretation |
| --- | --- | --- |
| C# daemon | Core, storage, trust, TLS, pairing, clipboard, file, notification, media, Linux/macOS integration tests | Strong implementation-level coverage for the shared desktop daemon family |
| Dart daemon | Crypto, fail-closed decoder, trust, session, pairing, clipboard, file, notification, media tests | Strong implementation-level coverage for the shared mobile daemon |
| Flutter client | IPC, transport, UI, queue, platform-bridge and iOS behavior tests | Strong client behavior coverage; native OS behavior still needs device runs |
| Desktop live transport | C# loopback stacks plus recorded Windows/macOS/Linux machine pairs | Does not prove every OS pair on every current build |
| Mobile live transport | Recorded Android↔iOS run for discovery, pairing, restart, clipboard, and file transfer | Android↔Android and iOS↔iOS remain unrecorded |
| Declarative conformance vectors | Dart runner executes the shared vectors | C# runner is a skeleton; cross-implementation vector parity is a gap |
| `tests-interop` package | Two in-memory Dart daemon stacks | Not a C#↔Dart end-to-end harness |

## Known Verification and Product Gaps

1. The C# declarative conformance runner is not implemented; CI only executes
   the Dart vector runner.
2. There is no automated C#↔Dart end-to-end interop job despite the directory's
   cross-implementation purpose.
3. Android↔Android and iOS↔iOS real-device matrices have no recorded run.
4. The recorded Android↔iOS run still lacks presence, notification, media, and
   overnight Android background-soak results.
5. The user-facing block action is not available across the product even though
   block enforcement and unblock paths exist in lower layers.
6. The Dart X.509 parser has deterministic malformed vectors and fail-closed
   tests, but no continuous coverage-guided fuzzing target is present.
7. Native notification and media directionality is constrained by each OS;
    bidirectional protocol capability does not imply that every platform can
    originate system data.
8. `rift.performNotificationAction` is exposed by the C# IPC handler and used
    by the shared Flutter client, but the Dart daemon does not currently expose
    the same request. Mobile clients can receive mirrored notification state,
    but remote open/dismiss initiated through the mobile daemon is not verified
    as API-parity behavior.

`rift.listPeersByState` is documented as a current Dart diagnostic extension,
not a required cross-daemon API. `rift.onPresenceUpdate` is available from the
Dart daemon, while the current Flutter client deliberately obtains presence by
polling; this is an implementation difference rather than a missing user-facing
capability.

These gaps must be reported as limitations or pending verification. They must
not be converted into pass results based only on implementation presence.

## Audited Verification Baseline

The documentation audit performed on 2026-08-03 used `main` commit
`866901bdebc160cba12de6667cf7bdea90ced208` and produced the following local
results:

| Command surface | Result |
| --- | --- |
| `dotnet test Rift.Daemon.sln --no-restore` | 378 passed, 0 failed, 0 skipped |
| `dart test` in `daemon-dart/` | 191 passed |
| `flutter test` in `app-flutter/` | 194 passed |
| `dart analyze` in `daemon-dart/` | No issues |
| `flutter analyze` in `app-flutter/` | No issues |
| Dart declarative conformance runner | 15 passed, 0 failed |
| `flutter analyze` in `tests-interop/` | No issues |
| `flutter test` in `tests-interop/` | 8 passed |

This baseline is suitable as automated evidence for reports, subject to the
known gaps above and the historical/live-device qualifications in the two
runbooks. Re-run it when the report baseline commit changes.
