# Multi-Device Queue and Recovery

Status: implementation design draft.

This document defines the next app-level design for queued send and recovery
behavior when Rift moves from a single-target send queue toward a
multi-device trusted set.

It is intentionally short and implementation-facing. The normative source of
truth for peer protocol and local IPC remains:

- `spec/doc/protocol.md`
- `spec/doc/ipc.md`

This document does not redefine peer protocol semantics. It defines how the
Flutter client should drive the existing daemon behavior in a way that stays
predictable when peers disconnect, reappear, or are added later.

## 1. Current Baseline

Today the app already has:

- a staged send queue in `app-flutter/lib/screens/clipboard_transfer_screen.dart`
- per-item status (`queued`, `sending`, `sent`, `failed`)
- manual retry for failed items
- limited auto-retry for recoverable disconnect failures
- recovery bound to the same target peer when that peer becomes online again

That behavior is intentionally conservative and should remain the baseline.

## 2. Problem to Solve

The current queue is good for one peer at a time, but it is underspecified for
these cases:

1. a queued or active send loses connection mid-transfer
2. a trusted peer disappears and later comes back
3. the user has multiple trusted devices
4. a new trusted device is added after items are already queued
5. the UI is restarted while queued work still exists

Without explicit rules, the queue can feel random: users do not know which
device an item is waiting for, whether it will retry automatically, or whether
new devices will unexpectedly receive old pending items.

## 3. Design Goals

1. Keep send intent explicit. A queued item must always know who it is for.
2. Auto-recover only when the app can do so safely without changing user
   intent.
3. Never treat "more trusted devices exist" as permission to fan out a file to
   them.
4. Keep daemon authority intact: trust, protocol, operation lifecycle, and
   transfer truth still come from the daemon.
5. Make recovery visible in the UI so users can tell whether an item is
   waiting, retrying, completed, or needs attention.

## 4. Core Model

### 4.1 Queue Ownership

The Flutter app owns the local staged send queue.

The daemon owns:

- trusted-peer state
- peer presence / connectivity
- actual file transfer operations
- terminal transfer events and failure reasons

The app queue is therefore a local delivery plan layered on top of daemon
operations, not a replacement for daemon operation history.

### 4.2 Queue Item Shape

Each staged queue item should be treated as this logical model:

- `queueItemId`: local stable ID
- `localPath`
- `displayName`
- `mediaType`
- `byteSize`
- `targetDeviceId`
- `status`
- `transferId` / `operationId` when active
- `retryPolicy`
- `lastFailureReason`
- `createdAt`
- `updatedAt`

Important rule: `targetDeviceId` is required once the item is submitted for
delivery. A send item is never an unscoped "send to any trusted device"
operation.

### 4.3 Retry Policy

Use three retry modes:

- `none`: terminal failure, user must act
- `same_peer_auto`: retry automatically only for the same `targetDeviceId`
- `manual_ready`: item is valid but waiting for the user to choose or confirm a
  peer

For the current product direction, most normal sends should immediately move to
`same_peer_auto` after submission.

## 5. Recovery Rules

### 5.1 Recoverable Failure

A failed send is recoverable only when the failure implies transport or session
loss, for example:

- peer unreachable
- no active session
- session dropped
- reconnect required
- connection lost while sending

Recoverable failure behavior:

1. keep the item in queue
2. keep the same `targetDeviceId`
3. clear stale `transferId` / `operationId`
4. reset progress
5. mark the item as waiting for reconnect
6. auto-resume only when that same peer is online again

### 5.2 Terminal Failure

Failures should become terminal when retrying automatically could be wrong or
annoying, for example:

- peer rejected
- capability unavailable
- file missing locally
- file access denied
- hash mismatch
- invalid request / invalid transition
- policy denied

Terminal failure behavior:

1. keep the item visible
2. mark it `failed`
3. require explicit user action with `Retry` or `Remove`

### 5.3 In-Flight Disconnect

If a task is already running and the peer disconnects mid-transfer:

- the app should not silently mark it `sent`
- the queue item returns to waiting state if the error is recoverable
- the next attempt is a fresh transfer against the same peer

This first design does not attempt partial chunk resume. Recovery is
operation-level restart, not byte-range resume.

## 6. Multi-Device Semantics

### 6.1 Existing Trusted Set

If the user has multiple trusted devices, the send queue must remain
target-specific.

Examples:

- send to Android phone: queue item is bound to phone only
- send to Linux desktop: queue item is bound to Linux only

Another trusted device becoming online must not consume that queue item.

### 6.2 Adding a New Trusted Device Later

When a new device is added after queue items already exist:

- existing queued items stay bound to their original target
- the new device receives nothing automatically
- future sends may target the new device

This avoids accidental delivery expansion and matches the user's original send
intent.

### 6.3 Future Fan-Out

If Rift later adds "send to many devices" or "send to all trusted devices",
that must be modeled as a separate explicit feature.

It should not be inferred from one queue item plus a growing trusted list.

## 7. Persistence Direction

The next slice should persist the local queue so recovery survives app restart.

Recommended persistence boundary:

- persist local queue item metadata in app storage
- do not persist raw file bytes beyond the existing source path
- on reload, revalidate that `localPath` still exists before retrying

If the file no longer exists:

- mark the item `failed`
- surface a clear local error such as `Source file no longer exists`

## 8. Event Triggers

The queue should reevaluate pending items on these app-level events:

1. IPC connection restored
2. trusted peer list refreshed
3. peer presence changed to online
4. app resumed with persisted queued items

The queue should not auto-send merely because discovery starts. The peer must
be both trusted and presently reachable enough for the daemon to send.

## 9. UI Contract

The queue UI should communicate intent and state directly:

- `QUEUED`: ready but not yet submitted
- `SENDING`: active daemon transfer
- `WAITING`: blocked on same-peer reconnect
- `FAILED`: user action required
- `SENT`: completed

Each item should visibly show:

- file name
- target device name
- current state
- failure message when relevant

For recovery cases, the message should name the peer:

- `Waiting to retry when <device> is available again.`

## 10. Rollout Slices

Implement in this order.

### Slice 1: Formalize Current Same-Peer Recovery

- keep current same-target auto-retry rule
- tighten recoverable vs terminal classification
- ensure target peer name is always visible in queue UI
- add focused tests for state transitions

### Slice 2: Persist Queue Across App Restart

- serialize staged queue items
- reload on screen/app startup
- revalidate source file existence
- auto-resume only for `same_peer_auto` items when peer is online

### Slice 3: Explicit Peer-Bound UX

- show target device on every queued item
- if the target peer is removed from trust, convert item to `failed`
- message example: `Target device is no longer trusted`

### Slice 4: Multi-Device Target Selection Hardening

- prevent ambiguous send actions when multiple trusted peers exist
- make "Add device" separate from existing trusted-device presence
- keep new peers from affecting existing queued items

### Slice 5: Optional Advanced Recovery

Later, if needed:

- resumable chunk transfer
- send to multiple selected peers
- daemon-backed durable queue instead of UI-owned queue

These should be separate design steps.

## 11. Non-Goals

This design does not add:

- relay delivery
- offline guaranteed delivery
- partial byte-range resume
- automatic rebinding from one peer to another
- implicit broadcast to all trusted devices

## 12. Recommended Immediate Implementation

The next implementation pass should start with:

1. queue item target visibility in UI
2. stricter failure classification
3. trust-removal handling for queued items
4. queue persistence and reload

That gives the user the highest-value improvement first: the queue becomes
understandable, restart-safe, and still conservative.
