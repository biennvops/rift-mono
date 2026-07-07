# Dart Daemon Assessment & Analysis Report (Milestone M4)

**Reference Standards:** `spec/doc/protocol.md`, `spec/doc/ipc.md`, and the current `daemon-dart` implementation
**Component:** Android Daemon (`daemon-dart`)
**Assessed by:** System Review

---

## Directory Structure & Important Files (Milestone M4)

```text
daemon-dart/
├── bin/
│   └── daemon.dart                        # Standalone desktop/Linux IPC smoke-test entrypoint
├── lib/
│   ├── daemon_dart.dart                    # Exporter
│   └── src/
│       ├── clipboard/
│       │   ├── clipboard_engine.dart       # In-memory offer/fetch state, expiry, replay protection
│       │   ├── clipboard_handler.dart      # Clipboard protocol message handlers
│       │   └── clipboard_models.dart       # Clipboard offer/fetch model types
│       ├── core/
│       │   ├── rift_constants.dart         # Shared protocol/version/capability metadata
│       │   ├── rift_exceptions.dart        # Typed Rift/JSON-RPC exceptions
│       │   ├── rift_log.dart               # Local fallback log persistence for offline debugging
│       │   └── rpc_utils.dart              # Shared JSON-RPC parameter validation helpers
│       ├── crypto/
│       │   ├── base32_utils.dart           # RFC 4648 Base32 encoder with Web/JS float bit-clamping
│       │   ├── cert_builder.dart           # Generates mTLS X.509 certificate with random 64-bit entropy serials
│       │   ├── cert_decoder.dart           # Fail-Closed Parser to extract Ed25519 from ASN.1
│       │   ├── identity_manager_impl.dart  # Generates/stores Ed25519 key, handles Atomic Write and heap zeroing
│       │   └── pop_manager.dart            # PoP static 107-byte payload builder & verifier
│       ├── interfaces/
│       │   ├── clipboard_service.dart      # Abstract Interface managing Clipboard
│       │   ├── discovery_service.dart      # Abstract Interface managing mDNS with explicit dispose()
│       │   ├── identity_manager.dart       # Abstract Interface defining Identity info
│       │   ├── transport.dart              # Abstract Interface managing Network connection and disconnect streams
│       │   └── trust_store.dart            # Abstract Interface managing trust list
│       ├── network/
│       │   ├── discovery_peer_tracker.dart # Tracks discovered peer instances and resolves duplicates
│       │   ├── discovery_service_factory*.dart # OS-specific mDNS factory implementations
│       │   ├── discovery_service_impl.dart # nsd mDNS Discovery robustly handling network flaps
│       │   ├── frame_codec.dart            # Stream transformer locking chunks to 64 KiB / 32 MiB bounds
│       │   ├── session_manager.dart        # Session Orchestrator & PoP validation with active Zone exception catching
│       │   └── transport_impl.dart         # mTLS SecureServerSocket with socket flush and peer disconnect tracking
│       ├── pairing/
│       │   └── pairing_manager.dart        # Pairing State Machine, timeouts, and Double-Approve prevention
│       ├── storage/
│       │   └── trust_store_impl.dart       # SQLite ACID Trust Store with WAL mode and Exhaustive Edge Validation
│       └── daemon.dart                     # IPC try/catch boundary and Isolate orchestrator for Flutter
├── test/
│   ├── capability_presence_test.dart       # Capability negotiation and presence heartbeat tests
│   ├── clipboard_engine_test.dart          # Clipboard offer/fetch engine tests
│   ├── clipboard_handler_test.dart         # Clipboard protocol handler tests
│   ├── crypto_test.dart                    # Cryptography security unit test for cert_builder
│   ├── daemon_pairing_fallback_test.dart   # Tests the standalone daemon auto-pairing fallback
│   ├── decoder_test.dart                   # Unit test to verify the Fail-Closed mechanism of cert_decoder
│   ├── discovered_peer_selection_test.dart # Multi-endpoint discovered-peer selection behavior
│   ├── frame_codec_test.dart               # Unit test to check the 64KiB/32MiB bounds (pre/post auth)
│   ├── identity_test.dart                  # Unit test to verify valid Device ID, Base32, and key zeroing
│   ├── discovery_integration_test.dart     # Pure Dart mDNS integration test exercising actual UDP network stack
│   ├── discovery_peer_tracker_test.dart    # Discovery dedupe / eviction tracker tests
│   ├── pairing_manager_test.dart           # Pairing test: Timeout, UI spoofing, Double-Approve Bypass
│   ├── pop_interop_test.dart               # PoP interop / payload compatibility tests
│   ├── pop_test.dart                       # PoP signature verification Test Vectors (107-byte canonical)
│   ├── session_manager_integration_test.dart # Session flow integration tests
│   ├── session_manager_test.dart           # Session bounds test: Client-side Auth Bypass prevention
│   ├── trust_store_impl_test.dart          # SQLite database persistence and ACID transitions test
│   └── trusted_reconnect_test.dart         # Tests automatic reconnection behavior for trusted peers
├── pubspec.yaml                            # Dart platform declaration (cryptography, nsd, uuid, etc.)
└── README.md                               # Guide for running tests, linter and overall architecture
```

---

## 1. Implementation Summary (Current `daemon-dart` State)

- **`[daemon-dart][infra]` (Week 1):** Initialize basic Dart daemon structure.
  - Installed and verified the usability of cryptography packages `pointycastle` and `asn1lib`.
  - Clearly shaped the directory planning in preparation for protocol modules.
  - **Assessment:** Infrastructure established.

- **`[daemon-dart] Module interfaces & [test]` (Week 2):** Build communication and certificate foundations.
  - Set up all 5 Interfaces (`IdentityManager`, `TrustStore`, `Transport`, `DiscoveryService`, `ClipboardService`).
  - Successfully wrote `cert_builder.dart` to automatically insert the custom OID and Ed25519 public key into the X.509 certificate.
  - Passed the mTLS certificate security Unit Test.
  - **Optimization:** Used `BytesBuilder` to prevent memory fragmentation during ASN.1 byte manipulation; Removed `dynamic` (replaced with `DiscoveredPeer`) to ensure absolute Type-Safety for the Interface architecture.
  - **Security & Refactoring (Leader's Review):** Upgraded `TrustState` to Enhanced Enums, fixed Exception double-wrapping in `cert_builder.dart`, added `signIdentityProof` for Ed25519 PoP compliance, added connection lifecycle methods to `Transport`, and expanded `crypto_test.dart` with robust negative testing (ASN.1 parsing and invalid key handling).
  - **Assessment:** Core certificate and interface groundwork established.

- **`[daemon-dart] Identity, Certificates, Frame Parsing` (Week 3):** Finalize core security.
  - Successfully built the standard Fail-Closed **X.509 Decoder (`cert_decoder.dart`)**. Safely extracted the Ed25519 key from the ASN.1 structure. **Security Hardening:** Passed 10 comprehensive attack vectors (missing OID, duplicate OID, unsupported critical flags, length anomalies, truncated DER, and fragile OID alteration) in `decoder_test.dart`. Fixed a critical Fail-Open bug to strictly reject unknown critical extensions.
  - Implemented the **Frame Codec (`frame_codec.dart`)** with a 4-byte length prefix structure. **Improvement:** Integrated `RiftFrameTransformer` (StreamTransformer) with a `try/finally` block to process data in chunks and guarantee memory zeroing on error. Optimized JSON parsing to return Map directly, completely preventing memory exhaustion (OOM) attacks and double-parsing overhead.
  - Finalized **`IdentityManagerImpl`**: Integrated the `cryptography` package to generate and store the Ed25519 key, calculating the standard `rift- + Base32` Device ID. **Security Hardening:** Added strict 32-byte length validation to `signIdentityProof`, verified async compliance via Contract Stubs, implemented `KeyPair` caching for extreme performance, and added memory clearing via `dispose()` to mitigate RAM scraping.
  - Fixed X.509 standard compliance in **`cert_builder.dart`** by generating cryptographically random 64-bit entropy serial numbers to prevent TLS caching collisions.
  - **Assessment:** Core crypto, identity, and framing pieces implemented.

- **`[daemon-dart] mDNS, Transport, Session Orchestration` (Week 4):** Finalize Network.
  - Implemented **mDNS Discovery (`discovery_service_impl.dart`)** using `nsd`. Opaque Instance IDs are bound to the daemon session lifecycle to mitigate passive tracking. **Network Flap Fix:** Enhanced `_seenInstanceIds` with diff-based eviction logic. Services that disappear during network flaps are actively removed from the tracker, ensuring they are automatically re-discovered when the connection stabilizes.
  - Implemented **mTLS Transport (`transport_impl.dart`)** with `SecureServerSocket`. **Security Hardening:** Strictly extracts Ed25519 identity from custom X.509 extension; enforced Memory Exhaustion protection (64 KiB/32 MiB) with strict chunking limits. Added 10-second Handshake Timeout to mitigate Connection Slot Exhaustion. **Security Deferral:** Purposefully returns `true` inside `onBadCertificate` when `expectedDeviceId` is null to allow incoming peers, passing the absolute verification burden down to the Ed25519 PoP validation layer.
  - Created **Session Orchestrator (`session_manager.dart`)** to manage `session.hello` and `session.accept`. **Security Hardening:** Enforced Risk 6, Envelope Identity validation (`sourceDeviceId`), and proper `session.reject` error dispatching. Implemented `PoPManager` for Ed25519 PoP signature verification over a 113-byte dynamic structure to mitigate Canonicalization Attacks. **Fix (Critical):** Resolved a critical verification mismatch by enforcing that PoP signatures are generated using the **signer's own local certificate DER**. This guarantees the payload mathematically matches the certificate extracted by the verifier's TLS context.
  - Created the Root Daemon Orchestrator **`daemon.dart`** with `isolateEntryPoint` to encapsulate Android Background Services. **Resilience:** Implemented `Isolate.current.addErrorListener` to propagate fatal isolate crashes to the UI layer. **Fix:** The isolate bridge now exposes a JSON-RPC-focused `rpcPort`, removing the old ad-hoc command naming and clarifying that the background bridge is request/response oriented.
  - **Security Alignment (M2 Implemented Against Current Spec):** Session bootstrap now follows the current Tier 3 channel-binding design from `protocol.md` / ADR-0011. Both `session.hello` and `session.accept` carry `bindingType: "app-nonce"` plus a 32-byte base64 `sessionNonce`, and PoP verification reconstructs `SHA-256(peerNonce || peerCertDer || localCertDer)` exactly as required. This restores per-session uniqueness within the boundaries explicitly accepted by the spec for platforms without `tls-exporter`.
  - **PoP Alignment (M2 Resolved):** Removed length-prefixes from the PoP signing payload to strictly conform to the 107-byte raw concatenation schema specified in Section 5.3.1.
  - **Assessment:** Transport and session flows are implemented in line with the current protocol draft. The remaining limitation is no longer an implementation blocker but the spec-documented residual risk of Tier 3 `app-nonce` versus Tier 1 `tls-exporter`.

- **`[daemon-dart] Pairing State Machine & Storage` (Week 5 / M3):** Finalize Trust boundaries.
  - Implemented **`TrustStoreImpl`**: Replaced mock data with a physical SQLite database (`sqlite3` FFI). **Database Hardening:** Enabled WAL mode to prevent lock contention between the Isolate and potential future readers. Enforced **Exhaustive Edge Validation** directly in `transitionState` to block invalid state jumps (e.g., `revoked` -> `trusted`). Implemented explicit `ON CONFLICT` constraints to prevent mDNS discovery mechanisms from automatically downgrading a `trusted` peer back to `discovered`, and now preserve pinned `cert_der` values for `trusted`, `blocked`, and `revoked` peers at the storage layer.
  - Implemented **`PairingManager`**: Built the strict State Machine orchestrating trust workflows. **Security Hardening:** Mitigated **Double-Approve Bypass** by maintaining an `_outboundPairings` set, silently dropping unsolicited `pairing.approve` packets from rogue peers. Mitigated **UI Spoofing** by deriving the fingerprint mathematically from the TLS Context instead of trusting the packet payload. Enforced a rigid 120s timeout via an explicit `pairing.reject` broadcast and timer cleanup, and later patched the outbound approve path to restore the timer for any exception type instead of only `StateError` / `SocketException`. Added an intermediate `rift.onPairingApproved` IPC notification so the UI can distinguish "peer approved" from final trust persistence.
  - Finalized **Client-side PoP Verification**: Hardened `SessionManager.accept` by validating the inbound PoP signature on the client side before allowing connection completion.
  - **Discovery Automation (M3 Resolved):** Added `discovery_integration_test.dart` using the pure-Dart `mdns_dart` package to actively advertise and discover `_rift._tcp` TXT records over the real local UDP network stack, replacing logical mocks.
  - **Assessment:** Pairing, discovery automation, and trust persistence are implemented in code. At the time of this report update, `dart test` passes with 92 tests.

- **`[daemon-dart] Security Audit & Hardening` (End of Week 4):** Conducted a deep-dive 16-point security and conformance audit across all Dart implementation files.
  - **Critical (C-1/C-2):** Resolved a severe Integer Overflow vulnerability in `Base32Utils` affecting Dart Web/JS builds (53-bit float limits) by implementing explicit bit clamping. Enforced strict memory zeroing of ephemeral TLS Certificates (`_tlsCertificateDer`) during daemon shutdown to prevent extraction from heap dumps.
  - **High (H-1 to H-4):** Eradicated silent `async void` error-swallowing in `SessionManager`, ensuring unhandled PoP verification exceptions immediately disconnect rogue peers. Mitigated stream aliasing hazards in `RiftFrameTransformer` by switching to `copy: true` buffers. Prevented racing data loss during shutdown by forcing kernel `socket.flush()`. Lifted `dispose()` abstractions to root interfaces to close leakage gaps.
  - **Medium (M-1 to M-5):** Solved a silent session starvation state where disconnected peers were locked out from reconnecting by integrating a reactive `onPeerDisconnected` stream. Bounded IPC `ReceivePort` lifecycles in `daemon.dart` behind `try/catch` logic to prevent headless port leaks on startup failures. Implemented dedicated unit tests for pre-auth (64 KiB) and post-auth (32 MiB) promotion boundaries. Later hardening also centralized shared protocol metadata, introduced typed Rift exceptions carrying explicit JSON-RPC error codes, extracted shared JSON-RPC param validation into `rpc_utils.dart`, and updated the isolate bridge naming from `commandPort` to `rpcPort` to reflect its real JSON-RPC role.
  - **Low/Conformance (L-1 to L-5):** Improved mDNS logic to gracefully skip null-named instances without collapsing peers into an 'unknown' namespace. Replaced hardcoded testing payloads with structurally valid ASN.1 DER stubs.
  - **Documentation & Technical Debt:** Executed a massive comment cleanup across the repository to ensure all code is strictly English-first. Purged verbose, redundant, and obsolete issue-tracker labels (`H-1:`, etc.), strictly preserving only non-obvious security rationales (e.g., JS integer bounds, TLS deference, Double OCTET STRING wrapping, and Risk 3/6 enforcement rules).
  - **Assessment:** `dart analyze` reports no issues found, and `dart test` currently passes with 92 tests.

- **`[daemon-dart] Capability Negotiation & Presence` (Week 6):** Added authenticated capability negotiation, trusted-peer presence tracking, and durable presence history.
  - Implemented `capability.advertise` / `capability.selected` negotiation with version intersection, responder-side validation, and a 5-second negotiation timeout.
  - Added `SessionContext` tracking for negotiated capabilities, trust state, heartbeat timers, and `lastHeartbeatReceived`.
  - Tightened envelope/schema conformance in `SessionManager`: required `messageId` validation, `destinationDeviceId` enforcement, rejection of unknown `requiredExtensions`, restoration of `implementationId` / `capabilities` in `session.hello`, and `capabilities` in `session.accept`.
  - Implemented trusted-peer `presence.update` handling with strict status validation, negotiated-capability enforcement, and durable `lastSeenAt` persistence through `TrustStoreImpl`.
  - Added SQLite schema migration from trust-store v1 to v2 to preserve older installs while introducing `lastSeenAt`.
  - Exposed `getPeerPresence` and `listTrustedPeers` responses through the daemon isolate bridge, including capability summaries and persisted timestamps.
  - Added unit coverage for malformed capability payloads, invalid selected sets, presence validation, heartbeat gating, trust-store persistence, and migration behavior.
  - **Battery Impact Check Status (Evidence):**
    - **Snapshot A captured (2026-06-19):** using `adb shell dumpsys battery unplug` + `adb shell dumpsys batterystats com.example.app_flutter` (simulated on-battery while keeping USB connected for ADB).
    - **Snapshot B captured (2026-06-19):** same commands after an idle window.
    - **A -> B delta (device-level signals):**
      - Time on battery: `+32m 36s`
      - Total partial wakelock time: `+4m 31s`
      - Connectivity changes: `343 -> 345`
      - WiFi data received: `679.67MB -> 1.05GB` (not an idle baseline)
      - WiFi data sent: `40.52MB -> 52.01MB`
    - **Interpretation:** This A/B run is valid as a “real device snapshot delta”, but it is **not a clean idle baseline** due to significant WiFi traffic during the window. It cannot be used to attribute battery/network impact to Rift heartbeats yet; it mainly proves the measurement pipeline works (snapshot deltas without `batterystats --reset`).
    - **Clean idle baseline run (Airplane Mode, 2026-06-19):**
      - **A2 -> B2 window:** `~16m 51s` on-battery (screen-off `~16m 39s`), WiFi and Cellular data `0B` throughout.
      - **B2 observed:** total partial wakelock time `6s 803ms`, device light idle `11m 53s` (entered Doze).
      - **Battery drain:** `0 mAh` reported for this window (short-window resolution; treat as “below meter precision” rather than guaranteed zero).
    - **1 trusted peer heartbeat run (WiFi on, 2026-06-19):**
      - **C -> D window:** `~15m 5s` on-battery (screen-off `~15m 5s`), screen-on delta `~0s`.
      - **C -> D deltas:** partial wakelock `+25s` (48.9s -> 74.3s), connectivity changes `13 -> 19`.
      - **C -> D network deltas:** WiFi RX `+302KB`, WiFi TX `+544KB` (Cellular `0B` throughout).
      - **Battery drain:** `0 mAh` reported for this window (again: likely below meter precision at this duration).
      - **Comparison to clean idle:** baseline shows `~0.40s/min` partial wakelock, while this run shows `~1.68s/min` partial wakelock delta. This suggests additional periodic work during the window (consistent with “heartbeat present”), but attribution remains imperfect because system jobs can also contribute; repeating the run with a longer window (30-60m) would improve confidence.
    - **Note:** `adb shell dumpsys batterystats --reset` is not available on this device/user (WRITE_SECURE_SETTINGS), so evidence must be recorded as snapshot deltas (A/B, C/D) rather than absolute "since reset" numbers.
  - **Assessment:** Capability/presence logic is implemented and covered by the current merged test suite. Week 6 battery evidence has been captured on a physical device for both a clean idle baseline and a 1 trusted peer heartbeat run (see above), with the caveat that short-window `batterystats` may under-report mAh deltas.

- **`[daemon-dart] Clipboard Offer/Fetch & Android Bridge` (Week 7 / M4 Groundwork):** Added the first complete clipboard protocol slice across daemon, IPC, and Android client bridge.
  - Implemented a dedicated clipboard module under `lib/src/clipboard/`:
    - `clipboard_models.dart` for `ClipboardOffer`, `ClipboardFetchRequest`,
      `ClipboardFetchResponse`, and `ClipboardFetchReject`
    - `clipboard_engine.dart` for in-memory active-offer tracking, expiry
      timers, local/remote offer separation, local content retention, and
      `offerSequence` replay protection
    - `clipboard_handler.dart` for `clipboard.offer`,
      `clipboard.fetchRequest`, `clipboard.fetchResponse`, and
      `clipboard.fetchReject`
  - Exposed Week 7 IPC methods through `daemon.dart`:
    - `rift.notifyClipboardChange`
    - `rift.listClipboardOffers`
    - `rift.fetchClipboardContent`
    - `rift.onClipboardOffer`
    - `rift.onClipboardExpired`
  - Hardened the daemon IPC boundary so clipboard changes are validated
    fail-closed before broadcast:
    - base64 must decode successfully
    - decoded byte count must match `byteSize`
    - SHA-256 must match the declared `sha256`
    - payloads over 32 MiB are rejected with `-32007`
  - Tightened fetch semantics:
    - only local offers can be served to peers
    - `listClipboardOffers` returns peer offers only
    - `fetchClipboardContent` now maps key failures to IPC-visible codes
      aligned with `ipc.md` (`OfferExpired`, `HashMismatch`,
      `PeerUnreachable`)
  - Added Week 7 daemon-side tests for:
    - offer creation/expiry
    - replay and out-of-order `offerSequence`
    - oversized offer rejection
    - fetch-response hash validation
    - rejection of fetches against non-local offers
    - malformed and size-mismatched fetch responses

  - **Verification update (2026-07-06):**
    - `dart analyze` -> `No issues found!`
    - `dart test` -> `00:07 +131: All tests passed!`
  - **Assessment:** Week 7 clipboard groundwork is implementation-ready at the daemon/API layer and currently clean under local analyze/test verification. Remaining closure items are manual E2E evidence and a full Flutter clipboard-offer UI flow.

- **`[daemon-dart] Network Handshake & Discovery Hardening` (Week 7 Stabilization):** Hardened connection deadlocks and eliminated ghost mDNS artifacts.
  - Implemented socket replacement logic in `TransportImpl`: When duplicate inbound connections race with outbound connections and role preferences overlap, the new connection replaces the stale socket instead of being incorrectly rejected. This resolves the `Peer closed connection before sending session.hello` deadlock.
  - Introduced explicit `IIdentityManager`-based Device ID filtering in `listDiscoveredPeers` to prevent the device from tracking itself and propagating ghost artifacts to the UI during hot reloads.

---

## 2. System Specification Alignment (Protocol & IPC)

The implementation is clearly derived from the two core specifications, but it should be described as **partially aligned** rather than fully conformant:

### 2.1. Compliance with `spec/doc/protocol.md` (Network Protocol & Security)
- **Implemented and aligned:** The code embeds the custom Ed25519 extension in the TLS certificate, parses it fail-closed, derives the device ID from the Ed25519 public key, enforces pre-auth/post-auth frame size limits, and canonicalizes the PoP signing payload strictly to the 107-byte raw format.
- **Implemented with spec-defined fallback:** `session.hello` / `session.accept` verification now uses the normative Tier 3 `app-nonce` channel binding from Section 5.3.1 / ADR-0011 because `dart:io` still lacks `tls-exporter` support.
- **Net assessment:** Security architecture is integrated and aligned with the current protocol draft for the Dart platform. The remaining tradeoff is the residual risk already documented in the spec for Tier 3 versus TLS-exporter.

### 2.2. Compliance with `spec/doc/ipc.md` (Flutter Client Communication)
- **Implemented and aligned:** The daemon exposes an isolate entrypoint and the pairing/trust notifications needed for the Flutter app to drive the flow.
- **Validated IPC Contracts (Presence & Trust):** The UI/App-layer integration is fully documented and successfully implemented via the following explicit JSON-RPC 2.0 notifications:
  - **Presence:** `rift.onPeerDiscovered` (emitted on mDNS discovery), `rift.onPeerLost` (emitted on mDNS eviction/network drop).
  - **Trust/Pairing:** `rift.onPairingRequest`, `rift.onPairingApproved`, `rift.onPairingComplete`, and `rift.onTrustChanged`.
- **Validated IPC Contracts (Clipboard):**
  - **Methods:** `rift.notifyClipboardChange`, `rift.listClipboardOffers`, `rift.fetchClipboardContent`
  - **Notifications:** `rift.onClipboardOffer`, `rift.onClipboardExpired`
- **Implemented and largely aligned:** The current isolate bridge uses explicit Rift exception codes for key application failures. It still retains isolate-specific `SendPort` transport details, but the old ad-hoc command naming has been cleaned up into `rpcPort`.
- **Net assessment:** The IPC implementation robustly fulfills the `ipc.md` contract for current app needs (M4), fully propagating presence events and trust transitions to the UI.

---

## 3. Risk Assessment & Blockers (Milestone M4)

1. **TLS-Exporter Absence (Residual Spec-Level Limitation):**
   `dart:io` `SecureSocket` does not expose `tls-exporter` (RFC 9266) or `tls-unique` material. The implementation therefore uses the current spec-approved Tier 3 `app-nonce` binding, which provides per-session uniqueness but does not cryptographically bind the PoP to the TLS transcript itself. **Action:** Upgrade to Tier 1 automatically once the Dart SDK exposes TLS keying material export.

2. **PoP Canonicalization (Resolved):**
   The implementation has been refactored to strictly match the 107-byte raw concatenation schema defined in `protocol.md` Section 5.3.1. The previous divergence (length prefixes) has been removed.

3. **Plaintext Key Storage Risk (Future/Backlog):**
   Currently, `identity_manager_impl.dart` stores `identity.key` in plaintext. While protected by the Android App Sandbox (chmod 700), it remains vulnerable on rooted devices. Future iterations should explore Android Keystore integration via Flutter channels.

4. **TLS Cert Extraction Race Condition (Technical Debt):**
   This was an earlier concern, but the current `SessionManager` already receives `peerCertDer` on each `TransportMessage` and validates PoP against that message-bound certificate context. This item should be considered resolved in the current code unless a new race is demonstrated elsewhere.


## 4. Reality Check Against the Repository

- `dart analyze` currently reports `No issues found!`.
- `dart test` currently passes with 131 tests.
- Latest local verification snapshot:
  `dart analyze` -> `No issues found!`
  `dart test` -> `00:07 +131: All tests passed!`
- `README.md` previously referenced `demo_cert.dart`, but that file does not exist in the current package.
- `bin/daemon.dart` now provides a minimal standalone Unix-socket runner for
  local Linux IPC smoke tests. It is useful for desktop verification, but it is
  not yet a full conformance/interop harness.
