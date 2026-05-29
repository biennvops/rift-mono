# Rift IPC API Specification

Status: v0.1-draft.

This document defines the transport-agnostic JSON-RPC 2.0 contract between a Rift daemon and its local client application (the Flutter UI). It is a companion to the peer protocol specification (`protocol.md`), which defines the wire contract between daemons.

The IPC API is the only interface through which a client application interacts with the daemon. Private key material, trust enforcement, and protocol state are internal to the daemon and are never exposed through this API.

## 1. Transport Independence

The IPC contract is defined independently of transport. In v0.1-draft, two transport bindings exist:

| Platform | Transport | Notes |
| --- | --- | --- |
| Windows | Named pipe | Flutter client connects to the riftd Windows Service |
| Android | `SendPort`/`ReceivePort` | Flutter UI isolate connects to the daemon background isolate |

Future transports (Unix domain sockets on macOS/Linux, in-process channels on iOS) require only a new transport binding, not changes to this contract.

All transports carry JSON-RPC 2.0 messages. Each message is a single JSON object. Framing (length-prefix, newline-delimited, or transport-native) is transport-specific and outside this specification.

## 2. JSON-RPC 2.0 Conventions

All messages conform to the JSON-RPC 2.0 specification.

**Requests** (client → daemon) carry `jsonrpc`, `method`, `params`, and `id`. The `params` field is always an object (named parameters), never an array.

**Responses** (daemon → client) carry `jsonrpc`, `result` or `error`, and `id`.

**Notifications** (daemon → client, unsolicited) carry `jsonrpc`, `method`, and `params` but no `id`. Clients MUST NOT send responses to notifications.

Batch requests are not required in v0.1-draft. Implementations MAY support them.

## 3. Error Model

Errors use the standard JSON-RPC 2.0 error object: `{ "code": integer, "message": string, "data": object? }`.

### 3.1 Standard JSON-RPC Errors

| Code | Meaning |
| --- | --- |
| `-32700` | Parse error (malformed JSON) |
| `-32600` | Invalid request (not a valid JSON-RPC object) |
| `-32601` | Method not found |
| `-32602` | Invalid params |
| `-32603` | Internal error |

### 3.2 Application Error Codes

Rift application errors use codes in the range `-32000` to `-32099`:

| Code | Name | Mapped from | Description |
| --- | --- | --- | --- |
| `-32000` | `PeerUnreachable` | `PeerUnreachable` | Target peer is not connected |
| `-32001` | `PeerRejected` | `PeerRejected` | Peer rejected the request |
| `-32002` | `OfferExpired` | `OfferExpired` | Clipboard offer has expired |
| `-32003` | `CapabilityUnavailable` | `CapabilityUnavailable` | Required capability not negotiated |
| `-32004` | `Unauthorized` | `Unauthorized` | Peer is not trusted |
| `-32005` | `AuthenticationFailed` | `AuthenticationFailed` | Identity verification failed |
| `-32006` | `HashMismatch` | `HashMismatch` | Clipboard content hash mismatch |
| `-32007` | `PayloadTooLarge` | `PayloadTooLarge` | Content exceeds frame limit |
| `-32008` | `InvalidTransition` | `InvalidTransition` | Invalid operation state transition |
| `-32009` | `NotFound` | — | Requested resource (peer, offer, operation) does not exist |
| `-32010` | `PolicyDenied` | `PolicyDenied` | Action denied by local policy |
| `-32011` | `Timeout` | `Timeout` | Operation timed out |
| `-32012` | `IdentityNotInitialized` | — | Daemon identity not yet generated |

The `data` field of an error object MAY contain additional diagnostic information. It MUST NOT contain private keys or clipboard content.

## 4. Methods

All method names use the `rift.` prefix.

### 4.1 Identity

#### `rift.getDeviceInfo`

Returns the local device's identity information.

**Params:** none.

**Result:**

```json
{
  "deviceId": "rift-cpgwo6wefdkxwxfugsvcjbwj6mhp4gfq",
  "fingerprint": "CPGW-O6WE-FDKX-WXFU-GSVC-JBWJ-6MHP-4GFQ",
  "implementationId": "riftd-cs/0.1.0",
  "protocolVersion": "0.1-draft",
  "capabilities": [
    { "name": "clipboard.offer_fetch", "version": 1 },
    { "name": "presence.basic", "version": 1 },
    { "name": "operation.lifecycle", "version": 1 },
    { "name": "security.event_log", "version": 1 }
  ]
}
```

**Errors:** `-32012` if identity is not yet initialized.

### 4.2 Discovery

#### `rift.listDiscoveredPeers`

Returns all peers currently visible via mDNS-SD discovery, including their trust state.

**Params:** none.

**Result:**

```json
{
  "peers": [
    {
      "deviceId": "rift-abcdefghijklmnopqrstuvwxyz234567",
      "address": "192.168.1.42",
      "port": 9735,
      "trustState": "discovered",
      "txtRecord": { "minV": "0.1-draft", "maxV": "0.1-draft" }
    }
  ]
}
```

#### `rift.startDiscovery`

Begins mDNS-SD browsing for `_rift._tcp` services.

**Params:** none.

**Result:** `{ "started": true }`

#### `rift.stopDiscovery`

Stops mDNS-SD browsing.

**Params:** none.

**Result:** `{ "stopped": true }`

### 4.3 Pairing

#### `rift.startPairing`

Initiates the pairing flow with a discovered peer.

**Params:**

| Field | Type | Required | Description |
| --- | --- | --- | --- |
| `deviceId` | device ID string | Yes | The peer to pair with |

**Result:**

```json
{
  "fingerprint": "CPGW-O6WE-FDKX-WXFU-GSVC-JBWJ-6MHP-4GFQ",
  "peerFingerprint": "ABCD-EFGH-IJKL-MNOP-QRST-UVWX-YZ23-4567",
  "expiresInMs": 120000
}
```

**Errors:** `-32009` if peer not found, `-32004` if peer is blocked or revoked.

#### `rift.approvePairing`

Confirms the fingerprint matches and approves the pairing.

**Params:**

| Field | Type | Required | Description |
| --- | --- | --- | --- |
| `deviceId` | device ID string | Yes | The peer being paired |
| `fingerprint` | fingerprint string | Yes | The fingerprint the user confirmed |

**Result:** `{ "trustedDeviceId": "rift-...", "persistedAt": "2026-05-30T10:00:00Z" }`

**Errors:** `-32009` if no pending pairing, `-32005` if fingerprint mismatch.

#### `rift.rejectPairing`

Rejects an incoming or outgoing pairing.

**Params:**

| Field | Type | Required | Description |
| --- | --- | --- | --- |
| `deviceId` | device ID string | Yes | The peer whose pairing to reject |

**Result:** `{ "rejected": true }`

### 4.4 Trust Management

#### `rift.listTrustedPeers`

Returns all peers in the trust store with their current state.

**Params:** none.

**Result:**

```json
{
  "peers": [
    {
      "deviceId": "rift-abcdefghijklmnopqrstuvwxyz234567",
      "displayName": "Pixel 9",
      "trustState": "trusted",
      "pairedAt": "2026-05-15T14:30:00Z",
      "lastSeenAt": "2026-05-30T09:45:00Z",
      "presence": "online",
      "capabilities": ["clipboard.offer_fetch", "presence.basic"]
    }
  ]
}
```

#### `rift.revokeTrust`

Revokes trust for a peer. Deletes key material, terminates sessions, permanently rejects future connections from the revoked Ed25519 key.

**Params:**

| Field | Type | Required | Description |
| --- | --- | --- | --- |
| `deviceId` | device ID string | Yes | The peer to revoke |
| `reason` | string | Yes | Human-readable reason for audit log |

**Result:** `{ "revoked": true, "revokedAt": "2026-05-30T10:05:00Z" }`

**Errors:** `-32009` if peer not found.

#### `rift.unblockPeer`

Removes a block on a peer, returning them to `discovered` state.

**Params:**

| Field | Type | Required | Description |
| --- | --- | --- | --- |
| `deviceId` | device ID string | Yes | The peer to unblock |

**Result:** `{ "unblocked": true }`

**Errors:** `-32009` if peer not found, `-32008` if peer is not in `blocked` state.

### 4.5 Clipboard

#### `rift.notifyClipboardChange`

Called by the client to inform the daemon that the local clipboard has changed. The daemon broadcasts a metadata offer to trusted peers.

**Params:**

| Field | Type | Required | Description |
| --- | --- | --- | --- |
| `contentType` | string | Yes | MIME type of the clipboard content |
| `byteSize` | integer | Yes | Size of the raw content in bytes |
| `sha256` | string | Yes | SHA-256 hash of the raw content (64 lowercase hex) |
| `contentBase64` | string | Yes | Base64-encoded content for the daemon to hold |

**Result:**

```json
{
  "offerId": "018f2f9a-8b7c-4a4b-9c0d-444444444444",
  "expiresInMs": 120000,
  "broadcastTo": ["rift-abcdefghijklmnopqrstuvwxyz234567"]
}
```

**Errors:** `-32007` if content exceeds frame limit.

#### `rift.listClipboardOffers`

Returns active clipboard offers from peers.

**Params:** none.

**Result:**

```json
{
  "offers": [
    {
      "offerId": "018f2f9a-8b7c-4a4b-9c0d-555555555555",
      "sourceDeviceId": "rift-abcdefghijklmnopqrstuvwxyz234567",
      "contentType": "text/plain",
      "byteSize": 42,
      "sha256": "abc123...",
      "expiresAt": "2026-05-30T10:02:00Z"
    }
  ]
}
```

#### `rift.fetchClipboardContent`

Requests the actual clipboard content from a peer for a given offer.

**Params:**

| Field | Type | Required | Description |
| --- | --- | --- | --- |
| `offerId` | UUIDv4 string | Yes | The offer to fetch |

**Result:**

```json
{
  "offerId": "018f2f9a-8b7c-4a4b-9c0d-555555555555",
  "contentBase64": "aGVsbG8=",
  "byteSize": 5,
  "sha256": "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824",
  "verified": true
}
```

The daemon performs hash verification before returning the content. The `verified` field confirms that `byteSize` and `sha256` matched.

**Errors:** `-32002` if offer expired, `-32000` if source peer unreachable, `-32006` if hash mismatch.

### 4.6 Presence

#### `rift.getPeerPresence`

Returns presence information for a specific trusted peer.

**Params:**

| Field | Type | Required | Description |
| --- | --- | --- | --- |
| `deviceId` | device ID string | Yes | The peer to query |

**Result:**

```json
{
  "deviceId": "rift-abcdefghijklmnopqrstuvwxyz234567",
  "status": "online",
  "lastSeenAt": "2026-05-30T09:58:00Z",
  "capabilities": ["clipboard.offer_fetch", "presence.basic"]
}
```

**Errors:** `-32009` if peer not found, `-32004` if peer not trusted.

### 4.7 Operations

#### `rift.listOperations`

Returns recent operation history.

**Params:**

| Field | Type | Required | Description |
| --- | --- | --- | --- |
| `limit` | integer | No | Maximum number of operations to return (default: 50) |
| `offset` | integer | No | Pagination offset (default: 0) |

**Result:**

```json
{
  "operations": [
    {
      "operationId": "018f2f9a-8b7c-4a4b-9c0d-666666666666",
      "operationType": "clipboard.fetch",
      "state": "Done",
      "sourceDeviceId": "rift-cpgwo6wefdkxwxfugsvcjbwj6mhp4gfq",
      "destinationDeviceId": "rift-abcdefghijklmnopqrstuvwxyz234567",
      "createdAt": "2026-05-30T09:55:00Z",
      "updatedAt": "2026-05-30T09:55:02Z"
    }
  ],
  "total": 1
}
```

#### `rift.getOperation`

Returns details for a single operation, including its transition history.

**Params:**

| Field | Type | Required | Description |
| --- | --- | --- | --- |
| `operationId` | UUIDv4 string | Yes | The operation to retrieve |

**Result:**

```json
{
  "operationId": "018f2f9a-8b7c-4a4b-9c0d-666666666666",
  "operationType": "clipboard.fetch",
  "state": "Done",
  "sourceDeviceId": "rift-cpgwo6wefdkxwxfugsvcjbwj6mhp4gfq",
  "destinationDeviceId": "rift-abcdefghijklmnopqrstuvwxyz234567",
  "transitions": [
    { "from": "Created", "to": "Pending", "at": "2026-05-30T09:55:00Z" },
    { "from": "Pending", "to": "Dispatched", "at": "2026-05-30T09:55:00Z" },
    { "from": "Dispatched", "to": "Active", "at": "2026-05-30T09:55:01Z" },
    { "from": "Active", "to": "Done", "at": "2026-05-30T09:55:02Z" }
  ]
}
```

**Errors:** `-32009` if operation not found.

### 4.8 Event Log

#### `rift.queryEventLog`

Queries the security event log with optional filters.

**Params:**

| Field | Type | Required | Description |
| --- | --- | --- | --- |
| `eventTypes` | array of strings | No | Filter by event type (Section 13.1 of protocol spec) |
| `severities` | array of strings | No | Filter by severity level |
| `peerDeviceId` | device ID string | No | Filter by peer |
| `since` | RFC 3339 string | No | Events after this timestamp |
| `limit` | integer | No | Maximum events to return (default: 100) |
| `offset` | integer | No | Pagination offset (default: 0) |

**Result:**

```json
{
  "events": [
    {
      "eventId": "018f2f9a-8b7c-4a4b-9c0d-777777777777",
      "eventType": "connection.established",
      "severity": "info",
      "localDeviceId": "rift-cpgwo6wefdkxwxfugsvcjbwj6mhp4gfq",
      "peerDeviceId": "rift-abcdefghijklmnopqrstuvwxyz234567",
      "timestamp": "2026-05-30T09:50:00Z",
      "outcome": "success",
      "details": {}
    }
  ],
  "total": 1
}
```

## 5. Notifications

Notifications are unsolicited daemon → client messages with no `id` field. The client receives them automatically after connecting; no subscription handshake is required in v0.1-draft.

| Method | Payload | Description |
| --- | --- | --- |
| `rift.onPeerDiscovered` | `{ "deviceId", "address", "port", "txtRecord" }` | New peer found via mDNS-SD |
| `rift.onPeerLost` | `{ "deviceId" }` | Peer service record disappeared |
| `rift.onPairingRequest` | `{ "deviceId", "fingerprint", "displayName?", "expiresInMs" }` | Incoming pairing request from a peer |
| `rift.onPairingComplete` | `{ "deviceId", "fingerprint", "persistedAt" }` | Pairing completed successfully |
| `rift.onTrustChanged` | `{ "deviceId", "previousState", "newState", "reason?" }` | Trust state transitioned |
| `rift.onClipboardOffer` | `{ "offerId", "sourceDeviceId", "contentType", "byteSize", "sha256", "expiresInMs" }` | New clipboard offer from a peer |
| `rift.onClipboardExpired` | `{ "offerId" }` | Clipboard offer expired |
| `rift.onPresenceUpdate` | `{ "deviceId", "status", "lastSeenAt?", "capabilities" }` | Peer presence changed |
| `rift.onOperationTransition` | `{ "operationId", "operationType", "previousState", "nextState", "failureReason?" }` | Operation state changed |
| `rift.onSecurityEvent` | `{ "eventId", "eventType", "severity", "peerDeviceId?", "outcome", "failureReason?" }` | Security event logged |

## 6. Security Boundary

The IPC API enforces the following security invariants:

1. **Private keys are never exposed.** No method returns Ed25519 or ECDSA P-256 private key material. The daemon generates, stores, and uses private keys internally.

2. **Trust decisions are daemon-enforced.** The client surfaces approval prompts (pairing fingerprint verification) but the daemon enforces all trust state transitions, identity validation, and access control.

3. **Clipboard content crosses the IPC boundary.** The client needs clipboard content bytes for pasting. This is the expected data flow. However, clipboard content MUST NOT appear in event log entries (either daemon-side or in `rift.queryEventLog` results).

4. **The client holds no authoritative state.** The daemon's SQLite database is the single source of truth for identity, trust store, capabilities, and event log. The client MAY cache view-model state in memory but MUST NOT persist authoritative protocol state.

5. **Transport security is transport-specific.** Named pipes on Windows inherit OS access control (the pipe ACL restricts access to the current user session). `SendPort`/`ReceivePort` on Android is process-internal. This specification does not define additional IPC-layer encryption because both v0.1-draft transports are local and OS-protected.
