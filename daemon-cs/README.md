# Rift Daemon (C#/.NET)

`daemon-cs` is the shared C#/.NET daemon implementation for Windows, macOS, and Linux. It hosts one protocol core behind platform-specific service and IPC entrypoints.

## Scope

- shared daemon core in `Rift.Daemon.Core`
- Windows host with named-pipe IPC and Windows Service support
- macOS host with Unix-domain-socket IPC and LaunchAgent support
- Linux host with Unix-domain-socket IPC and console/systemd-style hosting

Normative behavior lives in:

- `../spec/doc/protocol.md`
- `../spec/doc/ipc.md`
- `../spec/decisions/README.md`

## Structure

```text
daemon-cs/
├── Rift.Daemon.Core/      # shared protocol, trust, transport, IPC logic
├── Rift.Daemon.Windows/   # Windows host and named-pipe IPC
├── Rift.Daemon.macOS/     # macOS host and launchd-facing entrypoint
├── Rift.Daemon.Linux/     # Linux host and Unix-socket IPC
├── Rift.Daemon.Tests/     # automated tests
└── Tools/                 # local utilities and packaging helpers
```

## Key Responsibilities

- identity and certificate lifecycle
- trust-state persistence and revocation
- peer discovery and authenticated transport bootstrap
- capability negotiation and presence handling
- clipboard and operation lifecycle handling
- local JSON-RPC IPC for the Flutter client

## Build And Run

```bash
dotnet build Rift.Daemon.sln
dotnet test Rift.Daemon.Tests/
```

Run a host directly during development:

```bash
dotnet run --project Rift.Daemon.macOS/
dotnet run --project Rift.Daemon.Linux/
```

```powershell
dotnet run --project Rift.Daemon.Windows/
```
## Linux

Install the Linux daemon as a per-user systemd service:

```bash
Rift.Daemon.Linux/Tools/build_linux_daemon.sh
Rift.Daemon.Linux/Tools/install_user_service.sh
systemctl --user status rift-daemon.service
```

The installer places the self-contained daemon under
`~/.local/lib/rift-daemon` and preserves identity and trust data under
`~/.local/share/rift-daemon` during upgrades or uninstall.

Linux protects the local identity encryption key with the desktop Secret
Service when available. Existing mode-`0600` key files are migrated after a
successful identity decrypt. Headless sessions without Secret Service retain
the mode-`0600` filesystem fallback; the active backend is reported by
`rift.getDeviceInfo` as `IdentityProtectionBackend`.

On Linux, the daemon observes MPRIS players on the user session D-Bus and
publishes their playback state to trusted peers. Remote playback is exposed as
the Rift-owned `org.mpris.MediaPlayer2.rift` player, so desktop MPRIS clients
can display and control playback from another trusted device. Remote play,
pause, toggle, next, previous, and seek actions are routed back to the
originating device or MPRIS player.

Run the isolated Linux daemon smoke test with:

```bash
Rift.Daemon.Linux/Tools/smoke_test_linux_daemon.sh
```

The smoke test verifies Unix IPC startup, Linux device information, media IPC,
and identity persistence across a daemon restart.

## macOS

### Prerequisites and verification

Install the .NET 10 SDK. From the repository root, build the macOS components directly because the full solution includes the Windows WPF host, which cannot be built on macOS:

```bash
dotnet build daemon-cs/Rift.Daemon.macOS/Rift.Daemon.macOS.csproj
dotnet build daemon-cs/Rift.NotificationExtractor.macOS/Rift.NotificationExtractor.macOS.csproj
dotnet test daemon-cs/Rift.Daemon.Tests/
```

### Run in the foreground

Build the notification extractor app from the repository root:

```bash
daemon-cs/Rift.NotificationExtractor.macOS/Tools/build_macos_notification_extractor_app.sh
```

Add `dist/macos/Rift Notification Extractor.app` under **System Settings → Privacy & Security → Full Disk Access**, then run the daemon with the development extractor path:

```bash
RIFT_NOTIFICATION_EXTRACTOR_APP="$PWD/dist/macos/Rift Notification Extractor.app" \
  dotnet run --project daemon-cs/Rift.Daemon.macOS/
```

Only the notification extractor should receive Full Disk Access. Do not grant it to the daemon or Flutter app.

### Install and run as a LaunchAgent

Build both app bundles, install the extractor at the daemon's default lookup path, and install the daemon LaunchAgent:

```bash
daemon-cs/Rift.NotificationExtractor.macOS/Tools/build_macos_notification_extractor_app.sh
daemon-cs/Rift.Daemon.macOS/Tools/build_macos_daemon_app.sh

mkdir -p "$HOME/Applications"
rm -rf "$HOME/Applications/Rift Notification Extractor.app"
cp -R "dist/macos/Rift Notification Extractor.app" "$HOME/Applications/"

daemon-cs/Rift.Daemon.macOS/Tools/install_launchagent.sh
```

Grant `$HOME/Applications/Rift Notification Extractor.app` Full Disk Access before relying on notification sync. Use a stable signing identity and install path if the FDA grant must survive rebuilds.

Check the agent and its logs with:

```bash
launchctl print "gui/$(id -u)/com.rift.daemon"
tail -f "$HOME/Library/Logs/rift-daemon/stdout.log" \
  "$HOME/Library/Logs/rift-daemon/stderr.log"
```

### Uninstall

Unload the LaunchAgent and remove the installed daemon, extractor, plist, and logs:

```bash
launchctl unload "$HOME/Library/LaunchAgents/com.rift.daemon.plist" 2>/dev/null || true
rm -f "$HOME/Library/LaunchAgents/com.rift.daemon.plist"
rm -rf "$HOME/Applications/Rift Daemon.app" \
  "$HOME/Applications/Rift Notification Extractor.app" \
  "$HOME/Library/Logs/rift-daemon"
```

Remove **Rift Notification Extractor** from Full Disk Access in System Settings. Uninstalling leaves daemon state in `$HOME/Library/Application Support/Rift` and identity material in Keychain intact so reinstalling can preserve device identity and trust.

## Related Docs

- `../docs/macOS/TCC.md`
- `../docs/macOS/NotificationExtractor.md`
- `../tests-conformance/README.md`
- `../tests-interop/README.md`
