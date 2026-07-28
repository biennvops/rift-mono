# ADR 0012: Native TLS Transport for Mobile Pairing

## Status

Proposed.

## Context

The Dart mobile transport uses `dart:io` `SecureServerSocket`. On Android, the
platform TLS stack rejects arbitrary self-signed client certificates before
Rift can inspect the certificate extension and perform Ed25519 Proof of
Possession. The current workaround prefers outbound sessions, which cannot
establish a mobile-to-mobile session when both endpoints use the Dart mobile
transport.

The same transport path is shared by the iOS in-process daemon and does not
have real mobile-to-mobile TLS coverage.

## Decision

Mobile peer transport will use native platform TLS for the socket boundary:

- Android will use the platform TLS server/client APIs with a custom client
  certificate trust callback.
- iOS will use Network.framework TLS with an equivalent certificate policy.
- Native transport will provisionally accept an unknown self-signed peer
  certificate so the daemon can extract its DER certificate and run the
  existing Ed25519 Proof of Possession flow.
- Trusted peers will continue to be checked against the pinned Ed25519
  identity and certificate binding rules enforced by the Dart session layer.
- Native code will expose framed byte streams, peer certificate DER, endpoint
  state, and connection lifecycle events to the Dart daemon. It will not
  implement pairing, trust transitions, capabilities, or operations.
- Dart continues to generate each process-lifetime ephemeral P-256 TLS key and
  its self-signed certificate containing the permanent Ed25519 public key. The
  certificate and ephemeral private-key PEM are provisioned to the native TLS
  bridge over an in-process Flutter method channel. The permanent Ed25519 seed
  is never sent through this transport bridge.
- The existing 4-byte big-endian frame format remains unchanged.

No plaintext peer bootstrap or certificate material in discovery records will
be added. The protocol's mutual TLS and post-handshake identity requirements
remain authoritative.

## Consequences

- Native code must be added to both mobile targets and bridged to the daemon.
- The ephemeral TLS identity key and certificate cross the in-process Flutter
  method-channel boundary. They are not persisted by the bridge and are
  regenerated when the daemon starts. The permanent Ed25519 identity seed
  remains protected by Android Keystore/iOS Keychain-backed storage and does
  not cross the native TLS bridge.
- Real-device tests are required for Android-to-Android, Android-to-iOS, and
  iOS-to-iOS pairing.
- The existing Dart transport remains useful for desktop/standalone tests until
  the mobile transport binding is selected at runtime.
- iOS background suspension and Android process lifecycle remain separate
  availability constraints after transport pairing is fixed.

## Acceptance criteria

1. An untrusted mobile peer can complete provisional mutual TLS and Dart PoP.
2. Invalid certificates, extension data, device IDs, and PoP values fail closed.
3. Pairing works in both initiation directions for all three mobile platform
   combinations.
4. Trusted reconnect uses the pinned identity and survives endpoint changes.
5. The native bridge never returns private-key material; only the ephemeral
   P-256 TLS private key may be provisioned from Dart to native code. The
   permanent Ed25519 identity seed never crosses the TLS bridge.
6. The transport passes real-device framing, disconnect, duplicate-session, and
   network-change tests.
