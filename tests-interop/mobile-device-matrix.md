# Mobile Device Interop Test Matrix

Manual validation procedure for mobile↔mobile peer capability parity
(Android↔iOS, Android↔Android, iOS↔iOS). Desktop pairs are covered by the
automated harness in `test/`; mobile pairs require real devices because the
transport is platform-native TLS (see `spec/decisions/0012`).

## Prerequisites

- Both devices on the same subnet. Personal hotspots work; watch for:
  - VPNs (e.g. Tailscale) capturing traffic and advertising the tunnel IP
    over mDNS instead of the LAN address. Disable or allow local network
    access for the test profile.
  - USB tethering adding a second interface that produces duplicate peer
    endpoints.
- Android work profiles: quick-settings tiles are unavailable; use the
  in-app Send Clipboard button instead.
- Debug/dev builds recommended: the Dart daemon mirrors logs to
  stdout (`[rift/…]` in logcat). iOS release builds strip Flutter prints;
  native `[Rift TLS]` failure logs remain visible in the device syslog.

## Log capture

- Android: `adb logcat --pid $(adb shell pidof <package>)`, filter `rift/`.
- iOS: `idevicesyslog -u <udid>`, filter `Rift TLS` (native failures only).
- iOS crash reports: `idevicecrashreport -e <dir>`, look for `Runner-*.ips`.

## Test cases

Run each case in both directions where directionality applies. Record
pass/fail per device pair.

### 1. Discovery

| # | Step | Expected |
|---|------|----------|
| 1.1 | Launch both apps on the same subnet | Each device appears in the other's peer list within ~15 s |
| 1.2 | Leave both idle 5 min | Peer entry remains stable; no flapping or duplicates (mDNS instance names rotate but identity is keyed by device ID hint) |

### 2. Pairing

| # | Step | Expected |
|---|------|----------|
| 2.1 | A starts pairing with B | Both devices show fingerprint verification prompt |
| 2.2 | Approve on both sides | Trust established only after **both** approvals |
| 2.3 | Repeat initiated from B | Same result (both directions must work) |
| 2.4 | Reject on one side | No trust established on either side |

### 3. Session resilience

| # | Step | Expected |
|---|------|----------|
| 3.1 | Kill app on A, reopen | Session re-established within a few seconds; no unpair needed |
| 3.2 | Same for B | Same |
| 3.3 | Lock A's screen 1 min (suspend, not kill), unlock | Session recovers |
| 3.4 | Android only: background the app overnight | Foreground service notification persists; no `ForegroundServiceDidNotStopInTimeException` (requires `connectedDevice` FGS type, not `dataSync`) |

### 4. Clipboard

| # | Step | Expected |
|---|------|----------|
| 4.1 | Copy text on A, Send Clipboard | Offer appears on B; accepting places text on B's clipboard |
| 4.2 | Same from B | Same |
| 4.3 | Copy an image, Send Clipboard | Offer labeled Image; accepting places the image on the receiver's clipboard (PNG re-encode) |
| 4.4 | Text send after image send | Still works (offer sequence ordering intact) |

### 5. File transfer

| # | Step | Expected |
|---|------|----------|
| 5.1 | Send a file A→B | Offer on B; accept completes transfer; hash verified |
| 5.2 | Send a file B→A | Same |

## Failure signatures

Known past regressions and where they show up:

| Symptom | Signature | Reference fix |
|---------|-----------|---------------|
| Pairing times out; iOS cancels inbound TLS ~14 ms after handshake | `[Rift TLS] … cancelled` right after `ready` | duplicate pre-auth connection handling |
| iOS app dies on clipboard traffic; peer offline until unpair | `EXC_BREAKPOINT` in `__DISPATCH_WAIT_FOR_QUEUE__` in Runner crash report | FlutterResult must be delivered on main thread |
| Session drops immediately after `clipboard.offer` | `Rejecting session … MalformedMessage - Missing or invalid messageId` | envelope must carry `id` + `messageId` |
| Peer stuck offline after one side restarts; other side thinks it is online | `Tie-break (we win): Rejecting inbound duplicate session.hello` repeating | hello on established session = peer restart, rebuild session |
| Android app killed after ~6 h in background | `ForegroundServiceDidNotStopInTimeException` (dataSync) in dropsys dropbox | `connectedDevice` FGS type |
| Peers see wrong/unreachable addresses | mDNS TXT advertises VPN/tether interface IP | network environment, not code; see Prerequisites |

## Recorded runs

| Date | Pair | Build | Cases | Result |
|------|------|-------|-------|--------|
| 2026-07-26 | Pixel (Android 17, work profile) ↔ iPhone XR (iOS 18.7) | `feat/mobile-parity` @ `a16050d` | 1.1–1.2, 2.1–2.3, 3.1–3.2, 4.1–4.4, 5.1–5.2 | Pass |
| 2026-07-26 | same | same | 3.4 | Pending overnight soak |
| — | Android ↔ Android | — | — | Not yet run |
| — | iOS ↔ iOS | — | — | Not yet run |
