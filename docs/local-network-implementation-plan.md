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

Deliverable:

- UI that matches the local-first contract

## Phase 7: Automated Test Coverage

Files:

- `daemon-cs/Rift.Daemon.Tests/Core/PairingProtocolCoordinatorTests.cs`
- `daemon-dart/test/session_manager_test.dart`
- `daemon-dart/test/session_manager_integration_test.dart`
- `app-flutter/test/trusted_devices_screen_test.dart`
- `tests-interop/test/presence_sync_test.dart`
- `.github/workflows/flutter-ci.yml`

Tasks:

1. Add unit tests for pairing fallback when an active authenticated session
   already exists.
2. Add tests for duplicate outbound/inbound connection races.
3. Add tests for disconnect during pairing.
4. Add tests for offline/online transitions after local network flap.
5. Keep simulated harness tests clearly labeled as simulation, not real LAN
   validation.
6. Keep CI running app and harness tests.

Deliverable:

- regression coverage for the local-only contract

## Phase 8: Manual Validation Matrix

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
   - existing trusted peers remain offline/unreachable until a direct connect
     path exists
5. Local network flap:
   - peers go offline
   - peers rediscover/reconnect after recovery

Deliverable:

- recorded evidence that Rift works on a local network without internet

## Recommended Implementation Order

1. Documentation clarification
2. Discovery hardening
3. Transport hardening
4. Pairing bidirectional stability
5. Presence/offline recovery
6. UI/IPC wording
7. Automated tests
8. Manual matrix sign-off

## Definition of Done

The work is complete when:

1. Rift discovers peers on the same LAN without internet.
2. Direct TLS/bootstrap succeeds over local IP connectivity.
3. Pairing works in both directions.
4. Trusted peers transition offline/online correctly on local reachability
   changes.
5. UI states and errors reflect local-first behavior accurately.
6. CI stays green.
7. `tests-interop/README.md` contains recorded manual evidence for the
   LAN-without-internet cases.
