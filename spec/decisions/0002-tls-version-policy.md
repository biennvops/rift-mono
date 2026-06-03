# ADR-0002: TLS version policy

Status: proposed

Decision: Prefer TLS 1.3; allow TLS 1.2 fallback with EMS and strong ciphers where platform APIs force it. Details TBD.
# ADR 0002: TLS Version Policy

## Status

Accepted

## Context

Rift requires mutual TLS for all peer communication after discovery. TLS 1.3 provides improved handshake performance, forward secrecy by default, and removes legacy cipher suites. However, Dart's `SecurityContext` API does not expose BoringSSL's `SSL_CTX_set_min_proto_version`, meaning the Dart daemon cannot programmatically reject TLS 1.2 connections.

## Decision

TLS 1.3 is preferred. TLS 1.2 with strong cipher suites is allowed as a fallback where TLS 1.3-only enforcement is unavailable at the platform API level. The C# daemon can enforce TLS 1.3 minimum via `SslStream`. The Dart daemon accepts whatever BoringSSL negotiates.

See protocol specification Section 5.1.

## Consequences

- Mutual TLS 1.2 with ECDSA P-256 remains secure for this use case.
- The security architecture should describe this as "TLS 1.3 preferred, TLS 1.2 minimum."
- The threat model should not claim TLS 1.3-only enforcement as a security property.
- If Dart's `SecurityContext` gains min-version control, the Dart daemon should adopt TLS 1.3 minimum.
