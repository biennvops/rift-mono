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

## Execution (Week 2 Interfaces)

The system successfully builds. The architecture integrates natively, and execution flows through the `xUnit` test suite where test skeletons run and pass without errors.

---

# Windows Daemon (riftd) - Week 3 Implementation: Cryptography & Framing

**Assignee:** Thạo
**Task:** `[daemon-cs][identity] Identity manager, certificate generation, and frame codec`

This section summarizes the implementation of the core cryptographic identity and transport framing modules, ensuring full compliance with the Rift Protocol v0.1-draft.

## Cryptographic Identity (IdentityManager)

The `IdentityManager` has been implemented using **BouncyCastle.NET** and native **.NET Cryptography** to satisfy the protocol's dual-keypair requirement:

1. **Ed25519 Identity:**
   - Generates a long-term Ed25519 keypair for device identification.
   - Derives the 32-character `rift-` prefixed Device ID and the 8x4 character pairing Fingerprint (e.g., `ABCD-EFGH-...`) using a SHA-256 + Base32 (RFC 4648) pipeline.
   - Validated against **RFC 8032 Test Vector 1** to ensure cross-platform consistency.

2. **TLS Certificate Generation:**
   - Generates a self-signed **ECDSA P-256** certificate for mutual TLS.
   - **Custom Extension Binding:** Embeds the Ed25519 public key in a non-critical X.509 extension with OID `2.25.293029629918709742181702189012786017422`.
   - The extension follows the exact DER encoding structure defined in `spec §15.2` (`04 22 04 20 <32-bytes>`), ensuring the Ed25519 identity is cryptographically bound to the TLS session.

3. **Proof of Possession:**
   - Exposes signing capabilities for the post-handshake Ed25519 Proof of Possession (PoP) required by `spec §5.3`.

## Transport Framing (RiftFrame)

A dedicated frame codec was implemented to handle the protocol's wire format (`spec §1`):

1. **Format:** 4-byte big-endian length prefix followed by a UTF-8 JSON object.
2. **Security Limits:**
   - **Pre-authentication:** 64 KiB (strictly enforced).
   - **Post-authentication:** 32 MiB.
3. **Logic:** The `RiftFrame` utility provides `Encode` and `Decode` methods that validate buffer bounds and payload sizes, ensuring malformed or oversized frames cause immediate session termination.

## Verification & Testing

1. **Unit Tests:**
   - `IdentityManagerTests`: Verifies Device ID/Fingerprint derivation against protocol test vectors and validates the binary structure of the X.509 extension.
   - `RiftFrameTests`: Verifies framing logic, big-endian byte order, and size-limit enforcement.
2. **Success:** All unit tests pass, confirming the C# daemon correctly implements the security-critical identity and transport layers.

---

# Windows Daemon (riftd) - Week 4 Implementation: Discovery & TLS Transport

**Assignee:** Thạo
**Task:** `[daemon-cs][network] Windows mDNS advertise + discover, TLS server/client, Session bootstrap`

This section details the implementation of the core networking layers and session management, integrating the previously built cryptographic primitives.

## Local Discovery (MakaretuDiscoveryService)

Implemented `IDiscoveryService` using the `Makaretu.Dns.Multicast` library for mDNS-SD peer discovery and advertisement.
1. **Advertisement**: Advertises the `deviceId` generated via the Ed25519 key on the `_rift._tcp` service type. 
2. **Privacy**: Only minimal non-sensitive metadata (e.g., protocol capabilities version bounds) is broadcasted, strictly avoiding unauthenticated leakage as required by the KDE Connect CVE mitigations.

## Encrypted Transport (TlsTransport)

Implemented `ITransport` to facilitate standard mutual TLS connections and wire-level protocol framing.
1. **Mutual TLS**: Leveraged `SslStream` backed by `TcpClient` / `TcpListener`, preferring TLS 1.3 with a fallback to TLS 1.2.
2. **Certificate Authentication**: ECDSA P-256 self-signed certificates are successfully negotiated for authentication bounding.
3. **Identity Binding Verification**: Immediately post-handshake, the custom X.509 ASN.1 extension (OID `2.25.293029629918709742181702189012786017422`) is cleanly extracted from the peer certificate, hashed using SHA-256, and encoded via Base32 to rigorously recover and validate the authenticated Ed25519 `rift-` `deviceId`.
4. **Stream Framing**: Fully delegates to `RiftFrame` helper methods. Malicious or malformed length-prefixed protocol spans that exceed the 32 MiB post-auth limits throw hard validation faults terminating the TCP link dynamically.

## Session Orchestration (SessionBootstrap)

1. A background orchestration loop `SessionBootstrap` was provisioned.
2. Ties the local daemon Identity initialization with starting mDNS discovery and listening on the designated `ITransport` TCP endpoints, completing the daemon entry flow.
