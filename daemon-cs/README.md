# Rift Windows Daemon (riftd)

A .NET 10 Worker Service that implements the Rift protocol on Windows.

## Libraries & Rationale

- **Portable.BouncyCastle**: Used for Ed25519 identity generation and X.509 certificate extension crafting. It provides finer control over ASN.1 structures than the standard `System.Security.Cryptography` stack.
- **Makaretu.Dns.Multicast**: A lightweight mDNS-SD implementation used for local peer discovery and advertisement.
- **StreamJsonRpc**: Implements JSON-RPC 2.0 over arbitrary transports. Used here for IPC between the daemon and the Flutter client.
- **Microsoft.Data.Sqlite**: Provides durable local persistence for the trust store, capabilities, and security event log.
- **Microsoft.Extensions.Hosting.WindowsServices**: Enables the daemon to run as a native Windows Service with proper lifecycle mapping.

## Infrastructure
- **IPC**: Uses Windows Named Pipes (`\\.\pipe\rift-daemon-v0.1`) for local communication.
- **Lifecycle**: Managed via .NET Generic Host.

## Development

### Build
```ps1
dotnet build
```

### Run (Console)
```ps1
dotnet run
```

### Install as Windows Service
```ps1
sc.exe create RiftDaemon binPath= "C:\path\to\Rift.Daemon.Windows.exe"
sc.exe start RiftDaemon
```
