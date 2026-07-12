---
title: "Rift Architecture and ERDs"
type: report
sources:
  - "../raw/repos/rift-canonical-doc-surface.md"
  - "../../README.md"
  - "../../AGENTS.md"
  - "../../spec/doc/protocol.md"
  - "../../spec/doc/ipc.md"
  - "../../spec/decisions/README.md"
  - "../../spec/decisions/0010-json-rpc-error-model.md"
  - "../../spec/decisions/0011-channel-binding-tiers.md"
  - "../../daemon-cs/README.md"
  - "../../daemon-dart/README.md"
  - "../../app-flutter/README.md"
  - "../../tests-conformance/README.md"
  - "../../tests-interop/README.md"
generated: 2026-07-11
summary: "Architecture overview and conceptual ERDs for the Rift monorepo, centered on the protocol-first dual-daemon design and transport-agnostic IPC."
---

# Rift Architecture and ERDs

## Scope

This document describes the canonical architecture surfaced by the repository
specifications and component READMEs. The ERDs below are conceptual data models
for protocol and daemon state, not a physical SQLite schema.

## Architecture Summary

Rift is a protocol-first, local-first device continuity system with one written
specification and two independent daemon implementations. The protocol and IPC
specs are the source of truth; the C# daemon family and the Dart Android daemon
must conform to them rather than define their own behavior.

The runtime has three major layers:

1. Peer protocol layer: daemon-to-daemon discovery, mutual TLS, Ed25519 proof
   of possession, trust-state enforcement, capability negotiation, clipboard
   offer/fetch, presence, and operation lifecycle.
2. Local daemon layer: identity generation, trust/persistence, event logging,
   session handling, and enforcement of all security-sensitive state.
3. Client layer: one Flutter app that talks to the local daemon over a single
   JSON-RPC 2.0 contract, using named pipes on Windows, Unix sockets on
   macOS/Linux, and isolate ports on Android.

## System Context

```mermaid
flowchart LR
  subgraph DeviceA["Device A"]
    UIA["Flutter App"]
    DA["Local Daemon"]
    DBA[("Local State / SQLite")]
  end

  subgraph DeviceB["Device B"]
    UIB["Flutter App"]
    DB["Local Daemon"]
    DBB[("Local State / SQLite")]
  end

  UIA <-->|JSON-RPC 2.0 IPC| DA
  UIB <-->|JSON-RPC 2.0 IPC| DB
  DA --> DBA
  DB --> DBB
  DA <-->|mDNS + mTLS + Rift peer protocol| DB
```

## Deployment View

```mermaid
flowchart TB
  subgraph Windows_macOS_Linux["Desktop Hosts"]
    F1["Flutter App"]
    CSD["daemon-cs host"]
    CORE1["Rift.Daemon.Core"]
  end

  subgraph Android["Android Host"]
    F2["Flutter App"]
    ISO["Background daemon isolate"]
    DARTD["daemon-dart core"]
  end

  F1 <-->|JSON-RPC over local transport| CSD
  CSD --> CORE1
  F2 <-->|JSON-RPC over SendPort/ReceivePort| ISO
  ISO --> DARTD
  CORE1 <-->|Protocol conformance| DARTD
```

## Trust and Identity Model

- Each device owns a long-term Ed25519 keypair for device identity.
- Each device also owns an ECDSA P-256 keypair for mutual TLS.
- The Ed25519 public key is embedded in the TLS certificate via a custom X.509
  extension and then proven post-handshake with Ed25519 PoP.
- Trust state is durable and explicit: `discovered`, `pairing_pending`,
  `trusted`, `blocked`, `revoked`.
- Private keys never cross the IPC boundary and never leave the daemon.

## ERD 1: Identity, Peer, Trust, and Certificate

```mermaid
erDiagram
  DEVICE_IDENTITY ||--|| TLS_CERTIFICATE : binds_to
  DEVICE_IDENTITY ||--o{ PEER_TRUST_RECORD : local_device_tracks_peers
  PEER_TRUST_RECORD ||--o{ TRUST_EVENT : emits
  PEER_TRUST_RECORD ||--o{ CAPABILITY_GRANT : authorizes

  DEVICE_IDENTITY {
    string device_id PK
    bytes ed25519_public_key
    string fingerprint
    string implementation_id
    string protocol_version
  }

  TLS_CERTIFICATE {
    string certificate_fingerprint PK
    string subject_name
    string algorithm
    string extension_oid
    bytes embedded_ed25519_public_key
    datetime issued_at
    datetime expires_at
  }

  PEER_TRUST_RECORD {
    string peer_device_id PK
    string trust_state
    string display_name
    string last_known_address
    int last_known_port
    string last_seen_version
    datetime last_seen_at
  }

  CAPABILITY_GRANT {
    string peer_device_id FK
    string capability_name
    int capability_version
    string grant_state
  }

  TRUST_EVENT {
    string event_id PK
    string peer_device_id FK
    string event_type
    string severity
    datetime occurred_at
  }
```

## ERD 2: Session, Discovery, Operation, and Clipboard Flow

```mermaid
erDiagram
  DISCOVERED_PEER ||--o| SESSION : may_upgrade_to
  SESSION ||--o{ NEGOTIATED_CAPABILITY : yields
  SESSION ||--o{ OPERATION : carries
  OPERATION ||--o| CLIPBOARD_OFFER : may_represent
  OPERATION ||--o{ OPERATION_EVENT : emits

  DISCOVERED_PEER {
    string instance_id PK
    string device_id
    string address
    int port
    string min_version
    string max_version
    string trust_state
  }

  SESSION {
    string session_id PK
    string peer_device_id
    string binding_type
    string tls_version
    string auth_state
    datetime established_at
  }

  NEGOTIATED_CAPABILITY {
    string session_id FK
    string capability_name
    int capability_version
  }

  OPERATION {
    string operation_id PK
    string session_id FK
    string operation_type
    string state
    string failure_reason
    datetime created_at
    datetime expires_at
  }

  CLIPBOARD_OFFER {
    string offer_id PK
    string operation_id FK
    string mime_type
    int byte_size
    string sha256
    datetime expires_at
  }

  OPERATION_EVENT {
    string event_id PK
    string operation_id FK
    string from_state
    string to_state
    string reason
    datetime occurred_at
  }
```

## ERD 3: IPC and Local Client Boundary

```mermaid
erDiagram
  LOCAL_CLIENT ||--o{ IPC_REQUEST : sends
  IPC_REQUEST ||--o| IPC_RESPONSE : receives
  IPC_REQUEST ||--o{ IPC_NOTIFICATION : may_trigger
  IPC_REQUEST }o--|| DAEMON_METHOD : targets

  LOCAL_CLIENT {
    string client_id PK
    string platform
    string transport
  }

  DAEMON_METHOD {
    string method_name PK
    string boundary
    string result_shape
    string error_family
  }

  IPC_REQUEST {
    string id PK
    string client_id FK
    string method_name FK
    string params_shape
    datetime sent_at
  }

  IPC_RESPONSE {
    string id PK
    string request_id FK
    string status
    string error_code
    datetime completed_at
  }

  IPC_NOTIFICATION {
    string notification_id PK
    string request_id FK
    string method
    string params_shape
    datetime emitted_at
  }
```

## Verification Architecture

The architecture is defended by three test layers:

- Conformance tests validate both daemon implementations against the written
  protocol contract.
- Interoperability tests exercise the C# and Dart daemons together end-to-end.
- Component tests and security-focused validation cover parser behavior,
  transport bootstrap, and IPC error mapping.

## Notes and Boundaries

- These ERDs are intentionally conceptual. The canonical docs define protocol
  entities and state transitions, but not a final normalized persistence schema.
- If a future SQLite schema is documented in canonical repo docs, a physical ERD
  should be produced separately rather than silently replacing this one.
- The daemon is the sole authority for identity, trust, certificates, sessions,
  and event logs. The Flutter app is a transport-agnostic client, not a second
  source of truth.
