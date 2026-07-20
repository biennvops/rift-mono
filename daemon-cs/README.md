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

Install the Linux daemon as a per-user systemd service:

```bash
Rift.Daemon.Linux/Tools/build_linux_daemon.sh
Rift.Daemon.Linux/Tools/install_user_service.sh
systemctl --user status rift-daemon.service
```

The installer places the self-contained daemon under
`~/.local/lib/rift-daemon` and preserves identity and trust data under
`~/.local/share/rift-daemon` during upgrades or uninstall.

On Linux, the daemon observes MPRIS players on the user session D-Bus and
publishes their playback state to trusted peers. Remote play, pause, toggle,
next, previous, and seek actions are routed back to the originating MPRIS
player.

## Related Docs

- `../docs/macos-permissions.md`
- `../tests-conformance/README.md`
- `../tests-interop/README.md`
