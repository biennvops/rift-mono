# Desktop Clipboard Runtime Checklist

Status: supporting verification note.

Current verified pairings:

- Linux desktop <-> Android device: verified for `text/plain` and `image/png`
  in both directions.

This checklist is for validating the desktop clipboard bridges on real target
hosts after the repository-side code paths have landed.

Targets:

- Windows
- Linux
- macOS

The goal is to verify actual runtime behavior of the shared desktop clipboard
method channel `rift/desktop/clipboard` for:

- `text/plain`
- `image/png`

Keep this runbook short while actively debugging. Record exact elapsed times
only for real send/apply events, not clipboard polling reads.

## 1. Preconditions

Before running platform checks:

1. Start a compatible daemon for the target desktop host.
2. Launch `app-flutter` on the target machine.
3. Pair the desktop host with an Android or second desktop peer that can send
   clipboard offers.
4. Confirm the peer negotiates `clipboard.offer_fetch`.

## 2. Common Test Cases

Run these cases on each desktop OS.

### 2.1 Local Text Send

1. Copy a short text string locally.
2. Wait for Rift to detect the clipboard change.
3. Confirm the peer receives a `text/plain` clipboard offer.
4. Fetch/apply it on the peer.

Expected result:

- outgoing offer is created
- peer receives the expected text
- no duplicate echo loop occurs

### 2.2 Incoming Text Apply

1. Copy text on the peer device.
2. Let the desktop host receive the clipboard offer.
3. Fetch or auto-fetch the content.
4. Paste into a local text field on the desktop host.

Expected result:

- local clipboard now contains the fetched text
- pasted text matches the peer source exactly

### 2.3 Local PNG Send

1. Copy a PNG image locally using a normal OS clipboard workflow.
2. Wait for Rift to detect the clipboard change.
3. Confirm the peer receives an `image/png` clipboard offer.
4. Fetch/apply it on the peer.

Expected result:

- outgoing offer reports `contentType = image/png`
- peer receives image bytes, not text fallback
- image is usable after paste on the peer side

### 2.4 Incoming PNG Apply

1. Copy a PNG image on the peer device.
2. Let the desktop host receive the clipboard offer.
3. Fetch or auto-fetch the content.
4. Paste into a local image-capable target on the desktop host.

Expected result:

- local clipboard now contains an image, not a text placeholder
- pasted image matches the peer source visually

### 2.5 Unsupported Content Safety

1. Copy a clipboard payload that Rift does not claim to support.
2. Observe Rift behavior on the desktop host.

Expected result:

- unsupported payload is ignored safely
- session remains healthy
- text clipboard behavior still works afterward

### 2.6 Image Stability Sweep

Run this sweep on Linux, macOS, and Android pairings once basic image copy
already works.

1. Small image: under 250 KiB PNG-equivalent payload.
2. Medium image: around 1 MiB to 3 MiB after PNG normalization.
3. Large image: around 8 MiB to 16 MiB after PNG normalization.
4. Repeat the same clipboard content without changing it.
5. Try these source applications:
   - screenshot tool
   - browser image copy
   - file manager image copy
   - gallery/photo app copy on Android

Expected result:

- a real send/apply event is logged only when clipboard content actually changes
- unchanged clipboard content is not re-sent to peers
- each source image arrives as `image/png`
- transparency survives for alpha-capable source images
- large images either transfer successfully or fail clearly without wedging later clipboard sync

## 3. Windows Checks

Use applications that are known to place real PNG clipboard data on Windows.

Additional checks:

1. Verify text clipboard read/write through the native runner channel.
2. Verify PNG clipboard read/write through the native runner channel.
3. Confirm the app still receives clipboard change notifications after image
   copy operations.
4. Confirm minimizing to tray does not stop clipboard detection.

## 4. Linux Checks

Run on an actual desktop session where GTK clipboard access is available.

Additional checks:

1. Verify text clipboard read/write through the GTK clipboard bridge.
2. Verify PNG clipboard read/write through the GTK clipboard bridge.
3. Confirm polling-based clipboard monitoring still notices text changes.
4. Confirm image clipboard operations do not break later text clipboard reads.

## 5. macOS Checks

Run on a real macOS host with normal `NSPasteboard` access.

Additional checks:

1. Verify text clipboard read/write through the `NSPasteboard` bridge.
2. Verify PNG clipboard read/write through the `NSPasteboard` bridge.
3. Confirm window hide/show behavior does not break later clipboard handling.
4. Confirm notification behavior remains unchanged after image clipboard flows.

## 6. Failure Notes To Capture

For any failing case, record:

1. platform and OS version
2. source application used for copy
3. whether the offer was emitted
4. reported `contentType`
5. whether fetch succeeded
6. whether local paste matched expected content
7. relevant app or daemon logs
8. elapsed send/apply time observed for the successful run

## 7. Exit Criteria

Desktop image clipboard support should be treated as runtime-verified only
after each target OS has passed:

- local text send
- incoming text apply
- local PNG send
- incoming PNG apply
- unsupported-content safety
