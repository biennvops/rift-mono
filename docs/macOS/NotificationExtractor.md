# macOS Notification Extractor

Rift uses a dedicated background app for reading Notification Center metadata on macOS. The separate app identity keeps Full Disk Access (FDA) away from the network-facing daemon.

## Security boundary

The extractor bundle identifier is `com.rift.notification-extractor`. It has no network listener. Its signed Swift broker accepts compact JSON through one authenticated XPC method carrying `Data`. Extraction operations go to a private C# worker over inherited standard streams; bounded notification-action operations, when explicitly compiled, stay in the native broker. The worker's operation vocabulary is fixed:

- `getStatus`
- `scanNotificationChanges`
- `rescanActiveNotifications`

The worker does not accept paths, SQL, shell commands, or generic file-read requests. It always reads:

```text
~/Library/Group Containers/group.com.apple.usernoted/db2/db
```

Database access is read-only. Each scan uses SQLite's online backup API to create a private mode-`0600` snapshot, which includes committed WAL state without modifying Notification Center's database. The snapshot is deleted when the request completes.

The extractor validates the expected `app` and `record` columns before querying. Unknown schemas fail closed with `unsupportedSchema`. Neither `record.presented` nor `delivered.list` is a reliable active-notification set on current macOS: `delivered.list` retains historical per-app UUIDs after notifications are no longer visible. `rescanActiveNotifications` therefore fails closed with `activeStateUnavailable` rather than replaying stale notification history. Malformed notification payloads are skipped and counted without returning their content.

Default macOS-origin records report `isDismissible: false` and `isOpenable: false`. An explicitly built and manually authorized Accessibility backend may set `isDismissible: true` for one record only while its database UUID resolves to exactly one individually actionable AX notification; this optional flavor still requires production-path qualification with the installed extractor before release. It never advertises open. The extractor returns only the source bundle identifier, title, combined subtitle/body preview, timestamp, and stable notification identifier; it does not return the full property-list payload.

## Building the app

From the repository root:

```bash
daemon-cs/Rift.NotificationExtractor.macOS/Tools/build_macos_notification_extractor_app.sh
```

Default builds compile no notification-action backend. The separate optional Accessibility flavor and the development-only private-framework flavor are documented in [Experimental macOS Notification Actions](PrivateNotificationActions.md). Both require explicit build switches; neither is silently enabled.

The script defaults to the current architecture and creates:

```text
dist/macos/Rift Notification Extractor.app
```

Development builds automatically use `Rift Development Code Signing` when that local identity is available. Create it once with:

```bash
daemon-cs/Tools/setup_rift_dev_signing.sh
```

Set `RIFT_CODESIGN_IDENTITY` to override automatic selection with another stable identity:

```bash
RIFT_CODESIGN_IDENTITY='Developer ID Application: Example (TEAMID)' \
  daemon-cs/Rift.NotificationExtractor.macOS/Tools/build_macos_notification_extractor_app.sh
```

Use the same signing identity and bundle location between builds so macOS retains the FDA grant. Ad-hoc signatures change when the app is rebuilt and require the FDA entry to be removed and re-added. When migrating an existing ad-hoc installation, remove its old FDA entry before adding the certificate-signed bundle because TCC retains the previous CDHash requirement.

## Granting Full Disk Access

1. Build the app and place it in its intended stable location.
2. Open **System Settings → Privacy & Security → Full Disk Access**.
3. Add and enable **Rift Notification Extractor**.
4. Restart the extractor after changing the grant.

FDA belongs only to the extractor. Do not grant FDA to Rift Daemon or the Flutter UI.

## Optional Accessibility dismissal (experimental)

Only a bundle built with `RIFT_MACOS_ACCESSIBILITY_NOTIFICATION_ACTIONS=1` can use Accessibility dismissal. This flavor is not release-qualified by the research-app results: production qualification must use the installed extractor bundle at its stable path. After installing that bundle, the user may explicitly add and enable **Rift Notification Extractor** under **System Settings → Privacy & Security → Accessibility**. The extractor never opens that pane or prompts during startup.

Without this grant, notification synchronization remains functional and all macOS records remain non-dismissible. Capability is per record and dynamic: closed Notification Center, collapsed stacks, permission loss, ambiguity, or a missing individual Close action all advertise false. See [Experimental macOS Notification Actions](PrivateNotificationActions.md) for the required daemon/XPC qualification matrix.

## Request protocol

One compact JSON object is accepted per authenticated XPC request, with a maximum request size of 64 KiB. The broker frames extraction requests as a single line only on its private worker stream.

```json
{"id":"1","operation":"getStatus"}
{"id":"2","operation":"scanNotificationChanges","cursor":0}
{"id":"3","operation":"rescanActiveNotifications"}
```

The optional native broker surface adds `getNotificationActionBackendStatus`, `getNotificationActionCapabilities`, and `dismissNotification`. These operations are handled in-process and are never written to the worker stream. Their exact request and failure semantics are documented in [Experimental macOS Notification Actions](PrivateNotificationActions.md).

Each response echoes the request ID and contains either `result` or a closed error object:

```json
{"id":"1","ok":true,"result":{"databaseFound":true,"databaseReadable":true,"schemaSupported":true,"state":"ready"}}
```

Expected status states are:

- `ready`
- `databaseNotFound`
- `fullDiskAccessRequired`
- `unsupportedSchema`

The installed LaunchAgent owns the extractor app process, so TCC attributes FDA to that bundle rather than the daemon. The daemon reaches its certificate-pinned broker over the authenticated Mach service described in [Notification Extractor XPC](NotificationExtractorXpc.md). The broker launches a fresh worker for each extraction request, enforces a 10-second timeout, limits responses to 1 MiB, and rejects malformed or oversized responses. Database scans use private mode-`0600` snapshots. On startup the daemon advances its cursor without replaying historical records, then publishes only newly observed records. Rift-owned bundle identifiers are ignored to prevent mirrored notifications from being extracted and echoed back to peers.

The database still does not provide a validated natural-removal lifecycle, so unrelated desktop-origin removals are not emitted. A verified Accessibility action reports its own result, but Rift does not infer removals from retained `delivered.list` UUIDs or replay stale notification history.

Authenticated XPC is the production transport boundary for the extractor. Seatbelt confinement remains separate follow-up hardening.
