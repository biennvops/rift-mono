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

# Week 2 Architecture & Testing Setup

**Tasks:**
- `[daemon-cs] Module interfaces and DI setup`
- `[daemon-cs][test] Unit test skeleton with first crypto tests`

During Week 2, the focus shifted to establishing the architectural boundaries (so implementation can be done cleanly against the protocol spec) and initializing the testing infrastructure.

## Module Boundaries defined

Strict C# interfaces were created in `daemon-cs/Interfaces` to enforce dependency injection contracts for all primary components:
1.  **`IIdentityManager`**: Exposes `GetPublicKey`, `GetCertificate`, and `EnsureIdentityAsync`.
2.  **`ITrustStore`**: Exposes getters and setters for the device trust states using the `PeerTrustState` enum.
3.  **`IDiscoveryService`**: Wraps the mDNS-SD multicast logic.
4.  **`IClipboardService`**: Abstracts the protocol logic for `clipboard.offer` and `clipboard.fetch`.

Dummy/Mock implementations of these interfaces were registered in `Program.cs` locally. This ensures that the generic .NET Host remains resolvable and compiles correctly while the business logic gets implemented.

## Unit Test Infrastructure

A dedicated test suite was created in `daemon-cs.Tests`:
*   Initialized as an **xUnit** test project.
*   Added the `System.Text.Json` dependency to consume raw JSON reference payloads.
*   **`VectorLoader.cs`**: A helper class programmed to dynamically read canonical test vectors from the `spec/vectors/` directory relative path, ensuring test determinism.
*   **`ConformanceTests.cs`**: Initialized with unit test stubs (`Identity_Matches_Vector`, `Fingerprint_Matches_Vector`) that will be populated to assert the daemon logic against the standard spec vectors.
