# Rift v0.1 â Master Plan

**Timeline:** 12 weeks
**Scope:** Local-first, peer-to-peer secure clipboard continuity between Android and Windows. No cloud. Cloud relay, account management, and trust backup are explicit future work.
**Defensible thesis:** A security-first cross-platform device continuity protocol with two independent daemon implementations conforming to one written specification, designed to mitigate three documented KDE Connect CVEs.

## 1. Team & Ownership

| Member | Role | Primary scope |
|---|---|---|
| **BiÃªn** | Protocol & Security Lead | `spec/`, `tests-conformance/`, threat model, CVE comparative analysis, ASN.1 vectors, failure-reason mapping. Owns the protocol specification as a first-class artifact. |
| **Tháº¡o** | Windows Daemon Lead | `daemon-cs/`, Windows clipboard integration, mTLS stack, trust store, Windows Service packaging. |
| **Kiá»t** | Android Daemon Lead | `daemon-dart/`, Android networking, **custom X.509 ASN.1 parsing**, certificate generation via PointyCastle, foreground service integration. |
| **Kim** | Flutter & QA Lead | `app-flutter/`, pairing UI, trust management UI, system tray on Windows, `tests-interop/`, CI test automation, bug triage, QA sign-off. |

Security-sensitive changes (anything touching `spec/`, crypto code, or trust state) require review from at least BiÃªn plus one other team member. Kim has authority to block merges that fail CI.

## 2. Target Outcome (Week 12)

A frozen v0.1-draft protocol specification, complete with ASN.1 definitions and conformance test vectors. Two working daemons (C#/.NET 10 Windows Service; Dart-on-Android in Flutter foreground service) that pair, exchange clipboard content, and revoke trust durably, with the C# daemon also runnable as a standalone console process for CI. A Flutter app on Android and Windows (tray-resident on Windows) consuming both daemons through one JSON-RPC contract. A passing conformance test suite that runs against both daemon implementations. A passing interop test suite. A fuzz-tested ASN.1 parser. Comparative vulnerability analysis covering CVE-2025-66270, CVE-2025-32900, CVE-2025-32898. A STRIDE threat model. A demo script and known-issues document.

## 3. Working Rhythm

**Daily:** No standups required, but each member updates their in-flight GitHub issues with a brief status comment whenever they hit a blocker.

**Every Friday â Integration Checkpoint:** All open PRs targeting `main` must pass CI (which runs the conformance suite against both daemons as standalone processes). Kim runs the CI gate; failing PRs are not merged.

**Every Monday â Bug Triage:** 30-minute meeting. Kim leads. New bugs from the previous week get priority labels (`P0-blocker`, `P1-high`, `P2-medium`, `P3-low`) and assignees. Anything older than two weeks without progress gets escalated or closed.

**From Week 5 â Live Interop Test (Friday):** A live Windows â Android pairing and clipboard exchange test runs every Friday regardless of what feature is in development. Catches protocol drift early.

**QA Sign-off Rule:** A feature card moves to `Done` only when Kim has confirmed the relevant test cases pass on CI and (for user-facing features) on at least one live device pair.

**Issue Priority Order (use this for triage decisions):**
1. Security invariants (anything that could enable CVE-class attacks)
2. Protocol correctness (anything that breaks conformance between daemons)
3. Interop blockers (anything that breaks Windows â Android end-to-end flow)
4. Data integrity (clipboard corruption, trust store corruption)
5. App usability for the demo path
6. Polish

## 4. GitHub Projects Setup

**Project board view:** Kanban with columns `Backlog`, `This Week`, `In Progress`, `In Review`, `Blocked`, `Done`.

**Labels to create:**

- *Domain:* `spec`, `daemon-cs`, `daemon-dart`, `app-flutter`, `tests-conformance`, `tests-interop`, `docs`, `ci`, `security`
- *Type:* `feature`, `bug`, `test`, `infra`, `decision`
- *Priority:* `P0-blocker`, `P1-high`, `P2-medium`, `P3-low`
- *Status modifier:* `needs-spec`, `needs-review`, `needs-qa-signoff`, `blocked-on-other-daemon`
- *Risk flags:* `risk-asn1-parser`, `risk-cert-interop`, `risk-clipboard-perms`

**Milestones** (use GitHub Milestones, one per major checkpoint):

- `M1: Spec & Vectors Frozen` (end of Week 2)
- `M2: Encrypted Sessions Working` (end of Week 4)
- `M3: Pairing & Trust Persistent` (end of Week 5)
- `M4: Clipboard Round-Trip` (end of Week 7)
- `M5: Operation Lifecycle Complete` (end of Week 8)
- `M6: Interop Stable` (end of Week 10)
- `M7: Demo Ready` (end of Week 12)

**Branching:** `main` is always green. Feature branches named `<owner>/<short-description>` (e.g., `bien/asn1-vectors`, `thao/win-trust-store`). PRs require one review plus passing CI.

## 5. Risk Register

| Risk | Severity | Owner | Mitigation |
|---|---|---|---|
| Dart X.509 ASN.1 parser bugs (security-critical) | ð´ Critical | Kiá»t + BiÃªn | Prototype parser in Week 2-3 before higher-level features. Dedicated fuzz testing in Week 9. BiÃªn writes adversarial test vectors. |
| Certificate byte-incompatibility between BouncyCastle.NET and PointyCastle | ð´ Critical | BiÃªn + Tháº¡o + Kiá»t | First crypto deliverable in Week 3 is exchanging a known-good certificate between implementations. Don't proceed until parsers agree. |
| Protocol ambiguity causing incompatible implementations | ð  High | BiÃªn | Conformance fixtures land **before** Tháº¡o/Kiá»t implement each protocol layer. Spec must be precise enough to pass BiÃªn's tests blind. |
| mDNS reliability and Android background restrictions | ð  High | Kiá»t + Kim | Manual IP fallback for debugging. Test on Android 14 specifically given foreground service type rules. |
| Windows clipboard listener reliability (community packages) | ð¡ Medium | Tháº¡o + Kim | Prototype `clipboard_watcher` in Week 2-3; budget time for C++ shim fallback if needed. |
| Kim overloaded (UI + QA + CI) | ð¡ Medium | BiÃªn + Kim | BiÃªn writes conformance tests; Kim focuses on interop tests and CI gating. Revisit at Week 4. |
| Scope creep | ð¡ Medium | Whole team | Cloud relay, account management, trust backup, push notifications, session handoff, file transfer = explicit future work. Don't reopen without BiÃªn/supervisor approval. |

## 6. Weekly Breakdown

Each week below ends with a flat issue list ready to paste into GitHub Projects.

---

### Week 1 â Project Alignment & Spec Lockdown

**Goals:** Set up the workspace. Lock v0.1 scope. Decide protocol versioning, OID, and naming. Establish CI shape.

**Deliverables:** Monorepo initialized; `spec/protocol.md` skeleton; ADRs for OID choice, TLS version policy, protocol versioning, `Intent` naming, clipboard offer hash purpose, pairing flow, clock skew; CI pipeline skeleton; v0.1 feature list locked.

**Owner focus:**
- BiÃªn: Workspace setup, spec skeleton, ADR drafts, scope lockdown.
- Tháº¡o: C# daemon architecture spike; pick libraries (BouncyCastle.NET, Makaretu, StreamJsonRpc, Microsoft.Data.Sqlite); prototype Worker Service structure.
- Kiá»t: Dart daemon architecture spike; verify PointyCastle can construct a self-signed ECDSA P-256 certificate; assess `dart:io` `X509Certificate` limitations.
- Kim: Flutter project shell on Android and Windows; pairing/trust UX wireframes; set up CI (GitHub Actions) skeleton.

**GitHub issues to create:**
- `[spec][infra] Initialize monorepo and directory structure` â BiÃªn
- `[spec][decision] ADR-0001: Custom X.509 extension OID` â BiÃªn
- `[spec][decision] ADR-0002: TLS version policy` â BiÃªn
- `[spec][decision] ADR-0003: Protocol versioning scheme` â BiÃªn
- `[spec][decision] ADR-0004: Intent vs Action naming` â BiÃªn
- `[spec][decision] ADR-0005: Clipboard offer hash purpose` â BiÃªn
- `[spec][decision] ADR-0006: Pairing flow transport (mTLS-based)` â BiÃªn
- `[spec][decision] ADR-0007: Clock skew / TTL handling` â BiÃªn
- `[spec][docs] v0.1 feature list locked` â BiÃªn
- `[spec] Draft Section 1-2 (Introduction, Terminology)` â BiÃªn
- `[daemon-cs][infra] C# Worker Service skeleton with library choices documented` â Tháº¡o
- `[daemon-dart][infra] Dart daemon skeleton with PointyCastle smoke test` â Kiá»t
- `[daemon-dart][risk-asn1-parser] Spike: verify PointyCastle can build ECDSA P-256 cert` â Kiá»t
- `[app-flutter][infra] Flutter app shell for Android and Windows targets` â Kim
- `[app-flutter][docs] Wireframes: pairing, trusted devices, event log` â Kim
- `[ci][infra] GitHub Actions skeleton: lint, build, test matrix` â Kim

---

### Week 2 â Protocol Test Vectors & Core Architecture

**Goals:** Deterministic conformance vectors land before implementations diverge. Daemon module boundaries defined. Cross-language certificate compatibility verified at the byte level.

**Deliverables:** Conformance test vectors for Ed25519 identity, fingerprint format, valid/invalid certificate extension DER, frame envelope, clipboard hash. Daemon interface definitions in C# and Dart. Spec sections 3 (Cryptographic primitives) and 12 (Protocol versioning) drafted. **Milestone M1.**

**Owner focus:**
- BiÃªn: Authoritative test vectors generated via OpenSSL. Spec section 3 including the ASN.1 module for the custom extension. Conformance test runner harness.
- Tháº¡o: C# daemon module interfaces (`IIdentityManager`, `ITrustStore`, `ITransport`, `IDiscoveryService`, `IClipboardService`). Unit test skeleton.
- Kiá»t: Dart daemon module interfaces matching the C# shape. **PointyCastle certificate construction working end-to-end against BiÃªn's reference vectors.** Unit test skeleton.
- Kim: Flutter â daemon IPC spike (named pipe on Windows, isolate channel on Android). Unit test skeleton for the Flutter app.

**GitHub issues:**
- `[spec] Section 3: Cryptographic primitives drafted` â BiÃªn
- `[spec] Section 12: Protocol versioning and compatibility` â BiÃªn
- `[spec][test] Test vectors: Ed25519 keypair â device ID derivation` â BiÃªn
- `[spec][test] Test vectors: fingerprint format and derivation` â BiÃªn
- `[spec][test] Test vectors: custom extension DER (valid and malformed)` â BiÃªn
- `[spec][test] Test vectors: frame envelope encoding` â BiÃªn
- `[spec][test] Test vectors: clipboard offer hash` â BiÃªn
- `[tests-conformance][infra] Conformance test runner harness` â BiÃªn
- `[daemon-cs] Module interfaces and DI setup` â Tháº¡o
- `[daemon-cs][test] Unit test skeleton with first crypto tests` â Tháº¡o
- `[daemon-dart] Module interfaces matching C# shape` â Kiá»t
- `[daemon-dart][risk-cert-interop] Generate ECDSA cert with custom extension; verify against BiÃªn's vectors` â Kiá»t
- `[daemon-dart][test] Unit test skeleton with first crypto tests` â Kiá»t
- `[app-flutter] IPC spike: named pipe (Windows) and isolate channel (Android)` â Kim
- `[app-flutter][test] Widget test skeleton` â Kim
- `[ci] CI runs conformance suite against both daemons as standalone processes` â Kim

**Milestone M1 review:** Friday of Week 2. Both daemons must generate certificates that pass BiÃªn's conformance vectors. If either fails, Week 3 work is blocked until fixed.

---

### Week 3 â Identity, Certificates, Frame Parsing

**Goals:** Both daemons fully implement identity material and protocol frame handling. Custom X.509 extension parser works on both sides. Negative testing for malformed inputs.

**Deliverables:** Ed25519 identity generation and durable storage. ECDSA P-256 self-signed certificate generation. Frame encoder/decoder. Custom extension parser. Conformance tests pass for identity, extension DER, frame validation. Negative tests for malformed certificates pass. Spec section 5 (Transport security) drafted.

**Owner focus:**
- BiÃªn: Spec section 5. Conformance test cases for failure paths (malformed extension, wrong OID, wrong key length). Spec section 13 (test vectors) updated.
- Tháº¡o: C# identity manager, certificate generation, frame codec.
- Kiá»t: Dart identity manager, certificate generation, frame codec, **first version of the custom X.509 ASN.1 parser**. This parser is the highest-risk component in the project.
- Kim: Flutter settings/debug screen showing local device ID and fingerprint. Test cases for parser robustness against malformed inputs.

**GitHub issues:**
- `[spec] Section 5: Transport security drafted` â BiÃªn
- `[spec][test] Negative test vectors: malformed extensions, wrong OIDs, truncated certs` â BiÃªn
- `[daemon-cs] Ed25519 identity generation and storage` â Tháº¡o
- `[daemon-cs] ECDSA P-256 self-signed certificate generation with custom extension` â Tháº¡o
- `[daemon-cs] Frame encoder/decoder` â Tháº¡o
- `[daemon-cs] X.509 extension parser via System.Security.Cryptography` â Tháº¡o
- `[daemon-dart] Ed25519 identity generation and storage` â Kiá»t
- `[daemon-dart] ECDSA P-256 self-signed certificate generation with custom extension` â Kiá»t
- `[daemon-dart] Frame encoder/decoder` â Kiá»t
- `[daemon-dart][risk-asn1-parser] Custom X.509 ASN.1 parser v1` â Kiá»t
- `[tests-conformance] Identity + cert + frame tests pass on both daemons` â BiÃªn
- `[tests-conformance] Negative tests: malformed inputs rejected on both daemons` â BiÃªn
- `[app-flutter] Settings/debug screen with local identity display` â Kim
- `[app-flutter][test] Tests for parser robustness in UI layer` â Kim

---

### Week 4 â Discovery & Session Bootstrap

**Goals:** Devices discover each other on LAN and establish encrypted sessions. No protected operations yet â just the secure channel. **Milestone M2.**

**Deliverables:** mDNS-SD advertisement and discovery on both daemons (Makaretu on C#, `nsd` package on Dart). Mutual TLS 1.3 handshake. Post-handshake Ed25519 extraction and verification. `session.hello`, `session.accept`, `session.reject` messages. Event log entries for connection lifecycle. Spec section 4 (Discovery) and the session messages portion of section 6 drafted. Integration tests for discovery automation. Network-flapping resilience test.

**Owner focus:**
- BiÃªn: Spec section 4. Session transcript test vectors. Failure-reason mapping for handshake errors.
- Tháº¡o: Windows mDNS advertise + discover. TLS server/client. Session bootstrap.
- Kiá»t: Android mDNS via `nsd`. TLS server/client. Session bootstrap. Foreground service lifecycle integration.
- Kim: Trusted/discovered device list UI. Integration test for discovery flow. Simulated network drop test.

**GitHub issues:**
- `[spec] Section 4: Device discovery drafted` â BiÃªn
- `[spec] Session bootstrap messages in Section 6` â BiÃªn
- `[spec][test] Session transcript vectors and failure reasons` â BiÃªn
- `[daemon-cs] mDNS advertise/discover via Makaretu` â Tháº¡o
- `[daemon-cs] TLS 1.3 server and client with cert validation hook` â Tháº¡o
- `[daemon-cs] Post-handshake Ed25519 extraction and device ID verification` â Tháº¡o
- `[daemon-cs] session.hello/accept/reject implementation` â Tháº¡o
- `[daemon-dart] mDNS via nsd package (advertise + browse)` â Kiá»t
- `[daemon-dart] TLS 1.3 via SecureSocket` â Kiá»t
- `[daemon-dart] Post-handshake Ed25519 extraction via custom ASN.1 parser` â Kiá»t
- `[daemon-dart] session.hello/accept/reject implementation` â Kiá»t
- `[daemon-dart] Android foreground service hosting daemon isolate` â Kiá»t
- `[app-flutter] Discovered/trusted device list UI` â Kim
- `[tests-interop] Discovery integration test (automated)` â Kim
- `[tests-interop] Network drop / reconnect resilience test` â Kim

**Milestone M2 review:** Friday of Week 4. Both daemons must establish a mutual TLS session and post-handshake-verify each other's Ed25519 keys. **First live interop test runs this week** even though pairing isn't done yet â verifies the channel works.

---

### Week 5 â Pairing & Trust Store

**Goals:** Manual fingerprint pairing works end-to-end. Trust state persists durably. **Milestone M3.**

**Deliverables:** Pairing state machine (`pairing.start`, `pairing.approve`, `pairing.reject`, `pairing.complete`). Trust store with five states (discovered, pairing_pending, trusted, blocked, revoked). Fingerprint comparison UI. Event logging for pairing attempts and trust transitions. Scenario tests for pairing edge cases (reject, cancel, timeout, asymmetric approval). Live weekly interop test from this week onward.

**Owner focus:**
- BiÃªn: Spec section 6 (Trust state machine) finalized. Conformance cases for pairing including asymmetric approval/rejection. Threat model entry for pairing.
- Tháº¡o: Windows trust store (SQLite). Pairing logic. Persistent identity recovery on service restart.
- Kiá»t: Android trust store (sqflite). Pairing logic. Persistent identity recovery on foreground service restart.
- Kim: Flutter pairing approval flow with fingerprint display. E2E pairing test automated across Windows â Android.

**GitHub issues:**
- `[spec] Section 6: Trust state machine and pairing protocol finalized` â BiÃªn
- `[spec][test] Pairing transcript vectors including asymmetric approval` â BiÃªn
- `[security] Threat model entry for pairing flow` â BiÃªn
- `[daemon-cs] SQLite trust store with five states` â Tháº¡o
- `[daemon-cs] Pairing state machine` â Tháº¡o
- `[daemon-cs] Persistent identity recovery on restart` â Tháº¡o
- `[daemon-dart] sqflite trust store with five states` â Kiá»t
- `[daemon-dart] Pairing state machine` â Kiá»t
- `[daemon-dart] Persistent identity recovery on foreground service restart` â Kiá»t
- `[app-flutter] Pairing approval UI with fingerprint comparison` â Kim
- `[app-flutter] Trusted devices management screen` â Kim
- `[tests-interop] Automated E2E pairing test (Win â And and And â Win)` â Kim
- `[tests-interop] Pairing edge cases: reject, cancel, timeout` â Kim
- `[tests-interop][infra] Weekly live interop test schedule starts` â Kim

**Milestone M3 review:** Friday of Week 5. Live pairing test must succeed bi-directionally. Trust state must survive daemon restart on both sides.

---

### Week 6 â Capability Negotiation & Presence

**Goals:** Trusted peers negotiate which features they support. App displays authenticated peer availability.

**Deliverables:** `capability.advertise` and `capability.selected` flow. Authenticated presence updates (online/offline). `CapabilityUnavailable` typed failure for unsupported operations. UI showing peer status and capability summary. Heartbeat latency test.

**Owner focus:**
- BiÃªn: Spec section 7 (Capability negotiation) finalized. Capability/presence schema test vectors.
- Tháº¡o: Windows capability advertise/select. Presence heartbeats.
- Kiá»t: Android capability advertise/select. Presence heartbeats. Battery impact check.
- Kim: Device list polish with capability + presence indicators. Heartbeat-latency test.

**GitHub issues:**
- `[spec] Section 7: Capability negotiation finalized` â BiÃªn
- `[spec] Presence model in Section 10` â BiÃªn
- `[spec][test] Capability and presence schema vectors` â BiÃªn
- `[daemon-cs] Capability advertise/select` â Tháº¡o
- `[daemon-cs] Presence heartbeat publisher and reachability tracker` â Tháº¡o
- `[daemon-dart] Capability advertise/select` â Kiá»t
- `[daemon-dart] Presence heartbeat publisher and reachability tracker` â Kiá»t
- `[daemon-dart] Battery impact check for continuous heartbeats` â Kiá»t
- `[app-flutter] Peer status and capability summary UI` â Kim
- `[tests-interop] Heartbeat latency and presence sync tests` â Kim

---

### Week 7 â Clipboard Offer/Fetch

**Goals:** Clipboard content moves only via metadata offer and explicit authenticated fetch. **Milestone M4.**

**Deliverables:** Clipboard monitor on Windows and Android. `clipboard.offer`, `clipboard.fetchRequest`, `clipboard.fetchResponse`, `clipboard.fetchReject` messages. SHA-256 integrity check after fetch. Size-limit handling. Metadata-only event logging. Spec section 9 (Clipboard) finalized. Data integrity tests. Boundary tests (oversized, empty, special characters).

**Owner focus:**
- BiÃªn: Spec section 9. Clipboard conformance tests including hash-mismatch rejection.
- Tháº¡o: Windows clipboard read/write (in the user-session Flutter process, not the service â already decided architecture). Offer/fetch logic in the daemon.
- Kiá»t: Android clipboard via `ClipboardManager` through Kotlin shim. Offer/fetch logic in the daemon.
- Kim: Clipboard transfer status UI. Tray-resident behavior on Windows confirmed (closing window doesn't kill clipboard monitor). E2E clipboard test.

**GitHub issues:**
- `[spec] Section 9: Clipboard offer/fetch finalized` â BiÃªn
- `[spec][test] Clipboard conformance vectors including hash mismatch` â BiÃªn
- `[daemon-cs] Clipboard offer/fetch service` â Tháº¡o
- `[app-flutter][risk-clipboard-perms] Windows clipboard listener integration in tray-resident process` â Tháº¡o + Kim
- `[daemon-dart] Clipboard offer/fetch service` â Kiá»t
- `[app-flutter] Android clipboard integration via Kotlin platform channel` â Kiá»t + Kim
- `[app-flutter] Clipboard transfer status UI with progress` â Kim
- `[app-flutter] Tray-resident minimize-on-close behavior on Windows` â Kim
- `[tests-interop] E2E clipboard transfer test (Win â And)` â Kim
- `[tests-interop] Data integrity: hash verification post-fetch` â Kim
- `[tests-interop] Boundary tests: oversized, empty, special characters` â Kim

**Milestone M4 review:** Friday of Week 7. Clipboard transfer works at least one direction in the live interop test.

---

### Week 8 â Operation Lifecycle & Error Handling

**Goals:** Cross-device actions tracked consistently. Failures are inspectable instead of ad hoc. **Milestone M5.**

**Deliverables:** Operation lifecycle (using whatever name was decided in ADR-0004 â assume `operation.*` throughout). Idempotent terminal state handling. `InvalidTransition` rejection for stale messages. Standard event log entries for state changes. App view for recent operations and events. Crash-free testing under simulated failures.

**Owner focus:**
- BiÃªn: Spec section 8 (Operation lifecycle) finalized. Lifecycle test suite.
- Tháº¡o: C# operation manager. Error handling and recovery.
- Kiá»t: Dart operation manager. Error handling and recovery.
- Kim: Operation history UI. Event log viewer with filtering. Crash-free testing.

**GitHub issues:**
- `[spec] Section 8: Operation lifecycle finalized` â BiÃªn
- `[spec] Section 11: Security event log schema finalized` â BiÃªn
- `[spec][test] Lifecycle transition vectors including invalid transitions` â BiÃªn
- `[daemon-cs] Operation manager with state machine` â Tháº¡o
- `[daemon-cs] Standard error mapping and recovery` â Tháº¡o
- `[daemon-dart] Operation manager with state machine` â Kiá»t
- `[daemon-dart] Standard error mapping and recovery` â Kiá»t
- `[app-flutter] Operation history UI` â Kim
- `[app-flutter] Event log viewer with filters` â Kim
- `[tests-interop] Crash-free under network drop, daemon kill, malformed input` â Kim
- `[tests-interop] User-friendly error message validation` â Kim

---

### Week 9 â Revocation, Blocking & Security Hardening

**Goals:** Trust removal is durable and enforced immediately. Known CVE-class attack vectors covered by automated tests.

**Deliverables:** `trust.revoke` and local block/unblock. Durable negative-trust records (revoked Ed25519 keys cannot reconnect). Active session termination on revoke. Security test suite covering: device ID mismatch (simulates CVE-2025-66270), spoofed discovery metadata (simulates CVE-2025-32900), weak fingerprint brute force resistance (addresses CVE-2025-32898), malformed certificate extension, revoked peer reconnect attempt, unauthorized clipboard fetch. **Comparative vulnerability analysis document drafted.** ASN.1 parser fuzz testing run.

**Owner focus:**
- BiÃªn: Comparative vulnerability analysis document. Attack simulation test cases for each CVE. ASN.1 fuzz test corpus.
- Tháº¡o: Windows revoke and block enforcement. Session termination.
- Kiá»t: Android revoke and block enforcement. Session termination. ASN.1 parser fuzz testing.
- Kim: Revoke/block UI. Event visibility for security-related entries. Help BiÃªn run security tests.

**GitHub issues:**
- `[security] Comparative vulnerability analysis: CVE-2025-66270` â BiÃªn
- `[security] Comparative vulnerability analysis: CVE-2025-32900` â BiÃªn
- `[security] Comparative vulnerability analysis: CVE-2025-32898` â BiÃªn
- `[security][test] Attack simulation: device ID mismatch` â BiÃªn
- `[security][test] Attack simulation: spoofed discovery metadata` â BiÃªn
- `[security][test] Attack simulation: revoked peer reconnect` â BiÃªn
- `[security][test] Attack simulation: unauthorized fetch` â BiÃªn
- `[security][test][risk-asn1-parser] ASN.1 parser fuzz harness and corpus` â BiÃªn + Kiá»t
- `[daemon-cs] trust.revoke implementation with session termination` â Tháº¡o
- `[daemon-cs] Durable negative-trust persistence` â Tháº¡o
- `[daemon-dart] trust.revoke implementation with session termination` â Kiá»t
- `[daemon-dart] Durable negative-trust persistence` â Kiá»t
- `[app-flutter] Revoke/block UI with confirmation` â Kim
- `[app-flutter] Security event visibility in event log` â Kim

---

### Week 10 â Interop Stabilization & Bug Triage

**Goals:** Windows and Android work together repeatedly under realistic conditions. **Milestone M6.**

**Deliverables:** Comprehensive interop test scenarios. Bi-directional pairing (WinâAnd and AndâWin). Bi-directional clipboard. Reconnect after daemon restart. Network interruption tests. Updated `docs/known-issues.md`. Bug bash week â fix as many P0/P1 issues as possible.

**Owner focus:**
- BiÃªn: Interop scenario design. Bug triage with Kim.
- Tháº¡o: Fix Windows daemon defects surfaced by interop tests.
- Kiá»t: Fix Android daemon defects surfaced by interop tests.
- Kim: Demo path automation. Bug triage. CI test stability.

**GitHub issues:**
- `[tests-interop] Comprehensive interop scenario catalog` â BiÃªn
- `[tests-interop] Bi-directional pairing scenarios` â BiÃªn + Kim
- `[tests-interop] Bi-directional clipboard scenarios` â BiÃªn + Kim
- `[tests-interop] Daemon restart and reconnect tests` â BiÃªn + Kim
- `[tests-interop] Network interruption tests` â Kim
- `[docs] Known issues document updated` â BiÃªn + Kim
- `[daemon-cs][bug] Triage and fix all P0/P1 Windows defects` â Tháº¡o
- `[daemon-dart][bug] Triage and fix all P0/P1 Android defects` â Kiá»t
- `[app-flutter] Demo path automation` â Kim
- `[ci] Stabilize flaky tests; goal is zero flakes by end of week` â Kim

**Milestone M6 review:** End of Week 10. Live interop demo must succeed without intervention. All P0 bugs closed.

---

### Week 11 â Polish, Packaging & Documentation

**Goals:** Make the project demonstrable and reviewable. No new features. Bug fixes only with regression coverage.

**Deliverables:** Setup docs for Windows and Android. Demo script. Architecture overview document. Protocol conformance report. STRIDE threat model finalized. UI polish on main flows. Final regression run. Final test report.

**Owner focus:**
- BiÃªn: Protocol specification finalized and tagged v0.1-draft. STRIDE threat model finalized. Comparative vulnerability analysis finalized.
- Tháº¡o: Windows installer/run instructions. Windows Service deployment guide.
- Kiá»t: Android APK/run instructions. Foreground service setup notes.
- Kim: App polish. Demo script. Final regression test run. Final test report.

**GitHub issues:**
- `[spec] Tag v0.1-draft and freeze` â BiÃªn
- `[security] STRIDE threat model document finalized` â BiÃªn
- `[security] Comparative vulnerability analysis document finalized` â BiÃªn
- `[docs] Architecture overview` â BiÃªn
- `[docs] Protocol conformance report` â BiÃªn
- `[docs] Windows installation guide` â Tháº¡o
- `[docs] Android installation guide` â Kiá»t
- `[docs] Demo script with screenshots` â Kim
- `[app-flutter] UI polish: error messages, empty states, loading states` â Kim
- `[tests-interop] Final regression run` â Kim
- `[docs] Final test report` â Kim

---

### Week 12 â Freeze, Smoke Test & Defense

**Goals:** Stop feature work. Validate end-to-end story. Prepare presentation. **Milestone M7.**

**Deliverables:** Final v0.1 release branch. Passing conformance and critical interop tests. Final known-issues document. Demo (recorded or live). Final presentation/report. All P0/P1 issues closed.

**Owner focus:**
- BiÃªn: Final protocol and test evidence. Presentation slides on security architecture.
- Tháº¡o: Windows daemon stability. Final installer.
- Kiá»t: Android daemon stability. Final APK.
- Kim: Smoke test. Demo dry runs. Presentation slides on UX and QA.

**GitHub issues:**
- `[infra] Release branch v0.1-draft cut` â BiÃªn
- `[docs] Final presentation slides` â All
- `[tests-interop] Smoke test checklist executed daily` â Kim
- `[tests-interop] Demo dry run #1` â Whole team
- `[tests-interop] Demo dry run #2 (with mock supervisor questions)` â Whole team
- `[docs] Final defense materials assembled` â BiÃªn

---

## 7. Definition of Done

A card moves to `Done` only when:

1. Code is merged to `main`.
2. CI is green on `main` after the merge.
3. For features touching the protocol: a corresponding test in `tests-conformance/` exists and passes.
4. For features touching cross-platform behavior: a corresponding test in `tests-interop/` exists and passes.
5. For security-sensitive changes: BiÃªn has reviewed.
6. For user-facing features: Kim has signed off after manual verification.
7. Documentation (spec, ADR, or README) is updated if the change affects external behavior.

---

## 8. What's explicitly out of scope

These are deliberately deferred to future work and must not creep back in without supervisor approval and a scope discussion:

- Cloud relay / signaling server
- Account management / authentication / OAuth
- End-to-end-encrypted trust backup
- Push notifications (FCM / WNS)
- Mobile network handover beyond what mutual TLS handles natively
- Session handoff / file transfer / generic continuity beyond clipboard
- iOS, macOS, Linux clients or daemons
- Relay-based discovery for devices on different networks

If the team identifies a need to add any of these mid-project, the request goes through BiÃªn and the supervisor before any work begins.

---

Two practical things for setting this up in GitHub Projects:

When you create the project, use the **Roadmap** view alongside the Kanban view â it'll let you visualize the milestone dependencies (M1 blocks M2, M2 blocks M3, etc.). GitHub Projects' built-in iteration field maps cleanly onto your weeks, so set up 12 iterations named Week 1 through Week 12 and use them as the timeline axis on the Roadmap.

Create the issues for Weeks 1 and 2 in full detail right now, so the team can start picking up cards on day one. Create the issues for Weeks 3 onward as placeholder stubs with just the title, owner, and labels â fill in the descriptions during the prior Friday's planning conversation. This avoids spending three days writing 100 detailed issues that may need rewriting once you learn what week 1 actually surfaces.
