# macOS Share Extension Testing

This is the practical test checklist for the current macOS share-extension flow.

## Current expected behavior

- Finder `Open With Rift` / document-open routes selected files into Rift's
  send queue and opens `History -> Send`.
- The dedicated `RiftShareExtension` target copies shared files/text into the
  App Group inbox, stores a pending payload, and wakes the main app via
  `rift://history.send`.
- On launch/activation, the Flutter app consumes pending share items and stages
  them in the send queue.

## Automated checks available in this repo

- Flutter bridge analysis:
  - `flutter analyze lib/main.dart lib/src/platform/macos_notifications.dart`
- Flutter bridge tests:
  - `flutter test test/macos_notifications_test.dart`
  - `flutter test test/app_shell_test.dart --plain-name "App shell boots up and displays main navigation"`

## Manual test on a real Mac

1. Build and run the macOS app target.
2. Build the `RiftShareExtension` target in Xcode.
3. Confirm the app has the App Group entitlement:
   - `group.com.example.appFlutter`
4. In Finder, right-click one or more files:
   - `Open With -> Rift`
   - Expected: Rift opens to `History -> Send`, files appear in queue.
5. In a text-capable app, share plain text to `Rift Share`.
   - Expected: extension finishes, Rift opens, a `.txt` staged item appears in queue.
6. In Finder or Photos, share one or more files/images to `Rift Share`.
   - Expected: copied files appear in queue with original file names and media types.
7. Close Rift, trigger a share again.
   - Expected: app wakes, consumes pending payload, still lands in `History -> Send`.
8. Pair with a target device and send queued items.
   - Expected: standard send queue / transfer activity flow continues normally.

## Known next-pass items

- Validate target signing/build end-to-end with `xcodebuild` on a real Mac.
- Replace placeholder App Group / bundle identifiers with project-owned values.
- Add macOS-native UI or logging around extension import failures if needed.
- **Shared inbox cleanup.** The share extension copies payloads into
  `<AppGroup>/SharedInbox/`, but nothing deletes them once the host app has
  consumed them or after a queue item reaches `sent` / `failed` / `removed`.
  Long-running installs will accumulate inbox files. Suggested next slice:
  expose a `share.cleanupInbox` MethodChannel call from `SharedTransferInbox`
  that takes a list of paths and unlinks them inside the App Group
  container; have `SendQueueController` call it when an item transitions
  to a terminal state (or at startup, with a list of paths from the
  most recent `consumePendingItems` payload, so the cleanup is bounded
  to files actually owned by Rift).
