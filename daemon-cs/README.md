# Rift Daemon (C#/.NET)

A .NET 10 daemon that implements the Rift protocol. Multi-platform: Windows
(named pipes, Windows Service), macOS (Unix domain sockets, launchd
LaunchAgent), and Linux (Unix domain sockets, systemd-style host).

## Current Status

The C# daemon is no longer just a transport/service skeleton. The shared core
now covers identity, trust, transport/session bootstrap, pairing, clipboard
offer/fetch handling, security event logging, and the Week 8 operation
lifecycle surface used by the Flutter client.

## Project Structure

```
daemon-cs/
├── Rift.Daemon.Core/           # Shared library (net10.0)
│   ├── Interfaces/             # Platform-agnostic contracts
│   ├── Worker.cs               # Background service
│   ├── Networking/             # TLS transport, session bootstrap, heartbeat/presence
│   ├── ClipboardService.cs     # Clipboard offer/fetch lifecycle handling
│   ├── OperationService.cs     # Operation lifecycle manager and retention
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

## Implemented Surfaces

- **Pairing & trust:** trusted / blocked / revoked lifecycle, pairing requests,
  approvals, rejections, and trust-state IPC notifications.
- **Transport & session:** mTLS transport, session bootstrap, channel-binding
  verification, presence/session-state propagation, and capability-aware worker
  handling.
- **Clipboard:** `clipboard.offer`, `clipboard.fetchRequest`,
  `clipboard.fetchResponse`, `clipboard.fetchReject`, plus local IPC wrappers.
- **Operation lifecycle (Week 8):**
  - `OperationService` tracks cross-device actions with spec-aligned states
  - `clipboard.fetch` is wrapped in operation lifecycle tracking
  - IPC now exposes `rift.listOperations`, `rift.getOperation`, and
    `rift.onOperationTransition`
  - terminal-state idempotency, invalid/conflicting transition rejection, and
    newest-first retained history are covered by tests

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
Windows, with the user Keychain on macOS, and with a daemon-local AES key
file (`.rift-secrets.key`, mode `0600`) on Linux.

On macOS, the daemon keeps only public identity metadata in
`~/Library/Application Support/Rift/riftd.sqlite3`; the Ed25519 private key
and TLS PKCS#12 identity are stored as Keychain items under
`com.rift.daemon.identity`.

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

Focused verification used during the current Week 8 close-out:

```bash
dotnet test Rift.Daemon.Tests/ --filter "FullyQualifiedName~OperationServiceTests"
dotnet test Rift.Daemon.Tests/ --filter "FullyQualifiedName~RiftApiHandlerTests"
dotnet test Rift.Daemon.Tests/ --filter "FullyQualifiedName~ClipboardServiceTests"
dotnet test Rift.Daemon.Tests/ --filter "FullyQualifiedName~ProtocolMessageRouterTests"
dotnet test Rift.Daemon.Tests/ --filter "FullyQualifiedName~SessionBootstrapTests"
```

These focused suites passed locally during the latest review/fix cycle. The
`SessionBootstrapTests` failures that previously appeared in the broader suite
were caused by outdated test expectations around `tls-unique`; they have been
updated to the current `app-nonce` bootstrap semantics and now pass.

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
