# Rift Daemon (C#/.NET)

A .NET 10 daemon that implements the Rift protocol. Multi-platform: Windows
(named pipes, Windows Service), macOS (Unix domain sockets, launchd
LaunchAgent), and Linux (Unix domain sockets, systemd-style host).

## Project Structure

```
daemon-cs/
├── Rift.Daemon.Core/           # Shared library (net10.0)
│   ├── Interfaces/             # Platform-agnostic contracts
│   ├── Worker.cs               # Background service
│   ├── IRiftApi.cs             # JSON-RPC API interface
│   └── RiftApiHandler.cs      # JSON-RPC API implementation
├── Rift.Daemon.Windows/        # Windows entry point (net10.0-windows)
│   ├── Program.cs              # Windows Service host
│   └── WindowsIpcListener.cs   # Named Pipes + ACL security
├── Rift.Daemon.Linux/          # Linux entry point (net10.0)
│   ├── Program.cs              # Generic Host (for systemd / console)
│   ├── LinuxIpcListener.cs     # Unix Domain Socket + POSIX security
│   └── Resources/              # systemd unit
├── Rift.Daemon.macOS/          # macOS entry point (net10.0)
│   ├── Program.cs              # Generic Host (for launchd)
│   ├── MacIpcListener.cs       # Unix Domain Socket + POSIX security
│   └── Resources/              # launchd plist
├── Rift.Daemon.Tests/          # Cross-platform tests (net10.0)
├── Tools/
│   └── Rift.IpcProbe/          # Local IPC probe / debugging utility
└── Rift.Daemon.sln
```

## Libraries & Rationale

- **Portable.BouncyCastle**: Ed25519 identity generation and X.509 certificate extension crafting.
- **Makaretu.Dns.Multicast**: mDNS-SD for local peer discovery and advertisement.
- **StreamJsonRpc**: JSON-RPC 2.0 over arbitrary transports for IPC with the Flutter client.
- **Microsoft.Data.Sqlite**: Durable local persistence for trust store, capabilities, and security event log.
- **Microsoft.Extensions.Hosting.WindowsServices** (Windows only): Windows Service lifecycle.

## IPC

| Platform | Transport | Security |
|----------|-----------|----------|
| Windows  | Named Pipes (`\\.\pipe\rift-daemon-v0.1`) | Windows ACLs: deny NetworkSid, allow current user + InteractiveSid |
| Linux    | Unix Domain Socket (`$XDG_RUNTIME_DIR/rift-daemon/v0.1.sock`, fallback `/tmp/rift-daemon-<uid>/v0.1.sock`) | 0700 parent directory + 0600 socket file |
| macOS    | Unix Domain Socket (`$TMPDIR/rift-daemon/v0.1.sock`) | 0700 parent directory + 0600 socket file |

## Storage

- Windows stores daemon state under `%ProgramData%\\Rift\\riftd.sqlite3`.
- Linux stores daemon state under `$XDG_DATA_HOME/rift-daemon/riftd.sqlite3`
  or `~/.local/share/rift-daemon/riftd.sqlite3`.
- macOS stores daemon state under `~/Library/Application Support/Rift/riftd.sqlite3`.

Sensitive identity material is protected at rest with Windows DPAPI on
Windows, and with a daemon-local AES key file (`.rift-secrets.key`, mode
`0600`) on Unix hosts.

## Development

### Build

```bash
# Core library (cross-platform)
dotnet build Rift.Daemon.Core/

# macOS daemon
dotnet build Rift.Daemon.macOS/

# Linux daemon
dotnet build Rift.Daemon.Linux/

# Tests
dotnet test Rift.Daemon.Tests/
```

### Run (Console)

```bash
# macOS
dotnet run --project Rift.Daemon.macOS/

# Linux
dotnet run --project Rift.Daemon.Linux/
```

```powershell
# Windows
dotnet run --project Rift.Daemon.Windows/
```

### Install as macOS LaunchAgent

```bash
# 1) Build the background app bundle (dev output under dist/macos/)
./Rift.Daemon.macOS/Tools/build_macos_daemon_app.sh

# 2) Install it into your user Applications folder
mkdir -p ~/Applications
rm -rf ~/Applications/'Rift Daemon.app'
cp -R dist/macos/'Rift Daemon.app' ~/Applications/

# 3) Install + load the LaunchAgent (generates plist with your $HOME expanded)
./Rift.Daemon.macOS/Tools/install_launchagent.sh
```

### Install as Windows Service

```powershell
sc.exe create RiftDaemon binPath= "C:\path\to\Rift.Daemon.Windows.exe"
sc.exe start RiftDaemon
```
