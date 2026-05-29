# Rift Protocol Specification

Status: v0.1-draft implementable contract.

This document is the language-independent contract for Rift daemon implementations. It defines the security model, wire format, protocol invariants, message schemas, state machines, and conformance requirements that the C#/.NET and Dart daemon implementations must satisfy.

Open ADRs in `spec/decisions/` still record decisions that must later be accepted or revised. This v0.1-draft profile intentionally defines concrete draft values so both daemon implementations can interoperate before those ADRs are finalized.

## 1. v0.1-Draft Profile

The v0.1-draft profile has these normative constants:

| Field | Value |
| --- | --- |
| Protocol version | `0.1-draft` |
| Peer transport framing | 4-byte unsigned big-endian length prefix followed by one UTF-8 JSON object |
| Maximum encoded JSON frame size | 32 MiB |
| Binary clipboard content | Base64 in JSON; payloads exceeding the frame limit fail with `PayloadTooLarge` |
| Message IDs, operation IDs, offer IDs, event IDs | Lowercase RFC 4122 UUIDv4 strings |
| Audit timestamps | RFC 3339 UTC |
| Relative durations and expiries | Integer milliseconds, interpreted with local monotonic timers |

Each received frame MUST contain exactly one JSON object. A zero-length frame, invalid UTF-8, invalid JSON, non-object JSON value, negative or overflowing length, or encoded frame larger than 32 MiB MUST be rejected with `MalformedMessage` or `PayloadTooLarge` as applicable.

## 2. Terminology and Conventions

The key words "MUST", "MUST NOT", "REQUIRED", "SHOULD", "SHOULD NOT", and "MAY" are to be interpreted as described in RFC 2119 and RFC 8174 when written in uppercase.

`Device` means one Rift-capable endpoint. `Peer` means another device observed or contacted by the local daemon. `Device identity` means the long-term Ed25519 keypair and values derived from its public key. `TLS identity` means the ECDSA P-256 keypair and self-signed certificate used for mutual TLS. `Trust store` means durable local state recording trusted, blocked, or revoked peer identities.

`Operation` is the protocol-level term for a cross-device action flowing through the lifecycle in Section 10. Earlier project documents use `Intent`; implementations SHOULD avoid unqualified `Intent` names on Android to prevent confusion with `android.content.Intent`.

## 3. Cryptographic Primitives and Identity Values

Rift uses a dual-keypair model. Ed25519 provides stable device identity and fingerprint verification. ECDSA P-256 provides compatibility with standard TLS certificate authentication. The two identities are bound by embedding the Ed25519 public key in a custom extension of the ECDSA P-256 X.509 certificate.

Private keys MUST be generated and stored by the daemon. Private keys MUST NOT leave the daemon process, be transmitted on the network, or be exposed through IPC APIs.

### 3.1 Ed25519 Device Identity

Each device has one long-term Ed25519 keypair representing its protocol identity. The Ed25519 public key is the root of trust for device ID derivation, human-verifiable pairing fingerprints, trust store lookup, post-handshake identity verification, revocation, and permanent rejection of revoked identities.

In v0.1-draft, the device ID is derived as:

1. take the exact raw 32-byte Ed25519 public key;
2. compute SHA-256 over those 32 bytes;
3. encode the digest as Base32 per RFC 4648, then strip any padding characters (`=`) and lowercase the result;
4. take the first 32 characters;
5. prefix with `rift-`.

A valid device ID therefore matches `^rift-[a-z2-7]{32}$`. Any protocol message carrying a device ID MUST match the Ed25519 identity bound to the current TLS session.

### 3.2 Pairing Fingerprint

In v0.1-draft, the pairing fingerprint uses the same SHA-256 digest as device ID derivation, encoded as Base32 per RFC 4648 with padding stripped, uppercased, truncated to 32 characters, and displayed as eight groups of four characters separated by hyphens.

Example format: `ABCD-EFGH-IJKL-MNOP-QRST-UVWX-YZ23-4567`.

The fingerprint is derived from the full Ed25519 public key, not from a short random code. During pairing, both users or both local approval surfaces MUST compare and confirm the same fingerprint before a peer can enter the `trusted` state.

### 3.3 Clipboard Hash

Clipboard payload hashes are SHA-256 over the exact raw fetched bytes before Base64 encoding. The hash is represented as 64 lowercase hexadecimal characters. A receiver MUST verify both `byteSize` and `sha256` before accepting fetched content. A mismatch fails with `HashMismatch` and MUST be logged.

### 3.4 ECDSA P-256 TLS Certificates

Each device also has an ECDSA P-256 keypair used to create a self-signed X.509 certificate for mutual TLS. The certificate authenticates the TLS endpoint and carries the Ed25519 public key extension described in Section 3.5.

Certificate lifetime, renewal behavior, and regeneration policy are implementation concerns, but renewal MUST preserve the same Ed25519 identity unless the device is intentionally reset and re-paired. The stored ECDSA certificate fingerprint is audit and diagnostic metadata, not the trust root. Certificate renewal is accepted when the Ed25519 public key matches the trusted identity and the extension is valid. Certificate fingerprint changes for trusted peers MUST be logged as certificate rotation events.

### 3.5 Custom X.509 Extension for Ed25519 Public Key

The ECDSA P-256 certificate MUST include exactly one custom non-critical X.509 extension carrying the device's Ed25519 public key.

The v0.1-draft extension is:

| Property | Value |
| --- | --- |
| OID | `2.25.293029629918709742181702189012786017422` |
| Criticality | Non-critical |
| X.509 `extnValue` payload | DER bytes for an OCTET STRING containing exactly 32 raw Ed25519 public-key bytes |
| Expected inner encoding | `04 20 <32 bytes>` (34 bytes: tag `04`, length `20`, value) |
| Full `extnValue` on wire | The outer X.509 `extnValue` is itself an OCTET STRING wrapping the inner encoding, producing `04 24 04 20 <32 bytes>` (36 bytes total) |

On receipt, an implementation MUST reject the session if the extension is absent, duplicated, critical, malformed, uses the wrong OID, has the wrong length, is oversized, contains unparsable DER, or does not decode to exactly one 32-byte Ed25519 public key. The Dart implementation's custom certificate parser MUST fail closed for all parse failures.

## 4. Device Discovery: mDNS-SD

Rift uses mDNS-SD for local peer discovery and advertisement. Discovery exists only to find candidate peers and connection endpoints. Discovery data is unauthenticated and MUST be treated as provisional.

Discovery records MUST expose only minimal non-sensitive metadata needed to initiate a connection, such as service type, `minVersion`, `maxVersion`, transport endpoint, and a non-authoritative instance identifier. Discovery records MUST NOT expose trusted device names, icons, clipboard metadata, capability grants, or security state.

Discovery version fields are hints only. The first encrypted peer message performs authoritative version negotiation.

### 4.1 Service Type and Instance Naming

The v0.1-draft mDNS-SD service type is `_rift._tcp`. This name is not registered with IANA per RFC 6763 §7 and is used as a local-network application protocol name only. Implementers should note that the IANA Service Name registry contains related entries `rift-lies` (port 914) and `rift-ties` (port 915) for the unrelated IETF RIFT protocol (Routing in Fat Trees, RFC 9692); there is no technical conflict because service type matching is exact.

The service instance name MUST be unique on the local network segment. Implementations SHOULD use the device ID (which is derived from a public key hash and reveals no private information beyond reachability) as the instance name. Implementations MAY use an opaque random identifier regenerated on each advertisement cycle if even public-key-derived identifiers are considered too much pre-authentication disclosure. The instance name MUST NOT contain the trusted device display name.

The service domain is `local.`.

### 4.2 TXT Record Keys

The following TXT record key-value pairs are defined for v0.1-draft:

| Key | Required | Value | Notes |
| --- | --- | --- | --- |
| `minV` | Yes | Protocol version string | Lowest version this daemon supports, e.g. `0.1-draft` |
| `maxV` | Yes | Protocol version string | Highest version this daemon supports, e.g. `0.1-draft` |
| `did` | No | Device ID string | Non-authoritative hint; MUST be verified post-TLS |
| `fp` | No | Fingerprint prefix (first 8 characters) | Optional UI recognition hint; MUST NOT be relied on for trust |

All TXT record values are UTF-8 strings. The total TXT record payload MUST NOT exceed 1300 bytes. Unknown TXT record keys MUST be ignored by receivers. TXT records MUST NOT contain: device display names, capability lists, trust state information, clipboard metadata, or any content exchanged only over authenticated channels.

### 4.3 Advertisement and Browse Behavior

A daemon MUST begin advertising its service record when it is ready to accept peer TLS connections and MUST stop advertising when it is shutting down or no longer accepting connections. Implementations SHOULD re-advertise on network interface changes (Wi-Fi reconnection, IP address change).

A daemon MAY browse continuously or periodically for `_rift._tcp` services. Implementations MUST handle the appearance and disappearance of peer service records gracefully. When a previously advertised peer's service record disappears, the implementation SHOULD mark the peer as unreachable but MUST NOT change its trust state based on discovery events alone.

Duplicate service records (same instance name from the same host) MUST be deduplicated by the implementation. If two distinct hosts advertise the same instance name, the implementation SHOULD present both as separate discovered peers distinguished by their resolved addresses.

## 5. Transport Security and Session Bootstrap

All peer protocol messages after discovery run inside an authenticated encrypted transport. No clipboard content, authenticated device information, capability grants, trust transitions, operation messages, or event-log content may be exchanged over plaintext peer transport.

### 5.1 Mutual TLS Policy

Rift uses mutual TLS with ECDSA P-256 certificates. TLS 1.3 is preferred. TLS 1.2 with strong cipher suites is allowed as a fallback where TLS 1.3-only enforcement is unavailable at the platform API level (for example, Dart's `SecurityContext` does not expose a minimum protocol version setter).

Both peers MUST present certificates. A successful TLS handshake is necessary but not sufficient for trust. Trusted peers are accepted by Ed25519 public-key match, not by certificate chain trust alone.

For pairing candidates, the TLS layer MAY provisionally accept a self-signed peer certificate only to complete the handshake and extract the Ed25519 extension. Before post-handshake Ed25519 verification succeeds, the peer may exchange only `session.hello`, `session.accept`, `session.reject`, and pairing messages.

### 5.2 Post-Handshake Ed25519 Verification

Immediately after TLS establishment, each peer MUST extract the Ed25519 public key from the custom certificate extension and derive the expected device ID and fingerprint inputs from that key.

For trusted peers, the extracted Ed25519 public key MUST match the trust store entry for the claimed peer. For untrusted discovered peers, the extracted key MAY be used to create a pairing candidate but MUST NOT grant access to protected operations until pairing completes. For blocked or revoked peers, the session MUST be rejected.

Every message carrying a device ID MUST be checked for consistency with the Ed25519 identity bound to the current TLS session. A peer that changes from one device ID in discovery to another authenticated identity MUST NOT inherit trust from the discovery identity. This invariant directly mitigates the device-ID mismatch class represented by CVE-2025-66270.

## 6. Peer Message Envelope and Version Negotiation

Every peer message is one JSON object using the common envelope:

| Field | Required | Type | Notes |
| --- | --- | --- | --- |
| `rift` | Yes | string | Protocol version for this message, `0.1-draft` in this profile |
| `type` | Yes | string | Message type from Section 7 |
| `messageId` | Yes | UUIDv4 string | Unique message identifier |
| `sourceDeviceId` | Yes | device ID string | MUST match the session's Ed25519 identity |
| `payload` | Yes | object | Type-specific payload |
| `destinationDeviceId` | No | device ID string | MUST match the receiving device when present |
| `operationId` | No | UUIDv4 string | Required for operation-scoped messages |
| `timestamp` | No | RFC 3339 UTC string | Audit timestamp only |
| `requiredExtensions` | No | array of strings | Unknown values cause `ProtocolError` |

Unknown optional fields MUST be ignored. Unknown values in `requiredExtensions` MUST cause `ProtocolError`. Implementations MUST reject missing required fields, wrong JSON types, malformed identifiers, or envelope/device identity mismatches with `MalformedMessage`, `Unauthorized`, or `ProtocolError` as applicable.

Discovery advertises `minVersion` and `maxVersion` as unauthenticated hints. The first encrypted peer message MUST be `session.hello` using `rift: "0.1-draft"`. `session.hello` includes `supportedVersions`, `deviceId`, `implementationId`, and `capabilities`. The selected version is the highest mutually supported version; v0.1-draft only supports `0.1-draft`. If there is no mutually supported version, the session fails with `VersionMismatch`. No protected operation may run until `session.accept` confirms the selected version and identity verification has passed.

## 7. Normative Peer Message Schemas

All schemas below are the `payload` shape inside the envelope in Section 6. UUID, device ID, timestamp, duration, and hash fields use the formats defined in Sections 1 and 3.

### 7.1 Session Messages

`session.hello`:

```json
{
  "supportedVersions": ["0.1-draft"],
  "deviceId": "rift-abcdefghijklmnopqrstuvwxyz234567",
  "implementationId": "riftd-cs/0.1.0",
  "capabilities": [{ "name": "clipboard.offer_fetch", "version": 1 }]
}
```

`session.accept` payload fields: `selectedVersion` string, `deviceId` device ID, `identityVerified` boolean, `capabilities` array of capability objects.

`session.reject` payload fields: `failureReason` failure reason, optional `message` string.

### 7.2 Capability Messages

Required MVP capability names are `clipboard.offer_fetch`, `presence.basic`, `operation.lifecycle`, and `security.event_log`, all with version `1`.

`capability.advertise` payload fields: `capabilities` array of `{ "name": string, "version": integer, "policyFlags": array<string> }`.

`capability.selected` payload fields: `selectedCapabilities` array of capability objects.

### 7.3 Pairing Messages

`pairing.start` payload fields: `fingerprint` fingerprint string, `expiresInMs` duration, optional `displayName` string.

`pairing.approve` payload fields: `fingerprint` fingerprint string, `approvedAt` RFC 3339 timestamp.

`pairing.reject` payload fields: `failureReason` failure reason, optional `message` string.

`pairing.complete` payload fields: `trustedDeviceId` device ID, `fingerprint` fingerprint string, `persistedAt` RFC 3339 timestamp.

### 7.4 Presence Messages

`presence.update` payload fields: `status` one of `online`, `offline`, `away`; optional `lastSeenAt` RFC 3339 timestamp; `capabilities` array of selected capability names.

### 7.5 Clipboard Messages

`clipboard.offer` payload fields: `offerId`, `contentType` string, `byteSize` non-negative integer, `sha256` clipboard hash, `expiresInMs` duration, `sourceDeviceId` device ID, `requiredCapability` string.

`clipboard.fetchRequest` payload fields: `offerId`, `requestingDeviceId` device ID.

`clipboard.fetchResponse` payload fields: `offerId`, `contentBase64` string, `byteSize` non-negative integer, `sha256` clipboard hash.

`clipboard.fetchReject` payload fields: `offerId`, `failureReason`, optional `message` string.

### 7.6 Operation Messages

`operation.transition` payload fields: `operationId`, `operationType` string, `previousState` operation state, `nextState` operation state, optional `failureReason`, optional `details` object.

### 7.7 Trust Messages

`trust.revoke` payload fields: `revokedDeviceId` device ID, `reason` string, `revokedAt` RFC 3339 timestamp.

Revocation messages are advisory. Local revocation state is authoritative and MUST NOT depend on receiving a peer's `trust.revoke`.

### 7.8 Error Messages

`error` payload fields: `failureReason`, optional `refMessageId`, optional `message` string, optional `details` object.

## 8. Trust State Machine

Trust is local state. Each daemon independently decides whether a peer is discovered, pending pairing, trusted, blocked, or revoked. Implementations MUST persist trust state durably before relying on it for protected operations.

| From | To | Trigger | Requirements |
| --- | --- | --- | --- |
| `discovered` | `pairing_pending` | Local pairing start or accepted remote pairing start | TLS established and Ed25519 extension parsed |
| `pairing_pending` | `trusted` | Pairing completion | Identity verification passed, matching fingerprint confirmed on both sides, durable trust persisted |
| `pairing_pending` | `discovered` | Reject, timeout, or failed verification | No trusted entry persisted; failure logged |
| `trusted` | `blocked` | Local block | Active sessions terminated; block recorded |
| `trusted` | `revoked` | Local revocation | Active trust removed; negative-trust evidence retained |
| `blocked` | `discovered` | Explicit local unblock | Prior block evidence remains auditable |
| `revoked` | `discovered` | Explicit local reset followed by full new pairing flow | Silent re-trust forbidden |

Only `trusted` peers may perform protected operations. `discovered` and `pairing_pending` peers may exchange only the minimum messages required for authentication and pairing.

Revocation MUST keep a durable negative-trust record keyed by the Ed25519 public key and derived device ID. Deleting active trust MUST NOT delete the evidence needed to reject the identity later. Re-establishing trust with a revoked identity requires an explicit local reset followed by a full new pairing flow.

Pairing occurs over mutual TLS. There is no separate custom key exchange outside TLS; ephemeral key agreement is provided by the TLS handshake.

## 9. Capability Negotiation

After transport and identity verification, peers exchange authenticated capability advertisements. A capability advertisement MUST include the protocol version, implementation identifier, supported feature names, feature versions where applicable, and policy flags required to use each feature.

Peers compute a mutually supported session capability set. A peer MUST reject or fail an operation with `CapabilityUnavailable` if the required capability is absent from the authenticated negotiated set. Capabilities learned through discovery are hints only and MUST NOT authorize behavior.

The daemon exposes negotiated capabilities and all protocol functionality to local client applications via a transport-agnostic JSON-RPC 2.0 IPC contract defined in the companion IPC API Specification (`ipc.md`).

### 9.1 Capability Object Schema

Each capability is represented as a JSON object:

| Field | Required | Type | Notes |
| --- | --- | --- | --- |
| `name` | Yes | string | Dot-separated lowercase identifier, e.g. `clipboard.offer_fetch` |
| `version` | Yes | integer | Positive integer, monotonically increasing across revisions |
| `policyFlags` | No | array of strings | Policy constraints required to use this capability; empty array or absent if none |

Capability names use a `<domain>.<feature>` convention. The v0.1-draft vocabulary is a closed set; implementations MUST NOT advertise capability names outside this set in v0.1-draft.

### 9.2 Negotiation Algorithm

Capability negotiation proceeds as follows:

1. After `session.accept`, each peer sends a `capability.advertise` message containing all capabilities it supports.
2. The session initiator (the peer that sent `session.hello`) computes the selected set: for each capability name present in both advertisements, the selected version is the minimum of the two advertised versions.
3. If the selected version for any capability is below the minimum required version for that capability (defined per capability), the capability is excluded from the selected set.
4. The initiator sends `capability.selected` containing the computed intersection.
5. The responder validates the selection. If the responder disagrees (the initiator selected a capability it did not advertise, or selected a version it cannot support), the responder MUST send `error` with `ProtocolError` and terminate the session.
6. After successful capability selection, both peers use only the selected capabilities for the remainder of the session.

If either peer does not send `capability.advertise` within a reasonable timeout after `session.accept`, the session MUST fail with `Timeout`.

### 9.3 Required v0.1-Draft Capabilities

The following capabilities are REQUIRED for a conformant v0.1-draft session:

| Name | Version | Minimum | Description |
| --- | --- | --- | --- |
| `clipboard.offer_fetch` | 1 | 1 | Clipboard metadata offer and authenticated content fetch |
| `presence.basic` | 1 | 1 | Online/offline status and last-seen tracking |
| `operation.lifecycle` | 1 | 1 | Operation state machine transitions |
| `security.event_log` | 1 | 1 | Security event logging for audit |

All four capabilities MUST be present in the selected set for a v0.1-draft session to proceed to protected operations. If any required capability is absent after negotiation, the session MAY remain open for diagnostic purposes but MUST NOT permit clipboard, presence, or operation messages.

### 9.4 Version Mismatch and Forward Compatibility

When a peer advertises a capability version higher than the local implementation supports, the negotiation algorithm selects the lower version. The higher-version peer MUST be able to operate at any version down to the minimum defined for that capability.

Unknown capability names in a peer's advertisement MUST be silently ignored. This allows future protocol versions to introduce new capabilities without breaking v0.1-draft peers.

## 10. Operation Lifecycle

All cross-device actions flow through this transition table:

| From | To | Rule |
| --- | --- | --- |
| `Created` | `Pending` | Operation accepted locally |
| `Pending` | `Dispatched` | Message queued or sent to peer |
| `Dispatched` | `Active` | Peer acknowledges or starts work |
| `Active` | `Done` | Work completed successfully |
| `Created`, `Pending`, `Dispatched`, `Active` | `Failed` | Failure reason recorded |
| `Pending`, `Dispatched`, `Active` | `Expired` | Monotonic expiry elapsed |
| `Done`, `Failed`, `Expired` | none | Terminal states have no outgoing transitions |

Duplicate reports for the same terminal state are idempotent. Conflicting terminal reports MUST be rejected with `InvalidTransition` and logged. Each transition MUST record the operation ID, source device ID, destination device ID, operation type, previous state, next state, timestamp or monotonic-relative timing data, and typed failure reason when applicable.

## 11. Clipboard Offer/Fetch

Clipboard continuity uses metadata-only offers and authenticated fetch. A device MUST NOT eagerly push clipboard content to all peers.

Offers contain metadata only: `offerId`, `contentType`, `byteSize`, `sha256`, `expiresInMs`, `sourceDeviceId`, and `requiredCapability`. Fetch responses include `contentBase64`, `byteSize`, and `sha256`. Receivers MUST verify byte size and SHA-256 before accepting content.

Expiry is measured from local receipt time using monotonic timers. Wall-clock timestamps are audit-only. Expired, rejected, unauthorized, payload-too-large, or mismatched-hash fetches MUST fail with typed failure reasons and produce security event log entries. Clipboard event log entries MUST record metadata only, never clipboard content.

## 12. Presence

Presence provides basic trusted-peer visibility: online/offline state, last-seen information, reachability, and authenticated capability summary. Presence is not a trust source.

Presence heartbeats and status updates MUST be exchanged only after transport and identity verification. A peer observed only through discovery is `discovered`, not authenticated online. Offline detection SHOULD use local monotonic timers and configurable timeout thresholds so clock skew does not decide reachability.

## 13. Security Event Log Schema

Each daemon maintains an append-only security event log for audit, debugging, conformance, and attack-simulation evidence. Event logs are local audit records; peers do not exchange event-log contents as protocol data.

Each event MUST include `eventId`, `eventType`, `severity`, `localDeviceId`, optional `peerDeviceId`, optional `operationId`, `timestamp`, `outcome`, optional `failureReason`, and `details`. Event details MUST NOT contain private keys or clipboard content.

Security tests for the KDE Connect vulnerability classes MUST assert both network rejection behavior and the expected event-log failure reason.

### 13.1 Event Type Strings

The v0.1-draft `eventType` vocabulary is a closed set. Implementations MUST NOT emit event types outside this vocabulary in v0.1-draft.

| `eventType` | Description |
| --- | --- |
| `pairing.attempted` | Pairing flow initiated (local or remote) |
| `pairing.completed` | Pairing succeeded; trust persisted |
| `pairing.rejected` | Pairing rejected by either side |
| `trust.transitioned` | Trust state changed (any transition from Section 8) |
| `trust.revoked` | Peer trust revoked; sessions terminated |
| `auth.failed` | Authentication or identity verification failed |
| `connection.established` | Mutual TLS session established with a peer |
| `connection.rejected` | TLS session rejected (untrusted, blocked, or revoked peer) |
| `connection.lost` | TLS session lost unexpectedly |
| `certificate.rotated` | Peer certificate changed while Ed25519 identity unchanged |
| `capability.negotiated` | Capability set computed for a session |
| `operation.transitioned` | Operation state changed (any transition from Section 10) |
| `clipboard.offered` | Clipboard offer broadcast to peers |
| `clipboard.fetched` | Clipboard content fetched by or from a peer |
| `clipboard.expired` | Clipboard offer expired without fetch |
| `message.malformed` | Received peer message failed envelope or schema validation |
| `certificate.malformed` | Peer certificate failed extension parsing |
| `policy.denied` | Action denied by local policy |

### 13.2 Severity Levels

| `severity` | Usage |
| --- | --- |
| `info` | Normal protocol events: connection established, pairing completed, capability negotiated, clipboard offered/fetched |
| `warning` | Non-fatal anomalies: certificate rotation, capability version downgrade, offer expiry |
| `error` | Failed operations or rejected sessions: pairing rejected, connection lost, operation failed |
| `critical` | Security violations: authentication failure, identity mismatch, revoked peer reconnection attempt, malformed certificate |

### 13.3 Outcome Values

| `outcome` | Meaning |
| --- | --- |
| `success` | Event completed normally |
| `failure` | Event failed; `failureReason` MUST be present and MUST use a value from Section 14 |
| `denied` | Event blocked by local policy; `failureReason` MUST be present |

## 14. Failure Reasons

The v0.1-draft failure reason vocabulary is:

- `PeerUnreachable`
- `PeerRejected`
- `OfferExpired`
- `CapabilityUnavailable`
- `ConnectionLost`
- `Timeout`
- `PolicyDenied`
- `AuthenticationFailed`
- `Unauthorized`
- `HashMismatch`
- `MalformedMessage`
- `VersionMismatch`
- `ProtocolError`
- `PayloadTooLarge`
- `InvalidTransition`

Implementations MUST NOT invent peer-visible failure reason strings in v0.1-draft. Additional diagnostics may appear in local event `details` or optional human-readable `message` fields.

## 15. Test Vectors

The protocol requires deterministic test vectors for both daemon implementations. The full certificate bytes are future conformance material and are not defined in this draft. Machine-readable JSON versions of these vectors will be maintained in `spec/vectors/`.

### 15.1 Identity Derivation

Test input: the Ed25519 public key from RFC 8032 §7.1 Test Vector 1.

| Step | Value |
| --- | --- |
| Ed25519 public key (32 bytes, hex) | `d75a980182b10ab7d54bfed3c964073a0ee172f3daa3f4a18446b0b8d183f8e3` |
| SHA-256 of public key (32 bytes, hex) | `13cd677ac428d57b5cb434aa2486c9f30efe18b067fc7f6b248644a9580d21e7` |
| Base32 (RFC 4648, lowercase, padding stripped) | `cpgwo6wefdkxwxfugsvcjbwj6mhp4gfqm76h62zeqzckswanehtq` |
| First 32 characters | `cpgwo6wefdkxwxfugsvcjbwj6mhp4gfq` |
| Device ID | `rift-cpgwo6wefdkxwxfugsvcjbwj6mhp4gfq` |
| Display fingerprint | `CPGW-O6WE-FDKX-WXFU-GSVC-JBWJ-6MHP-4GFQ` |

Both implementations MUST produce identical device ID and fingerprint values from this public key.

### 15.2 Custom Extension DER Encoding

Using the test public key from Section 15.1, the custom X.509 extension has the following DER structure:

**OID encoding** for `2.25.293029629918709742181702189012786017422` (20 value bytes):

```
06 14 69 83 b8 f3 ba 8c ba bf ca d1 cd 9a ab f7 88 88 95 fb e9 0e
```

**Inner extnValue content** (34 bytes: OCTET STRING tag `04`, length `20`, 32-byte key):

```
04 20 d7 5a 98 01 82 b1 0a b7 d5 4b fe d3 c9 64 07 3a
     0e e1 72 f3 da a3 f4 a1 84 46 b0 b8 d1 83 f8 e3
```

**Outer extnValue OCTET STRING** (36 bytes: wraps the inner encoding):

```
04 22 04 20 d7 5a 98 01 82 b1 0a b7 d5 4b fe d3 c9 64 07 3a
          0e e1 72 f3 da a3 f4 a1 84 46 b0 b8 d1 83 f8 e3
```

**Complete Extension SEQUENCE** (60 bytes: OID + extnValue, criticality FALSE omitted per DER):

```
30 3a 06 14 69 83 b8 f3 ba 8c ba bf ca d1 cd 9a ab f7 88 88
     95 fb e9 0e 04 22 04 20 d7 5a 98 01 82 b1 0a b7 d5 4b
     fe d3 c9 64 07 3a 0e e1 72 f3 da a3 f4 a1 84 46 b0 b8
     d1 83 f8 e3
```

Both implementations MUST produce byte-identical extension DER for a given Ed25519 public key. The OID value bytes and the inner OCTET STRING encoding are the critical conformance surfaces.

### 15.3 Clipboard Hash

| Field | Value |
| --- | --- |
| Content (UTF-8 string) | `hello` |
| Content (raw bytes, hex) | `68656c6c6f` |
| Byte size | `5` |
| SHA-256 (64 lowercase hex characters) | `2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824` |
| Base64 of content | `aGVsbG8=` |

A receiver MUST verify both `byteSize` and `sha256` match after decoding `contentBase64`.

### 15.4 Envelope Validation

**Valid envelope** using the test device ID:

```json
{
  "rift": "0.1-draft",
  "type": "presence.update",
  "messageId": "018f2f9a-8b7c-4a4b-9c0d-aaaaaaaaaaaa",
  "sourceDeviceId": "rift-cpgwo6wefdkxwxfugsvcjbwj6mhp4gfq",
  "payload": {
    "status": "online",
    "capabilities": ["clipboard.offer_fetch", "presence.basic"]
  }
}
```

**Invalid envelope** — device ID does not match `^rift-[a-z2-7]{32}$`:

```json
{
  "rift": "0.1-draft",
  "type": "presence.update",
  "messageId": "018f2f9a-8b7c-4a4b-9c0d-bbbbbbbbbbbb",
  "sourceDeviceId": "rift-INVALID_ID_WITH_UPPERCASE",
  "payload": { "status": "online" }
}
```

Implementations MUST reject this envelope with `MalformedMessage`.

## 16. Security Considerations

Rift's security design specifically addresses three KDE Connect vulnerability classes documented in the project register.

CVE-2025-66270-style identity switching is mitigated by deriving device identity from the Ed25519 public key and validating device ID consistency across every authenticated session. Trust never follows unauthenticated discovery identifiers.

CVE-2025-32900-style device spoofing is mitigated by keeping discovery metadata minimal and unauthoritative. User-visible device information and capabilities are accepted only after mutual TLS and Ed25519 binding verification.

CVE-2025-32898-style weak verification is mitigated by pairing with a fingerprint derived from the full Ed25519 public key rather than an eight-character verification code.

The Dart certificate parser is a security-sensitive component because the platform certificate API does not expose extensions. It MUST reject malformed, truncated, duplicated, oversized, or adversarial extension data without accepting the peer. Parser failures are authentication failures, not recoverable warnings.

Rift does not claim to prove peer devices are uncompromised. A trusted but compromised peer may still request capabilities allowed by local policy. Capability grants, audit logging, revocation, and explicit fetch are the controls for that risk.

## Appendix A. ASN.1 Extension Definition

The v0.1-draft custom extension is identified by OID `2.25.293029629918709742181702189012786017422` and is non-critical.

The X.509 `Extension.extnValue` contains the DER bytes for this ASN.1 value:

```asn1
RiftEd25519PublicKey ::= OCTET STRING (SIZE(32))
```

The complete `extnValue` payload for a valid key is exactly 34 bytes: `04 20` followed by the 32 raw Ed25519 public-key bytes. In the X.509 `Extension` SEQUENCE, this 34-byte value is wrapped in the outer `extnValue` OCTET STRING, producing `04 24 04 20 <32 bytes>` (36 bytes) on the wire.

## Appendix B. Example Certificates

Deterministic certificate vector bytes are future conformance material to be generated by each implementation and placed in `spec/vectors/`. This appendix defines the structural requirements and the malformed-input rejection catalog.

### B.1 Conformant Certificate Structure

A conformant Rift ECDSA P-256 self-signed certificate MUST have the following structure:

| Field | Requirement | Notes |
| --- | --- | --- |
| Version | v3 (integer `2`) | Required to carry extensions |
| Serial number | Implementation-chosen | No normative value; MUST be unique per device |
| Signature algorithm | `ecdsa-with-SHA256` (OID `1.2.840.10045.4.3.2`) | ECDSA P-256 with SHA-256 |
| Issuer | Same as Subject | Self-signed |
| Validity | Implementation-chosen | See Section 3.4 for renewal policy |
| Subject | Implementation-chosen | No normative format required |
| Subject public key algorithm | `id-ecPublicKey` (OID `1.2.840.10045.2.1`) with `secp256r1` | ECDSA P-256 |
| Extensions | Custom Ed25519 extension (Section 3.5) | MUST be present; MUST NOT be critical |

### B.2 Extension Placement

The custom extension appears inside the `extensions` field of `tbsCertificate` as a standard X.509v3 Extension SEQUENCE:

```
Certificate
  └─ tbsCertificate
       └─ extensions [3] EXPLICIT
            └─ SEQUENCE OF Extension
                 └─ Extension (Rift Ed25519)
                      ├─ extnID: 2.25.293029629918709742181702189012786017422
                      ├─ critical: FALSE (omitted in DER)
                      └─ extnValue: OCTET STRING containing 04 20 <32-byte Ed25519 key>
```

Implementations locating the extension MUST match by OID only. The extension MAY appear at any position within the extensions sequence.

### B.3 Malformed Certificate Rejection Catalog

Both implementations MUST reject the TLS session with `AuthenticationFailed` for each of the following malformed-input classes. Security tests (Section 13, `certificate.malformed` event type) MUST cover every class.

| # | Malformed Input Class | Expected Behavior |
| --- | --- | --- |
| 1 | Extension absent | Reject: no Ed25519 identity bound |
| 2 | Extension duplicated (two extensions with the Rift OID) | Reject: ambiguous identity |
| 3 | Extension marked critical | Reject: violates spec requirement of non-critical |
| 4 | Wrong OID (valid extension structure but different OID) | Reject: extension not found |
| 5 | Inner OCTET STRING too short (fewer than 32 key bytes) | Reject: invalid key length |
| 6 | Inner OCTET STRING too long (more than 32 key bytes) | Reject: invalid key length |
| 7 | Wrong DER tag (e.g. `03` BIT STRING instead of `04` OCTET STRING) | Reject: unparsable value |
| 8 | Truncated DER (tag and length present but value bytes missing) | Reject: incomplete encoding |
| 9 | Oversized extnValue (length field exceeds remaining certificate bytes) | Reject: malformed DER |
| 10 | Valid structure but Ed25519 key does not match trust store | Reject: untrusted identity (see Section 5.2) |

For all classes 1–9, the parser MUST fail closed without crashing, leaking memory, or accepting the peer. Class 10 is a trust-layer rejection that occurs after successful parsing.

## Appendix C. Example Message Flows

### C.1 Session Establishment

```json
{
  "rift": "0.1-draft",
  "type": "session.hello",
  "messageId": "018f2f9a-8b7c-4a4b-9c0d-111111111111",
  "sourceDeviceId": "rift-abcdefghijklmnopqrstuvwxyz234567",
  "payload": {
    "supportedVersions": ["0.1-draft"],
    "deviceId": "rift-abcdefghijklmnopqrstuvwxyz234567",
    "implementationId": "riftd-cs/0.1.0",
    "capabilities": [{ "name": "clipboard.offer_fetch", "version": 1 }]
  }
}
```

### C.2 Capability Negotiation

```json
{
  "rift": "0.1-draft",
  "type": "capability.selected",
  "messageId": "018f2f9a-8b7c-4a4b-9c0d-222222222222",
  "sourceDeviceId": "rift-abcdefghijklmnopqrstuvwxyz234567",
  "payload": {
    "selectedCapabilities": [
      { "name": "clipboard.offer_fetch", "version": 1 },
      { "name": "presence.basic", "version": 1 },
      { "name": "operation.lifecycle", "version": 1 },
      { "name": "security.event_log", "version": 1 }
    ]
  }
}
```

### C.3 Clipboard Success

```json
{
  "rift": "0.1-draft",
  "type": "clipboard.fetchResponse",
  "messageId": "018f2f9a-8b7c-4a4b-9c0d-333333333333",
  "sourceDeviceId": "rift-abcdefghijklmnopqrstuvwxyz234567",
  "payload": {
    "offerId": "018f2f9a-8b7c-4a4b-9c0d-444444444444",
    "contentBase64": "aGVsbG8=",
    "byteSize": 5,
    "sha256": "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824"
  }
}
```

### C.4 Hash Mismatch Error

```json
{
  "rift": "0.1-draft",
  "type": "error",
  "messageId": "018f2f9a-8b7c-4a4b-9c0d-555555555555",
  "sourceDeviceId": "rift-abcdefghijklmnopqrstuvwxyz234567",
  "payload": { "failureReason": "HashMismatch" }
}
```

### C.5 Revocation Rejection

```json
{
  "rift": "0.1-draft",
  "type": "session.reject",
  "messageId": "018f2f9a-8b7c-4a4b-9c0d-666666666666",
  "sourceDeviceId": "rift-abcdefghijklmnopqrstuvwxyz234567",
  "payload": { "failureReason": "Unauthorized", "message": "peer identity is revoked" }
}
```

### C.6 Identity-Switch Rejection

```json
{
  "rift": "0.1-draft",
  "type": "error",
  "messageId": "018f2f9a-8b7c-4a4b-9c0d-777777777777",
  "sourceDeviceId": "rift-abcdefghijklmnopqrstuvwxyz234567",
  "payload": { "failureReason": "AuthenticationFailed", "message": "device ID does not match TLS-bound Ed25519 identity" }
}
```
