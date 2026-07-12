# Rift File Transfer Extension Proposal

Status: review draft, non-normative.

This document proposes a standalone file transfer extension for Rift. It is
intentionally written outside the current normative protocol and capstone
documents so the group owner can review scope, tradeoffs, and wording before
merging any part of it into:

- `spec/doc/protocol.md`
- `spec/doc/ipc.md`
- `docs/capstone-register.md`
- implementation plans and test plans

## 1. Purpose

Rift currently defines a clipboard-first MVP over authenticated peer JSON
messages framed as one UTF-8 JSON object per TLS frame. That design is a good
fit for metadata-first clipboard exchange, but it does not yet define a general
file transfer capability.

This proposal adds a separate file transfer feature. It does not treat file
send as clipboard transport, and it does not repurpose clipboard schemas for
files.

## 2. Scope Boundary

This proposal extends Rift beyond the current clipboard-first capstone MVP.

It introduces:

- a new peer capability for file transfer
- new peer message schemas for file offers and chunk transfer
- new local JSON-RPC methods and notifications for file transfer UX
- a daemon-side transfer engine with integrity checks, progress tracking, and
  cleanup rules
- a phased implementation plan for both daemons and the Flutter client

It does not introduce:

- cloud relay
- internet-only delivery
- NAT traversal
- STUN/TURN/ICE
- unauthenticated direct file sharing
- a requirement to merge this feature into `0.1-draft` unchanged

## 3. Design Goals

The file transfer extension should preserve Rift's existing security and
architecture principles:

1. File transfer is available only to authenticated trusted peers.
2. The daemon remains the source of truth for trust, protocol state, operation
   state, and audit logging.
3. The Flutter client remains a UI and local integration layer, not the
   protocol authority.
4. File content must remain off unauthenticated channels and out of security
   event log payloads.
5. The design must fit the current operation lifecycle and negotiated
   capability model.
6. The first implementation should minimize protocol complexity and reuse the
   existing authenticated TLS session where practical.

## 4. Recommended Direction

The recommended first version is chunked transfer over the existing
authenticated Rift peer session.

Rationale:

- Rift already has authenticated TLS transport, negotiated capabilities, and a
  formal operation lifecycle.
- A chunked JSON design requires less architectural change than a second binary
  stream while preserving the current trust and session model.
- A secondary binary channel would introduce additional complexity around
  authentication binding, flow control, lifecycle recovery, and cross-language
  interoperability.

This proposal therefore recommends:

- Phase 1: chunked JSON transfer on the existing peer session
- Phase 2: optional future binary-stream optimization if real measurements show
  the JSON/Base64 path is insufficient

## 5. Capability Proposal

Add a new optional capability:

- `file.transfer` version `1`

Meaning:

- the peer can send and receive file offers
- the peer can approve or reject file transfers
- the peer can exchange file chunks and completion messages
- the peer can surface progress and terminal status through the local IPC API

This capability should be negotiated independently from
`clipboard.offer_fetch`. A peer may support clipboard only, file transfer only,
or both.

## 6. Peer Protocol Extension Proposal

### 6.1 Operation Model

Each file transfer should be represented as a normal Rift operation using the
existing lifecycle:

- `Created`
- `Pending`
- `Dispatched`
- `Active`
- `Done`
- `Failed`
- `Expired`

Recommended operation types:

- `file.send`
- `file.receive`

The sender and receiver may each keep their own local operation records, but
the shared `operationId` should identify one transfer across peer messages and
local IPC updates.

### 6.2 Core Message Set

Recommended peer message types:

- `file.offer`
- `file.accept`
- `file.reject`
- `file.chunk`
- `file.complete`
- `file.cancel`

Optional later additions:

- `file.resumeRequest`
- `file.resumeResponse`
- `file.progress`

### 6.3 `file.offer`

Purpose:

- sender advertises file metadata and requests receiver approval before sending
  file content

Recommended payload fields:

- `transferId`: UUIDv4
- `fileName`: string
- `mediaType`: string
- `byteSize`: non-negative integer
- `sha256`: lowercase hex SHA-256 of the full file
- `chunkSize`: positive integer
- `chunkCount`: positive integer
- `expiresInMs`: duration
- `sourceDeviceId`: device ID
- `requiredCapability`: string, must be `file.transfer`
- `overwriteHint`: optional string such as `ask`, `replace`, `rename`

Rules:

- metadata only, no file bytes
- `chunkSize` must be bounded by the protocol profile
- `chunkCount` must match `byteSize`
- receiver must validate `sourceDeviceId` against the authenticated envelope

### 6.4 `file.accept`

Purpose:

- receiver approves the offered transfer and allows chunk transmission to begin

Recommended payload fields:

- `transferId`
- `receivingDeviceId`
- `chunkSize`: selected chunk size if the receiver wants to reduce it
- `destinationToken`: optional opaque token bound to receiver-local staging
  state, not a raw filesystem path

Rules:

- approval must occur only after local policy and user approval checks
- destination selection is a local IPC concern; peer messages should not expose
  raw receiver filesystem paths

### 6.5 `file.reject`

Purpose:

- receiver declines the offered transfer

Recommended payload fields:

- `transferId`
- `failureReason`
- `message`: optional diagnostic text

### 6.6 `file.chunk`

Purpose:

- sender transmits one chunk of the file after approval

Recommended payload fields:

- `transferId`
- `chunkIndex`: zero-based integer
- `offset`: non-negative integer
- `byteSize`: non-negative integer
- `chunkSha256`: lowercase hex SHA-256 of the raw chunk
- `contentBase64`: Base64 chunk bytes
- `isLastChunk`: boolean

Rules:

- chunks must be accepted only for an active approved transfer
- receiver must validate chunk ordering rules, offsets, and size bounds
- receiver must verify `chunkSha256` before writing the chunk into staged
  transfer state

### 6.7 `file.complete`

Purpose:

- sender declares all chunks sent and provides final transfer metadata for
  verification

Recommended payload fields:

- `transferId`
- `byteSize`
- `sha256`
- `chunkCount`

Rules:

- receiver must verify full staged byte count, chunk count, and whole-file
  SHA-256 before committing the file as complete
- final file commit should be atomic from the receiver's local perspective

### 6.8 `file.cancel`

Purpose:

- sender or receiver aborts an in-flight transfer

Recommended payload fields:

- `transferId`
- `failureReason`
- `message`: optional

Rules:

- cancellation should be idempotent
- staged partial data should be deleted after cancellation unless a future
  resume mode explicitly preserves it

## 7. Transport Constraints

### 7.1 Existing Constraint

The current Rift peer transport uses:

- one JSON object per frame
- 4-byte big-endian frame length prefix
- 64 KiB pre-authentication limit
- 32 MiB authenticated frame limit

Because of this, a file transfer extension cannot rely on sending an entire
file in one peer message.

### 7.2 Proposed Phase 1 Profile

Recommended initial chunk profile:

- default raw chunk size target: 1 MiB to 4 MiB
- all chunk messages remain comfortably below the 32 MiB authenticated frame
  cap after Base64 and JSON overhead
- implementations may negotiate or locally reduce the effective chunk size

The final chosen default should be measured against both daemon
implementations, Android memory behavior, and UI responsiveness.

### 7.3 Future Optimization Path

If chunked JSON proves too inefficient for real-world file sizes, a future
extension may define a separate authenticated binary stream or multiplexed
subchannel. That should be treated as a later protocol version or a new
capability revision, not silently folded into version 1 behavior.

## 8. Failure Model Extension

The current peer-visible failure reasons are intentionally closed. File
transfer will likely require extending that vocabulary.

Recommended additions for review:

- `TransferCancelled`
- `StorageUnavailable`
- `StorageQuotaExceeded`
- `FileTypeRejected`
- `FileIntegrityFailed`
- `TransferStateMismatch`

If the project wants to preserve a tighter failure vocabulary, some of these
could instead map to existing reasons such as `PolicyDenied`, `HashMismatch`,
`Timeout`, or `ProtocolError`. That decision should be made explicitly when the
proposal is merged into the normative protocol.

## 9. Security and Privacy Requirements

The file transfer extension should inherit Rift's current security invariants
and add these rules:

1. File transfer is allowed only for trusted peers with negotiated
   `file.transfer`.
2. Discovery records must not advertise filenames, file sizes, transfer
   offers, or policy state.
3. File metadata and file content must never be exchanged before the peer's
   TLS identity and Ed25519 proof are verified.
4. Receiver filesystem paths must remain local-only and must not be sent to the
   peer.
5. Security event logs may record metadata such as transfer ID, peer, size,
   media type, and outcome, but must not store file content.
6. Temporary transfer files must be staged in a bounded location and cleaned up
   on expiry, failure, or cancellation.
7. Transfer approval should be explicit by default unless a local allow-policy
   is later added.
8. Resume support, if added later, must verify partial file state
   cryptographically before reuse.

## 10. IPC Extension Proposal

This feature also requires a local JSON-RPC extension between the Flutter app
and the daemon.

### 10.1 New Methods

Recommended methods:

- `rift.offerFile`
- `rift.listIncomingFileOffers`
- `rift.acceptFileOffer`
- `rift.rejectFileOffer`
- `rift.cancelFileTransfer`
- `rift.listFileTransfers`
- `rift.getFileTransfer`

Suggested parameter shape:

#### `rift.offerFile`

Client to daemon when the user selects a local file to send.

Params:

- `targetDeviceId`
- `localPath` or a platform-safe file handle token
- `fileName`
- `mediaType`
- `byteSize`
- `sha256`

Result:

- `transferId`
- initial `operationId`
- local status

#### `rift.acceptFileOffer`

Client to daemon when the user accepts an incoming file.

Params:

- `transferId`
- `destinationPath` or a receiver-local destination token
- overwrite policy

Result:

- updated status
- local `operationId`

### 10.2 New Notifications

Recommended daemon-to-client notifications:

- `rift.onFileOffer`
- `rift.onFileTransferProgress`
- `rift.onFileTransferCompleted`
- `rift.onFileTransferFailed`
- `rift.onFileTransferCancelled`

Suggested payload fields:

- `transferId`
- `operationId`
- `sourceDeviceId`
- `destinationDeviceId`
- `fileName`
- `mediaType`
- `byteSize`
- `bytesTransferred`
- `state`
- `failureReason`

### 10.3 IPC Boundary Rules

The daemon should continue to own:

- trust enforcement
- peer capability checks
- transfer state machine
- integrity verification
- cleanup of staged partial data

The Flutter client should own:

- file picking
- receive/save approval prompts
- destination selection
- progress display
- user-initiated cancel actions

## 11. Daemon Implementation Proposal

### 11.1 Shared Requirements

Both daemons should implement:

- in-memory active transfer tracking
- bounded staging storage for partial incoming files
- whole-file SHA-256 verification
- per-chunk verification before commit to staged state
- operation lifecycle integration
- security event logging for offer, accept, reject, complete, cancel, fail, and
  expiry
- cleanup timers for abandoned offers and partial transfers

### 11.2 C# Daemon Notes

Likely core implementation areas:

- `Rift.Daemon.Core` transfer service
- protocol message handlers alongside existing clipboard handlers
- `System.IO.FileStream` for staged reads and writes
- integration with `IOperationService`
- integration with security event logging and negotiated capability checks

### 11.3 Dart Daemon Notes

Likely core implementation areas:

- file transfer engine parallel to the clipboard engine, not merged into it
- `dart:io` `File` and `RandomAccessFile` for staged writes
- transfer handler integrated with the session manager
- careful bounds checking and low-memory behavior on Android

## 12. Flutter Client Proposal

### 12.1 Sending

The Flutter client should:

- allow the user to choose a target device and select a file
- call `rift.offerFile`
- show queued, pending, active, completed, and failed transfers

### 12.2 Receiving

The Flutter client should:

- show incoming file offers with filename, type, size, and source device
- require explicit approval by default
- let the user choose a save destination where the platform allows it
- show progress and final success/failure state

### 12.3 Platform Integration

Potential integration areas include:

- standard file picker APIs for selecting outbound files
- OS share-target integration as a later phase, especially on Android

Those integrations should remain outside the peer protocol itself.

## 13. Conformance and Interop Testing Proposal

This extension should add new verification assets before feature sign-off.

Recommended coverage:

1. Schema validation for all file-transfer peer messages.
2. Capability negotiation tests for `file.transfer`.
3. Chunk ordering, replay, duplication, and out-of-range chunk rejection.
4. Whole-file SHA-256 verification on successful completion.
5. Rejection of oversized chunks before excessive buffering.
6. Expiry behavior for unaccepted or abandoned transfers.
7. Cancellation behavior from both sender and receiver.
8. Cross-implementation interop:
   - C# sender to Dart receiver
   - Dart sender to C# receiver
9. Policy and trust enforcement tests:
   - untrusted peer rejected
   - missing capability rejected
   - malformed metadata rejected
10. Event-log checks confirming metadata-only audit records.

## 14. Masterplan Extension Proposal

This feature should be tracked as an explicit extension workstream rather than
silently blended into the clipboard MVP.

### Phase A: Documentation and Protocol Draft

Files to update later:

- `spec/doc/protocol.md`
- `spec/doc/ipc.md`
- `docs/capstone-register.md`
- `tests-conformance/schema.md`

Tasks:

1. Decide whether file transfer lands in `0.1-draft` as an optional extension
   or in a later protocol revision.
2. Approve capability name, message names, and failure vocabulary.
3. Define chunk-size profile and integrity rules.
4. Define audit-log schema additions.

Deliverable:

- reviewed normative draft text for peer protocol and IPC

### Phase B: Shared Domain and Daemon Transfer Engine

Files likely involved later:

- `daemon-cs/Rift.Daemon.Core/*`
- `daemon-dart/lib/src/*`

Tasks:

1. Add transfer models and state tracking.
2. Add message encode/decode and validation.
3. Add staging storage and cleanup logic.
4. Integrate operation lifecycle and event logging.

Deliverable:

- daemon-side file transfer engines in both implementations

### Phase C: IPC and Flutter UX

Files likely involved later:

- `spec/doc/ipc.md`
- `daemon-cs/Rift.Daemon.Core/RiftApiHandler.cs`
- `app-flutter/lib/src/ipc/json_rpc_client.dart`
- Flutter screens and view-models

Tasks:

1. Add file transfer JSON-RPC methods and notifications.
2. Add send-file and receive-file approval flows.
3. Add progress UI and transfer history UI.

Deliverable:

- end-user file send and receive UX through one shared Flutter client

### Phase D: Conformance, Interop, and Security Testing

Files likely involved later:

- `tests-conformance/*`
- `tests-interop/*`
- daemon unit and integration tests

Tasks:

1. Add schema and vector tests for file messages.
2. Add cross-implementation file-transfer interop tests.
3. Add malformed-input and state-mismatch tests.
4. Add cancellation, expiry, and cleanup tests.

Deliverable:

- repeatable evidence that both daemons implement the same file transfer
  behavior

### Phase E: Optional Performance Revision

Tasks:

1. Measure throughput, memory usage, and UI responsiveness for chunked JSON.
2. Decide whether a binary subchannel is justified.
3. If needed, draft a new capability revision or new extension profile.

Deliverable:

- explicit keep-or-revise decision backed by measurements

## 15. Open Questions for Review

The owner group should decide these before merging any normative text:

1. Should file transfer be an optional extension in `0.1-draft`, or deferred to
   a post-`0.1-draft` protocol version?
2. What chunk size should be the initial interoperable default?
3. Is resumable transfer required in the first version, or should version 1 be
   send-once with restart-on-failure?
4. Should the failure vocabulary be extended, or should file transfer reuse the
   current closed reasons as much as possible?
5. Should transfer history be folded into the existing operation history UI, or
   shown in a dedicated file transfer view backed by the same operation model?
6. Is OS share-target integration part of the first implementation phase, or a
   later UX enhancement?

## 16. Recommended Merge Strategy

To minimize churn in the live documents:

1. Review this proposal as a standalone artifact.
2. Approve the capability name, message set, and failure-model direction.
3. Merge normative protocol and IPC text in small focused patches.
4. Add implementation-plan and test-plan updates only after protocol wording is
   stable.

This keeps the current clipboard MVP intact while giving the project a clear
path to a separate secure file transfer feature.
