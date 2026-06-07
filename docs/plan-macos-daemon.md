# Multi-Platform daemon-cs: macOS Support Plan

## Goal

Restructure `daemon-cs/` from a Windows-only project into a multi-platform solution with a shared core library and per-platform entry projects. The immediate target is macOS (LaunchAgent), preserving the existing Windows support.

## Current State — Platform Coupling Audit

The codebase has **4 hard Windows dependencies**:

| File | Windows-Only API | Why it's platform-locked |
|------|-----------------|-------------------------|
| `Rift.Daemon.Windows.csproj` | `net10.0-windows` TFM, `Microsoft.Extensions.Hosting.WindowsServices` | Can't build/run on macOS |
| `Program.cs:4` | `AddWindowsService()` | Registers as Windows Service |
| `IpcListener.cs:1-3,20-54` | `PipeSecurity`, `PipeAccessRule`, `WindowsIdentity`, `SecurityIdentifier`, `WellKnownSidType`, `NamedPipeServerStreamAcl.Create()` | Windows ACL-secured Named Pipes |
| All files | `namespace Rift.Daemon.Windows` | Misleading if used cross-platform |

**Platform-agnostic code** (reusable as-is):
- `Core/Interfaces/*` — pure interface contracts
- `IRiftApi.cs`, `RiftApiHandler.cs` — pure business logic
- `Worker.cs` — orchestrates an IPC listener; only coupled to concrete `IpcListener` by type reference

---

## Target Architecture

```
daemon-cs/
├── Rift.Daemon.Core/                  # Shared library (NEW)
│   ├── Rift.Daemon.Core.csproj        #   TFM: net10.0
│   ├── Interfaces/                    #   Moved from Core/Interfaces/
│   │   ├── IClipboardService.cs
│   │   ├── ITransport.cs
│   │   ├── ISecurityEventLog.cs
│   │   ├── ITrustStore.cs
│   │   ├── IDiscoveryService.cs
│   │   ├── IIdentityManager.cs
│   │   └── IIpcListener.cs            #   NEW: extracted interface
│   ├── IRiftApi.cs                    #   Moved from root
│   ├── RiftApiHandler.cs              #   Moved from root
│   └── Worker.cs                      #   Moved from root
│
├── Rift.Daemon.Windows/              # Existing Windows project (SLIMMED)
│   ├── Rift.Daemon.Windows.csproj    #   TFM: net10.0-windows
│   ├── Program.cs                    #   AddWindowsService() + DI
│   └── WindowsIpcListener.cs         #   Renamed from IpcListener.cs
│
├── Rift.Daemon.macOS/                # New macOS project
│   ├── Rift.Daemon.macOS.csproj      #   TFM: net10.0
│   ├── Program.cs                    #   Plain Generic Host + DI
│   └── MacIpcListener.cs             #   Unix Domain Socket IPC
│
├── Rift.Daemon.Tests/               # Renamed from Windows.Tests
│   ├── Rift.Daemon.Tests.csproj     #   TFM: net10.0, refs Core
│   └── Core/
│       ├── IdentityManagerTests.cs
│       └── TrustStoreTests.cs
│
├── Rift.Daemon.sln                  # Updated
└── README.md                        # Updated
```

---

## Design Decisions

### 1. IPC on macOS: Unix Domain Sockets

**Transport**: `Socket(AddressFamily.Unix, SocketType.Stream, ProtocolType.Unspecified)` wrapping a `NetworkStream` for StreamJsonRpc.

**Socket path resolution** (macOS-specific):
- Primary: `$TMPDIR/rift-daemon/v0.1.sock`
- Fallback: `/tmp/rift-daemon-$UID/v0.1.sock`

Note: `$XDG_RUNTIME_DIR` is essentially never set on macOS (macOS has no standard equivalent; the nearest is `DARWIN_USER_TEMP_DIR` via `confstr`, but `$TMPDIR` already points there). On macOS, `$TMPDIR` is a per-user path like `/var/folders/xy/abc123.../T/` — already ~50 characters. The `sun_path` limit on macOS/Darwin is **104 characters** (not 108 as on Linux). With the containing directory appended, paths can approach this limit. The implementation must validate total path length < 104 at startup and fail with a clear error if exceeded.

**Security model — directory-first isolation**:

The primary security mechanism is a **0700 parent directory**, not the socket file mode. This addresses two concerns:

1. **bind/chmod race**: `bind()` creates the socket file with permissions modified by the process umask. If we rely on a subsequent `chmod 0600`, there is a window between `bind()` and `chmod()` where the socket may be more permissive. Creating the socket inside a `0700` directory eliminates this race — the socket is unreachable regardless of its own mode during that window.

2. **Portability**: On some Unix platforms, permission bits on the socket file itself are not honored for `connect()` — only the permissions of the containing directory matter. macOS/Darwin (BSD-derived) does generally honor socket file permissions, but relying solely on file mode is fragile across Unix variants.

The implementation sequence:
1. Resolve socket path (primary or fallback); validate total length < 104
2. Create parent directory (e.g. `$TMPDIR/rift-daemon/`) with mode `0700` via `Directory.CreateDirectory` + `File.SetUnixFileMode`
3. Connect-probe any existing socket file (see stale socket detection below)
4. `bind()` the socket inside that directory
5. Set socket file to `0600` via `File.SetUnixFileMode` as defense-in-depth

Note: an earlier draft included a umask(`0177`) → bind → restore-umask sequence, but `umask()` is process-global and not thread-safe. If any other host activity (logging, SQLite, config writes) touches the filesystem concurrently during that window, those files inherit the restrictive mask. Since the `0700` directory is the real security boundary — making the socket unreachable regardless of its own mode — the post-bind `SetUnixFileMode` is sufficient defense-in-depth without the global-state hazard.

This is an approximation of the Windows ACL model, not a precise equivalent:
- Windows: deny `NetworkSid`, allow current user `FullControl`, allow `InteractiveSid` read/write — verified per-connection via SID
- macOS: `0700` directory restricts to the owning user; all local sessions for that user can connect

For stronger peer identity verification equivalent to Windows SID checks, macOS supports `getsockopt(LOCAL_PEERCRED)` / `xucred` to verify the connecting peer's UID at connection time. This is likely overkill for a LaunchAgent (everything runs as one user), but is the correct escalation path if per-connection UID verification is ever needed.

**Stale socket detection and cleanup**: On startup, if the socket file already exists, a bare `File.Delete` would clobber a legitimately running instance (e.g. launchd double-launch, or a user running `dotnet run` while the agent is loaded). The correct idiom is a **connect-probe**: attempt `connect()` to the existing socket and handle the result explicitly:

- **`connect()` succeeds**: another instance is live. Log at `LogLevel.Critical` with a distinct message (e.g. "Another rift-daemon instance is already listening on {path}, exiting") so this is distinguishable from a genuine successful shutdown in log analysis. Abort startup with exit 0 — with `KeepAlive { SuccessfulExit: false }`, launchd will not restart, which is the desired behavior.
- **`ECONNREFUSED`**: socket file exists but nothing is listening — stale from a prior crash. Unlink and proceed with `bind()`.
- **`ENOENT`**: socket file doesn't exist at all — proceed directly to `bind()`.
- **Any other error** (`EACCES`, `ECONNRESET`, `EINVAL`, etc.): do not silently lump into either bucket. Log at `Warning` with the specific error, treat as stale (unlink and proceed), since these typically indicate a broken socket file rather than a live instance. A transient connect failure misread as "live instance" would silently prevent startup with no retry under the current KeepAlive semantics.

**Shutdown and SIGTERM**: On graceful shutdown, delete the socket file. The parent directory is left in place (it may be reused on restart). launchd sends `SIGTERM` and then `SIGKILL` after a grace period (default 5s, configurable via `ExitTimeOut` in the plist). The .NET Generic Host's `ConsoleLifetime` (the default when neither `AddWindowsService` nor `AddSystemd` is used) registers a POSIX signal handler for `SIGTERM` that triggers `IHostApplicationLifetime.StopApplication()`, which fires the `stoppingToken`. The `MacIpcListener` must unlink the socket in its cancellation path — but if `SIGKILL` wins the race, the socket file survives and the next startup relies on the connect-probe to recover. This makes the connect-probe **load-bearing**, not just a safety net — its error handling above must be robust. A test should verify that `SIGTERM` → `stoppingToken` cancellation → socket file deletion works end-to-end on macOS with the bare Generic Host (no `AddSystemd`/`AddWindowsService`).

### 2. Service Hosting: launchd LaunchAgent

The macOS daemon runs as a **LaunchAgent** (per-user, in login session):
- Can access user clipboard directly
- Runs under the user's UID — consistent with socket `0600` permissions
- `launchd` manages lifecycle (start on login, restart on crash via `KeepAlive`)

**Plist location**: `~/Library/LaunchAgents/com.rift.daemon.plist`

**Example plist**:
```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.rift.daemon</string>
    <key>ProgramArguments</key>
    <array>
        <string>/usr/local/bin/rift-daemon</string>
    </array>
    <key>KeepAlive</key>
    <dict>
        <key>SuccessfulExit</key>
        <false/>
        <key>Crashed</key>
        <true/>
    </dict>
    <key>ThrottleInterval</key>
    <integer>30</integer>
    <key>RunAtLoad</key>
    <true/>
    <key>StandardOutPath</key>
    <string>Library/Logs/rift-daemon/stdout.log</string>
    <key>StandardErrorPath</key>
    <string>Library/Logs/rift-daemon/stderr.log</string>
</dict>
</plist>
```

**KeepAlive semantics**: Dictionary-form `KeepAlive` is used instead of unconditional `<true/>`. With `SuccessfulExit: false` and `Crashed: true`, launchd restarts only on crashes (non-zero exit), not on intentional shutdown (exit 0). `ThrottleInterval: 30` prevents tight crash-restart loops if the daemon fails immediately on startup (e.g. missing dependency, unrecoverable socket error). The default throttle of 10 seconds would flood logs in a perpetual crash loop.

**Log paths**: Logs go to `~/Library/Logs/rift-daemon/` (paths are relative to the user's home directory in LaunchAgent plists). This follows macOS conventions, integrates with Console.app, and avoids the world-readable `/tmp/` directory — which would be an info-leak surface, a collision risk on multi-user machines, and a symlink-attack vector. The daemon or an install script must create `~/Library/Logs/rift-daemon/` before first run.

**Install/uninstall**:
```bash
# Install
cp com.rift.daemon.plist ~/Library/LaunchAgents/
launchctl load ~/Library/LaunchAgents/com.rift.daemon.plist

# Uninstall
launchctl unload ~/Library/LaunchAgents/com.rift.daemon.plist
rm ~/Library/LaunchAgents/com.rift.daemon.plist
```

During development, just run `dotnet run` from the `Rift.Daemon.macOS/` directory.

### 3. Extracted IPC Interface

```csharp
namespace Rift.Daemon.Core.Interfaces;

public interface IIpcListener
{
    Task ListenAsync(CancellationToken stoppingToken);
}
```

Both `WindowsIpcListener` and `MacIpcListener` implement this. The `Worker` depends only on `IIpcListener`, injected via DI.

### 4. Namespace Strategy

| Project | Root Namespace |
|---------|---------------|
| Core | `Rift.Daemon.Core` / `Rift.Daemon.Core.Interfaces` |
| Windows | `Rift.Daemon.Windows` |
| macOS | `Rift.Daemon.macOS` |
| Tests | `Rift.Daemon.Tests` |

### 5. Shared NuGet Packages

| Package | Where | Purpose |
|---------|-------|---------|
| `Makaretu.Dns.Multicast` | Core | mDNS discovery (cross-platform) |
| `Microsoft.Data.Sqlite` | Core | Trust store, event log (cross-platform) |
| `Microsoft.Extensions.Hosting` | Core | Generic Host base (cross-platform) |
| `Portable.BouncyCastle` | Core | Ed25519 / X.509 crypto (cross-platform) |
| `StreamJsonRpc` | Core | JSON-RPC over IPC (cross-platform) |
| `Microsoft.Extensions.Hosting.WindowsServices` | Windows only | Windows Service lifecycle |

---

## Implementation Steps

### Phase 1: Extract Shared Core (no behavior change)

1. **Create `Rift.Daemon.Core/Rift.Daemon.Core.csproj`**
   - TFM: `net10.0`
   - Move shared NuGet refs (all except `Microsoft.Extensions.Hosting.WindowsServices`)

2. **Create `IIpcListener` interface** in `Core/Interfaces/`

3. **Move platform-agnostic files into Core**
   - `Core/Interfaces/*.cs` → update namespace to `Rift.Daemon.Core.Interfaces`
   - `IRiftApi.cs` → namespace `Rift.Daemon.Core`
   - `RiftApiHandler.cs` → namespace `Rift.Daemon.Core`
   - `Worker.cs` → namespace `Rift.Daemon.Core`, change `IpcListener` reference to `IIpcListener`

4. **Slim down Windows project**
   - Add `<ProjectReference>` to Core
   - Keep only `Program.cs` + rename `IpcListener.cs` → `WindowsIpcListener.cs`
   - `WindowsIpcListener` implements `IIpcListener`
   - `Program.cs` registers `WindowsIpcListener` as `IIpcListener` in DI
   - Only NuGet ref: `Microsoft.Extensions.Hosting.WindowsServices`

5. **Verify**: `dotnet build` on Windows project succeeds with no behavior change

### Phase 2: Add macOS Project

6. **Create `Rift.Daemon.macOS/Rift.Daemon.macOS.csproj`**
   - TFM: `net10.0`
   - `<ProjectReference>` to Core
   - No additional NuGet packages needed

7. **Implement `MacIpcListener : IIpcListener`**
   - Resolve socket path (`$TMPDIR/rift-daemon/v0.1.sock`, fallback `/tmp/rift-daemon-$UID/v0.1.sock`), validate total length < 104 chars
   - Create parent directory with mode `0700` (applies to whichever path won — critical for the `/tmp/` fallback since `/tmp/` itself is world-writable)
   - If socket file already exists: attempt `connect()` — if it succeeds, another instance is live, log error and exit 0; if `ECONNREFUSED`, unlink the stale socket and proceed
   - `bind()` the `UnixDomainSocketEndPoint`
   - Set socket file to `0600` via `File.SetUnixFileMode` (defense-in-depth; the `0700` directory is the real security boundary)
   - Accept loop: accept connection → wrap in `NetworkStream` → attach `JsonRpc` → spawn handler
   - Clean up socket file on shutdown (leave parent directory)

8. **Write macOS `Program.cs`**
   - Plain `Host.CreateApplicationBuilder(args)` (no `AddWindowsService`)
   - Register `MacIpcListener` as `IIpcListener`
   - Register `Worker` as `HostedService`

9. **Create launchd plist** in `Rift.Daemon.macOS/Resources/com.rift.daemon.plist`

10. **Update `Rift.Daemon.sln`** to include new projects

### Phase 3: Update Tests

11. **Rename** `Rift.Daemon.Windows.Tests/` → `Rift.Daemon.Tests/`
12. **Retarget** to `net10.0` (cross-platform TFM)
13. **Update** project reference to `Rift.Daemon.Core`
14. **Update** namespaces and usings
15. **Add** `MacIpcListener` unit tests:
    - Parent directory created with `0700` permissions (for both primary and fallback paths)
    - Socket file created at expected path inside the directory
    - Socket file has `0600` permissions (defense-in-depth)
    - Socket path length validated against 104-char limit
    - Connect-probe detects live instance (connect succeeds → abort startup)
    - Connect-probe detects stale socket (ECONNREFUSED → unlink and proceed)
    - Connect-probe handles ambiguous errors (EACCES, ECONNRESET → warn and treat as stale)
    - SIGTERM triggers stoppingToken → socket file is unlinked before process exits (ConsoleLifetime on macOS)
    - Client can connect and receive JSON-RPC response

### Phase 4: Documentation

16. **Update `daemon-cs/README.md`** with:
    - Project structure overview
    - macOS build/run/install instructions
    - launchd plist install commands

17. **Update `AGENTS.md`** to reflect new layout under `daemon-cs/`

---

## Risks & Mitigations

| Risk | Impact | Mitigation |
|------|--------|------------|
| Stale socket file prevents startup | Daemon won't start after crash | Connect-probe the existing socket: `connect()` succeeds → another instance is live, abort (exit 0); `ECONNREFUSED` → stale, unlink and proceed. Never bare-delete |
| Socket path too long (104-char `sun_path` limit on macOS) | `bind()` fails | `$TMPDIR` on macOS is ~50 chars; with `/rift-daemon/v0.1.sock` appended (~70 total), this is safe. Validate at startup, fail with clear error if exceeded. Fallback to `/tmp/rift-daemon-$UID/v0.1.sock` if primary path is too long |
| StreamJsonRpc over `NetworkStream` vs `PipeStream` | Behavioral differences | StreamJsonRpc is transport-agnostic; both are `Stream` subclasses |
| macOS Gatekeeper / notarization for published binary | Users can't run unsigned binary | Out of scope for this phase; document `xattr -d` workaround |
| launchd crash-restart loop | Log spam and CPU waste on persistent startup failure | Dictionary-form `KeepAlive` + `ThrottleInterval: 30` limits restart rate; daemon should exit 0 on unrecoverable errors to prevent restart |

---

## Out of Scope (Future Work)

- Linux support (would add `Rift.Daemon.Linux/` with systemd hosting — similar to macOS but with `Microsoft.Extensions.Hosting.Systemd`)
- Code signing / notarization for macOS distribution
- Homebrew formula or `.pkg` installer
- CI/CD pipeline for macOS builds
- Clipboard integration in the daemon itself (currently handled by Flutter UI)
