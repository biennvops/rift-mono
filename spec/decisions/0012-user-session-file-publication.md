# ADR 0012: User-Session Publication of Received Files

## Status

Accepted

## Context

Rift daemons receive file content over authenticated peer sessions and verify chunk and whole-file integrity. The current desktop implementation also moves the verified staging file directly into a user-selected destination.

That responsibility conflicts with the Linux service boundary. The daemon runs with `ProtectHome=read-only`, while XDG user directories are dynamic and may change with user configuration, localization, mounts, or desktop environment. Baking a current Downloads path into the service sandbox would become stale, and granting the daemon write access to the entire home directory would weaken the security boundary. The same ownership distinction applies to Windows and macOS even when their service models do not enforce it identically.

Desktop clipboard integration already requires a user-session process. Interactive file acceptance, destination selection, notifications, and publication into user-visible storage likewise require user-session context.

The peer protocol also needs to distinguish successful transmission from successful receiver publication. A local socket write of `file.complete` does not prove that the receiver verified and committed the destination file.

## Decision

The daemon owns authenticated receipt, private staging, integrity verification, operation state, and peer acknowledgements. A local user-session publication client owns copying verified content into user-visible storage.

Flutter is Rift's default publication client, but the IPC contract is client-agnostic so another authorized local client may perform the same role.

The incoming desktop flow is:

1. The local client accepts an offer and supplies an intended destination path.
2. The daemon receives content into its private writable data directory.
3. The daemon verifies chunk order, byte count, chunk hashes, and whole-file SHA-256.
4. The daemon transitions the transfer to `ready_to_commit` and notifies local clients.
5. A publication client copies the verified staging file to a temporary sibling of the destination and atomically renames it into place.
6. The client confirms the final destination through IPC.
7. The daemon independently verifies the final file's byte count and SHA-256 before marking the receive operation done and acknowledging the peer.

A daemon may run without a publication client, but an incoming transfer cannot reach user-visible completion until an authorized local client publishes it. Offers that require user approval are not accepted without such a client.

The first implementation recovers pending commits when the publication client reconnects while the daemon remains running. It does not guarantee pending-commit recovery across daemon restart. On daemon restart, orphaned private staging content is cleaned or failed according to local policy.

`file.transfer` version 2 adds receiver-confirmed peer completion. Version 1 remains supported through capability negotiation for compatibility.

## Consequences

- Linux retains `ProtectHome=read-only`; no dynamic user-directory path is embedded in the systemd service.
- The daemon's private incoming staging directory must be writable only by the current user and must not be presented as a completed user file.
- Desktop publication behavior becomes consistent with Android's stage-then-publish model.
- Local IPC gains pending-commit listing, ready notification, confirmation, and failure methods.
- A version 2 sender remains non-terminal until the receiver confirms final publication.
- Version 1 peers retain legacy completion semantics and cannot provide receiver-confirmed success.
- User-session app exit may delay final publication without losing a verified staging file while the daemon remains running.
- Supporting durable recovery across daemon restart requires separate persistence and migration work.
