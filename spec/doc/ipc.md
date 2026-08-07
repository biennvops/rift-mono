# Rift IPC API Specification

Status: v0.1-draft.

This document defines the transport-agnostic JSON-RPC 2.0 contract between a Rift daemon and its local client application (the Flutter UI). It is a companion to the peer protocol specification (`protocol.md`), which defines the wire contract between daemons.

The IPC API is the only interface through which a client application interacts with the daemon. Private key material, trust enforcement, and protocol state are internal to the daemon and are never exposed through this API.

## 1. Transport Independence

The IPC contract is defined independently of transport. In v0.1-draft, five transport bindings exist:

| Platform | Transport                | Notes                                                        |
| -------- | ------------------------ | ------------------------------------------------------------ |
| Windows  | Named pipe               | Flutter client connects to the riftd Windows Service         |
| macOS    | Unix domain socket       | Flutter client connects to the `daemon-cs` macOS host        |
| Linux    | Unix domain socket       | Flutter client connects to the `daemon-cs` Linux host        |
| Android  | `SendPort`/`ReceivePort` | Flutter UI isolate connects to the daemon background isolate |
| iOS      | In-process channel       | Flutter UI connects to the in-process Dart daemon            |

All transports carry JSON-RPC 2.0 messages. Each message is a single JSON object. Framing (length-prefix, newline-delimited, or transport-native) is transport-specific and outside this specification.

### 1.1 Framing Limits (IPC)

IPC transports that use explicit length framing (for example, `Content-Length` headers in a stream-based local socket) MUST enforce a reasonable maximum frame size and reject oversized messages with `-32600` (Invalid request).

This limit is independent from the peer-to-peer framing limits in `protocol.md` (4-byte length prefix with state-dependent size caps). IPC limits exist to prevent a local client (or a corrupted stream) from exhausting daemon memory.

## 2. JSON-RPC 2.0 Conventions

All messages conform to the JSON-RPC 2.0 specification.

**Requests** (client → daemon) carry `jsonrpc`, `method`, `params`, and `id`. The `params` field is always an object (named parameters), never an array.

**Responses** (daemon → client) carry `jsonrpc`, `result` or `error`, and `id`.

**Notifications** (daemon → client, unsolicited) carry `jsonrpc`, `method`, and `params` but no `id`. Clients MUST NOT send responses to notifications.

Batch requests are not required in v0.1-draft. Implementations MAY support them.

## 3. Error Model

Errors use the standard JSON-RPC 2.0 error object: `{ "code": integer, "message": string, "data": object? }`.

### 3.1 Standard JSON-RPC Errors

| Code     | Meaning                                       |
| -------- | --------------------------------------------- |
| `-32700` | Parse error (malformed JSON)                  |
| `-32600` | Invalid request (not a valid JSON-RPC object) |
| `-32601` | Method not found                              |
| `-32602` | Invalid params                                |
| `-32603` | Internal error                                |

### 3.2 Application Error Codes

Rift application errors use codes in the range `-32000` to `-32099`:

| Code     | Name                     | Mapped from             | Description                                                |
| -------- | ------------------------ | ----------------------- | ---------------------------------------------------------- |
| `-32000` | `PeerUnreachable`        | `PeerUnreachable`       | Target peer is not connected                               |
| `-32001` | `PeerRejected`           | `PeerRejected`          | Peer rejected the request                                  |
| `-32002` | `OfferExpired`           | `OfferExpired`          | Clipboard offer has expired                                |
| `-32003` | `CapabilityUnavailable`  | `CapabilityUnavailable` | Required capability not negotiated                         |
| `-32004` | `Unauthorized`           | `Unauthorized`          | Peer is not trusted                                        |
| `-32005` | `AuthenticationFailed`   | `AuthenticationFailed`  | Identity verification failed                               |
| `-32006` | `HashMismatch`           | `HashMismatch`          | Clipboard content hash mismatch                            |
| `-32007` | `PayloadTooLarge`        | `PayloadTooLarge`       | Content exceeds frame limit                                |
| `-32008` | `InvalidTransition`      | `InvalidTransition`     | Invalid operation state transition                         |
| `-32009` | `NotFound`               | —                       | Requested resource (peer, offer, operation) does not exist |
| `-32010` | `PolicyDenied`           | `PolicyDenied`          | Action denied by local policy                              |
| `-32011` | `Timeout`                | `Timeout`               | Operation timed out                                        |
| `-32012` | `IdentityNotInitialized` | —                       | Daemon identity not yet generated                          |

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
  "displayName": "Windows Desktop 07",
  "platform": "windows",
  "fingerprint": "CPGW-O6WE-FDKX-WXFU-GSVC-JBWJ-6MHP-4GFQ",
  "implementationId": "riftd-cs/0.1.0",
  "protocolVersion": "0.1-draft",
  "identityProtectionBackend": "dpapi",
  "capabilities": [
    { "name": "clipboard.offer_fetch", "version": 1 },
    { "name": "device.status", "version": 1 },
    { "name": "presence.basic", "version": 1 },
    { "name": "operation.lifecycle", "version": 1 },
    { "name": "security.event_log", "version": 1 },
    { "name": "notification.sync", "version": 1 }
  ]
}
```

`displayName` is resolved from the platform's current user-visible device or
machine name when available. Implementations fall back to a stable
identity-derived name, for example `Windows Desktop 07` or `Android Phone 12`,
when the platform returns no usable name. A platform rename may therefore be
reflected after the daemon restarts and reconnects. `displayName` is presentation
metadata only and is never an identity or authorization input. `platform` is a
canonical lowercase OS identifier: `android`, `ios`, `windows`, `macos`,
`linux`, or `unknown`. `identityProtectionBackend` is an OPTIONAL
implementation diagnostic naming the active local identity protection backend,
for example `dpapi`, `keychain`, `secret-service`, or `file`. It MUST NOT expose
key identifiers or other secret material.

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
      "instanceId": "rift-instance-id-from-mdns",
      "platform": "unknown",
      "address": "192.168.1.42",
      "port": 9735,
      "trustState": "discovered",
      "txtRecord": { "minV": "0.1-draft", "maxV": "0.1-draft" }
    }
  ]
}
```

**Note on Identity:** For discovered peers, `deviceId` is the canonical authenticated ID if available via DNS TXT records. If the peer obscures its identity for privacy (null-did), `deviceId` will be absent, and the UI should use `instanceId` (the mDNS service name) as a temporary handle to initiate pairing.

#### `rift.startDiscovery`

Begins mDNS-SD browsing for `_rift._tcp` services.

**Params:** none.

**Result:** `{ "started": true }`

**Errors:** `-32010` (`PolicyDenied`) if the OS denies local network access (for example, macOS Local Network privacy settings). In this case, the error `data` object includes `{ "policy": "local_network", "action": "startDiscovery" }`.

#### `rift.stopDiscovery`

Stops mDNS-SD browsing.

**Params:** none.

**Result:** `{ "stopped": true }`

### 4.3 Pairing

#### `rift.startPairing`

Initiates the pairing flow with a discovered peer.

**Params:**

| Field      | Type             | Required | Description           |
| ---------- | ---------------- | -------- | --------------------- |
| `deviceId` | device ID string | Yes      | The peer to pair with |

**Result:**

```json
{
  "deviceId": "rift-abcdefghijklmnopqrstuvwxyz234567",
  "fingerprint": "CPGW-O6WE-FDKX-WXFU-GSVC-JBWJ-6MHP-4GFQ",
  "peerFingerprint": "ABCD-EFGH-IJKL-MNOP-QRST-UVWX-YZ23-4567",
  "expiresInMs": 120000
}
```

**Errors:** `-32009` if peer not found, `-32004` if peer is blocked.

#### `rift.startPairingByEndpoint`

Initiates pairing by connecting directly to a peer's local TCP endpoint when
discovery is unavailable or incomplete (for example, hotspot / LAN paths where
mDNS or UDP broadcast is filtered).

This method is an explicit user-initiated pairing action. It is not the same as
the daemon's internal trusted-peer reconnect behavior. After a peer is already
trusted, implementations MAY reuse persisted last-known-good local endpoints to
re-establish an authenticated session for clipboard, presence, or other
protected operations without calling `rift.startPairingByEndpoint` again.

**Params:**

| Field     | Type    | Required | Description                         |
| --------- | ------- | -------- | ----------------------------------- |
| `address` | string  | Yes      | Peer IPv4/IPv6 address on the LAN   |
| `port`    | integer | Yes      | Peer TLS listener port              |

**Result:**

```json
{
  "deviceId": "rift-abcdefghijklmnopqrstuvwxyz234567",
  "fingerprint": "CPGW-O6WE-FDKX-WXFU-GSVC-JBWJ-6MHP-4GFQ",
  "peerFingerprint": "ABCD-EFGH-IJKL-MNOP-QRST-UVWX-YZ23-4567",
  "expiresInMs": 120000
}
```

**Errors:** `-32000` if the endpoint is not reachable on the local network,
`-32004` if the resolved peer is blocked.

#### `rift.approvePairing`

Confirms the fingerprint matches and approves the pairing.

**Params:**

| Field         | Type               | Required | Description                        |
| ------------- | ------------------ | -------- | ---------------------------------- |
| `deviceId`    | device ID string   | Yes      | The peer being paired              |
| `fingerprint` | fingerprint string | Yes      | The fingerprint the user confirmed |

**Result:** `{ "trustedDeviceId": "rift-...", "persistedAt": "2026-05-30T10:00:00Z" }`

**Errors:** `-32009` if no pending pairing, `-32005` if fingerprint mismatch.

#### `rift.rejectPairing`

Rejects an incoming or outgoing pairing.

**Params:**

| Field      | Type             | Required | Description                      |
| ---------- | ---------------- | -------- | -------------------------------- |
| `deviceId` | device ID string | Yes      | The peer whose pairing to reject |

**Result:** `{ "rejected": true }`

### 4.4 Trust Management

#### `rift.listTrustedPeers`

Returns the peers that should remain visible in the device-management list:
`pairing_pending`, `trusted`, and `blocked`.

Revoked peers are intentionally excluded from this list. Revocation behaves
like forgetting the device from the visible list while still retaining durable
negative-trust evidence internally so future connections from that identity are
rejected.

**Params:** none.

**Result:**

```json
{
  "peers": [
    {
      "deviceId": "rift-abcdefghijklmnopqrstuvwxyz234567",
      "displayName": "Pixel 9",
      "platform": "android",
      "trustState": "trusted",
      "pairedAt": "2026-05-15T14:30:00Z",
      "lastSeenAt": "2026-05-30T09:45:00Z",
      "presence": "online",
      "capabilities": ["clipboard.offer_fetch", "device.status", "presence.basic"],
      "deviceStatus": {
        "batteryPercent": 64,
        "chargingState": "charging",
        "powerSource": "usb",
        "lowPowerMode": false,
        "observedAt": "2026-05-30T09:44:00Z",
        "isStale": false
      }
    }
  ]
}
```

#### `rift.listPeersByState`

Returns all peers in the trust store for a given `trustState`.

**Params:**

| Field        | Type   | Required | Description                                                               |
| ------------ | ------ | -------- | ------------------------------------------------------------------------- |
| `trustState` | string | Yes      | One of: `discovered`, `pairing_pending`, `trusted`, `blocked`. |

**Result:** same shape as `rift.listTrustedPeers`.

#### `rift.revokeTrust`

Revokes a peer's trust. Terminates active trust, removes the peer from the
visible trusted-device list, and retains durable negative-trust evidence so
future connections from that identity are rejected until the revoked record is
explicitly cleared. The RPC method name is retained for compatibility with
older clients.

**Params:**

| Field      | Type             | Required | Description                         |
| ---------- | ---------------- | -------- | ----------------------------------- |
| `deviceId` | device ID string | Yes      | The peer to forget                  |
| `reason`   | string           | Yes      | Human-readable reason for audit log |

**Result:** `{ "revoked": true, "revokedAt": "2026-05-30T10:05:00Z" }`

**Errors:** `-32009` if peer not found.

#### `rift.unblockPeer`

Removes a block on a peer, returning them to `discovered` state.

**Params:**

| Field      | Type             | Required | Description         |
| ---------- | ---------------- | -------- | ------------------- |
| `deviceId` | device ID string | Yes      | The peer to unblock |

**Result:** `{ "unblocked": true }`

**Errors:** `-32009` if peer not found, `-32008` if peer is not in `blocked` state.

### 4.5 Clipboard

#### `rift.notifyClipboardChange`

Called by the client to inform the daemon that the local clipboard has changed.
The daemon broadcasts a metadata offer to trusted peers.

If a trusted peer is temporarily offline from discovery, implementations MAY
attempt an internal reconnect using persisted trusted endpoints before giving up
delivery. Such reconnect behavior is daemon-internal and does not change the
client-facing JSON-RPC method contract. Implementations MAY also hold pending
clipboard metadata locally for a short bounded period while waiting for trusted
local reachability to recover, provided normal offer expiry semantics still
apply.

**Params:**

| Field           | Type    | Required | Description                                        |
| --------------- | ------- | -------- | -------------------------------------------------- |
| `contentType`   | string  | Yes      | MIME type of the clipboard content                 |
| `byteSize`      | integer | Yes      | Size of the raw content in bytes                   |
| `sha256`        | string  | Yes      | SHA-256 hash of the raw content (64 lowercase hex) |
| `contentBase64` | string  | Yes      | Base64-encoded content for the daemon to hold      |

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
      "contentType": "image/png",
      "byteSize": 42,
      "sha256": "abc123...",
      "expiresAt": "2026-05-30T10:02:00Z"
    }
  ]
}
```

Implementations MUST support `text/plain`. They MAY additionally surface binary
clipboard content types such as `image/png`.

#### `rift.fetchClipboardContent`

Requests the actual clipboard content from a peer for a given offer.

If the source peer is trusted but not currently present in discovery,
implementations MAY first attempt an internal trusted-peer reconnect using
persisted last-known-good local endpoints before returning `PeerUnreachable`.

**Params:**

| Field     | Type          | Required | Description        |
| --------- | ------------- | -------- | ------------------ |
| `offerId` | UUIDv4 string | Yes      | The offer to fetch |

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

### 4.6 File Transfer

The file transfer IPC methods correspond to the optional peer capability
`file.transfer`. Implementations that do not support or negotiate this
capability MAY return `-32601` or `-32003`.

#### `rift.offerFile`

Offers a local file to a trusted peer.

**Params:**

| Field            | Type               | Required | Description                        |
| ---------------- | ------------------ | -------- | ---------------------------------- |
| `targetDeviceId` | device ID string   | Yes      | The destination peer               |
| `localPath`      | string             | Yes      | Local source path on this device   |
| `fileName`       | string             | No       | Override name shown to the peer    |
| `mediaType`      | string             | No       | MIME type; default is implementation-defined |

**Result:**

```json
{
  "transferId": "018f2f9a-8b7c-4a4b-9c0d-888888888888",
  "operationId": "018f2f9a-8b7c-4a4b-9c0d-999999999999",
  "targetDeviceId": "rift-abcdefghijklmnopqrstuvwxyz234567",
  "fileName": "example.png",
  "byteSize": 1024,
  "chunkSize": 262144,
  "chunkCount": 1
}
```

#### `rift.enqueueFileSend`

Queues a local file for durable daemon-managed sending. Unlike `rift.offerFile`,
this method creates a queued send intent that may survive Flutter UI exit and
may wait for target assignment or peer availability before dispatch.

**Params:**

| Field            | Type               | Required | Description                                 |
| ---------------- | ------------------ | -------- | ------------------------------------------- |
| `localPath`      | string             | Yes      | Local source path on this device            |
| `fileName`       | string             | No       | Override name shown to the peer             |
| `mediaType`      | string             | No       | MIME type; default is implementation-defined |
| `targetDeviceId` | device ID string   | No       | If omitted, the item waits for target assignment |
| `origin`         | string             | No       | Optional UI/source hint such as `picker` or `share` |

**Result:**

```json
{
  "queueItemId": "018f2f9a-8b7c-4a4b-9c0d-777777777777",
  "status": "waiting_for_target",
  "targetDeviceId": null
}
```

#### `rift.listSendQueue`

Returns durable outgoing send queue items owned by the daemon.

**Params:** none.

**Result:**

```json
{
  "items": [
    {
      "queueItemId": "018f2f9a-8b7c-4a4b-9c0d-777777777777",
      "status": "queued",
      "targetDeviceId": "rift-abcdefghijklmnopqrstuvwxyz234567",
      "localPath": "/home/user/Downloads/example.png",
      "fileName": "example.png",
      "mediaType": "image/png",
      "byteSize": 1024,
      "currentOperationId": null,
      "lastTransferId": null,
      "failureReason": null,
      "failureMessage": null,
      "createdAt": "2026-07-14T09:58:00.0000000+00:00",
      "updatedAt": "2026-07-14T09:58:00.0000000+00:00",
      "origin": "share"
    }
  ]
}
```

#### `rift.getSendQueueItem`

Returns one durable outgoing send queue item.

**Params:**

| Field         | Type          | Required | Description             |
| ------------- | ------------- | -------- | ----------------------- |
| `queueItemId` | UUIDv4 string | Yes      | The queue item to fetch |

#### `rift.assignSendQueueTarget`

Assigns or changes the target peer for an existing queue item.

**Params:**

| Field          | Type             | Required | Description        |
| -------------- | ---------------- | -------- | ------------------ |
| `queueItemId`  | UUIDv4 string    | Yes      | The queue item     |
| `targetDeviceId` | device ID string | Yes    | Trusted destination |

#### `rift.retrySendQueueItem`

Requests retry of a durable send queue item.

**Params:**

| Field         | Type          | Required | Description        |
| ------------- | ------------- | -------- | ------------------ |
| `queueItemId` | UUIDv4 string | Yes      | The queue item     |

#### `rift.removeSendQueueItem`

Removes a durable send queue item.

**Params:**

| Field         | Type          | Required | Description        |
| ------------- | ------------- | -------- | ------------------ |
| `queueItemId` | UUIDv4 string | Yes      | The queue item     |

#### `rift.cancelFileTransfer`

Cancels an in-flight file transfer initiated or accepted by the local daemon.

**Params:**

| Field        | Type          | Required | Description            |
| ------------ | ------------- | -------- | ---------------------- |
| `transferId` | UUIDv4 string | Yes      | The active transfer    |

**Result:**

```json
{
  "transferId": "018f2f9a-8b7c-4a4b-9c0d-888888888888",
  "cancelled": true
}
```

#### `rift.acceptFileOffer`

Accepts an incoming file offer and records the publication destination selected
by the local user-session client. On desktop, the daemon receives into private
staging and MUST NOT write directly to `destinationPath`. The path is retained
as intended-publication metadata for a local publication client.

**Params:**

| Field             | Type          | Required | Description                         |
| ----------------- | ------------- | -------- | ----------------------------------- |
| `transferId`      | UUIDv4 string | Yes      | The offered transfer                |
| `destinationPath` | string        | Yes      | Intended user-visible publication path |
| `overwrite`       | boolean       | No       | Whether to replace an existing file |

**Result:**

```json
{
  "transferId": "018f2f9a-8b7c-4a4b-9c0d-888888888888",
  "operationId": "018f2f9a-8b7c-4a4b-9c0d-aaaaaaaabbbb",
  "destinationPath": "/home/user/Downloads/example.png"
}
```

#### `rift.listPendingFileCommits`

Returns incoming desktop transfers whose content has been fully received and
verified but has not yet been published by a local user-session client.

**Params:** none.

**Result:**

```json
{
  "commits": [
    {
      "transferId": "018f2f9a-8b7c-4a4b-9c0d-888888888888",
      "operationId": "018f2f9a-8b7c-4a4b-9c0d-aaaaaaaabbbb",
      "peerDeviceId": "rift-abcdefghijklmnopqrstuvwxyz234567",
      "fileName": "example.png",
      "mediaType": "image/png",
      "byteSize": 1024,
      "sha256": "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
      "stagingPath": "/home/user/.local/share/rift-daemon/incoming/018f2f9a/content.part",
      "destinationPath": "/home/user/Downloads/example.png",
      "state": "ready_to_commit"
    }
  ]
}
```

The staging path is private daemon-owned content made available only to an
authorized same-user IPC client. Clients MUST treat the staging file as
read-only and MUST NOT present it as a completed user file.

#### `rift.confirmFileCommit`

Confirms that a local publication client copied and atomically published a
verified staging file. Before completing the operation, the daemon MUST read
the final file and independently verify its byte count and SHA-256 against the
pending commit.

**Params:**

| Field             | Type          | Required | Description                         |
| ----------------- | ------------- | -------- | ----------------------------------- |
| `transferId`      | UUIDv4 string | Yes      | Pending incoming transfer           |
| `destinationPath` | string        | Yes      | Final user-visible committed path   |

**Result:**

```json
{
  "transferId": "018f2f9a-8b7c-4a4b-9c0d-888888888888",
  "committed": true,
  "destinationPath": "/home/user/Downloads/example.png"
}
```

**Errors:** `-32009` when no pending commit exists, `-32006` when the final
file does not match the verified staging metadata, and `-32010` when local
policy denies the destination.

#### `rift.failFileCommit`

Reports that a local publication client could not publish a pending incoming
file. The daemon fails the local receive operation, cleans private staging, and
for `file.transfer` version 2 sends `file.cancel` to the peer.

**Params:**

| Field           | Type          | Required | Description                         |
| --------------- | ------------- | -------- | ----------------------------------- |
| `transferId`    | UUIDv4 string | Yes      | Pending incoming transfer           |
| `failureReason` | string        | Yes      | Closed-vocabulary failure reason    |
| `message`       | string        | No       | Local diagnostic without file data  |

**Result:**

```json
{
  "transferId": "018f2f9a-8b7c-4a4b-9c0d-888888888888",
  "failed": true
}
```

#### `rift.rejectFileOffer`

Rejects an incoming file offer.

**Params:**

| Field           | Type          | Required | Description                  |
| --------------- | ------------- | -------- | ---------------------------- |
| `transferId`    | UUIDv4 string | Yes      | The offered transfer         |
| `failureReason` | string        | Yes      | Closed-vocabulary failure    |
| `message`       | string        | No       | Optional local diagnostic    |

**Result:**

```json
{
  "transferId": "018f2f9a-8b7c-4a4b-9c0d-888888888888",
  "rejected": true
}
```

### 4.7 Notification Sync

#### `rift.listNotifications`

Returns the locally cached mirrored notification inbox plus the current local notification-sync policy.

**Params:** none.

**Result:**

```json
{
  "notifications": [
    {
      "notificationId": "android:com.example.chat:42",
      "sourceDeviceId": "rift-abcdefghijklmnopqrstuvwxyz234567",
      "sourcePlatform": "android",
      "packageName": "com.example.chat",
      "appName": "Example Chat",
      "title": "Riley",
      "bodyPreview": "See you at 6?",
      "postedAt": "2026-07-14T09:58:00Z",
      "isDismissible": true,
      "isOpenable": true
    }
  ],
  "observedApps": [
    {
      "packageName": "com.example.chat",
      "appName": "Example Chat"
    }
  ],
  "policy": {
    "enabled": true,
    "mode": "exclude",
    "packageNames": ["com.bank.example"]
  }
}
```

`observedApps` contains locally observed app identifiers from notification posts/updates, including notifications suppressed by the current local policy. It is a convenience index for local settings; it does not represent mirrored inbox notifications.

#### `rift.performNotificationAction`

Requests a remote action against a mirrored notification when the source marked that action as available.

**Params:**

| Field            | Type          | Required | Description                                 |
| ---------------- | ------------- | -------- | ------------------------------------------- |
| `sourceDeviceId` | device ID     | Yes      | Device that originated the notification     |
| `notificationId` | string        | Yes      | Source-scoped stable notification ID        |
| `action`         | string        | Yes      | Closed vocabulary: `open` or `dismiss`      |

`sourceDeviceId` is required because `notificationId` is only unique within its source device. Actions are always resolved through the composite `(sourceDeviceId, notificationId)` identity.

Action availability is controlled by the mirrored record's `isDismissible` and `isOpenable` flags. Android-origin records currently advertise only `dismiss`; remote `open` is not supported for Android sources.

**Result:**

```json
{
  "operationId": "018f2f9a-8b7c-4a4b-9c0d-666666666667",
  "sourceDeviceId": "rift-abcdefghijklmnopqrstuvwxyz234567",
  "notificationId": "android:com.example.chat:42",
  "action": "dismiss",
  "state": "Pending"
}
```

**Errors:** `-32003` if the source peer cannot currently perform notification sync or actions, `-32009` if `(sourceDeviceId, notificationId)` does not exist, `-32010` if the notification does not allow the requested action.

#### `rift.reportLocalNotificationActionHandled`

Reports the outcome of an action previously delivered through `rift.onNotificationActionRequest`.

**Params:** `requestId` string, `success` boolean, optional `failureReason` failure reason, optional `message` string.

**Errors:** `-32009` if `requestId` is unknown or already completed.

#### `rift.updateNotificationSyncPolicy`

Updates the local notification-sync policy. Filtering applies only to notification posts and updates originating on this device. Notification removals remain deliverable regardless of the current policy.

**Params:**

Canonical requests contain all three canonical fields:

| Field          | Type             | Required | Description                                                       |
| -------------- | ---------------- | -------- | ----------------------------------------------------------------- |
| `enabled`      | boolean          | Yes      | Whether local notification sync is enabled                        |
| `mode`         | string           | Yes      | `all`, `exclude`, or `include`                                    |
| `packageNames` | array of strings | Yes      | Exact, case-sensitive package/app identifiers used by the mode    |

Mode semantics:

- `all`: sync notifications from every app.
- `exclude`: sync every app except identifiers in `packageNames`.
- `include`: sync only identifiers in `packageNames`.

Package identifiers are trimmed, empty values are removed, duplicates are removed, and the result is sorted using ordinal/string ordering. A legacy request containing `enabled` and `blacklistedPackages` is accepted as `exclude` (or `all` when the list is empty). Mixing canonical and legacy fields is invalid.

**Result:**

```json
{
  "enabled": true,
  "mode": "exclude",
  "packageNames": ["com.bank.example"]
}
```

**Errors:** `-32602` for an invalid mode, package list, or ambiguous canonical/legacy request.

#### `rift.notifyLocalNotificationEvent`

Submits a locally observed or locally generated notification event into the daemon so it can update the local inbox and mirror the event to trusted peers, including desktop and Android sinks.

`posted` / `updated` require `notificationId`, `packageName`, `appName`, `postedAt`, `isDismissible`, and `isOpenable`. `removed` requires `notificationId` and may include `removedAt`. `sourcePlatform` is optional and carries a source hint such as `android`, `ios`, `windows`, `macos`, or `linux`.

#### `rift.listMediaPlayback`

Returns the locally cached mirrored media playback state.

**Params:** none.

#### `rift.getMediaPlayback`

Returns one mirrored playback record by its source-scoped identity.

**Params:** `sourceDeviceId` device ID string, `playbackId` string.

#### `rift.performMediaPlaybackAction`

Requests a remote media playback action.

**Params:** `sourceDeviceId` device ID string, `playbackId` string, `action` string, optional `positionMs` integer for `seek`.

`sourceDeviceId` is required because `playbackId` is scoped to its source device on the peer protocol.

#### `rift.reportLocalMediaPlaybackActionHandled`

Reports the outcome of an action previously delivered through `rift.onMediaPlaybackActionRequest`.

**Params:** `requestId` string, `success` boolean, optional `failureReason` failure reason, optional `message` string.

#### `rift.notifyLocalMediaPlaybackEvent`

Submits a locally observed or locally generated media playback event into the daemon so it can update the local playback cache and mirror the event to trusted peers.

`posted` / `updated` require `playbackId`, `appId`, `appName`, `playbackState`, `positionMs`, `updatedAt`, and the five `can*` booleans. `removed` requires `playbackId` and may include `removedAt`. `sourcePlatform` is optional and carries a source hint such as `android`, `ios`, `windows`, `macos`, or `linux`.

### 4.7A Device Status

#### `rift.getPeerDeviceStatus`

Returns the latest locally cached status snapshot for a trusted peer.

**Params:** `deviceId` device ID string.

**Result:**

```json
{
  "sourceDeviceId": "rift-abcdefghijklmnopqrstuvwxyz234567",
  "sourcePlatform": "android",
  "batteryPresent": true,
  "batteryPercent": 64,
  "chargingState": "charging",
  "powerSource": "usb",
  "lowPowerMode": false,
  "observedAt": "2026-05-30T09:44:00Z",
  "isStale": false
}
```

`isStale` is derived locally from receipt time and peer presence. It is never
accepted from the peer protocol. Unsupported power fields are omitted.

**Errors:** `-32009` if the peer or cached status is not found, `-32004` if the
peer is not trusted.

#### `rift.notifyLocalDeviceStatus`

Submits the latest locally observed power-state snapshot so the daemon can cache
it and mirror it to trusted peers that negotiated `device.status@1`.

**Params:** optional `batteryPresent` boolean, optional `batteryPercent` integer
`0` through `100`, optional `chargingState` string, optional `powerSource` string,
optional `lowPowerMode` boolean, optional `sourcePlatform` string, and optional
`observedAt` RFC 3339 UTC string. At least one power-state field is required.
When `batteryPresent` is false, battery percentage and charging state should be
omitted. The daemon supplies
`sourceDeviceId` and defaults `observedAt` and `sourcePlatform` when omitted.

**Result:** `{ "broadcastTo": ["rift-..."] }`

### 4.8 Presence

#### `rift.getPeerPresence`

Returns presence information for a specific trusted peer.

**Params:**

| Field      | Type             | Required | Description       |
| ---------- | ---------------- | -------- | ----------------- |
| `deviceId` | device ID string | Yes      | The peer to query |

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

### 4.9 Operations

#### `rift.listOperations`

Returns recent operation history.

**Params:**

| Field    | Type    | Required | Description                                          |
| -------- | ------- | -------- | ---------------------------------------------------- |
| `limit`  | integer | No       | Maximum number of operations to return (default: 50) |
| `offset` | integer | No       | Pagination offset (default: 0)                       |

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

| Field         | Type          | Required | Description               |
| ------------- | ------------- | -------- | ------------------------- |
| `operationId` | UUIDv4 string | Yes      | The operation to retrieve |

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

### 4.10 Event Log

#### `rift.queryEventLog`

Queries the security event log with optional filters.

**Params:**

| Field          | Type             | Required | Description                                          |
| -------------- | ---------------- | -------- | ---------------------------------------------------- |
| `eventTypes`   | array of strings | No       | Filter by event type (Section 13.1 of protocol spec) |
| `severities`   | array of strings | No       | Filter by severity level                             |
| `peerDeviceId` | device ID string | No       | Filter by peer                                       |
| `since`        | RFC 3339 string  | No       | Events after this timestamp                          |
| `limit`        | integer          | No       | Maximum events to return (default: 100)              |
| `offset`       | integer          | No       | Pagination offset (default: 0)                       |

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

| Method                       | Payload                                                                                | Description                          |
| ---------------------------- | -------------------------------------------------------------------------------------- | ------------------------------------ |
| `rift.onPeerDiscovered`      | `{ "deviceId?", "instanceId", "address", "port", "txtRecord" }`                        | New peer found via mDNS-SD           |
| `rift.onPeerLost`            | `{ "deviceId?", "instanceId" }`                                                        | Peer service record disappeared      |
| `rift.onPairingRequest`      | `{ "deviceId", "fingerprint", "displayName?", "expiresInMs" }`                         | Incoming pairing request from a peer |
| `rift.onPairingComplete`     | `{ "deviceId", "fingerprint", "persistedAt" }`                                         | Pairing completed successfully       |
| `rift.onTrustChanged`        | `{ "deviceId", "previousState", "newState", "reason?" }`                               | Trust state transitioned             |
| `rift.onClipboardOffer`      | `{ "offerId", "sourceDeviceId", "contentType", "byteSize", "sha256", "expiresInMs" }`  | New clipboard offer from a peer      |
| `rift.onClipboardExpired`    | `{ "offerId" }`                                                                        | Clipboard offer expired              |
| `rift.onNotificationPosted`  | `{ "notificationId", "sourceDeviceId", "packageName", "appName", "title?", "bodyPreview?", "postedAt", "isDismissible", "isOpenable", "icon?" }` | Mirrored notification posted         |
| `rift.onNotificationUpdated` | `{ "notificationId", "sourceDeviceId", "packageName", "appName", "title?", "bodyPreview?", "postedAt", "isDismissible", "isOpenable", "icon?" }` | Mirrored notification updated        |
| `rift.onNotificationRemoved` | `{ "notificationId", "sourceDeviceId", "removedAt?" }`                                | Mirrored notification removed        |
| `rift.onNotificationActionRequest` | `{ "requestId", "notificationId", "sourceDeviceId", "requestingDeviceId", "action", "requestedAt?" }` | Local notification action requested by a peer |
| `rift.onNotificationActionResult` | `{ "notificationId", "sourceDeviceId", "operationId", "action", "state", "success?", "failureReason?", "message?" }` | Remote notification action result |
| `rift.onDeviceStatusUpdated` | `{ "sourceDeviceId", "sourcePlatform?", "batteryPresent?", "batteryPercent?", "chargingState?", "powerSource?", "lowPowerMode?", "observedAt", "isStale?" }` | Device power status changed |
| `rift.onMediaPlaybackPosted` | `{ "playbackId", "sourceDeviceId", "appId", "appName", "title?", "artist?", "album?", "playbackState", "positionMs", "durationMs?", "canPlay", "canPause", "canSkipNext", "canSkipPrevious", "canSeek", "updatedAt", "artwork?" }` | Mirrored playback posted |
| `rift.onMediaPlaybackUpdated` | `{ "playbackId", "sourceDeviceId", "appId", "appName", "title?", "artist?", "album?", "playbackState", "positionMs", "durationMs?", "canPlay", "canPause", "canSkipNext", "canSkipPrevious", "canSeek", "updatedAt", "artwork?" }` | Mirrored playback updated |
| `rift.onMediaPlaybackRemoved` | `{ "playbackId", "sourceDeviceId", "removedAt?" }` | Mirrored playback removed |
| `rift.onMediaPlaybackActionRequest` | `{ "requestId", "playbackId", "sourceDeviceId", "requestingDeviceId", "action", "positionMs?", "requestedAt?" }` | Local playback action requested by a peer |
| `rift.onMediaPlaybackActionResult` | `{ "playbackId", "sourceDeviceId", "operationId", "action", "state", "success?", "failureReason?", "message?" }` | Remote playback action result |
| `rift.onFileOffer`           | `{ "transferId", "sourceDeviceId", "fileName", "mediaType", "byteSize", "sha256", "chunkSize", "chunkCount", "expiresAt" }` | New incoming file offer              |
| `rift.onFileTransferReadyToCommit` | `{ "transferId", "operationId", "peerDeviceId", "fileName", "mediaType", "byteSize", "sha256", "stagingPath", "destinationPath", "state" }` | Verified incoming file awaits user-session publication |
| `rift.onSendQueueChanged`    | `{ "queueItemId", "removed" }`                                                         | Durable send queue item removed      |
| `rift.onSendQueueItemUpdated`| `{ "queueItemId", "status", "targetDeviceId?", "currentOperationId?", "lastTransferId?", "failureReason?", "failureMessage?" }` | Durable send queue item changed      |
| `rift.onPresenceUpdate`      | `{ "deviceId", "status", "lastSeenAt?", "capabilities" }`                              | Peer presence changed                |
| `rift.onOperationTransition` | `{ "operationId", "operationType", "previousState", "nextState", "failureReason?" }`   | Operation state changed              |
| `rift.onSecurityEvent`       | `{ "eventId", "eventType", "severity", "peerDeviceId?", "outcome", "failureReason?" }` | Security event logged                |

## 6. Security Boundary

The IPC API enforces the following security invariants:

1. **Private keys are never exposed.** No method returns Ed25519 or ECDSA P-256 private key material. The daemon generates, stores, and uses private keys internally.

2. **Trust decisions are daemon-enforced.** The client surfaces approval prompts (pairing fingerprint verification) but the daemon enforces all trust state transitions, identity validation, and access control.

3. **Clipboard content crosses the IPC boundary.** The client needs clipboard content bytes for pasting. This is the expected data flow. However, clipboard content MUST NOT appear in event log entries (either daemon-side or in `rift.queryEventLog` results).

4. **The client holds no authoritative state.** The daemon's SQLite database is the single source of truth for identity, trust store, capabilities, and event log. The client MAY cache view-model state in memory but MUST NOT persist authoritative protocol state.

5. **Transport security is transport-specific.** Named pipes on Windows inherit OS access control (the pipe ACL restricts access to the current user session). `SendPort`/`ReceivePort` on Android is process-internal. Desktop Unix sockets are restricted to the current user. This specification does not define additional IPC-layer encryption because all v0.1-draft transports are local and OS-protected.

6. **Desktop file publication crosses the IPC boundary.** The daemon exposes a verified private staging path only to an authorized same-user client. The client treats staging content as read-only, publishes through a temporary destination file plus atomic rename, and reports the final path. The daemon independently verifies the committed file before acknowledging peer success. File content, staging paths, and destination paths MUST NOT be included in security-event details beyond the minimum local diagnostic metadata allowed by policy.
