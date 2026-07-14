# Clipboard Platform Support Matrix

Status: supporting implementation note.

Runtime verification snapshot:

- Linux <-> Android clipboard sync is runtime-verified for `text/plain` and
  `image/png`.
- Windows and macOS desktop image clipboard paths remain implementation-complete
  but still need host-side runtime verification.

This document records the current clipboard capability surface across the four
active Rift targets in this repository:

- Windows
- Linux
- macOS
- Android

It is intentionally narrower than the protocol specification. The protocol may
allow a content type while a specific platform binding still exposes only a
subset of that behavior.

## 1. Scope

This matrix covers the app-side clipboard integration paths used by the Flutter
client and its native platform shims.

It does not redefine the peer protocol. Instead, it answers a practical
question: what can each active target currently send, receive, and apply at the
platform clipboard boundary?

## 2. Current Matrix

| Platform | Clipboard change detection | Send `text/plain` | Apply `text/plain` | Send `image/png` | Apply `image/png` | Notes |
| --- | --- | --- | --- | --- | --- | --- |
| Windows | Yes | Yes | Yes | Implemented in runner path | Implemented in runner path | Windows image clipboard support is wired through a native method channel using the `PNG` clipboard format, but still needs native runtime verification on a Windows host. |
| Linux | Yes | Yes | Yes | Yes with Android verified | Yes with Android verified | Linux uses the GTK clipboard image bridge, which can read native image clipboard content and normalize it to `image/png` for the shared method channel. Linux <-> Android text and image flows have been verified on real devices. |
| macOS | Yes | Yes | Yes | Implemented in runner path | Implemented in runner path | macOS uses `NSPasteboard` image reading and now normalizes readable image clipboard content to `image/png` for the shared method channel. |
| Android | Yes | Yes | Yes | Yes with Linux verified | Yes with Linux verified | Android now supports native image clipboard payload relay through the existing method channel and native clipboard/file-provider helpers. Android <-> Linux text and image flows have been verified on real devices. |

## 3. Meaning of "Implemented"

This document uses the following terms:

- **Yes**: the repository currently contains an active path intended to support
  this behavior on that platform.
- **No**: the repository intentionally does not claim support for that behavior
  on that platform yet.
- **Implemented in runner path**: the code path exists in the platform runner
  or native shim, but should still be validated on the target OS before being
  treated as production-ready.

## 4. Safety Rules

The current implementation follows these safety rules:

1. A platform must not claim clipboard image support unless it has a concrete
   platform binding for reading or writing image clipboard data.
2. Unsupported clipboard content types are ignored locally rather than causing
   session failure.
3. Desktop image clipboard support is exposed only through the shared
   `rift/desktop/clipboard` method channel and remains platform-gated inside
   each native host.
4. Android-specific clipboard image code paths are gated by platform checks and
   do not alter desktop behavior.
5. Desktop runners may normalize platform-native image clipboard formats to
   `image/png` before sending them over the protocol boundary.

## 5. Recommended Next Validation Steps

The next platform-specific checks should be:

1. Verify the Windows native runner path on a real Windows machine:
   - read text clipboard through the method channel
   - read PNG clipboard through the method channel
   - write text clipboard through the method channel
   - write PNG clipboard through the method channel
2. Exercise Android end to end with:
   - local image copy -> Rift send path
   - incoming image fetch -> native clipboard apply path
3. Verify the Linux native runner path on a real Linux desktop session:
   - read text clipboard through the method channel
   - read platform-native image clipboard content and confirm it normalizes to `image/png`
   - write text clipboard through the method channel
   - write PNG clipboard through the method channel
4. Verify the macOS native host path on a real macOS machine:
   - read text clipboard through the method channel
   - read platform-native image clipboard content and confirm it normalizes to `image/png`
   - write text clipboard through the method channel
   - write PNG clipboard through the method channel

## 6. Non-Claims

This matrix does not currently claim:

- folder clipboard support
- arbitrary binary clipboard interoperability beyond `image/png` normalization
- application-state clipboard handoff
- verified parity of desktop image clipboard behavior across Windows, Linux,
  and macOS
