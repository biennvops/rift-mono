# MediaRemote notes

## Goal
Read current playback metadata and control playback from an app on macOS using Apple's private `MediaRemote.framework`.

## What was tested

### Direct private framework calls from our own process
We wrote and ran a local Objective-C test program:
- File: `main.m`
- Build:

```bash
clang -fobjc-arc -fblocks -framework Foundation -F /System/Library/PrivateFrameworks -framework MediaRemote main.m -o mediaremote-read-objc
./mediaremote-read-objc
```

### APIs used
- `MRMediaRemoteGetNowPlayingInfo`
- `MRMediaRemoteGetNowPlayingApplicationPlaybackState`
- `MRMediaRemoteSendCommand`
- `MRMediaRemoteRegisterForNowPlayingNotifications`

### Result
Direct calls from our app/process behaved like this:
- playback control commands were accepted
- playback state was readable
- now-playing metadata returned `nil`

Observed output pattern:

```text
Playback state: paused (2)
No now playing info available
Sent command togglePlayPause => YES
Sent command nextTrack => YES
Sent command previousTrack => YES
```

## Why metadata was missing
Web search and testing indicate that on newer macOS versions, `mediaremoted` restricts now-playing metadata reads behind private entitlements.

Reported private entitlements include:
- `com.apple.mediaremote.now-playing-read-access`
- `com.apple.mediaremote.full-now-playing-read-access`

So on modern macOS:
- third-party processes can often still send transport commands
- third-party processes may still read basic playback state
- third-party processes may not be allowed to read full now-playing metadata directly

## Working workaround: `/usr/bin/perl` + mediaremote-adapter
We then tested the community workaround from:
- Repo: `https://github.com/ungive/mediaremote-adapter`

### What it does
It launches a Perl script using Apple's system Perl binary:
- `/usr/bin/perl`

That script dynamically loads a helper framework and can successfully access MediaRemote metadata on current macOS.

## Build steps used

```bash
git clone https://github.com/ungive/mediaremote-adapter.git vendor/mediaremote-adapter
cd vendor/mediaremote-adapter
mkdir -p build
cd build
cmake ..
cmake --build . -j4
```

Artifacts produced:
- `vendor/mediaremote-adapter/build/MediaRemoteAdapter.framework`
- `vendor/mediaremote-adapter/build/MediaRemoteAdapterTestClient`

## Verification

### Entitlement/functionality test
```bash
FRAMEWORK=$(cd vendor/mediaremote-adapter/build && pwd)/MediaRemoteAdapter.framework
HELPER=$(cd vendor/mediaremote-adapter/build && pwd)/MediaRemoteAdapterTestClient
/usr/bin/perl vendor/mediaremote-adapter/bin/mediaremote-adapter.pl "$FRAMEWORK" "$HELPER" test
```

Observed result:

```text
EXIT:0
```

### Get current now-playing metadata
```bash
FRAMEWORK=$(cd vendor/mediaremote-adapter/build && pwd)/MediaRemoteAdapter.framework
/usr/bin/perl vendor/mediaremote-adapter/bin/mediaremote-adapter.pl "$FRAMEWORK" get --human-readable
```

Observed result:

```json
{
  "artist" : "eill official",
  "artworkData" : "<image/jpeg 22073 bytes...>",
  "contentItemIdentifier" : "0005F698-3FAD-4856-8C61-ECD04889047A",
  "title" : "eill | Finale. (Official Music Video)",
  "elapsedTime" : 38.200039240999999,
  "duration" : 242.761,
  "playing" : true,
  "processIdentifier" : 11317,
  "artworkMimeType" : "image/jpeg",
  "timestamp" : "2026-07-17T05:57:34Z",
  "playbackRate" : 1
}
```

## Conclusion
For this machine / macOS version:
- direct `MediaRemote.framework` use from our own app/process is not sufficient to read now-playing metadata
- using `/usr/bin/perl` with `mediaremote-adapter` does work

## Recommendation
If you need current track metadata on modern macOS, use the Perl adapter approach:

```bash
/usr/bin/perl /path/to/mediaremote-adapter.pl /path/to/MediaRemoteAdapter.framework get
```

For streaming updates:

```bash
/usr/bin/perl /path/to/mediaremote-adapter.pl /path/to/MediaRemoteAdapter.framework stream
```

For control commands:

```bash
/usr/bin/perl /path/to/mediaremote-adapter.pl /path/to/MediaRemoteAdapter.framework send 2
```

Example command IDs used by MediaRemote in our test code:
- `0` = play
- `1` = pause
- `2` = toggle play/pause
- `3` = stop
- `4` = next track
- `5` = previous track

## Local files
- `main.m` — direct Objective-C MediaRemote experiment
- `main.swift` — initial Swift attempt; not used for final result
- `MediaRemote-notes.md` — this reference note

## Sources
- `https://github.com/ungive/mediaremote-adapter`
- `https://github.com/aviwad/LyricFever/issues/94`
- Apple public docs for `MPNowPlayingInfoCenter` / Now Playing APIs, which are for publishing your app's own now-playing state, not reading system-wide metadata from other apps
