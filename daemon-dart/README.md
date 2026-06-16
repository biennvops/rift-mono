# Rift Android Daemon (Dart) - Usage Guide & Architecture

This is the core background module (daemon) on Android for the Rift project, developed in Dart. It handles device identity, certificate generation/parsing, local peer discovery, mTLS transport, pairing, and a Flutter-facing isolate bridge.

> **Implementation status note:** The current codebase has a real mTLS transport and Ed25519 Proof of Possession (PoP), but it is **not yet fully compliant with `spec/doc/protocol.md`** because Dart does not expose `tls-exporter` / TLS 1.2 EMS state. The current implementation uses an Application Nonce fallback (`sessionNonce` + cert hashing) for channel binding. While this provides true per-session replay protection, it deviates from the formal specification and requires cross-implementation support.

---

## 1. Directory Structure

- `lib/daemon_dart.dart`: The core library exporter bridging internal APIs (like `cert_decoder` and interfaces) to external consumers.
- `lib/src/interfaces/`: Contains 5 core Interfaces (`IdentityManager`, `TrustStore`, `Transport`, `DiscoveryService`, `ClipboardService`). All business operations must go through these interfaces.
- `lib/src/crypto/`: Contains extremely important cryptographic logic:
  - `base32_utils.dart`: Implements RFC 4648 Base32 encoding without padding. Features explicit bit-clamping to prevent 53-bit float integer overflows on Dart Web/JS.
  - `cert_builder.dart`: Automatically wraps the Ed25519 key into an X.509 certificate using the *Double OCTET STRING* technique. Replaced static sentinels with random 64-bit entropy serials.
  - `cert_decoder.dart`: A secure X.509 Parser (Fail-Closed).
  - `identity_manager_impl.dart`: Generates/stores the Ed25519 key. Implements **Atomic Write** against corruption and strict heap zeroing (`dispose()`).
  - `pop_manager.dart`: Manages the Ed25519 Proof of Possession (PoP) verification with a 113-byte dynamic structure mitigating Canonicalization attacks and fails closed on malformed proof hex.
- `lib/src/network/`: 
  - `frame_codec.dart`: Safe stream transformer handling Length prefix + JSON frames. Strictly limits sizes to 64 KiB pre-auth and 32 MiB post-auth without order-sensitive aliasing hazards.
  - `transport_impl.dart`: Implements Mutual TLS (mTLS). Defers cert pinning to PoP layer, flushes sockets cleanly, emits `onPeerDisconnected` events to clear stale sessions, and tracks unauthenticated connection timeouts per socket to avoid reconnect races.
  - `discovery_service_impl.dart`: Uses `nsd` for mDNS. Robustly handles network flaps by diff-ing active instances and evicting removed/null-named peers.
  - `session_manager.dart`: Orchestrates the `session.hello` state machine. Evaluates PoP signatures using the *signer's own cert DER*, catches Zone exceptions natively, and accurately prunes offline peers to allow seamless reconnections. Also enforces Client-side PoP validation on `session.accept`.
- `lib/src/core/`:
  - `rift_constants.dart`: Shared source of truth for protocol version, implementation ID, and capability advertisement metadata used by both handshake and IPC-facing surfaces.
  - `rift_exceptions.dart`: Typed Rift application exceptions carrying explicit JSON-RPC error codes, reducing reliance on brittle string-matching.
- `lib/src/pairing/`:
  - `pairing_manager.dart`: Manages the Pairing State Machine. Enforces 120s UI timeouts, blocks unauthorized `pairing.approve` packets (Double-Approve Bypass prevention), emits intermediate `rift.onPairingApproved` progress events, and prevents UI Spoofing.
- `lib/src/storage/`:
  - `trust_store_impl.dart`: SQLite-backed trust store using WAL mode and Atomic Updates (Exhaustive Edge Validation) to prevent state corruption. It now also preserves pinned `cert_der` values for `trusted`, `blocked`, and `revoked` peers at the storage layer.
- `lib/src/daemon.dart`: The master orchestrator bounding all services. Protects against UI-layer memory leaks via `try/catch` IPC port setups.
- `test/`: Contains security and conformance-oriented unit tests across crypto, identity, PoP, frames, pairing, sessions, and storage. At the time of this README update, `dart test` passes with 77 tests.

---

## 2. Usage Guide & Basic Commands

> **IMPORTANT NOTE:** All Terminal commands below MUST be run inside the `daemon-dart` directory. Make sure you use the `cd daemon-dart` command before typing any `dart` commands.

### 2.1. Install Dependencies
Before working, ensure you have downloaded enough libraries (`pointycastle`, `asn1lib`, `cryptography`, `nsd`, `uuid`, `crypto`):
```bash
dart pub get
```

### 2.2. Code Quality Check (Linter)
All code pushed to the branch must not have warnings. The Linter system is strictly configured in `analysis_options.yaml`.
```bash
dart analyze
```
> **Note:** Must output `No issues found!` to create a Pull Request.

### 2.3. Run Security Unit Tests
The test suite currently covers the core cryptography, framing, session, pairing, and storage subsystems. At the time of this README update, `dart test` reports 77 passing tests:
1. **ASN.1 Encryption (`crypto_test`):** Verifies the generated byte array contains the correct Ed25519 OID and randomized RFC 5280 serials (64-bit entropy).
2. **Fail-Closed Decoding (`decoder_test`):** Strictly verifies 10 advanced CVE-class attack vectors (missing OID, duplicate OID, unsupported critical flags, length manipulation, truncated DER, and fragile OID modifications).
3. **Stream Network Frame (`frame_codec_test`):** Verifies memory purging, explicit frame boundary upgrades (64 KiB rejection pre-auth vs 32 MiB acceptance post-auth), and prevents double-parsing by directly returning Maps.
4. **Identity (`identity_test`):** Verifies Atomic Write, Ed25519 PoP signature boundary enforcement (strict 32 bytes), memory zeroing (`dispose`), async contract stubs, and the standard `rift-` Device ID string.
5. **PoP Validation (`pop_test` & `session_manager_test`):** Verifies Ed25519 Proof of Possession dynamic structures (113 bytes) against Canonicalization attacks and Client-side Auth Bypass.
6. **Pairing State Machine (`pairing_manager_test`):** Validates strict protocol transitions, 120s auto-timeouts, Double-Approve Bypass prevention, and Fingerprint spoofing rejections.
7. **Storage ACID (`trust_store_test`):** Verifies SQLite WAL mode, atomic `transitionState`, and prevents mDNS `discovered` downgrade attacks.

```bash
dart test
```
> **If one or more tests fail:**
> Treat it as a signal that behavior has regressed or an important invariant is no longer being enforced:
> - **Error in `crypto_test` / `decoder_test` / `pop_test` / `session_manager_test`:** Proves the ASN.1 byte structure has been manipulated, or the Fail-Closed decoding/PoP mechanism has a loophole (vulnerable to spoofing).
> - **Error in `pairing_manager_test` / `trust_store_test`:** Proves the Pairing State Machine or SQLite storage is failing, risking Double-Approve Bypass, UI Spoofing, or mDNS Downgrade attacks.
> - **Error in `frame_codec_test`:** The stream filter system is not working, risking the passage of packets over 32 MiB or RAM overflow.
> - **Error in `identity_test`:** The Atomic Write structure is failing, or Canonicalization / Length Extension attacks on PoP signatures are possible.
> - **General Consequence:** Do not assume the implementation is still protocol-safe or review-ready until the failure is understood and fixed.

Latest local verification snapshot:
- `dart analyze` -> `No issues found!`
- `dart test` -> `00:03 +77: All tests passed!`

### 2.4. Standalone Runner Status
The repository currently contains a standalone entrypoint at `bin/daemon.dart`, but it is still a stub intended for future CI/conformance work. There is currently **no checked-in `demo_cert.dart` script** in this package.

```bash
dart run bin/daemon.dart
```

This currently prints a placeholder message and exits.

### 2.5. Flutter Integration Guide (Week 5 / M3)
The root orchestrator is designed to run inside a background isolate hosted by the Android app. The current implementation exposes a `SendPort`/`ReceivePort` bridge, which operates substantially via JSON-RPC 2.0 complying with `spec/doc/ipc.md` (with some legacy bridge payload shapes remaining in the daemon entrypoint).

To integrate this into the Flutter app, the UI must provide a writable `storagePath` and listen for isolate messages:
```dart
import 'dart:isolate';
import 'package:daemon_dart/daemon_dart.dart';

void startDaemon() async {
  ReceivePort receivePort = ReceivePort();
  SendPort? commandPort;
  final storagePath = '/data/user/0/com.example.app/files/rift';
  
  // Start the background daemon
  await Isolate.spawn(RiftDaemon.isolateEntryPoint, {
    'sendPort': receivePort.sendPort,
    'storagePath': storagePath,
  });

  // Listen for messages from the Daemon
  receivePort.listen((message) {
    if (message is Map<String, dynamic>) {
      if (message['method'] == 'rift.daemonReady') {
        commandPort = message['params']['commandPort'];
        print('Daemon is running. Device ID: ${message['params']['deviceId']}');
        
        // Example: Standard JSON-RPC command
        // commandPort?.send({
        //   'jsonrpc': '2.0',
        //   'method': 'rift.approvePairing',
        //   'id': 1,
        //   'params': { 'deviceId': 'rift-xyz123', 'fingerprint': 'ABCD-EFGH-IJKL-...' }
        // });
      } else if (message['method'] == 'rift.onPairingRequest') {
        // UI should show a popup with the Fingerprint for User to verify
        print('Pairing Request from: ${message['params']['displayName']}');
        print('Fingerprint: ${message['params']['fingerprint']}');
      } else if (message['method'] == 'rift.onTrustChanged') {
        // UI should update peer trust status
        print('Trust Changed: ${message['params']['deviceId']} -> ${message['params']['newState']}');
      }
    }
  });
}
```
This establishes the substantially aligned JSON-RPC 2.0 IPC bridge used by the Dart daemon, matching most of the JSON-RPC notification model described in `ipc.md` with some legacy structures intact.

---

## 3. Compliance Level with System Specification (Protocol & IPC)
- **With `protocol.md`:** 
  - Implemented the main crypto building blocks required by the spec: ECDSA P-256 self-signed certificates, the custom Ed25519 X.509 extension, fail-closed extension parsing, `rift-` device ID derivation, and state-dependent frame limits (64 KiB pre-auth / 32 MiB post-auth).
  - Implemented session bootstrap, PoP verification, client-side `session.accept` verification, pairing hardening, and trust-store persistence.
  - **Known gaps:** The current code does not yet fully match the normative peer message schema in `protocol.md` and is blocked on proper TLS channel binding because `dart:io` does not expose `tls-exporter` / EMS state.
- **With `ipc.md`:** 
  - The code implements the isolate entrypoint and all required IPC-facing commands/events needed by the Flutter app: `rift.startPairing`, `rift.approvePairing`, `rift.rejectPairing`, `rift.onTrustChanged`, `rift.onPairingRequest`, `rift.onPairingApproved`, etc., largely matching the standard JSON-RPC 2.0 spec mapping error codes (`-32009`, `-32004`, etc.), while retaining minor legacy bridge artifacts.
