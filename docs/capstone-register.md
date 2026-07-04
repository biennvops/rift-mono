# CAPSTONE PROJECT REGISTER

**Class**:            **Duration time**:  from ..……/20…. To ..….…./20….. **(\*) Profession:** **Specialty**: ☐ ☐ ☐ **(\*) Kinds of person make registers:**     Lecturer ☐     Students ☑

## 1. Register information for supervisor (if have)

| No. | Fullname | Phone | E-Mail | Title |
| :---- | :---: | :---: | :---: | :---: |
| Supervisor |  |  |  | Mr. |
| Supervisor |  |  |  | Mr. |

## 2. Register information for students (if have)

|  | Full name | Student code | Phone | E-mail | Role in Group |
| :---: | :---: | :---: | :---: | :---: | :---: |
|  |  |  |  |  | Leader |
|  |  |  |  |  | Member |
|  |  |  |  |  | Member |
|  |  |  |  |  | Member |

## 3. Register content of Capstone Project

**(\*) 3.1. Capstone Project name:**

- English: Rift: A Security-First Cross-Platform Device Continuity Platform
- Vietnamese: Rift: Nền tảng liên thông thiết bị đa nền tảng ưu tiên bảo mật

Abbreviation: RIFT

### 1. Context

The average user in 2026 operates across 3–5 personal devices daily — laptops, desktops, tablets, and smartphones — yet making these devices work together seamlessly and securely remains an unsolved problem with significant security implications. Cross-device data exchange involves some of the most sensitive content a user handles daily: clipboard contents that may include passwords, credentials, and private communications; local document exchange during continuity workflows; and device activity metadata that reveals behavioral patterns. Despite this sensitivity, existing cross-device solutions fall into three categories, each with critical shortcomings in security, privacy, or accessibility.

**Ecosystem-locked solutions** such as Apple Continuity (Universal Clipboard, Handoff, AirDrop) and Samsung Flow provide excellent user experience but only within their own ecosystems. A user with an Android phone and a Windows laptop — one of the most common device combinations globally — is entirely excluded. These solutions also route data through proprietary cloud infrastructure (iCloud, Samsung Cloud), giving the vendor persistent access to user data including clipboard contents, file metadata, and device activity patterns. Users have no ability to audit what data is collected, how long it is retained, or who can access it.

**Cloud-dependent services** such as Google Drive, OneDrive, and messaging applications require internet connectivity and route data through third-party servers. For sensitive workflows — software development (API keys, environment variables), legal work (privileged communications), medical environments (patient data), corporate settings (trade secrets) — this increases exposure to third-party infrastructure and creates additional privacy, auditability, and compliance considerations. A local-first solution that keeps core device-to-device communication on the user's own network reduces dependence on external processors and better supports privacy-focused deployment goals.

**Open-source alternatives** such as KDE Connect attempt to solve this problem but have demonstrated serious, repeated security failures. While KDE Connect offers limited or experimental support on Windows and iOS, its primary user base is on Linux and Android, and it lacks a polished cross-platform experience for the most common device combinations. In 2025 alone, KDE Connect disclosed multiple critical vulnerabilities that expose fundamental protocol design weaknesses:

- CVE-2025-66270 (Critical, November 2025): An attacker could impersonate a previously paired device and bypass authentication entirely. The KDE Connect protocol version 8 failed to validate that the device ID in the discovery packet matched the device ID in the subsequent authentication packet. By first sending an unpaired device ID (which requires no authentication) and then switching to a paired device ID, an attacker could gain full access with the privileges of the impersonated device. This is not an implementation bug — it is a fundamental protocol design flaw in the authentication model.

- CVE-2025-32900 (Medium, April 2025): Unauthenticated UDP broadcast packets allowed attackers to spoof device names and icons of legitimate paired devices, potentially tricking users into pairing with malicious devices that appear identical to their real ones.

- CVE-2025-32898 (April 2025): The verification code protocol used only 8 characters, making brute-force attacks computationally feasible and undermining the pairing verification process.

These vulnerabilities demonstrate that KDE Connect's security model was designed as an afterthought rather than a foundational concern.

Beyond security, there is a fundamental market gap: no existing solution provides all of the following simultaneously: (1) works across Android, Windows, and other platforms without ecosystem lock-in; (2) operates entirely on the local network with no cloud dependency; (3) implements cryptographically rigorous device identity and mutual authentication; (4) provides a formal, auditable trust model with explicit states and revocation; and (5) is available as an open protocol that anyone can implement or extend.

This project builds "Rift", a security-first, local-first, cross-platform device continuity platform that addresses these requirements through a daemon-centered architecture. Rift uses a dual-keypair cryptographic identity model — Ed25519 for permanent device identity with mutual fingerprint verification, and ECDSA P-256 for TLS certificate authentication with the Ed25519 public key embedded as an X.509 extension. The system implements a formal trust model with explicit states, ships two independent daemon implementations conforming to a single written protocol specification, and is designed as an open protocol that can be extended in future work.

Rift is composed of three major components. First, the **Rift protocol specification**, a written, language-independent contract that defines wire formats, cryptographic operations, state machine transitions, and message schemas for every cross-device interaction. Second, two independent **daemon implementations** that conform to this specification: a C#/.NET 10 daemon (riftd) deployed as a Windows Service on Windows, and a Dart daemon hosted inside a Flutter foreground service on Android. Both daemons manage device identity, cryptographic trust, peer-to-peer encrypted communication, clipboard capability handling, and structured security event logging. Each daemon is also runnable as a standalone console process for development and continuous integration testing, with platform-specific service hosting (Windows Service, Android foreground service) treated as a thin lifecycle wrapper around the same daemon core. Third, the **Rift Flutter application**, a single Dart codebase that ships to Android and Windows and provides the user-facing experience for pairing, clipboard continuity, presence, and security event viewing. On Windows the Flutter application is tray-resident and minimizes-on-close so that clipboard monitoring and notifications remain active throughout the user session.

The Flutter application communicates with whichever daemon it is paired with through a single JSON-RPC 2.0 IPC contract that is intentionally transport-agnostic: named pipes on Windows, and `SendPort`/`ReceivePort` channels between Dart isolates on Android, with the same JSON-RPC framing applied on top in both cases. Because the same JSON-RPC contract is exercised regardless of host OS, the Flutter UI has exactly one client implementation that works against every supported daemon host, and the same conformance harness validates every daemon implementation. The IPC contract is also designed to extend to Unix domain sockets on macOS (launchd agents) and Linux (systemd services) and to in-process channels on iOS, all as documented future work. Protocol semantic equivalence between the two implementations is verified by automated conformance tests that run against both daemon implementations, plus cross-platform integration tests that drive a Dart-on-Android daemon and a C#-on-Windows daemon through end-to-end pairing, encrypted communication, clipboard exchange, and basic presence.

This platform has 2 roles:

- **Admin/Developer (AD)**:
  - Configures daemon behavior, monitors node health and security event logs, manages trust policies and capability permissions, and maintains protocol/API documentation and verification assets.

- **End-User (EU)**:
  - Uses the Rift Flutter application on their personal devices to securely pair devices, share clipboard content, monitor device presence, and manage trusted device relationships.

This project targets 2 main goals:

- **Software Engineering**:
  - Design and implement a daemon-centered distributed system with a formal cryptographic trust model that specifically addresses the authentication bypass (CVE-2025-66270), device spoofing (CVE-2025-32900), and weak verification (CVE-2025-32898) vulnerabilities demonstrated by existing solutions.
  - Develop two independent daemon implementations (C# on Windows, Dart on Android) of a single written protocol specification, plus a single Flutter/Dart client codebase that consumes both daemons through one transport-agnostic JSON-RPC IPC contract.

- **Security Engineering**:
  - Define, document, and validate the security architecture through structured threat modeling, explicit trust-state transitions, typed failure handling, and comparative vulnerability analysis against documented KDE Connect weaknesses.
  - Produce protocol, IPC, conformance, and security documentation that demonstrates a defensible capstone focused on correctness, auditability, and IPC boundary discipline between daemons and the Flutter client.

The main objectives and context for this project are as follows:

1. **Language-Independent Protocol Specification as a First-Class Artifact**:
   - Author the Rift protocol specification as a written, language-independent contract that defines wire formats, cryptographic operations, the exact ASN.1 structure of the custom X.509 extension carrying the Ed25519 public key, state machine transitions, message schemas, and the structured event log schema. The specification serves as the conformance contract that both daemon implementations satisfy and as the reference document for any future implementation in other languages.

2. **Security-First Device Identity & Trust**:
   - Implement a dual-keypair cryptographic identity model: Ed25519 for permanent device identity (fingerprint verification, trust store operations, device ID derivation) and ECDSA P-256 for TLS certificate authentication. The Ed25519 public key is embedded in the ECDSA P-256 self-signed X.509 certificate as a custom X.509 extension under a stable OID defined by the protocol specification, enabling standard mutual TLS with explicit device-identity binding. This design is intended to address the authentication bypass vulnerabilities (CVE-2025-66270) and weak verification codes (CVE-2025-32898) found in existing solutions. Design a formal trust state machine (discovered → pairing_pending → trusted → blocked → revoked) with explicit state transitions and cryptographic validation at each step. Ensure device identity is bound to a single Ed25519 keypair and verified consistently across all protocol exchanges to reduce the risk of device ID mismatch attacks.

3. **Encrypted Local-First Communication with Data Sovereignty**:
   - All peer-to-peer communication is encrypted via mutual TLS, with TLS 1.3 preferred and TLS 1.2 fallback allowed where platform limitations require it, using ECDSA P-256 certificate authentication. After TLS handshake, the Ed25519 public key embedded in the peer's certificate extension is extracted and verified against the local trust store. In the capstone MVP, core device-to-device communication is designed to remain on the local network without requiring cloud servers. Device discovery via mDNS exposes only minimal, non-sensitive metadata, and device information is treated as authenticated only after TLS-based identity verification succeeds. This architecture supports local-first data handling and reduces dependence on third-party infrastructure for core continuity flows.
   - The intended operating model is "same local network, direct peer reachability". The MVP must continue to function when the local network has no upstream internet access, provided local multicast discovery and direct peer transport remain available. By contrast, internet-only connectivity without local reachability is not a capstone-core requirement and is treated as future work rather than expected runtime behavior.

4. **Cross-Platform Clipboard Continuity MVP**:
   - Implement a clipboard-first cross-device flow based on metadata-only offers, explicit authenticated fetch, deterministic expiry, and typed failure handling. This capability forms the primary user-facing demonstration of the platform's trust model, transport correctness, and IPC integration with the Flutter client.

5. **Capability-Driven Cross-Platform Protocol**:
   - Design a capability negotiation system where each device advertises the functionality required for the capstone MVP, especially clipboard offer/fetch support and the permissions needed to use it. Heterogeneous devices with different OS capabilities interoperate through an authenticated negotiated capability set rather than assuming that every feature exists on every platform.

6. **Structured Operation Lifecycle with Full Auditability**:
   - Implement a formal operation state machine (Created → Pending → Dispatched → Active → Done/Failed/Expired), with Intent retained only as an older project synonym where needed, and typed failure reasons that every cross-device action flows through. Every state transition is recorded to a structured, append-only security event log, providing complete auditability of cross-device operations and supporting debugging, verification, and security review.

7. **Basic Presence & Peer Visibility**:
   - Keep the capstone presence model intentionally small: online/offline visibility, last-seen context, and reachability state needed for peer visibility, debugging, and authenticated clipboard flow decisions.

8. **Capstone-Core Verification and Documentation**:
   - Deliver the capstone around security-focused engineering artifacts: protocol specification, IPC specification, threat model, comparative vulnerability analysis, cross-implementation conformance tests, and security tests. Two independent daemon implementations (C# and Dart) conforming to the same protocol specification provide stronger correctness evidence than any single implementation could. Features outside the MVP critical path, such as relay or monetization, may be documented as future work but are not required to defend the capstone core.

9. **Transport-Agnostic IPC for Future Platform Extension**:
   - The JSON-RPC 2.0 IPC contract between daemon and Flutter client is defined independently of any specific transport. On Windows it is served over named pipes; on Android it is served over `SendPort`/`ReceivePort` channels between a UI Dart isolate and a dedicated background daemon Dart isolate, with JSON-RPC framing applied on top so the contract is exercised identically to the Windows case. The same contract is intended to extend cleanly to Unix domain sockets on macOS (launchd) and Linux (systemd) and to in-process channels on iOS, all as documented future work. This design ensures that adding a new platform requires implementing only a new daemon host and a new transport binding, never changes to the protocol, the IPC contract, or the Flutter UI.

### 2. Proposed Solutions

The implementation of Rift involves two independent daemon backends (C#/.NET on Windows, Dart on Android), a single cross-platform Flutter application (Android + Windows), and a security-focused verification/documentation package. Below is a comprehensive breakdown of the proposed solutions:

- **Rift Protocol Specification (language-independent contract)**:
  - Author a written specification covering the wire format, cryptographic operations (Ed25519 identity and signing, ECDSA P-256 TLS certificates with custom X.509 extension, mutual TLS with TLS 1.3 preferred and TLS 1.2 fallback where platform limitations require it, post-handshake Ed25519 verification), the exact ASN.1 structure of the custom X.509 extension (including OID, criticality flag, and value encoding for the embedded Ed25519 public key), trust state machine, operation lifecycle state machine, capability negotiation, clipboard offer/fetch semantics, presence model, and structured event log schema.
  - The specification is the conformance contract that both daemon implementations must satisfy and the reference document for any future implementation (Swift on iOS/macOS, Rust on Linux, etc.).

- **Daemon Core on Windows — riftd (C#/.NET 10)**:
  - Implement a local-first daemon as a .NET 10 Worker Service using async/await with `System.Threading.Channels` for the internal event bus. The daemon manages device identity (dual-keypair model), peer discovery (mDNS-SD via Makaretu.Dns.Multicast), encrypted transport (mutual TLS with TLS 1.3 preferred and TLS 1.2 fallback where platform limitations require it, using ECDSA P-256 certificate authentication via `SslStream`, with Ed25519 identity binding verified post-handshake), and SQLite persistence via Microsoft.Data.Sqlite for durable state: trusted peers, identity, capability grants, preferences, and structured security event log.
  - The daemon core is runnable as a standalone .NET console process for development and CI testing. Deployment as a Windows Service is a thin lifecycle wrapper around the same core so that background daemon behavior (discovery, trust, transport, persistence, event log) is independent of any logged-in user session and survives the Flutter UI being closed.
  - Expose the documented JSON-RPC 2.0 IPC API via StreamJsonRpc over a named pipe, consumed by the Flutter Windows client.

- **Daemon Core on Android (Dart, in Flutter foreground service)**:
  - Implement a second, fully independent daemon in Dart that conforms to the same protocol specification. The daemon runs inside a dedicated background Dart isolate hosted by a Flutter foreground service, with a persistent notification indicating active participation in the Rift trust mesh. The UI Dart isolate communicates with the daemon isolate through a `SendPort`/`ReceivePort` pair with JSON-RPC 2.0 framing layered on top, exercising the same IPC contract as the Windows transport.
  - The daemon core is also runnable as a standalone Dart console process for development and CI testing, with the Android foreground service treated as a thin lifecycle wrapper around the same core.
  - Cryptography uses PointyCastle for Ed25519 keypair generation, signing and verification, fingerprint derivation, and ECDSA P-256 keypair generation. X.509 certificate construction is implemented by assembling the certificate's ASN.1 structures (`TBSCertificate`, `AlgorithmIdentifier`, `Extensions`, etc.) explicitly via PointyCastle's ASN.1 primitives, including the custom Ed25519 extension at the OID and DER structure mandated by the protocol specification.
  - Encrypted transport uses Dart's `SecureSocket` with a `SecurityContext` configured with the device's ECDSA P-256 certificate chain and private key for mutual TLS, with TLS 1.3 preferred and TLS 1.2 fallback where platform limitations require it. Post-handshake, the peer certificate's raw DER bytes are retrieved via `SecureSocket.peerCertificate.der` and parsed by a purpose-built ASN.1 parser in the daemon (built on PointyCastle primitives) to locate the custom extension, extract the Ed25519 public key, and verify it against the local trust store. This custom parsing is necessary because `dart:io`'s `X509Certificate` API does not expose certificate extensions and is therefore treated as a security-sensitive component subject to dedicated fuzz testing (see Task Package 6).
  - Peer discovery and advertisement use the `nsd` Flutter package, which wraps Android's `NsdManager`, on both browse and register paths. The same package is used on the Flutter Windows host where applicable.
  - Persistence uses `sqflite` for the same trust store, capability grants, and structured security event log schema described in the protocol specification.

- **Cryptographic Trust Engine (consistent semantics across both daemons)**:
  - Both implementations realize the dual-keypair identity model identically. Ed25519 keypair: permanent device identity. The Ed25519 public key is used for trust store operations, human-readable cryptographic fingerprint derivation (from the full 32-byte public key), and device ID derivation (hash of public key). The fingerprint addresses CVE-2025-32898 where KDE Connect's 8-character verification code was brute-forceable.
  - ECDSA P-256 keypair: TLS certificate authentication. A self-signed X.509 certificate wraps the ECDSA P-256 key, with the Ed25519 public key embedded as a custom X.509 extension under a stable OID and DER structure mandated by the protocol specification. On .NET the certificate is generated via `System.Security.Cryptography.ECDsa` and `CertificateRequest`, with BouncyCastle.NET used for the custom extension where finer ASN.1 control is required. On Dart the certificate is generated by assembling the ASN.1 structures via PointyCastle's ASN.1 primitives.
  - Mutual TLS with ECDSA P-256 certificate authentication is implemented via `SslStream` (C#) and `SecureSocket`/`SecurityContext` (Dart), with TLS 1.3 preferred and TLS 1.2 fallback where platform limitations require it. After TLS handshake, both implementations extract the Ed25519 public key from the peer's certificate extension and verify it against the local trust store. On .NET this uses standard `X509Extension` enumeration; on Dart this uses the daemon's purpose-built ASN.1 parser operating on the peer certificate's DER bytes. This keeps the transport model aligned with standard mutual TLS and explicit device-identity binding rather than a custom authentication protocol.
  - Both implementations are required to produce **semantically equivalent** wire-format output for every protocol message, verified by cross-implementation conformance tests. Byte-level equality is required specifically for the custom X.509 extension OID and DER encoding (so each implementation's parser can recognize and decode the other's extension); for other protocol messages, semantic equivalence under the protocol specification is the binding requirement.
  - Both implement the formal trust state machine with five explicit states (discovered, pairing_pending, trusted, blocked, revoked) and cryptographic validation at each transition. Device ID derived from the Ed25519 public key hash is validated consistently across every protocol packet within a session — directly addressing CVE-2025-66270.
  - All device information (name, type, capabilities) is exchanged only over authenticated TLS sessions — directly addressing CVE-2025-32900.
  - Trust revocation deletes the peer's key material (both Ed25519 and ECDSA P-256 certificate) from the local trust store, immediately terminates all active sessions, and permanently rejects future connection attempts from the revoked Ed25519 public key. Re-establishing trust requires a full new pairing flow from scratch.
  - Private key material never leaves the daemon process on either platform, is never transmitted over the network, and is never accessible through the JSON-RPC IPC API.

- **Operation Lifecycle State Machine**:
  - Both daemons implement the unified operation state machine (Created → Pending → Dispatched → Active → Done/Failed/Expired) with typed failure reasons (PeerUnreachable, PeerRejected, OfferExpired, CapabilityUnavailable, ConnectionLost, Timeout, PolicyDenied). Every capstone-core cross-device action flows through this machine. Every state transition emits an event on the internal bus, is pushed to subscribed Flutter clients via JSON-RPC subscriptions, and is appended to the structured event log. Intent remains only as an older project synonym where existing UI copy needs that bridge.

- **Capability Negotiation Protocol**:
  - Capability advertisement is exchanged during TLS session handshake. Each device sends the capabilities required for the capstone MVP and both peers compute the authenticated supported set for the session. Clipboard offer/fetch is the primary required capability, with the model kept extensible for future additions.

- **Clipboard Offer/Fetch Engine**:
  - Implement the offer/fetch model: local clipboard change detected by the Flutter client through platform integration (Android `ClipboardManager` via Kotlin platform-channel shim; Windows clipboard listener via `clipboard_watcher` or equivalent, hosted by the tray-resident Flutter Windows process) and forwarded to the local daemon over JSON-RPC → daemon broadcasts metadata (content type, size, hash — never the actual content) to trusted peers → ephemeral offer with configurable TTL (default 120 seconds) stored on receiving devices → actual content transferred only on explicit demand (user tap or auto-accept policy) → automatic expiry and cleanup of unclaimed offers.
  - This design avoids the security risk of eagerly pushing clipboard contents (which frequently contain passwords, API keys, authentication tokens, and sensitive text) to all devices unconditionally. The user explicitly decides when content is transferred.
  - The Windows clipboard listener is hosted in the user-session Flutter process rather than the Windows Service because Windows Session 0 isolation prevents service processes from interacting with user-session clipboard state. The Flutter Windows application is therefore implemented as a tray-resident application: closing the window minimizes the application to the system tray rather than terminating it, so clipboard monitoring and offer notifications remain active throughout the user session while the Windows Service continues to own background discovery, trust, transport, persistence, and event-log behavior.

- **Reduced Session Handoff Boundary**:
  - Keep session handoff outside the capstone critical path. If documented, it should be treated as a reduced future extension using user-selected files, recent documents, or app-owned files rather than generic active/open-file detection.

- **Security Verification & Conformance**:
  - Build the security-focused validation package around structured threat modeling, comparative vulnerability analysis, cross-implementation protocol conformance testing (the same harness driven against both the C# and Dart daemons running as standalone console processes in CI), cross-platform interop testing (C# daemon paired with Dart daemon end-to-end), deterministic failure-path verification, and dedicated fuzz testing of the Dart daemon's custom X.509 ASN.1 parser with malformed certificates. The capstone emphasizes protocol correctness, security properties, and IPC boundary discipline.

- **Future Extension Boundary**:
  - Features such as relay transport, trust backup, account management, subscriptions, broader continuity flows, and additional platform targets (Linux daemon via systemd, macOS daemon via launchd, iOS in-process daemon, additional Flutter desktop targets) may be documented as future extensions. The transport-agnostic IPC design is intended to make these additions straightforward without changing the protocol, the IPC contract, or the Flutter UI. iOS support specifically is expected to require Apple's Local Push Connectivity entitlement (`NEAppPushManager`), which is granted on a per-app review basis by Apple and is therefore noted as a future-work dependency outside the team's direct control. They are not required capstone-core deliverables and must not block demonstration of the software-engineering and security objectives.

- **Cross-Platform Flutter Application (Dart/Flutter)**:
  - Build a single Flutter application targeting Android and Windows from one Dart codebase, with Material 3 and platform-adaptive widgets so the same UI scales between phone and desktop form factors.
  - Implement a single Dart JSON-RPC 2.0 client (`JsonRpcRiftClient`) that consumes the daemon's IPC contract identically on both targets. On Windows it connects to the riftd Windows Service over a named pipe; on Android it connects to the dedicated background daemon Dart isolate over a `SendPort`/`ReceivePort` pair with JSON-RPC framing applied. The Flutter UI does not distinguish between the two transports — both are JSON-RPC 2.0.
  - On Android, implement a thin Kotlin platform-channel shim that owns the Flutter foreground service lifecycle, bridges clipboard monitoring through `ClipboardManager`, and surfaces Android notifications. The foreground service is declared with the combined service types `connectedDevice|dataSync`, qualified by the `CHANGE_WIFI_MULTICAST_STATE` manifest permission required for mDNS multicast. The Kotlin shim contains no protocol, trust, or cryptographic logic; mDNS-SD advertisement and discovery are performed in Dart via the `nsd` package.
  - On Windows, implement a thin C++/C# platform-channel shim that hooks the system clipboard, integrates with the system tray (via `tray_manager` or equivalent), and surfaces native Windows notifications (via `local_notifier` or equivalent). The Flutter Windows application runs as a tray-resident process that minimizes-on-close so clipboard monitoring and notifications remain active for the duration of the user session. All background core behavior remains inside the riftd Windows Service.
  - UI features delivered from the Dart layer: device discovery and pairing flow with Ed25519 fingerprint verification, trusted peer list with real-time presence, clipboard offer notifications with one-tap fetch, intent history with state transitions, security event log viewer, and device capability overview.
  - Authoritative state (identity, trust store, event log) lives only inside the daemon's SQLite database, never duplicated client-side. The Flutter layer may cache view-model state in memory but does not persist authoritative protocol state.

- **Structured Security Event Log**:
- Both daemons implement an append-only event log in SQLite recording every security-relevant event: pairing attempts (successful and rejected), trust state transitions, connection establishments and failures, authentication rejections, operation lifecycle transitions, clipboard operations (metadata only), and other audited security/runtime events required for the capstone MVP. This log is queryable via the IPC API and displayed in the Flutter app's security dashboard.

#### Functional requirements

**Daemons (riftd C# on Windows, Dart daemon on Android) — Security & Communication**

- Daemon can generate and securely persist the dual-keypair identity (Ed25519 + ECDSA P-256 self-signed certificate with the Ed25519 custom extension at the OID and DER structure mandated by the protocol specification) on first run.
- Daemon can advertise presence via mDNS-SD without exposing sensitive device information.
- Daemon can discover peers on the local network and present them as "discovered" (untrusted) to connected clients.
- Daemon can perform mutual pairing with full Ed25519 cryptographic fingerprint verification and persist the trust relationship.
- Daemon can validate device ID (derived from Ed25519 public key hash) consistency across all protocol packets within a session, preventing impersonation attacks.
- Daemon can establish and maintain mutual TLS sessions, with TLS 1.3 preferred and TLS 1.2 fallback where platform limitations require it, using ECDSA P-256 certificate authentication and post-handshake Ed25519 identity verification for all peer communication.
- Daemon can exchange authenticated device information (name, type, capabilities) only over TLS, never via unauthenticated channels.
- Daemon can revoke trust: delete peer key material (Ed25519 and certificate), terminate active sessions, reject all future connections from the revoked Ed25519 key.
- Daemon can exchange authenticated capability advertisements during session handshake and compute the mutually supported capability set required for the capstone MVP.
- Daemon can route operations through the lifecycle state machine with typed failure reasons, timeout handling, and event emission.
- Daemon can broadcast clipboard offer metadata to trusted peers and serve content on authenticated fetch requests.
- Daemon can publish presence heartbeats at configurable intervals and track peer reachability with timeout-based offline detection.
- Daemon can record all security-relevant events to the structured security event log promptly enough to support audit views, debugging, and deterministic verification.
- Daemon can expose all functionality via JSON-RPC 2.0 IPC with bidirectional event subscriptions, over named pipe on Windows and over a `SendPort`/`ReceivePort` isolate channel on Android.
- Daemon core can run as a standalone console process on a developer machine or CI runner, independent of any platform-specific service host (Windows Service or Android foreground service).

**Flutter Application — User Interface**

- User can view discovered and trusted devices with real-time online/offline status indicators.
- User can initiate pairing and visually verify the Ed25519 cryptographic fingerprint before confirming trust.
- User can unpair/revoke trusted devices with immediate effect.
- User can receive clipboard offer notifications showing content type, size, and source device.
- User can accept or fetch clipboard content with one tap.
- User can view operation history with full state transition audit trail (timestamps, status changes, failure reasons).
- User can view the security event log filtered by event type, severity, and time range.
- User can view basic presence information for paired devices, including online/offline status, last seen time, capabilities, and trust state.
- On Windows, closing the application window minimizes the application to the system tray rather than terminating it; clipboard monitoring and notifications remain active until the user explicitly exits from the tray menu.

#### Non-functional requirements

- Daemon startup and identity recovery must remain responsive enough for repeatable local demo and test workflows on both implementations.
- Peer discovery, pairing, local IPC, and clipboard-offer visibility must remain responsive under normal capstone MVP usage on a local network.
- All peer-to-peer communication must be encrypted via mutual TLS, with TLS 1.3 preferred and TLS 1.2 fallback where platform limitations require it, using ECDSA P-256 certificate authentication and Ed25519 identity verification; no plaintext data exchange at any point after discovery.
- Private key material (both Ed25519 and ECDSA P-256) must never leave the daemon process, be transmitted over the network, or be accessible via the IPC API. This requirement applies identically to both the C# and Dart daemon implementations.
- The structured event log must record security-relevant events promptly enough to support audit views, debugging, and deterministic verification.
- The system must handle daemon restart gracefully, recovering all durable state from SQLite without requiring re-pairing. This applies to the Windows Service restart case and to the Android foreground service restart case.
- Both daemon implementations must produce semantically equivalent wire-format output for every protocol message defined in the specification, verified by cross-implementation conformance tests. Byte-level equality is additionally required for the custom X.509 extension OID and DER encoding so each implementation's certificate parser can recognize and decode the other's extension.
- The Dart daemon's custom X.509 ASN.1 parser, which is required because `dart:io`'s `X509Certificate` does not expose certificate extensions, must be subject to dedicated fuzz testing against malformed certificate inputs and must fail closed (reject the session) on any parse failure.
- The system must preserve deterministic trust, clipboard, and event-log behavior across repeated capstone MVP test runs on both platforms.
- The Flutter application must target Android 12 (API 31) and above, with a runtime security advisory displayed on devices running Android versions that have reached end-of-life for security patches.
- The Flutter application must target Windows 10 version 1809 and above.

### (\*) 3.2. Main proposal content (including result and product)

#### 2. Theory and practice (document)

- Students should apply the software development process and UML 2.0 in modelling the system.
- The documents include User Requirement, Software Requirement Specification, Architecture Design (including Security Architecture and Threat Model using STRIDE methodology), Detail Design, System Implementation, Testing Document (including Security Testing with attack simulation, ASN.1 parser fuzz testing, and Cross-Implementation Protocol Conformance Testing), Installation Guide, source code, and deployable software packages.
- Windows daemon technologies:
  - Daemon Core: C# / .NET 10 Worker Service with async/await, `System.Threading.Channels` for internal event bus. The core is runnable as a standalone .NET console process and deployed on Windows as a Windows Service via a thin lifecycle wrapper.
  - Networking: Mutual TLS over TCP via `SslStream`, with TLS 1.3 preferred and TLS 1.2 fallback where platform limitations require it, using ECDSA P-256 certificate authentication and post-handshake Ed25519 identity verification via standard `X509Extension` enumeration; mDNS-SD via Makaretu.Dns.Multicast for local discovery; JSON-RPC 2.0 via StreamJsonRpc over named pipe for local IPC to the Flutter Windows client.
  - Cryptography: BouncyCastle.NET for Ed25519 device identity operations and custom X.509 extension construction. ECDSA P-256 TLS certificate generation via `System.Security.Cryptography`. TLS 1.3 negotiates the session cipher suite.
  - Database: SQLite via Microsoft.Data.Sqlite for durable state persistence.
- Android daemon technologies:
  - Daemon Core: Dart, runnable as a standalone Dart console process. On Android, hosted inside a dedicated background Dart isolate spawned by a Flutter foreground service (declared with `connectedDevice|dataSync` service types, qualified by `CHANGE_WIFI_MULTICAST_STATE`) with a persistent notification.
  - Networking: Mutual TLS via Dart `SecureSocket` with `SecurityContext` configured for ECDSA P-256 client and server authentication, with TLS 1.3 preferred and TLS 1.2 fallback where platform limitations require it; post-handshake Ed25519 extraction performed by a purpose-built ASN.1 parser operating on `SecureSocket.peerCertificate.der` (required because `dart:io`'s `X509Certificate` API does not expose extensions); mDNS-SD discovery and advertisement via the `nsd` Flutter package, which wraps Android's `NsdManager`; JSON-RPC 2.0 via `json_rpc_2` over a `SendPort`/`ReceivePort` pair connecting the UI isolate to the daemon isolate within the same Flutter process.
  - Cryptography: PointyCastle for Ed25519 keygen/sign/verify, ECDSA P-256 keygen, X.509 certificate construction by explicit ASN.1 assembly with the custom Ed25519 extension at the OID and DER structure defined by the protocol specification, and ASN.1 decoding of peer certificate extensions.
  - Database: SQLite via `sqflite` for the same trust store, capability grant, and event log schema.
- Flutter client technologies:
  - Dart with Flutter (stable channel) and Material 3, building from a single codebase to Android (target API 31+) and Windows (target 10 build 1809+). One `JsonRpcRiftClient` implementation drives both targets over different transports.
  - Cross-platform Dart packages: `json_rpc_2` for the IPC client, `nsd` for mDNS-SD discovery and registration where the Flutter client itself participates, `flutter_local_notifications` for notifications, `tray_manager` for the Windows system tray, `clipboard_watcher` (with platform-channel fallbacks where needed) for clipboard observation.
  - Android platform-channel shim (Kotlin): foreground service lifecycle, `ClipboardManager` integration, Android notifications. No protocol or cryptographic logic.
  - Windows platform-channel shim (C++/C#): system clipboard hooking, system tray, native notifications. Background core remains in the Windows Service. The Flutter Windows application is tray-resident and minimizes-on-close.
- Security: Formal threat model using STRIDE methodology, dual-keypair identity model (Ed25519 + ECDSA P-256), mutual TLS with TLS 1.3 preferred and TLS 1.2 fallback where platform limitations require it plus explicit device-identity binding, formal trust state machine, structured security event logging, comparative vulnerability analysis against documented KDE Connect CVEs (CVE-2025-66270, CVE-2025-32900, CVE-2025-32898), cross-implementation protocol conformance testing (one harness against two daemons running as standalone console processes in CI), cross-platform interop testing (C# daemon paired with Dart daemon end-to-end), and dedicated fuzz testing of the Dart daemon's custom X.509 ASN.1 parser.

#### 3. Products

- **Rift Protocol Specification** — a written, language-independent contract defining the wire format, cryptographic operations (including the exact ASN.1 structure and OID of the custom Ed25519 X.509 extension), trust and operation state machines, capability negotiation, clipboard offer/fetch semantics, presence model, and event log schema. The conformance contract that both daemon implementations satisfy and the reference for any future implementation.
- **Rift Daemon for Windows** (C#/.NET 10) — dual-keypair device identity via BouncyCastle.NET, Ed25519 trust engine, ECDSA P-256 mutual TLS, encrypted P2P communication, capability handling for the capstone MVP, operation state machine, structured security event log, and JSON-RPC IPC server over named pipe. Runnable as a standalone console process and deployed on Windows as a Windows Service.
- **Rift Daemon for Android** (Dart) — an independent Dart implementation of the same protocol specification using PointyCastle for cryptography (including explicit ASN.1 assembly of the X.509 certificate with the custom Ed25519 extension), a purpose-built ASN.1 parser for peer certificate extension extraction, and `SecureSocket` for mutual TLS with TLS 1.3 preferred and TLS 1.2 fallback where platform limitations require it. Runnable as a standalone Dart console process and hosted on Android inside a dedicated background Dart isolate within a Flutter foreground service. Exposes the same JSON-RPC IPC contract over a `SendPort`/`ReceivePort` channel.
- **Rift Flutter Application** — a single Dart/Flutter codebase producing two deployable artifacts (tray-resident Windows desktop application with system tray and named-pipe IPC client; Android application with foreground-service-hosted daemon isolate and isolate-channel IPC client) and a single Dart UI that consumes both daemons identically through JSON-RPC.
- **Security Documentation** — STRIDE threat model, security architecture document, comparative vulnerability analysis mapping Rift's design against CVE-2025-66270, CVE-2025-32900, CVE-2025-32898, IPC API specification, and Rift protocol specification.
- **Cross-Implementation Protocol Conformance & Security Test Suite** — automated tests validating that both daemon implementations (C# and Dart) conform identically to the written Rift protocol specification across discovery, pairing, encrypted communication, clipboard exchange, and basic presence; cross-platform interop tests pairing the C# Windows daemon with the Dart Android daemon end-to-end; deterministic security tests simulating the documented KDE Connect attack vectors against both daemons; and dedicated fuzz tests targeting the Dart daemon's custom X.509 ASN.1 parser with malformed certificate inputs.

#### 4. Proposed Tasks

**Task package 1: Security Architecture, Protocol Specification & Core Infrastructure**

Requirement:
- Conduct threat modeling using STRIDE methodology to identify and document all security threats to the cross-device communication system. Explicitly include the custom X.509 ASN.1 parser in the Dart daemon as a security-sensitive component in the threat model.
- Produce comparative vulnerability analysis documenting how Rift's protocol design specifically mitigates each KDE Connect CVE (CVE-2025-66270 authentication bypass, CVE-2025-32900 device spoofing, CVE-2025-32898 weak verification). For each CVE, document the specific invariant in Rift's design that rules out the vulnerability class and reference the section of the protocol specification where that invariant is enforced.
- Design and document the complete security architecture: dual-keypair identity model, trust state machine with explicit validation rules, pairing protocol with mutual Ed25519 fingerprint verification, mutual TLS session encryption with TLS 1.3 preferred and TLS 1.2 fallback where platform limitations require it, explicit device-identity binding, and structured security event logging.
- Author the Rift protocol specification as a language-independent contract: message schemas, wire format, state machine transition tables, expected cryptographic operations per protocol step, **the exact ASN.1 structure of the custom Ed25519 X.509 extension including OID, criticality flag, and value encoding**, and event log schema. This document is the conformance contract for both daemon implementations.
- Define and document the JSON-RPC IPC API specification (all methods, parameters, responses, error codes, subscription events) as the transport-agnostic contract between any daemon and the Flutter client.
- Define the shared domain model in C# (`Rift.Core`) and Dart (`rift_core`) packages: Node, Peer, Capability, Operation (with lifecycle state machine; Intent retained only as an older project synonym where needed), Event, Offer entities.
- Implement dual-keypair identity generation on .NET via BouncyCastle.NET and native `System.Security.Cryptography`, with secure persistence to SQLite. Verify that the resulting X.509 certificate's custom extension is byte-compatible with the structure mandated by the protocol specification.
- Build a mock JSON-RPC server in Dart that returns canned responses for the documented IPC contract, enabling Flutter UI work to proceed in parallel before either daemon is feature-complete.

**Task package 2: Encrypted Transport, Discovery & Trust Engine (Both Daemons)**

Requirement:
- Implement mDNS-SD peer discovery and advertisement in both daemons: Makaretu.Dns.Multicast on the C# daemon; the `nsd` Flutter package wrapping `NsdManager` on the Dart-on-Android daemon (and on the standalone Dart console daemon used for CI). Both expose only minimal non-sensitive metadata in discovery packets.
- Implement mutual TLS encrypted transport in both daemons, with TLS 1.3 preferred and TLS 1.2 fallback where platform limitations require it: `SslStream` (C#) and `SecureSocket` with `SecurityContext` (Dart), both with ECDSA P-256 certificate authentication.
- Implement post-handshake Ed25519 identity verification in both daemons. On .NET this uses standard `X509Extension` enumeration. On Dart this requires a purpose-built ASN.1 parser operating on `SecureSocket.peerCertificate.der` to locate the custom extension by OID and extract the Ed25519 public key — the parser must fail closed on any malformed input and is treated as a high-risk security-sensitive component subject to fuzz testing in Task Package 6.
- Implement dual-keypair identity generation on the Dart daemon via PointyCastle, including ECDSA P-256 self-signed certificate construction by explicit ASN.1 assembly with the custom Ed25519 extension at the OID and DER structure mandated by the protocol specification. Verify byte-level compatibility of the custom extension's encoding with the C# daemon's output (extension OID, criticality flag, and value bytes must match exactly so each implementation's parser recognizes the other's extension).
- Implement the complete pairing flow in both daemons: TLS handshake ephemeral key agreement with no separate pairing key exchange, full Ed25519 cryptographic fingerprint display and verification, mutual user confirmation, trust persistence to SQLite (Ed25519 public key plus ECDSA P-256 certificate fingerprint as audit metadata).
- Implement device ID consistency validation in both daemons (preventing CVE-2025-66270 impersonation).
- Implement authenticated device information exchange in both daemons (preventing CVE-2025-32900 spoofing).
- Implement trust revocation in both daemons: key material deletion (Ed25519 and certificate), immediate session termination, permanent connection rejection for revoked Ed25519 keys.
- Implement capability advertisement exchange during session handshake with version negotiation in both daemons.

**Task package 3: Operation Engine, Clipboard & Security Event Log (Both Daemons)**

Requirement:
- Implement the operation lifecycle state machine (Created → Pending → Dispatched → Active → Done/Failed/Expired) with typed failure reasons, timeout handling, and event emission on every state transition, in both daemons.
- Implement the internal async event bus: `System.Threading.Channels` on the C# daemon, Dart `Stream`/`StreamController` on the Dart daemon, both providing decoupled module communication and fan-out to subscribed JSON-RPC clients.
- Implement the structured append-only security event log in SQLite on both daemons, recording pairing attempts, trust transitions, authentication events, operation transitions, clipboard operations (metadata only), and other audited capstone-core runtime events. Schema is shared via the protocol specification.
- Implement presence heartbeat publishing and peer reachability tracking with configurable intervals and timeout-based offline detection in both daemons.
- Implement clipboard offer/fetch service in both daemons: receive platform clipboard-change notifications forwarded by the Flutter client over JSON-RPC, broadcast metadata, manage ephemeral offers with configurable TTL, perform authenticated content transfer on demand, and run automatic expiry and cleanup.

**Task package 4: Flutter Application — Shared Codebase, Android Integration**

Requirement:
- Build the Flutter/Dart application with Material 3 and platform-adaptive layouts shared between Android and Windows.
- Implement the single `JsonRpcRiftClient` Dart client, state management, and UI screens once: device discovery and pairing flow with Ed25519 fingerprint verification, trusted peer list with real-time presence, clipboard offer notifications with one-tap fetch, operation history with state transitions, security event log viewer, and device capability overview.
- Implement the Android platform-channel shim in Kotlin: a foreground service declared with `connectedDevice|dataSync` service types (qualified by `CHANGE_WIFI_MULTICAST_STATE`) that hosts the Dart daemon in a dedicated background isolate, owns the lifecycle and the persistent notification, bridges `ClipboardManager` events into the Dart daemon over JSON-RPC, and surfaces Android notifications for clipboard offers and trust/event updates. The shim contains no protocol, trust, or cryptographic logic.
- Wire up the `SendPort`/`ReceivePort` channel pair on Android with JSON-RPC 2.0 framing so the Flutter UI's `JsonRpcRiftClient` and the in-process Dart daemon communicate through exactly the same JSON-RPC contract used on Windows.
- Validate that the Dart UI layer holds no cryptographic key material and that the Kotlin shim contains no protocol or trust logic — both consume the daemon strictly through the documented IPC contract.

**Task package 5: Flutter Application — Windows Integration & Runtime Boundary Enforcement**

Requirement:
- Implement the Windows platform-channel shim that connects the Flutter app to the riftd Windows Service over named pipe, hooks system clipboard events, integrates with the Windows system tray, and surfaces native Windows notifications.
- Implement the tray-resident, minimize-on-close behavior for the Flutter Windows application so that clipboard monitoring and notifications remain active throughout the user session even when the main application window is closed. Provide an explicit "Exit" action from the tray menu for the user to fully terminate the Flutter process.
- Package and install the C# daemon as a Windows Service whose lifecycle is independent of the Flutter UI process; verify that closing the UI (or even fully exiting it from the tray) does not interrupt background daemon behavior (discovery, trust, transport, persistence, event log) and that re-opening the UI reconnects cleanly to the running service.
- Enforce the Windows runtime split: the Windows Service owns background core behavior; the user-session Flutter process owns clipboard handling, tray, notifications, and approval prompts. Document and justify this split in terms of Windows Session 0 isolation in the architecture document.
- Validate that the Flutter Windows client uses the same `JsonRpcRiftClient` as the Android build, with only the transport binding (named pipe vs `SendPort`/`ReceivePort`) differing between targets.

**Task package 6: Cross-Implementation Conformance, Integration Testing, Security Testing & Core Documentation**

Requirement:
- Build a cross-implementation protocol conformance test suite: a single harness that drives both the C# daemon and the Dart daemon (both run as standalone console processes in CI) against the same set of protocol-specification test vectors. Conformance areas include discovery, pairing (mutual Ed25519 fingerprint verification), TLS session establishment (ECDSA P-256 mutual auth + Ed25519 identity binding extracted from the custom X.509 extension), clipboard offer/fetch, basic presence, operation state machine transitions, capability negotiation, and event log schema. The same harness producing the same outcomes for both implementations is the core evidence that the protocol specification is correctly written and implementable across language ecosystems.
- Build a cross-platform interop test suite: spin up a C# daemon instance and a Dart daemon instance, both as standalone console processes on a CI runner, and verify end-to-end discovery, pairing, encrypted communication, clipboard exchange, and basic presence between the two independent implementations.
- Implement security-specific test cases against both daemons, structured as documented attack simulations against each KDE Connect CVE. For each test case the suite produces: the simulated attack vector, the expected typed failure reason recorded in the security event log, and the assertion that the session was rejected. Specifically: verify mutual TLS with ECDSA P-256 certificates rejects unauthenticated peers; verify post-handshake Ed25519 identity verification rejects peers with untrusted Ed25519 keys even if TLS handshake succeeds; verify trust revocation immediately terminates sessions and rejects future connections; verify device ID consistency validation prevents impersonation (simulate CVE-2025-66270 attack); verify device information is never transmitted over unauthenticated channels (simulate CVE-2025-32900 attack); verify clipboard content is never transmitted in plaintext.
- Implement a dedicated fuzz-testing harness against the Dart daemon's custom X.509 ASN.1 parser: feed malformed, truncated, oversized, and adversarial certificate inputs and verify the parser fails closed (rejects the session) on every malformed input without crashing, leaking memory, or accepting invalid data. The fuzz harness should also feed valid certificates produced by the C# daemon to verify the parser correctly extracts the Ed25519 public key from real-world inputs.
- Consolidate deterministic verification outputs for cross-implementation conformance, cross-platform interop, trust/security validation, ASN.1 fuzz testing, and cross-platform clipboard MVP evidence.
- Finalize core documentation: System Analysis & Design, Security Architecture & Threat Model (STRIDE), Comparative Vulnerability Analysis, IPC API Specification, Rift Protocol Specification, Test Plan (including security test cases, cross-implementation conformance tests, cross-platform interop tests, and ASN.1 fuzz tests), Installation Manual, and User Manual.

#### 5. Other comments

- The project directly addresses documented security vulnerabilities in the most widely used open-source cross-device solution (KDE Connect CVE-2025-66270, CVE-2025-32900, CVE-2025-32898) by designing the trust and authentication model to mitigate these specific attack vectors. The Comparative Vulnerability Analysis document will, for each CVE, identify the structural invariant in Rift's design that rules out the vulnerability class, reference the section of the protocol specification where that invariant is enforced, and pair the design argument with an executable security test that simulates the attack and verifies rejection. The scope of this artifact is explicitly the three named vulnerability classes; it is not a general security proof.

- The cryptographic implementations use BouncyCastle.NET together with native .NET cryptography APIs in the C# daemon, and PointyCastle in the Dart daemon. The dual-keypair identity model (Ed25519 for device identity, ECDSA P-256 for TLS certificates) uses standard mutual TLS with explicit device-identity binding, avoiding custom authentication protocols. The custom X.509 extension carrying the Ed25519 public key uses a stable OID and DER structure defined by the protocol specification so both implementations produce byte-compatible certificate extensions that each other's parsers can recognize.

- A known high-risk implementation area is the Dart daemon's custom X.509 ASN.1 parser, which is required because `dart:io`'s `X509Certificate` API does not expose certificate extensions. The team has explicitly scoped dedicated fuzz testing of this component in Task Package 6 and treats it as a security-sensitive component in the threat model. The parser fails closed on any malformed input.

- The capstone delivers two genuinely independent daemon implementations (C#/.NET on Windows using BouncyCastle.NET and `SslStream`; Dart on Android using PointyCastle and `SecureSocket`) that conform to a single written protocol specification. This dual-implementation approach is a stronger engineering validation than code sharing or single-implementation testing, because correct interoperation between two codebases in two language ecosystems with two different cryptographic libraries proves the protocol specification itself is well-defined and implementable. Both daemons are runnable as standalone console processes for CI testing; their platform-specific deployment (Windows Service, Android foreground service) is a thin lifecycle wrapper.

- The JSON-RPC 2.0 IPC contract between daemon and Flutter client is intentionally transport-agnostic. Within the capstone scope it is served over named pipes on Windows and over `SendPort`/`ReceivePort` isolate channels on Android (with JSON-RPC framing applied so the contract is exercised identically). The contract is designed to extend cleanly to Unix domain sockets on macOS (launchd agent hosting a daemon) and Linux (systemd service hosting a daemon), and to in-process channels on iOS, all as documented future work. Adding a new platform requires implementing only a new daemon host and a new transport binding, with no changes to the protocol, the IPC contract, or the Flutter UI. iOS specifically is expected to require Apple's Local Push Connectivity entitlement (`NEAppPushManager`), which is granted on a per-app review basis by Apple and is therefore outside the team's direct control.

- The Flutter Windows application is implemented as a tray-resident, minimize-on-close process because Windows Session 0 isolation prevents the Windows Service from interacting with user-session clipboard state. The user-session Flutter process owns clipboard monitoring and notifications and remains active throughout the session; the Windows Service owns background core behavior (discovery, trust, transport, persistence, event log) and is independent of the UI process lifecycle. This split is explicitly justified in the Windows architecture documentation.

- The Flutter client is implemented as a single Dart codebase that targets Android and Windows with a single `JsonRpcRiftClient` driving both, distinguished only by which transport it binds to. This consolidates client-side engineering effort onto one codebase while preserving the strength of the two-daemon protocol-conformance story on the daemon side.

- The team has identified the following as the minimum viable deliverable for capstone defense: written Rift protocol specification (including the exact ASN.1 structure of the custom Ed25519 X.509 extension), C# daemon on Windows as a Windows Service, Dart daemon on Android inside a Flutter foreground service with a dedicated background isolate, single Flutter UI on Android and Windows consuming both daemons through one JSON-RPC contract, the Flutter Windows application running tray-resident with minimize-on-close, mDNS-SD discovery and advertisement via Makaretu (Windows daemon) and `nsd` (Dart daemon), mutual TLS encrypted communication with Ed25519 identity binding, pairing with fingerprint verification, clipboard offer/fetch between Android and Windows, basic presence, structured security event log, cross-implementation conformance tests, cross-platform interop tests, security tests including ASN.1 parser fuzz testing, and core security documentation. Features including reduced session handoff, relay transport, additional daemon hosts (macOS, Linux), additional client targets (iOS, Linux, macOS Flutter desktop), and other product-expansion work are treated as future extensions whose absence does not compromise the demonstrability of the system's architecture or security properties.

- The project is intentionally framed as a software-engineering and security capstone. The strongest evidence of success is protocol correctness (validated by cross-implementation conformance), trust-model clarity, IPC boundary discipline between daemons and client, and repeatable security testing rather than feature breadth.

- macOS and Linux daemon support, iOS in-process daemon support, and additional Flutter desktop targets are documented in the architecture as planned future extensions. The transport-agnostic IPC design and the language-independent protocol specification are intended to make these additions straightforward without changing the capstone-core trust model.

- All project documentation, including the threat model, protocol specification, and security architecture, will be written with sufficient detail to enable independent security review of the protocol and both implementations.

| Supervisor (If have)   *(Sign and full name)* | Quy Nhon, date …… ………. /20 …  On behalf of Registers   *(Sign and full name)* |
| :---- | :---: |
