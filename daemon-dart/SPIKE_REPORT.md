# Dart Daemon Assessment & Analysis Report (Week 1-6)

**Reference Standard:** `フィナーレ.md` (Master Plan)
**Component:** Android Daemon (`daemon-dart`)
**Assessed by:** System Review

---

## Directory Structure & Important Files (As of Week 6)

```text
daemon-dart/
├── lib/
│   ├── daemon_dart.dart                    # Exporter
│   └── src/
│       ├── crypto/
│       │   ├── base32_utils.dart           # RFC 4648 Base32 encoder with Web/JS float bit-clamping
│       │   ├── cert_builder.dart           # Generates mTLS X.509 certificate with random 64-bit entropy serials
│       │   ├── cert_decoder.dart           # Fail-Closed Parser to extract Ed25519 from ASN.1
│       │   ├── identity_manager_impl.dart  # Generates/stores Ed25519 key, handles Atomic Write and heap zeroing
│       │   ├── pop_manager.dart            # PoP static 113-byte payload builder & verifier
│       │   └── trust_store_impl.dart       # SQLite trust persistence with lastSeenAt migration
│       ├── interfaces/
│       │   ├── clipboard_service.dart      # Abstract Interface managing Clipboard
│       │   ├── discovery_service.dart      # Abstract Interface managing mDNS with explicit dispose()
│       │   ├── identity_manager.dart       # Abstract Interface defining Identity info
│       │   ├── transport.dart              # Abstract Interface managing Network connection and disconnect streams
│       │   └── trust_store.dart            # Abstract Interface managing trust list and lastSeen persistence
│       ├── network/
│       │   ├── discovery_service_impl.dart # nsd mDNS Discovery robustly handling network flaps
│       │   ├── frame_codec.dart            # Stream transformer locking chunks to 64 KiB / 32 MiB bounds
│       │   ├── session_manager.dart        # Session orchestration, capability negotiation, and presence heartbeats
│       │   └── transport_impl.dart         # mTLS SecureServerSocket with socket flush and peer disconnect tracking
│       └── daemon.dart                     # IPC bridge exposing trusted peers and presence state to Flutter
├── test/
│   ├── capability_presence_test.dart       # Capability negotiation and presence validation tests
│   ├── crypto_test.dart                    # Cryptography security unit test for cert_builder
│   ├── decoder_test.dart                   # Unit test to verify the Fail-Closed mechanism of cert_decoder
│   ├── frame_codec_test.dart               # Unit test to check the 64KiB/32MiB bounds (pre/post auth)
│   ├── identity_test.dart                  # Unit test to verify valid Device ID, Base32, and key zeroing
│   ├── pop_test.dart                       # PoP signature verification Test Vectors (113-byte dynamic)
│   └── trust_store_impl_test.dart          # SQLite persistence and migration coverage
├── pubspec.yaml                            # Dart platform declaration (cryptography, nsd, sqlite, meta, uuid, etc.)
└── README.md                               # Guide for running tests, linter and overall architecture
```

---

## 1. Task Compliance Level (According to `フィナーレ.md`)

- **`[daemon-dart][infra]` (Week 1):** Initialize basic Dart daemon structure.
  - Installed and verified the usability of cryptography packages `pointycastle` and `asn1lib`.
  - Clearly shaped the directory planning in preparation for protocol modules.
  - **Assessment:** **PASSED (100%)**

- **`[daemon-dart] Module interfaces & [test]` (Week 2):** Build communication and certificate foundations.
  - Set up all 5 Interfaces (`IdentityManager`, `TrustStore`, `Transport`, `DiscoveryService`, `ClipboardService`).
  - Successfully wrote `cert_builder.dart` to automatically insert the custom OID and Ed25519 public key into the X.509 certificate.
  - Passed the mTLS certificate security Unit Test.
  - **Optimization:** Used `BytesBuilder` to prevent memory fragmentation during ASN.1 byte manipulation; Removed `dynamic` (replaced with `DiscoveredPeer`) to ensure absolute Type-Safety for the Interface architecture.
  - **Security & Refactoring (Leader's Review):** Upgraded `TrustState` to Enhanced Enums, fixed Exception double-wrapping in `cert_builder.dart`, added `signIdentityProof` for Ed25519 PoP compliance, added connection lifecycle methods to `Transport`, and expanded `crypto_test.dart` with robust negative testing (ASN.1 parsing and invalid key handling).
  - **Assessment:** **PASSED (100%)**

- **`[daemon-dart] Identity, Certificates, Frame Parsing` (Week 3):** Finalize core security.
  - Successfully built the standard Fail-Closed **X.509 Decoder (`cert_decoder.dart`)**. Safely extracted the Ed25519 key from the ASN.1 structure. **Security Hardening:** Passed 10 comprehensive attack vectors (missing OID, duplicate OID, unsupported critical flags, length anomalies, truncated DER, and fragile OID alteration) in `decoder_test.dart`. Fixed a critical Fail-Open bug to strictly reject unknown critical extensions.
  - Implemented the **Frame Codec (`frame_codec.dart`)** with a 4-byte length prefix structure. **Improvement:** Integrated `RiftFrameTransformer` (StreamTransformer) with a `try/finally` block to process data in chunks and guarantee memory zeroing on error. Optimized JSON parsing to return Map directly, completely preventing memory exhaustion (OOM) attacks and double-parsing overhead.
  - Finalized **`IdentityManagerImpl`**: Integrated the `cryptography` package to generate and store the Ed25519 key, calculating the standard `rift- + Base32` Device ID. **Security Hardening:** Added strict 32-byte length validation to `signIdentityProof`, verified async compliance via Contract Stubs, implemented `KeyPair` caching for extreme performance, and added memory clearing via `dispose()` to mitigate RAM scraping.
  - Fixed X.509 standard compliance in **`cert_builder.dart`** by generating cryptographically random 64-bit entropy serial numbers to prevent TLS caching collisions.
  - **Assessment:** **PASSED (100%)** 31/31 Security Unit Tests passing.

- **`[daemon-dart] mDNS, Transport, Session Orchestration` (Week 4):** Finalize Network.
  - Implemented **mDNS Discovery (`discovery_service_impl.dart`)** using `nsd`. Opaque Instance IDs are bound to the daemon session lifecycle to mitigate passive tracking. **Network Flap Fix:** Enhanced `_seenInstanceIds` with diff-based eviction logic. Services that disappear during network flaps are actively removed from the tracker, ensuring they are automatically re-discovered when the connection stabilizes.
  - Implemented **mTLS Transport (`transport_impl.dart`)** with `SecureServerSocket`. **Security Hardening:** Strictly extracts Ed25519 identity from custom X.509 extension; enforced Memory Exhaustion protection (64 KiB/32 MiB) with strict chunking limits. Added 10-second Handshake Timeout to mitigate Connection Slot Exhaustion. **Security Deferral:** Purposefully returns `true` inside `onBadCertificate` when `expectedDeviceId` is null to allow incoming peers, passing the absolute verification burden down to the Ed25519 PoP validation layer.
  - Created **Session Orchestrator (`session_manager.dart`)** to manage `session.hello` and `session.accept`. **Security Hardening:** Enforced Risk 6, Envelope Identity validation (`sourceDeviceId`), and proper `session.reject` error dispatching. Implemented `PoPManager` for Ed25519 PoP signature verification over a 113-byte dynamic structure to mitigate Canonicalization Attacks. **Fix (Critical):** Resolved a critical verification mismatch by enforcing that PoP signatures are generated using the **signer's own local certificate DER**. This guarantees the payload mathematically matches the certificate extracted by the verifier's TLS context.
  - Created the Root Daemon Orchestrator **`daemon.dart`** with `isolateEntryPoint` to encapsulate Android Background Services. **Resilience:** Implemented `Isolate.current.addErrorListener` to propagate fatal isolate crashes to the UI layer. **Fix:** Replaced auto-connect privacy risk with a bidirectional IPC `commandPort`, allowing the Flutter UI to explicitly trigger `connect` and `stop` commands.
  - **BLOCKER (High Risk):** Due to Dart `SecureSocket` limitations, `tls-exporter` (TLS 1.3) and Extended Master Secret (TLS 1.2) are unavailable. PoP signatures currently bind to a `_dummyChannelBinding` (32 bytes of zeros). This leaves the protocol vulnerable to Triple Handshake Attacks. Awaiting Architect Decision (ADR) on whether to downgrade spec to use Application Nonces or write a JNI/BoringSSL native plugin.
  - **Assessment:** Code structurally compliant, but pending Architect ADR for the TLS Channel Binding blocker.

- **`[daemon-dart] Security Audit & Hardening` (End of Week 4):** Conducted a deep-dive 16-point security and conformance audit across all Dart implementation files.
  - **Critical (C-1/C-2):** Resolved a severe Integer Overflow vulnerability in `Base32Utils` affecting Dart Web/JS builds (53-bit float limits) by implementing explicit bit clamping. Enforced strict memory zeroing of ephemeral TLS Certificates (`_tlsCertificateDer`) during daemon shutdown to prevent extraction from heap dumps.
  - **High (H-1 to H-4):** Eradicated silent `async void` error-swallowing in `SessionManager`, ensuring unhandled PoP verification exceptions immediately disconnect rogue peers. Mitigated stream aliasing hazards in `RiftFrameTransformer` by switching to `copy: true` buffers. Prevented racing data loss during shutdown by forcing kernel `socket.flush()`. Lifted `dispose()` abstractions to root interfaces to close leakage gaps.
  - **Medium (M-1 to M-5):** Solved a silent session starvation state where disconnected peers were locked out from reconnecting by integrating a reactive `onPeerDisconnected` stream. Bounded IPC `ReceivePort` lifecycles in `daemon.dart` behind `try/catch` logic to prevent headless port leaks on startup failures. Implemented dedicated unit tests for pre-auth (64 KiB) and post-auth (32 MiB) promotion boundaries.
  - **Low/Conformance (L-1 to L-5):** Corrected `session.reject` and `session.accept` envelope payloads to use the spec-compliant `id` instead of the legacy `messageId`. Improved mDNS logic to gracefully skip null-named instances without collapsing peers into an 'unknown' namespace. Replaced hardcoded testing payloads with structurally valid ASN.1 DER stubs.
  - **Documentation & Technical Debt:** Executed a massive comment cleanup across 7 core files (`session_manager.dart`, `cert_builder.dart`, `base32_utils.dart`, etc.). Purged verbose, redundant, and obsolete issue-tracker labels (`H-1:`, etc.), strictly preserving only non-obvious security rationales (e.g., JS integer bounds, TLS deference, Double OCTET STRING wrapping, and Risk 3/6 enforcement rules).
  - **Assessment:** **PASSED (100%)** Zero linter warnings. 35/35 Unit Tests passing (including 2 new frame boundary coverage tests).

- **`[daemon-dart] Capability Negotiation & Presence` (Week 6):** Added authenticated capability negotiation, trusted-peer presence tracking, and durable presence history.
  - Implemented `capability.advertise` / `capability.selected` negotiation with version intersection, responder-side validation, and a 5-second negotiation timeout.
  - Added `SessionContext` tracking for negotiated capabilities, trust state, heartbeat timers, and `lastHeartbeatReceived`.
  - Implemented trusted-peer `presence.update` handling with strict status validation, negotiated-capability enforcement, and durable `lastSeenAt` persistence through `TrustStoreImpl`.
  - Added SQLite schema migration from trust-store v1 to v2 to preserve older installs while introducing `lastSeenAt`.
  - Exposed `getPeerPresence` and `listTrustedPeers` responses through the daemon isolate bridge, including capability summaries and persisted timestamps.
  - Added unit coverage for malformed capability payloads, invalid selected sets, presence validation, heartbeat gating, trust-store persistence, and migration behavior.
  - **Battery Impact Check Status:** The heartbeat implementation is in place and ready for measurement, but real-device battery evidence is still pending. The required verification remains: run Android foreground-service measurements on at least one physical device in idle mode and in "1 trusted peer heartbeat" mode, capture `adb shell dumpsys batterystats` output, then record the observed drain and any interval/backoff decision here.
  - **Assessment:** **PASSED (100%)** Zero linter warnings. 43/43 Unit Tests passing.

---

## 2. System Specification Alignment (Protocol & IPC)

All architectural decisions in Week 1 and Week 2 are strictly designed to meet the two core specifications of the project:

### 2.1. Compliance with `spec/doc/protocol.md` (Network Protocol & Security)
- **Application in Week 1:** The specification strictly requires the ECDSA P-256 signature standard and X.509 extension. Since the Dart SDK is not powerful enough to manipulate custom OIDs, Week 1 finalized the infrastructure approach: installing 2 low-level libraries, `pointycastle` and `asn1lib`.
- **Application in Week 2 & 3:** Exactly executed Section 3.4 of the Protocol. Wrote `cert_builder.dart` to embed the custom OID (`2.25...`) containing the Ed25519 key, and `cert_decoder.dart` to decode it back with the secure Fail-Closed standard. The Device ID format was also strictly adhered to the `rift- + lowercase Base32` standard via `IdentityManagerImpl`. The `frame_codec.dart` framework strictly limits messages to 32 MiB according to the specification.

### 2.2. Compliance with `spec/doc/ipc.md` (Flutter Client Communication)
- **Application in Week 1:** Built a strict directory framework, separating the communication code area (`ipc/`) and core business code (`interfaces/`, `crypto/`).
- **Application in Week 2 & 3:** The IPC specification requires connections via JSON-RPC 2.0 over a Transport-agnostic binding. As a foundation, Week 2 & 3 created 5 Abstract Interfaces (`IdentityManager`, `DiscoveryService`...). This is the Abstraction Layer that forces future JSON-RPC communication code to interact through it, keeping the Daemon from being hard-coded to any rigid connection protocol.

---

## 3. Risk Assessment & Blockers (Post-Week 4)

1. **TLS-Exporter Blocker (Risk 1 / TLS Downgrade):**
   `dart:io` `SecureSocket` does not expose `tls-exporter` (RFC 9266) or Extended Master Secret (EMS) status. Falling back to an Application-Layer Nonce exposes the protocol to Triple Handshake Attacks (CVE-2014-1295), which is an unacceptable downgrade. **Action Required:** Pending Architecture Decision Record (ADR) from the Protocol Lead to either adopt a Native JNI/Kotlin BoringSSL plugin or revise the protocol spec. A dummy `_dummyChannelBinding` array is temporarily used.

2. **PoP Canonicalization Attack Vector:**
   The `RiftPoP-v2:` signing payload concatenates raw 32-byte fields. While our current implementation strictly enforces length invariants (`if (length != 32) throw Error`), the protocol specification (Section 5.3.1) lacks Length-Prefixes. Any future modifications to field sizes will introduce Canonicalization Vulnerabilities. **Action Required:** Logged as a speculative ADR to require Length-Prefixes.

3. **Plaintext Key Storage Risk (Future/Backlog):**
   Currently, `identity_manager_impl.dart` stores `identity.key` in plaintext. While protected by the Android App Sandbox (chmod 700), it remains vulnerable on rooted devices. Future iterations should explore Android Keystore integration via Flutter channels.
