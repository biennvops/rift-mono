# Windows Daemon (riftd) - Week 1 Infrastructure Report

**Assignee:** Thạo
**Task:** `[daemon-cs][infra] C# Worker Service skeleton with library choices documented`

This document summarizes the changes and infrastructure established for the Windows daemon (`daemon-cs/`) during Week 1.

## Project Structure

A new **.NET 10 Worker Service** project (`Rift.Daemon.Windows`) has been created to serve as the foundation. It targets `net10.0-windows` and produces an executable capable of running either as a console application or a background Windows Service.

## Core Libraries & Rationale

The following NuGet packages have been integrated to fulfill the core requirements of the Rift protocol:

1.  **`Portable.BouncyCastle` (1.9.0)**
    *   **Purpose:** Cryptography, specifically Ed25519 identity generation and custom X.509 certificate generation.
    *   **Rationale:** Provides much finer control over ASN.1 encoding than `System.Security.Cryptography`, which is crucial for Rift's custom X.509 extensions.
2.  **`Makaretu.Dns.Multicast` (0.27.0)**
    *   **Purpose:** Local peer discovery.
    *   **Rationale:** A lightweight, pure-C# implementation of mDNS-SD that avoids depending on Windows' native DNS-SD API, which can be inconsistent across versions.
3.  **`StreamJsonRpc` (2.24.92)**
    *   **Purpose:** Transport-agnostic JSON-RPC 2.0.
    *   **Rationale:** Allows us to easily serialize/deserialize complex protocol types and map them directly to C# methods.
4.  **`Microsoft.Data.Sqlite` (10.0.8)**
    *   **Purpose:** Local persistence.
    *   **Rationale:** Durable, fast, and dependency-free persistence mechanism used to store the trust state machine (trusted/revoked peer fingerprints) and the security event log.
5.  **`Microsoft.Extensions.Hosting.WindowsServices` (10.0.8)**
    *   **Purpose:** Native deployment targeting.
    *   **Rationale:** Hooks the generic `.NET Host` lifecycle into the Windows Service Control Manager, allowing it to start automatically on system boot.

## Core Architecture Added

1.  **IPC Listener (`IpcListener.cs`)**
    *   A background loop has been set up to handle incoming connections via **Windows Named Pipes** at `\\.\pipe\rift-daemon-v0.1`.
    *   This named pipe will serve as the communication bridge between the daemon running in Session 0 and the Flutter UI running in the user session.
2.  **JSON-RPC Server (`IRiftApi.cs`, `RiftApiHandler.cs`)**
    *   We mapped the Named Pipe stream to `StreamJsonRpc`, providing a strongly typed `IRiftApi` interface.
    *   Initial dummy methods `GetVersionAsync` and `GetStatusAsync` check network health.
3.  **Service Coordinator (`Worker.cs`, `Program.cs`)**
    *   The .NET Generic Host now natively manages both the `IpcListener` background task and the main dummy loop, preparing the daemon to accept discovery messages.

## Execution

The daemon can currently be built and run. When running in a standard console via `dotnet run`, it successfully hosts the Named Pipe and remains persistently active.

---

# Windows Daemon (riftd) - Week 2 Interface Architecture

**Assignee:** Thạo
**Task:** `[daemon-cs][infra] C# daemon module interfaces and Unit test skeleton`

This section outlines the architectural foundation built for the daemon's internal modules and testing infrastructure during Week 2.

## Project Structure Updates

1. **Solution File (`Rift.Daemon.sln`)**
   * A solution file was introduced to manage multiple `.csproj` projects together seamlessly.
2. **Unit Testing Project (`Rift.Daemon.Windows.Tests`)**
   * A new `xUnit` testing project was instantiated inside the `daemon-cs/` root directory.
   * It properly targets `net10.0-windows` and leverages **Moq** for mocking dependencies.

## Core Interfaces Designed

A clean set of interfaces was added to `Core/Interfaces/` to abstract the system components per the project specification (preparing for concrete dependency injection):

1.  **`IIdentityManager` (Identity Engine)**
    *   **Responsibilities:** Ensures Ed25519 device identity and custom X.509 P-256 certificate generation via BouncyCastle.NET. Exposes `GetDeviceId` and cryptographic keys.
2.  **`ITrustStore` (Database Abstraction)**
    *   **Responsibilities:** Persists and retrieves `PeerIdentity` records based on the Protocol's Trust State Machine (`Discovered`, `PairingPending`, `Trusted`, `Blocked`, `Revoked`).
3.  **`ITransport` (Network/RPC Layer)**
    *   **Responsibilities:** Handles incoming/outgoing mTLS sessions and secure payload dispatching over mutually authenticated connections.
4.  **`IDiscoveryService` (mDNS Engine)**
    *   **Responsibilities:** Wraps the `Makaretu` library logic to advertise device capabilities and discover peers locally without exposing sensitive payloads.
5.  **`IClipboardService` (Clipboard Operations)**
    *   **Responsibilities:** Manages the broadcasting and reception of Clipboard Offers (metadata only) across trusted connections without hooking local desktop boundaries natively inside Session 0.

## Execution (Week 2 Tests)

The system successfully builds. The architecture integrates natively, and execution flows through the `xUnit` test suite where test skeletons run and pass without errors.
