# Local-Network Operation Implementation Plan

## Scope Note

This plan follows the current Rift protocol and capstone documentation. Rift is
currently a local-first, peer-to-peer system that is expected to work on the
same reachable local network even when internet access is unavailable.
Internet-only connectivity without local peer reachability is not part of the
current implementation scope and would require a future protocol/design
extension.

## Source Files

- `spec/doc/protocol.md`
- `spec/doc/ipc.md`
- `docs/capstone-register.md`
- `tests-interop/README.md`
- `daemon-cs/Rift.Daemon.Core/Networking/DiscoveryService.cs`
- `daemon-cs/Rift.Daemon.Core/Networking/TlsTransport.cs`
- `daemon-cs/Rift.Daemon.Core/PairingProtocolCoordinator.cs`
- `daemon-dart/lib/src/daemon.dart`
- `daemon-dart/lib/src/network/discovery_service_impl.dart`
- `daemon-dart/lib/src/network/session_manager.dart`
- `app-flutter/lib/src/ipc/json_rpc_client.dart`
- `app-flutter/lib/screens/trusted_devices_screen.dart`

## Goal

Ensure Rift reliably supports:

- peer discovery on the same LAN without internet
- direct TLS session establishment over local IP connectivity
- pairing in both directions
- trust-state synchronization
- presence and reachability updates
- recovery after local network changes

## Current Platform Limitation

During Linux <-> Android and desktop <-> Android pairing work, we confirmed a
platform-specific limitation in the Dart/Android transport implementation:
Android's `SecureServerSocket` does not reliably provisionally accept arbitrary
self-signed client certificates on the inbound server-side TLS path. In
practice, Linux-initiated or desktop-initiated outbound connects to Android can
fail at the Android TLS layer with a certificate verification error before the
Rift session bootstrap code can inspect the peer certificate and run Ed25519
PoP validation.

This does not change the Rift peer protocol or trust model. The current
implementation compensates at the connection-strategy layer instead:

- Android proactively opens outbound authenticated sessions to discovered peers.
- Linux/C# pairing prefers reusing an already-active authenticated session
  before attempting a fresh outbound connect.

This is an implementation workaround for current platform behavior, not a wire
protocol change. If Dart/BoringSSL later exposes a way to provisionally accept
self-signed inbound client certificates for pairing candidates, this workaround
should be revisited and potentially simplified.

## Non-Goals

This plan does not implement:

- relay transport
- NAT traversal
- STUN/TURN/ICE
- cloud rendezvous
- internet-only pairing across unrelated networks

## Phase 1: Lock the Local-Network Contract

Files:

- `spec/doc/protocol.md`
- `docs/capstone-register.md`
- `tests-interop/README.md`

Tasks:

1. State explicitly that same-LAN operation does not require internet
   connectivity.
2. State explicitly that internet-only reachability is future work.
3. Expand the interop matrix to include:
   - same LAN with internet
   - same LAN without internet
   - same SSID with client isolation
   - multicast unavailable but direct local IP reachable

Deliverable:

- a documentation baseline that distinguishes internet access from local peer
  reachability

## Phase 2: Harden Discovery for Offline Local Networks

Files:

- `daemon-cs/Rift.Daemon.Core/Networking/DiscoveryService.cs`
- `daemon-cs/Rift.Daemon.Core/DiscoveryCoordinator.cs`
- `daemon-dart/lib/src/network/discovery_service_impl.dart`
- `daemon-dart/lib/src/daemon.dart`

Tasks:

1. Verify discovery startup does not depend on internet reachability checks.
2. Ensure mDNS advertise/discover starts from local interface availability
   alone.
3. Improve handling for:
   - Wi-Fi reconnect
   - interface IP change
   - duplicate service records
   - stale discovered peers after network flaps
4. Confirm discovered peer records prefer usable local IP addresses.

Deliverable:

- reliable `_rift._tcp` discovery on a LAN with or without internet

## Phase 3: Harden Direct Local Transport Establishment

Files:

- `daemon-cs/Rift.Daemon.Core/Networking/TlsTransport.cs`
- `daemon-cs/Rift.Daemon.Core/Interfaces/ITransport.cs`
- `daemon-dart/lib/src/network/session_manager.dart`
- `daemon-dart/lib/src/network/transport_impl.dart`

Tasks:

1. Ensure local IP connect attempts use the discovered local endpoint directly.
2. Avoid dependence on hostnames that may fail on LAN-only setups.
3. Normalize IPv4/IPv6 selection rules for discovered peers.
4. Improve duplicate-session handling when both peers initiate simultaneously.
5. Distinguish these failure classes clearly in logs:
   - discovery succeeded but TCP connect failed
   - TCP/TLS succeeded but session bootstrap failed
   - bootstrap failed due to protocol rejection
   - peer closed a duplicate connection intentionally

Deliverable:

- stable local peer connection behavior even with no internet

## Phase 4: Make Pairing Resilient in Both Directions

Files:

- `daemon-cs/Rift.Daemon.Core/PairingProtocolCoordinator.cs`
- `daemon-cs/Rift.Daemon.Core/PairingService.cs`
- `daemon-dart/lib/src/pairing/pairing_manager.dart`
- `daemon-dart/lib/src/daemon.dart`

Tasks:

1. Verify Android -> desktop pairing and desktop -> Android pairing both reuse
   active sessions when possible.
2. Ensure pairing does not fail just because a duplicate outbound connection
   lost the race.
3. Normalize timeout, reject, cancel, and unreachable transitions back to
   `discovered` where appropriate.
4. Ensure pairing UI is driven by authenticated session state, not discovery
   hints.
5. Verify both sides persist `trusted` and publish trust changes back to
   IPC/UI.

Deliverable:

- clean bidirectional pairing on a LAN-only network

## Phase 5: Presence and Offline Recovery

Files:

- `spec/doc/protocol.md`
- `daemon-cs/Rift.Daemon.Core/Networking/SessionCapabilityCoordinator.cs`
- `daemon-dart/lib/src/network/session_manager.dart`
- `app-flutter/lib/screens/trusted_devices_screen.dart`

Tasks:

1. Confirm presence updates flow only after authenticated transport
   establishment.
2. Ensure offline detection works from local session timeout/disconnect, not
   internet checks.
3. Ensure both sides transition from online to offline when local reachability
   disappears.
4. Ensure they recover back to online after LAN recovery.
5. Keep UI presence accurate during long-lived sessions.

Deliverable:

- correct local reachability state independent of internet connectivity

## Phase 6: IPC and UI Behavior for LAN-Only Mode

Files:

- `spec/doc/ipc.md`
- `app-flutter/lib/src/ipc/json_rpc_client.dart`
- `app-flutter/lib/screens/pairing_screen.dart`
- `app-flutter/lib/screens/trusted_devices_screen.dart`

Tasks:

1. Make error wording say "local network reachability" instead of vaguely
   implying internet problems.
2. Show useful states:
   - discovered on local network
   - pairing pending
   - trusted but offline
   - trusted and online
3. Avoid suggesting that internet is required.
4. Add user-facing error copy for:
   - local peer unreachable
   - mDNS discovery unavailable
   - secure session bootstrap rejected
5. Provide a manual endpoint fallback for cases where hotspot / AP mode blocks
   both mDNS and UDP broadcast discovery, but a direct peer IP:port is known.

Deliverable:

- UI that matches the local-first contract

## Phase 7: Trusted Endpoint Persistence and Reconnect

Files:

- `spec/doc/ipc.md`
- `docs/capstone-register.md`
- `daemon-cs/Rift.Daemon.Core/ClipboardService.cs`
- `daemon-cs/Rift.Daemon.Core/PairingProtocolCoordinator.cs`
- `daemon-cs/Rift.Daemon.Core/PresenceService.cs`
- `daemon-dart/lib/src/daemon.dart`
- `daemon-dart/lib/src/network/session_manager.dart`
- `daemon-dart/lib/src/clipboard/clipboard_handler.dart`

Tasks:

1. Persist one or more last-known-good direct endpoints for each `trusted`
   peer after successful authenticated transport establishment.
2. Record enough metadata to rank reconnect attempts deterministically:
   endpoint address, port, address family, source (`mdns`, `fallback`,
   `manual`), and last-success timestamp.
3. Define a trusted-peer reconnect path that can use persisted endpoints when
   discovery is missing, stale, or filtered on hotspot / LAN-only networks.
4. Keep this reconnect behavior scoped to already-authenticated / already-trusted
   peers; pairing by endpoint remains a separate explicit user action.
5. Ensure endpoint persistence updates only after identity verification and
   capability negotiation succeed, so unauthenticated discovery hints are not
   promoted into trusted reconnect state.

Deliverable:

- trusted peers can be reached again after discovery degradation by reusing a
  persisted local endpoint

## Phase 8: Fast-Fail and Single-Flight Reconnect

Files:

- `daemon-cs/Rift.Daemon.Core/Interfaces/ITransport.cs`
- `daemon-cs/Rift.Daemon.Core/ClipboardService.cs`
- `daemon-cs/Rift.Daemon.Core/PresenceService.cs`
- `daemon-dart/lib/src/network/transport_impl.dart`
- `daemon-dart/lib/src/network/session_manager.dart`
- `daemon-dart/lib/src/daemon.dart`

Tasks:

1. Apply a short per-endpoint reconnect timeout for trusted direct-connect
   attempts so stale hotspot / DHCP addresses fail quickly instead of stalling
   clipboard UX behind long OS TCP timeouts.
2. Try trusted endpoints in a deterministic order rather than racing all of
   them at once.
3. Enforce a single in-flight reconnect operation per peer device ID so
   multiple clipboard events cannot stampede the same peer with duplicate
   outbound connections.
4. Ensure callers that need the same peer connection await the existing
   reconnect attempt instead of creating a second one.
5. Surface reconnect-failure reasons in logs and IPC in terms of local
   reachability, stale endpoint, timeout, or bootstrap rejection.

Deliverable:

- bounded, deterministic reconnect behavior for trusted peers on unstable local
  networks

## Phase 9: Clipboard Delivery on Local-Only Networks

Files:

- `spec/doc/protocol.md`
- `spec/doc/ipc.md`
- `daemon-cs/Rift.Daemon.Core/ClipboardService.cs`
- `daemon-dart/lib/src/clipboard/clipboard_engine.dart`
- `daemon-dart/lib/src/clipboard/clipboard_handler.dart`
- `app-flutter/lib/src/clipboard/desktop_clipboard_manager.dart`

Tasks:

1. Route `clipboard.offer` and `clipboard.fetchRequest` through the trusted-peer
   reconnect path instead of assuming the peer is already online in discovery.
2. Preserve pending clipboard metadata locally for a short bounded period when a
   trusted peer is temporarily unreachable on the local network.
3. Retry delivery when a trusted session becomes available again, without
   replaying already-acknowledged or expired offers.
4. Keep expiry semantics deterministic and local-clock tolerant; reconnect
   should not extend the protocol TTL indefinitely.
5. Document that this is a local store-and-forward layer for trusted peers on
   the same reachable network segment, not a relay or cloud queue.

Deliverable:

- clipboard offer/fetch remains usable for trusted peers across hotspot and
  local-network discovery gaps

## Phase 10: Automated Test Coverage

Files:

- `daemon-cs/Rift.Daemon.Tests/Core/PairingProtocolCoordinatorTests.cs`
- `daemon-cs/Rift.Daemon.Tests/Core/ClipboardServiceTests.cs`
- `daemon-dart/test/session_manager_test.dart`
- `daemon-dart/test/session_manager_integration_test.dart`
- `daemon-dart/test/clipboard_handler_test.dart`
- `app-flutter/test/trusted_devices_screen_test.dart`
- `tests-interop/test/presence_sync_test.dart`
- `tests-interop/test/clipboard_transfer_test.dart`
- `.github/workflows/flutter-ci.yml`

Tasks:

1. Add unit tests for pairing fallback when an active authenticated session
   already exists.
2. Add tests for duplicate outbound/inbound connection races.
3. Add tests for disconnect during pairing.
4. Add tests for offline/online transitions after local network flap.
5. Add tests for trusted-peer reconnect using persisted endpoints when
   discovery is unavailable or stale.
6. Add tests that multiple clipboard events share one reconnect attempt per
   peer rather than creating a connection stampede.
7. Add tests for pending clipboard delivery, expiry, and non-replay behavior
   after reconnect.
8. Keep simulated harness tests clearly labeled as simulation, not real LAN
   validation.
9. Keep CI running app and harness tests.

Deliverable:

- regression coverage for the local-only contract

## Phase 11: Manual Validation Matrix

File:

- `tests-interop/README.md`

Required manual scenarios:

1. Same LAN, internet available:
   - Android -> Linux
   - Linux -> Android
   - Android -> Windows
   - Windows -> Android
2. Same LAN, internet disabled on router/uplink:
   - discovery still works
   - pairing still works
   - trust still persists
   - presence still updates
3. Same SSID, client isolation enabled:
   - verify discovery/connect failure is expected and clearly surfaced
4. Multicast blocked, direct IP still reachable:
   - discovery fails or is partial
   - manual pairing by endpoint works
   - existing trusted peers reconnect through a persisted direct endpoint path
   - clipboard offer/fetch still works for trusted peers after reconnect
5. Local network flap:
   - peers go offline
   - peers rediscover/reconnect after recovery
6. Hotspot / DHCP address churn:
   - old persisted endpoint fails fast
   - new endpoint is learned and replaces the stale winner
   - clipboard resumes without re-pairing

Deliverable:

- recorded evidence that Rift works on a local network without internet

## Phase 12: Reduce Discovery Privacy Tradeoff (`did`)

Files:

- `spec/doc/protocol.md`
- `app-flutter/lib/src/ipc/android_root_discovery_bridge.dart`
- `daemon-cs/Rift.Daemon.Core/Networking/DiscoveryService.cs`
- `daemon-dart/lib/src/network/discovery_service_impl.dart`
- `daemon-dart/lib/src/daemon.dart`

Tasks:

1. Acknowledge current tradeoff: Both C# and Dart daemons currently include `did` (device ID) in the mDNS TXT record by default. This violates the strict privacy intent of the protocol (`SHOULD NOT include this field by default`) but is temporarily necessary to maintain usability and interoperability.
2. Without `did` in the broadcast, the UI would only see random instance UUIDs until a session is bootstrapped. While Android proactively prefetches sessions (and could resolve the real device ID), the C# Linux daemon does not currently support session prefetching.
3. Future Implementation: 
   - Remove `did` from default discovery broadcasts.
   - Update the UI to temporarily display the `instanceId` and a fallback `fingerprint prefix` (if provided) for unauthenticated peers.
   - Map the temporary identity to the real `deviceId` only *after* the initial session bootstrap (TLS handshake) is successfully completed.
   - Do not implement this change until the Linux/C# daemon supports lightweight session prefetching or identity resolution, to avoid degrading the pairing UX.

Deliverable:

- `did` removed from mDNS TXT records by default, achieving the final privacy target without breaking cross-platform peer recognition.

## Recommended Implementation Order

1. Documentation clarification
2. Discovery hardening
3. Transport hardening
4. Pairing bidirectional stability
5. Presence/offline recovery
6. Trusted endpoint persistence
7. Fast-fail single-flight reconnect
8. Clipboard delivery over trusted reconnect
9. UI/IPC wording
10. Automated tests
11. Manual matrix sign-off

## Definition of Done

The work is complete when:

1. Rift discovers peers on the same LAN without internet.
2. Direct TLS/bootstrap succeeds over local IP connectivity.
3. Pairing works in both directions.
4. Trusted peers transition offline/online correctly on local reachability
   changes.
5. Trusted peers can reconnect using persisted local endpoints when discovery
   is degraded or filtered.
6. Clipboard offer/fetch remains usable for trusted peers on hotspot /
   multicast-limited local networks without requiring re-pairing.
7. UI states and errors reflect local-first behavior accurately.
8. CI stays green.
9. `tests-interop/README.md` contains recorded manual evidence for the
   LAN-without-internet cases.
