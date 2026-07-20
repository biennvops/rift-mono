# Authenticated extractor IPC prototype

The extractor hardening branch prototypes a launchd Mach service named:

```text
com.rift.notification-extractor.xpc
```

The extractor app's main executable is a small Swift XPC broker. The existing C# reader is retained as a private worker under:

```text
Rift Notification Extractor.app/Contents/Helpers/rift-notification-extractor-worker
```

The broker accepts only the existing newline-delimited JSON operation contract over one XPC method carrying `Data`. It forwards requests to the worker through inherited standard streams and enforces the same 64 KiB request, 1 MiB response, and 10-second timeout limits.

## Peer authentication

The listener calls `setConnectionCodeSigningRequirement` before activation. Development builds accept the ad-hoc signed daemon identifier:

```text
identifier "com.rift.daemon"
```

Production builds must replace this with a requirement containing the release team identifier and the daemon's designated requirement. The listener rejects clients before its delegate receives a connection.

The daemon loads a small Swift bridge dynamic library into the C# daemon process. The bridge connects to the Mach service and also requires:

```text
identifier "com.rift.notification-extractor"
```

This keeps both ends of the peer identity check explicit. A separate command-line probe is provided only for signed-bundle testing and is not a production transport.

## Bundle and launchd layout

The extractor LaunchAgent advertises the Mach service and launches:

```text
~/Applications/Rift Notification Extractor.app/Contents/MacOS/rift-notification-extractor
```

Install only after reviewing the generated bundle and signing identity:

```bash
daemon-cs/Rift.NotificationExtractor.macOS/Tools/build_macos_notification_extractor_app.sh
daemon-cs/Rift.NotificationExtractor.macOS/Tools/install_macos_notification_extractor.sh
```

The installer refuses to overwrite an existing app bundle. It uses `launchctl bootstrap` for the current GUI user domain.

The daemon app build now compiles the bridge library and signs the daemon executable with identifier `com.rift.daemon`. A stable Apple signing identity is required for production; ad-hoc signatures are suitable only for local authentication experiments and will not preserve FDA grants across rebuilds.

## Current status

This branch has compile-time and bundle-layout validation. Runtime installation is deliberately separate because it changes a user LaunchAgent, replaces the FDA-bearing app, and requires FDA to be granted again. Before enabling it, test:

- the correct signed daemon is accepted;
- an incorrectly signed or unsigned client is rejected;
- the worker is not reachable through the old public stdin/stdout path;
- malformed, oversized, timed-out, and unknown requests remain bounded and fail closed.

Seatbelt confinement and no-network policy are a subsequent phase after these peer-authentication tests pass.
