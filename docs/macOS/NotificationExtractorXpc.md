# Notification Extractor XPC

The production macOS extractor transport is a launchd Mach service named:

```text
com.rift.notification-extractor.xpc
```

The app's main executable is a small Swift broker. The C# database reader remains a private helper at:

```text
Rift Notification Extractor.app/Contents/Helpers/rift-notification-extractor-worker
```

The authenticated broker has two bounded request branches:

```text
Authenticated XPC broker
    |
    +-- extraction operations
    |       |
    |       +-- private stdin/stdout stream
    |               |
    |               +-- C# read-only database worker
    |
    +-- native notification-action operations
            |
            +-- compiled native backend, or fail-closed none backend
```

The broker does not forward every request to the worker. It parses only enough JSON to recognize its fixed native operation names; all other bounded requests continue to the extraction worker for normal protocol validation.

## Extraction operations

The worker accepts only:

- `getStatus`
- `scanNotificationChanges`
- `rescanActiveNotifications`

The broker launches a fresh worker for each extraction request and sends exactly one newline-delimited JSON object over inherited standard input. The worker has no public stdin/stdout endpoint and accepts no paths, SQL, shell commands, or generic file reads.

## Native notification-action operations

The broker handles these operations in-process:

- `getNotificationActionBackendStatus`
- `getNotificationActionCapabilities`
- `dismissNotification`

Capability and dismissal requests require non-empty `notificationId` and `packageName` strings no longer than 512 characters. The surface returns JSON values only; it exposes no Objective-C object, AX handle, selector, arbitrary XPC target, or generic method invocation.

A default build contains a none backend and reports `notCompiled`. The optional Accessibility build and development-only private build are separate, mutually exclusive experimental/research infrastructure flavors in this PR, not release capabilities. Their exact build gates and safety behavior are documented in [Experimental macOS Notification Actions](PrivateNotificationActions.md).

Accessibility operations stay in the FDA-bearing extractor process because that process owns the stable notification database identity and native UI lookup. The network-facing daemon receives no Accessibility handle and cannot submit peer-provided visible content as a query. The daemon first resolves the remote notification ID to its locally retained `NotificationSyncRecord`, then sends the record's ID and package name over authenticated XPC.

## Peer authentication

Before activation, the listener applies a code-signing requirement to incoming connections. A development build binds the daemon identifier to the exact certificate used to sign the broker:

```text
identifier "com.rift.daemon"
and certificate leaf = H"<certificate SHA-1>"
```

Create the local identity once with:

```bash
daemon-cs/Tools/setup_rift_dev_signing.sh
```

The script stores the private key only in the selected local keychain and refuses to replace an existing identity. Rebuilds receive new code-directory hashes but retain the certificate requirement, avoiding ad-hoc identity churn.

Production builds derive an Apple-anchored requirement from their signing Team ID:

```text
identifier "com.rift.daemon"
and anchor apple generic
and certificate leaf[subject.OU] = "<Team ID>"
```

The listener rejects an invalid client before its delegate receives the connection.

The daemon loads a small Swift bridge dynamic library into its own process. The bridge applies the corresponding certificate-pinned or Apple-anchored requirement to `com.rift.notification-extractor`. Both peers therefore authenticate the other side. A command-line probe exists only for signed-bundle development testing and is not a production transport.

## Bounds and failure behavior

The single XPC method carries `Data` and enforces:

- maximum request: 64 KiB;
- maximum response: 1 MiB;
- maximum worker error output: 1 MiB;
- worker timeout: 10 seconds;
- notification-action identity field: 512 characters.

Malformed, oversized, timed-out, and unknown extraction requests fail within the existing worker protocol. A recognized malformed native request returns `invalidRequest` without starting the worker. Native backend exceptions cannot crash extraction; they return a closed unavailable result.

Unknown operation names are not treated as native calls. They continue to the worker, which owns the canonical extraction-operation validation.

## Bundle and launchd layout

The extractor LaunchAgent advertises the Mach service and launches:

```text
~/Applications/Rift Notification Extractor.app/Contents/MacOS/rift-notification-extractor
```

Build and install only after reviewing the generated bundle and signing identity:

```bash
daemon-cs/Rift.NotificationExtractor.macOS/Tools/build_macos_notification_extractor_app.sh
daemon-cs/Rift.NotificationExtractor.macOS/Tools/install_macos_notification_extractor.sh
```

Both scripts refuse to overwrite an existing app bundle. The installer uses `launchctl bootstrap` in the current GUI-user domain. Both the daemon and extractor builds require a certificate-backed signing identity; ad-hoc signatures cannot establish the pinned peer identity.

Full Disk Access belongs to the extractor app. An Accessibility build also requires a separate, explicit user grant to that same installed app. Neither permission belongs to the daemon or Flutter UI, and basic notification synchronization does not depend on Accessibility. The Accessibility runtime result is not release-qualified until the installed extractor has completed the production daemon/XPC qualification matrix in [Experimental macOS Notification Actions](PrivateNotificationActions.md).

## Validation

The focused macOS test script compiles default, private, and Accessibility brokers, checks flavor sentinels, runs native request-validation and backend safety tests, validates rejected build-flag combinations, and checks shell syntax:

```bash
daemon-cs/Rift.NotificationExtractor.macOS/Tools/test_macos_notification_actions.sh
```

The signed full-app build additionally verifies bundle markers, nested signatures, and broker/worker identifiers. Runtime installation remains a separate user action because it changes a LaunchAgent and the stable TCC-bearing app bundle. Build success and research-app AX observations do not replace production-path qualification with the installed extractor, its LaunchAgent, and the running daemon.

Authenticated XPC is the production extractor boundary. Seatbelt confinement remains separate follow-up hardening.
