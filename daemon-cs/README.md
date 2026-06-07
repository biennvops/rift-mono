# Rift Daemon (C#/.NET)

A .NET 10 daemon that implements the Rift protocol. Multi-platform: Windows (named pipes, Windows Service) and macOS (Unix domain sockets, launchd LaunchAgent).

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
├── Rift.Daemon.macOS/          # macOS entry point (net10.0)
│   ├── Program.cs              # Generic Host (for launchd)
│   ├── MacIpcListener.cs       # Unix Domain Socket + POSIX security
│   └── Resources/              # launchd plist
├── Rift.Daemon.Tests/          # Cross-platform tests (net10.0)
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
| macOS    | Unix Domain Socket (`$TMPDIR/rift-daemon/v0.1.sock`) | 0700 parent directory + 0600 socket file |

## Development

### Build

```bash
# Core library (cross-platform)
dotnet build Rift.Daemon.Core/

# macOS daemon
dotnet build Rift.Daemon.macOS/

# Tests
dotnet test Rift.Daemon.Tests/
```

### Run (Console)

```bash
# macOS
dotnet run --project Rift.Daemon.macOS/
```

```powershell
# Windows
dotnet run --project Rift.Daemon.Windows/
```

### Install as macOS LaunchAgent

```bash
cp Rift.Daemon.macOS/Resources/com.rift.daemon.plist ~/Library/LaunchAgents/
# Edit the plist to set the correct binary path
launchctl load ~/Library/LaunchAgents/com.rift.daemon.plist
```

### Install as Windows Service

```powershell
sc.exe create RiftDaemon binPath= "C:\path\to\Rift.Daemon.Windows.exe"
sc.exe start RiftDaemon
```
