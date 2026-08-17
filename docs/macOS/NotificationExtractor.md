# macOS Notification Extractor

Rift uses a dedicated background app for reading Notification Center metadata on macOS. The separate app identity keeps Full Disk Access (FDA) away from the network-facing daemon.

## Security boundary

The extractor bundle identifier is `com.rift.notification-extractor`. It has no network listener. Its signed Swift broker accepts compact JSON through one authenticated XPC method carrying `Data`, and forwards only extraction operations to a private C# worker over inherited standard streams. The worker's operation vocabulary is fixed:

- `getStatus`
- `scanNotificationChanges`
- `rescanActiveNotifications`

The worker does not accept paths, SQL, shell commands, or generic file-read requests. It always reads:

```text
~/Library/Group Containers/group.com.apple.usernoted/db2/db
```

Database access is read-only. Each scan uses SQLite's online backup API to create a private mode-`0600` snapshot, which includes committed WAL state without modifying Notification Center's database. The snapshot is deleted when the request completes.

The extractor validates the expected `app` and `record` columns before querying. Unknown schemas fail closed with `unsupportedSchema`. Neither `record.presented` nor `delivered.list` is a reliable active-notification set on current macOS: `delivered.list` retains historical per-app UUIDs after notifications are no longer visible. `rescanActiveNotifications` therefore fails closed with `activeStateUnavailable` rather than replaying stale notification history. Malformed notification payloads are skipped and counted without returning their content.

macOS-origin records always report `isDismissible: false` and `isOpenable: false`, as required by notification sync v1. The extractor returns only the source bundle identifier, title, combined subtitle/body preview, timestamp, and stable notification identifier. It does not return the full property-list payload.

## Building the app

From the repository root:

```bash
daemon-cs/Rift.NotificationExtractor.macOS/Tools/build_macos_notification_extractor_app.sh
```

Normal builds compile no private notification-action probes. The explicit development-only flavor and its current unavailable research result are documented in [Experimental macOS Private Notification Actions](PrivateNotificationActions.md).

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

## Request protocol

One compact JSON object is accepted per authenticated XPC request, with a maximum request size of 64 KiB. The broker frames extraction requests as a single line only on its private worker stream.

```json
{"id":"1","operation":"getStatus"}
{"id":"2","operation":"scanNotificationChanges","cursor":0}
{"id":"3","operation":"rescanActiveNotifications"}
```

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

Current macOS data does not provide a validated dismissal lifecycle, so desktop-origin removals are not emitted in this phase. This is safer than treating retained `delivered.list` UUIDs as active and replaying stale notifications.

Authenticated XPC is the production transport boundary for the extractor. Seatbelt confinement remains separate follow-up hardening.
