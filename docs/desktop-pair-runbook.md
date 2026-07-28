# Desktop Pair Validation Runbook

Status: active qualification procedure.

This runbook qualifies real desktop-to-desktop continuity between two physical
machines on the same local network. It complements the automated loopback
interop suites in `daemon-cs/Rift.Daemon.Tests/Core/` (`TlsTransportTests`,
`PairingInteropTests`, `ClipboardFileInteropTests`), which prove protocol
correctness but not discovery, UI, installers, or real network behavior.

Record results per pair in the evidence table at the bottom. A pair passes
only when every step passes in **both directions**.

## Pairs

| Pair | Machines |
|---|---|
| P1 | Windows ↔ macOS |
| P2 | Linux ↔ macOS |
| P3 | Windows ↔ Linux |

## Prerequisites (per machine)

1. Build and start the daemon with the platform service model:
   - **Windows:** `dotnet run --project daemon-cs/Rift.Daemon.Windows/` (console)
     or the installed Windows Service.
   - **Linux:** `Rift.Daemon.Linux/Tools/build_linux_daemon.sh` +
     `install_user_service.sh`, or `dotnet run --project daemon-cs/Rift.Daemon.Linux/`.
   - **macOS:** installed LaunchAgent (`launchctl print gui/$(id -u)/com.rift.daemon`
     shows `state = running`), or `dotnet run --project daemon-cs/Rift.Daemon.macOS/`.
2. Start the Flutter app (`flutter run -d windows|linux|macos` or an installed
   build). Settings must show `Daemon IPC: connected` (Linux) or a populated
   device identity.
3. Both machines on the same Wi-Fi/LAN segment. mDNS (UDP 5353) and TCP 9140
   must not be blocked:
   - **Windows:** allow the daemon through Windows Defender Firewall
     (private network profile).
   - **Linux:** check `firewalld`/`ufw` if discovery fails.
   - **macOS:** approve the Local Network prompt; verify under
     System Settings → Privacy & Security → Local Network.

## Scenarios

### S1 — Discovery

1. On machine A, open the pairing screen and start discovery.
2. Machine B appears within ~10 s with a stable instance entry.
3. Repeat in the other direction.

**Fail notes to capture:** missing peer, duplicate entries, wrong address
family (e.g. unusable link-local IPv6), peer flapping.

### S2 — Pairing with fingerprint verification

1. From A, start pairing with B.
2. B shows an incoming pairing request with a fingerprint.
3. Verify the fingerprint matches on both screens **before** approving.
4. Approve on both sides. Both device lists show the peer as trusted.
5. Security event log on both sides records the pairing completion.

### S3 — Clipboard text (both directions)

1. Copy a short text on A → paste on B. Expect ≤ ~2 s latency.
2. Copy text with non-ASCII content (accents/emoji) on B → paste on A;
   content must be byte-identical.
3. Hide the app window to tray on both machines and repeat step 1.
   Clipboard sync must keep working from the tray.

### S4 — Clipboard image (both directions)

1. Copy an image (screenshot region is fine) on A → paste into an image
   editor on B. Pixels must match.
2. Repeat B → A.

### S5 — File transfer (both directions)

1. Send a small file (< 1 MB) from A → accept on B → contents identical.
2. Send a large file (≥ 100 MB) from B → A. Progress advances smoothly;
   final file hash matches the source
   (`shasum -a 256` / `sha256sum` / `Get-FileHash`).
3. Reject an incoming offer; sender shows the typed failure.
4. Cancel an in-flight large transfer from the receiver; sender stops
   sending and no partial file is committed at the destination.
5. For receiver-confirmed completion, close and reopen the receiving app after
   network receipt reaches `ready_to_commit`; the pending commit must be
   recovered and published without retransmitting the file.
6. The sender must not report success before the receiver publishes and
   independently verifies the final destination file. A failed publication
   must not emit receiver-confirmed completion.

### S6 — Interruption and resume

1. Start a large transfer A → B.
2. Mid-transfer, disable Wi-Fi on B (or A) for ~10 s, then re-enable.
3. After the session re-establishes, the transfer resumes from its prior
   offset (watch progress; it must not restart at 0) and completes with a
   matching hash.

### S7 — Restart persistence and trusted reconnect

1. Restart the daemon on A (service restart or Ctrl-C + rerun).
2. A keeps its device identity (same fingerprint in Settings).
3. B reconnects to A as trusted without any new pairing prompt.
4. Clipboard sync works again without user action.

### S8 — Trust removal and block

1. On A, remove trust for B. B's session ends; B sees the peer as removed.
2. Re-pair to restore trust (S2), confirming the forget path is clean.
3. On A, block B. B cannot re-establish a session; A's event log records
   the rejected connection.
4. Unblock and re-pair to leave the pair in a clean trusted state.

### S9 — Media playback state and actions (both directions)

This scenario was omitted from the original desktop-pair procedure. It is
implemented as the optional `media.playback` capability and must be qualified
separately from clipboard/file continuity.

1. Start a local MPRIS player on Linux and begin playback.
2. Query the macOS daemon's `rift.listMediaPlayback` IPC result. The Linux
   playback record must appear with current metadata and state.
3. Stop the Linux player and confirm macOS receives the removal/update.
4. Start a macOS media source and confirm Linux observes its playback state.
5. Where a desktop control client is available, issue pause/resume/seek or
   next/previous actions in both directions and verify the originating player.
6. Restart one daemon and confirm the active playback state is replayed without
   creating duplicate records.

### S10 — Notification sync (if enabled)

Notification sync is a separate optional capability and is not covered by the
clipboard/file scenarios. Qualify it only when the platform notification
listener/extractor is configured, recording platform permission limitations,
replay behavior after reconnect, and whether updates/removals create duplicate
native notifications.

## Evidence table

Copy one table per pair into the results section below (or into
`docs/final-test-report.md` when that lands).

```markdown
### Pair: <P1|P2|P3> — <machine A> ↔ <machine B>   Date: YYYY-MM-DD

| Scenario | A→B | B→A | Notes |
|---|---|---|---|
| S1 Discovery | | | |
| S2 Pairing | | (mutual) | |
| S3 Clipboard text | | | |
| S4 Clipboard image | | | |
| S5 File transfer | | | |
| S6 Interrupt/resume | | | |
| S7 Restart persistence | | | |
| S8 Remove/block | | | |
| S9 Media playback | | | |
| S10 Notification sync | | | |

Versions: daemon commit <sha>, app commit <sha>
OS versions: <A>, <B>
```

## Results

### Pair: P1 — Windows ↔ macOS   Date: 2026-07-28

| Scenario | Windows→macOS | macOS→Windows | Notes |
|---|---|---|---|
| S1 Discovery | Pass | Pass | Discovery recovered cleanly after unpairing; no duplicate peer entries. |
| S2 Pairing | Pass | (mutual) | Fingerprint-verified pairing completed over the LAN. |
| S3 Clipboard text | Pass | Pass | Plain text, Unicode, and tray-hidden synchronization passed. |
| S4 Clipboard image | Pass | Pass | Windows compatibility also verified in Paint and Photopea. |
| S5 File transfer | Pass | Pass | Small and ≥100 MB transfers passed with matching hashes; reject and receiver-side cancel passed without committing a partial destination file. |
| S6 Interrupt/resume | Pass | Pass | Transfers resumed from their prior offsets after a ~10 s network interruption and completed with matching hashes. |
| S7 Restart persistence | Pass | Pass | Restarting either daemon preserved identity and restored the trusted session automatically. |
| S8 Remove/block | Partial | Partial | Trust removal disconnected both sides, prevented reconnect, and re-pairing restored trust in both directions. Block qualification is unavailable: the UI/daemon returns `Block not implemented in daemon yet`. |
| S9 Media playback | Pending | Pending | Not included in the original P1 qualification. |
| S10 Notification sync | Pending | Pending | Not included in the original P1 qualification. |

Versions: qualification branch `98cdb7f`; daemon large-file fix `73b8c64`

OS versions: Windows version not recorded; macOS 26.6 (25G72)

### Pair: P2 — Linux ↔ macOS   Date: 2026-07-28

| Scenario | Linux→macOS | macOS→Linux | Notes |
|---|---|---|---|
| S1 Discovery | Partial | Partial | Linux discovery was slow and the peer entry sometimes disappeared. Multiple Linux interfaces (Docker, bridges, and other virtual adapters) may be contributing. |
| S2 Pairing | Partial | Partial | Linux often stayed at `Starting pairing`; macOS appeared to fail before later showing the fingerprint screen. The session eventually became usable, but the flow was delayed and confusing. |
| S3 Clipboard text | Pass | Pass | Clipboard synchronization continued to work after restarting the Linux daemon. |
| S4 Clipboard image | Pass | Pass | Image content passed in both directions. Tray/background delivery also worked; macOS currently has no visible tray/menu-bar icon, so the macOS window was moved to another Space instead. |
| S5 File transfer | Pass | Pass | Small and large transfers, matching hashes, reject, cancel, app-reconnect publication recovery, and receiver-confirmed completion passed. Private daemon staging plus user-session publication resolved the Linux read-only-home boundary. |
| S6 Interrupt/resume | Pass | Pass | Resume completed with matching hashes and no false sender success. The active session used direct Ethernet even when Wi-Fi was disabled; detection and recovery after loss of the active path took about 20–30 seconds. |
| S7 Restart persistence | Partial | Partial | Linux daemon restart preserved clipboard behavior. After macOS daemon restart, the Flutter app reported local IPC connected but clipboard remained unavailable until the Android app was foregrounded; prior Android notifications then replayed to peers. Requires retest on merged mobile-parity code. |
| S8 Remove/block | Pending | Pending | Not yet tested on this pair. |
| S9 Media playback | Pending | Pending | The original qualification omitted this scenario. |
| S10 Notification sync | Pending | Pending | Not yet tested as a desktop-pair scenario. |

Versions: qualification branch `f01b91e`

OS versions: Linux version not recorded; macOS 26.6 (25G72)
