# Linux Daemon Implementation Plan

## Overview
This plan outlines the architecture and implementation steps for adding a Linux daemon (`daemon-linux`) to the Rift ecosystem, alongside the existing C# and Dart daemons. The implementation must strictly adhere to the `v0.1-draft` profile defined in `spec/doc/protocol.md`.

## Tech Stack
- **Language**: Rust
- **Crypto / mTLS**: `rustls` (for TLS 1.3 preferred) and `ed25519-dalek` / `ring` for cryptographic primitives. The ECDSA certificate parsing with the custom extension might require `x509-parser` or `der` crate to ensure correct and fail-closed parsing of the X.509 extension (critical for security).
- **Database**: `rusqlite` (SQLite bindings) for the trust store and event log.
- **IPC / Transport**: `tokio` (for async runtime and named pipes / Unix domain sockets) and `jsonrpc-core` or a similar JSON-RPC 2.0 library for local Flutter client communication.
- **Discovery**: `mdns-sd` or `zeroconf` crate for advertising and discovering `_rift._tcp.local.`.

## Core Components (following AGENTS.md & protocol.md)
1.  **Identity & Keys**
    *   Generate and manage Ed25519 keypair (device identity).
    *   Generate and manage ECDSA P-256 keypair and self-signed certificate (TLS identity).
    *   Implement logic to embed the Ed25519 public key in the custom X.509 extension (OID `2.25.293029629918709742181702189012786017422`).
2.  **Network Transport (mTLS & TCP)**
    *   Setup TCP listener and connector.
    *   Implement mTLS handshake.
    *   **CRITICAL**: Implement Ed25519 Proof of Possession (PoP) via `tls-exporter` (RFC 9266).
    *   Implement frame framing: 4-byte big-endian length prefix + UTF-8 JSON.
    *   Enforce size limits: 64 KiB pre-auth, 32 MiB post-auth.
3.  **Discovery (mDNS-SD)**
    *   Advertise service `_rift._tcp` with TXT records (`minV`, `maxV`).
    *   Browse for peer services and resolve endpoints.
4.  **Protocol State & Routing**
    *   Implement JSON envelope parsing and validation (UUIDs, timestamps, matching device IDs).
    *   Implement capability negotiation (`capability.advertise`, `capability.selected`).
    *   Implement `session.hello`, `session.accept`, `session.reject`.
5.  **Operation & Features**
    *   Clipboard offer/fetch (metadata only on offer, explicit fetch over authenticated TLS, verify SHA-256 and byte sizes).
    *   Presence heartbeat and status updates.
    *   Trust state machine (discovered -> pairing_pending -> trusted -> blocked -> revoked).
6.  **Audit & Security Logging**
    *   Local SQLite event log storing security events according to the closed vocabulary in `protocol.md`.

## Implementation Steps (macOS / Dev Environment Setup)
*Note: Since you are currently on macOS, these are notes for setting up the target Linux environment.*
1.  Install Rust via `rustup`: `curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh`
2.  Install development dependencies:
    *   Debian/Ubuntu: `sudo apt-get install build-essential pkg-config libssl-dev libsqlite3-dev`
    *   Fedora/RHEL: `sudo dnf install gcc openssl-devel sqlite-devel`
3.  Ensure network ports (e.g. mDNS 5353/udp, Rift TCP port) are accessible in local firewall.

## Next Steps
1.  Initialize standard Rust binary crate in `daemon-linux`.
2.  Define data structures for the protocol JSON messages.
3.  Implement the custom X.509 extension parser and builder (high security risk area, needs fuzzing eventually).
