# Daemon-Backed Durable Send Queue

Status: implementation design draft.

This document defines the next architecture step after the current
Flutter-owned send queue:

- the durable send queue moves into the daemon
- Flutter becomes a client of queue state rather than the queue owner
- queued sends survive Flutter UI shutdown and app restart

This is a design note, not a normative protocol change. Any IPC additions
proposed here must later be folded into:

- `spec/doc/ipc.md`
- potentially `spec/doc/protocol.md` where operation behavior needs wording

## 1. Why Move Queue Ownership

The current app-side queue already improved:

- explicit target peer semantics
- same-peer recovery
- restart persistence
- unified enqueue path for notifications/share/open-file

But it still has a hard limit: if the Flutter UI is not running, the queue is
not the source of truth for delivery planning.

That causes architectural mismatch because the daemon already owns:

- trust
- presence
- reconnect behavior
- file transfer operations
- local persistence for transfer/operation history

The next step is therefore to move send queue ownership beside the actual send
engine.

## 2. Design Goals

1. Durable queued send items must survive Flutter process exit.
2. Auto-retry must continue when the daemon is alive, even if Flutter is not.
3. The queue must stay target-specific. No implicit fan-out.
4. The daemon must remain the authority for queue state, operation state, and
   retry decisions.
5. Flutter should still be able to stage, inspect, retry, retarget, and remove
   queue items through IPC.

## 3. Ownership Split

### 3.1 Daemon Owns

- queued send item persistence
- queue item lifecycle
- send attempt scheduling
- same-peer reconnect retry policy
- binding from queue item -> operation(s) / transfer(s)
- terminal failure classification

### 3.2 Flutter Owns

- file picking / share intake / open-with intake
- displaying queue and transfer state
- explicit user actions:
  - choose target peer
  - retry
  - retarget
  - remove

Flutter should stop persisting queue metadata as the long-term source of truth
once daemon queue support is complete.

## 4. Core Model

Introduce a daemon-local `SendQueueItem` model.

Recommended fields:

- `queueItemId`: UUIDv4
- `targetDeviceId`: nullable until user assigns target
- `sourcePath`
- `displayFileName`
- `mediaType`
- `byteSize`
- `status`
- `retryPolicy`
- `currentOperationId`: nullable
- `lastTransferId`: nullable
- `failureReason`: nullable
- `failureMessage`: nullable
- `createdAt`
- `updatedAt`
- `origin`: optional string such as `picker`, `share`, `open_with`

Recommended statuses:

- `queued`
- `waiting_for_target`
- `waiting_for_peer`
- `dispatching`
- `sending`
- `sent`
- `failed`
- `cancelled`

Important rule: once a target is assigned, the daemon must keep that target
unless Flutter explicitly retargets the item.

## 5. Persistence Boundary

The daemon should persist queue items in its own local store, next to other
durable daemon state.

Recommended minimum persistence:

- queue item metadata
- latest retry/failure state
- target peer binding
- source path string

Do not persist file bytes in the queue layer.

On daemon startup or queue reload:

1. reload queue items
2. revalidate that `sourcePath` still exists
3. if missing, transition item to `failed`
4. for recoverable waiting items, reevaluate peer availability and retry policy

## 6. Relationship to Existing File Transfer Operations

`rift.offerFile` today is an immediate action: one request creates one send
attempt and one operation.

With daemon queue support, that model should become layered:

- queue item = durable send intent
- operation = concrete send attempt

That means one queue item may produce:

- zero operations yet
- one active operation
- multiple operations over time if retries happen

Recommended invariant:

- `currentOperationId` points only to the latest active or most recent attempt
- prior attempts remain visible in operation history

## 7. IPC Additions

The current IPC has `rift.offerFile` and `rift.listFileTransfers`, but nothing
for a durable queue.

Recommended new IPC methods:

### 7.1 `rift.enqueueFileSend`

Adds a file to the daemon queue without immediately requiring a live peer
session.

**Params**

- `localPath`
- `fileName?`
- `mediaType?`
- `targetDeviceId?`
- `origin?`

**Result**

- `queueItemId`
- `status`
- `targetDeviceId?`

If `targetDeviceId` is absent, the daemon should place the item in
`waiting_for_target`.

### 7.2 `rift.listSendQueue`

Returns durable queue items.

**Result**

- `items: [...]`

Each item should include enough state for Flutter to render queue UX directly.

### 7.3 `rift.getSendQueueItem`

Fetches one queue item by `queueItemId`.

### 7.4 `rift.assignSendQueueTarget`

Assigns or changes the target peer for an existing queue item.

**Params**

- `queueItemId`
- `targetDeviceId`

### 7.5 `rift.retrySendQueueItem`

Requests retry of a failed queue item.

The daemon decides whether this becomes:

- immediate dispatch
- `waiting_for_peer`
- or stays failed because retry is invalid

### 7.6 `rift.removeSendQueueItem`

Deletes a queue item that is not active, or cancels it if currently dispatching.

### 7.7 `rift.clearCompletedSendQueueItems`

Optional convenience method for bulk cleanup.

## 8. IPC Notifications

Recommended new notifications:

- `rift.onSendQueueChanged`
- `rift.onSendQueueItemUpdated`

Suggested payload:

- `queueItemId`
- `status`
- `targetDeviceId?`
- `currentOperationId?`
- `lastTransferId?`
- `failureReason?`
- `failureMessage?`

Flutter can continue using file transfer notifications for detailed transfer
progress, but queue lifecycle changes should have their own explicit channel.

## 9. Recovery Behavior in the Daemon

### 9.1 Recoverable Failure

Recoverable failures should move the queue item to `waiting_for_peer`:

- peer unreachable
- no active session
- trusted reconnect in progress
- connection dropped mid-send

The daemon should automatically retry when:

1. peer remains trusted
2. peer is present/reachable again
3. source path still exists
4. queue item has not been cancelled or retargeted

### 9.2 Terminal Failure

Terminal failures should move the item to `failed`:

- file missing
- local file access denied
- peer rejected
- capability unavailable
- hash mismatch
- policy denied
- target removed from trust

### 9.3 Trust Changes

If `targetDeviceId` leaves trusted state:

- queued item must not auto-retarget
- transition to `failed`
- preserve target device ID for diagnostics

## 10. Scheduling Model

The first daemon-backed version should stay conservative:

- one queue item dispatches as one send attempt
- per-peer retries are serialized enough to avoid duplicate simultaneous sends
- no partial byte-range resume yet

Recommended policy:

- allow parallel sends to different peers
- avoid overlapping active attempts for the same queue item
- avoid duplicate reconnect attempts for the same peer

This fits existing trusted reconnect helpers already present in both daemons.

## 11. Flutter Migration Plan

Migration should happen in phases.

### Phase A: Dual-Path Preparation

- keep app-scoped queue for now
- add daemon queue IPC methods behind feature detection
- let Flutter prefer daemon queue when available

### Phase B: Daemon Queue as Source of Truth

- new enqueues go to daemon
- Flutter reads queue from `rift.listSendQueue`
- Flutter actions (`retry`, `retarget`, `remove`) call queue IPC methods

### Phase C: Remove App Persistence

- remove `SharedPreferences` send queue persistence in Flutter
- keep only transient UI filters/selection state in Flutter

## 12. Recommended Rollout Slices

Implement in this order.

### Slice 1: C# daemon queue model + IPC draft

- add queue item model
- add in-memory queue service
- add `enqueue/list/retry/remove/assign` IPC methods
- keep actual retry scheduling simple

### Slice 2: Persist queue in C# daemon

- durable storage
- source-path revalidation on startup
- trust/presence reevaluation

### Slice 3: Flutter prefers daemon queue

- use new IPC methods
- keep current app queue only as fallback if daemon lacks support

### Slice 4: Android daemon parity

- implement same queue IPC contract in `daemon-dart`
- reuse trusted reconnect and existing file transfer service behavior

### Slice 5: Remove Flutter-owned queue persistence

- delete `SharedPreferences` queue source of truth
- keep shared queue controller as a thin IPC-backed view model

## 13. Open Questions

These should be resolved before full rollout:

1. whether queue items belong in the same database as transfer history or in a
   separate table/store
2. whether `listFileTransfers` should expose queue linkage directly
3. whether one queue item should keep attempt history inline, or only via
   operation lookup
4. whether Windows service / user-session split needs extra path validation for
   user-picked files

## 14. Recommended Immediate Next Step

The most practical next slice is:

1. design the IPC contract additions in `spec/doc/ipc.md`
2. implement C# daemon in-memory queue service
3. wire Flutter to prefer daemon queue when those methods exist

That gives the project a real architectural pivot without forcing both daemons
and the full persistence layer to land in one risky jump.
