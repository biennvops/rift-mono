# Clipboard and File Transfer Boundary

Status: supporting implementation note.

This document records the current repository reality and the recommended
delivery boundary between clipboard continuity, file transfer, folder transfer,
and application data exchange.

It exists to keep follow-up implementation work aligned across:

- `spec/doc/protocol.md`
- `spec/doc/ipc.md`
- `daemon-cs/`
- `daemon-dart/`
- `app-flutter/`
- `tests-conformance/`
- `tests-interop/`

## 1. Current Repository State

The repository currently supports one mature continuity flow and one partially
landed extension:

1. Clipboard continuity is the normative MVP.
2. File transfer already has substantial implementation in both daemons and the
   Flutter client, but is not yet fully folded into the normative protocol and
   IPC specifications.

The current clipboard path is effectively text-first in the app integration
layer even though the protocol envelope already carries generic bytes plus a
`contentType`.

## 2. Delivery Boundary

The project should treat the following as separate capabilities rather than one
blended "copy anything" feature.

### 2.1 Clipboard

Clipboard is for transient clipboard content mirrored through metadata offer +
authenticated fetch.

Recommended MVP content types:

- `text/plain`
- `image/png`

Clipboard should remain:

- metadata-first
- expiry-based
- fetch-on-demand
- bounded by the existing authenticated JSON framing limits

Clipboard is not the transport for file, directory, or app-state replication.

### 2.2 File Transfer

File transfer is a separate authenticated capability:

- capability name: `file.transfer`
- operation types: `file.send` / `file.receive`
- explicit offer / accept / reject / chunk / complete flow

Files should continue to use the dedicated file transfer engines rather than be
encoded as clipboard payloads.

### 2.3 Folder Transfer

Folder transfer is not currently implemented as a first-class feature.

When it is introduced, it should build on the file transfer capability rather
than on clipboard semantics.

Preferred introduction order:

1. simple archive-based transfer (`zip` or equivalent), or
2. a later multi-entry manifest extension on top of `file.transfer`

### 2.4 Application Data

Application data exchange is out of the current MVP scope.

It should not be modeled as generic clipboard content and should not silently
piggyback on file transfer without an explicit capability and policy model.

Examples that would require separate design:

- browser session handoff
- note draft handoff
- app-owned sandbox payloads
- structured state sync

## 3. Recommended Implementation Order

Work should proceed in this order:

1. Preserve and stabilize text clipboard behavior.
2. Extend clipboard to support image content.
3. Fold `file.transfer` into the normative protocol and IPC specs.
4. Add folder transfer only after file transfer is specification-complete.
5. Defer application data exchange until concrete use cases exist.

This order keeps the MVP narrow while reusing the architecture already present
in the repository.

## 4. Immediate Work Plan

The next implementation steps should follow this sequence.

### Step 1: Spec Clarification

Update the normative docs so they no longer imply that clipboard is text-only.

Required follow-ups:

- define the allowed clipboard content types for the next increment
- specify hash and byte semantics for binary clipboard payloads
- document interoperability behavior when a peer does not support the same
  clipboard content type

### Step 2: File Transfer Normalization

Promote the implemented `file.transfer` behavior from repository reality to
documented contract by updating:

- `spec/doc/protocol.md`
- `spec/doc/ipc.md`

The existing proposal document should remain a drafting aid until the normative
spec text lands.

### Step 3: Platform Integration for Image Clipboard

Implement image clipboard end to end:

- desktop clipboard read/write integration in `app-flutter/`
- Android clipboard capture/application integration
- daemon-side validation and fetch/apply support
- interop and regression tests

## 5. Non-Goals for the Next Increment

The next increment should not attempt to:

- merge file transfer into clipboard
- support recursive folder transfer
- support arbitrary application state handoff
- redesign the operation model beyond what image clipboard and file transfer
  require

Keeping these out of scope reduces protocol churn and limits cross-platform
behavioral risk.
