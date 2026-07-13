# Audit Report

Scope: [architecture-and-erds-2026-07-11.md](../output/architecture-and-erds-2026-07-11.md)

Date: 2026-07-11

Verdict: `weakened`

The architecture document is directionally consistent with the repository, but
it currently overstates implementation completeness in several important areas.
The largest gaps are active-session revocation on the C# daemon, peer-protocol
coverage for advertised capabilities, discovery privacy drift from the protocol,
and a validation story that is still materially weaker than the document implies.

## Findings

1. High: C# trust revocation does not terminate an already-active session, which falls short of the architecture claim that revocation takes immediate effect.
   Evidence: [PairingService.cs](../../daemon-cs/Rift.Daemon.Core/PairingService.cs:176) persists the peer as revoked and emits a trust-change notification, but it does not disconnect the live transport session. The corresponding Dart path does disconnect immediately in [pairing_manager.dart](../../daemon-dart/lib/src/pairing/pairing_manager.dart:290).
   Impact: a desktop peer that was trusted before revocation can remain online until the session naturally drops, even though future handshakes are rejected.

2. High: The C# daemon advertises `operation.lifecycle` and `security.event_log`, but incoming `operation.*` and `security.*` peer messages are still rejected as unsupported.
   Evidence: [SessionBootstrap.cs](../../daemon-cs/Rift.Daemon.Core/Networking/SessionBootstrap.cs:197) advertises both capabilities, while [ProtocolMessageRouter.cs](../../daemon-cs/Rift.Daemon.Core/ProtocolMessageRouter.cs:108) throws for any `operation.*` or `security.*` message.
   Impact: the architecture doc’s peer-protocol layer currently overstates cross-device operation/security-message support on the .NET side.

3. Medium: Both daemons disclose discovery identity hints by default, contrary to the protocol and ADR guidance to omit them unless explicitly needed.
   Evidence: the C# daemon always adds `did` in discovery at [DiscoveryService.cs](../../daemon-cs/Rift.Daemon.Core/Networking/DiscoveryService.cs:61) and in UDP fallback at [DiscoveryService.cs](../../daemon-cs/Rift.Daemon.Core/Networking/DiscoveryService.cs:292). The Dart daemon starts discovery with both `deviceIdHint` and fingerprint prefix in [daemon.dart](../../daemon-dart/lib/src/daemon.dart:463).
   Impact: this widens pre-authentication identity disclosure beyond what [0009-mdns-service-identity-disclosure.md](../../spec/decisions/0009-mdns-service-identity-disclosure.md) intends.

4. Medium: Android identity storage is still plaintext file-backed rather than Keystore-backed.
   Evidence: [identity_manager_impl.dart](../../daemon-dart/lib/src/crypto/identity_manager_impl.dart:30) loads and writes `identity.key` directly, with an explicit security TODO at line 47.
   Impact: this is a real hardening gap in the most security-sensitive platform-specific daemon implementation.

5. Medium: The validation story is not yet aligned with the architecture document’s “one conformance harness, two daemons” and “end-to-end interop” framing.
   Evidence: the .NET conformance runner is still a skeleton in [Runner.cs](../../tests-conformance/runners/dotnet/Runner.cs:1). The current interop tests use `FakeTrustStore` and `FakeTransport` in [clipboard_transfer_test.dart](../../tests-interop/test/clipboard_transfer_test.dart:18) and [presence_sync_test.dart](../../tests-interop/test/presence_sync_test.dart:14), not a real C# daemon paired with the Dart daemon.
   Impact: the architecture output should describe the intended verification architecture, not imply it is already fully realized in code.

6. Medium: The two daemons do not yet emit the same IPC JSON shape directly; the Flutter client contains compatibility normalization logic to hide that mismatch.
   Evidence: [json_rpc_client.dart](../../app-flutter/lib/src/ipc/json_rpc_client.dart:92) explicitly documents that `daemon-cs` serializes PascalCase while `daemon-dart` uses lowerCamelCase, then aliases fields client-side.
   Impact: the transport-agnostic IPC contract exists, but wire-level response uniformity is not fully achieved yet.

7. Medium: Operation history is ephemeral in both daemons rather than durable, so restart-safe operation auditability is weaker than the architecture narrative suggests.
   Evidence: the C# operation store is an in-memory dictionary in [OperationService.cs](../../daemon-cs/Rift.Daemon.Core/OperationService.cs:8), and the Dart operation store is likewise an in-memory map in [operation_manager.dart](../../daemon-dart/lib/src/operation/operation_manager.dart:6).
   Impact: `listOperations` and `getOperation` lose history on restart even though event-log durability exists.

## Notes

- I did not find evidence that the core architectural split itself is wrong. The
  protocol-first dual-daemon model, daemon-owned trust boundary, Ed25519 plus
  P-256 identity model, and transport-agnostic Flutter IPC surface are all
  materially represented in the codebase.
- The main problem is implementation completeness and architectural drift in a
  handful of security-sensitive details, not a mismatch in overall direction.

## Recommended Doc Adjustment

The architecture document should be revised from “implemented architecture” to
“target architecture with current implementation status notes,” unless these
gaps are closed first.
