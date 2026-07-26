# macOS Permissions (Local Network, Notifications, Full Disk Access)

## Local Network

On macOS, Local Network access is granted per app identity (bundle id / code signature).
Rift's Bonjour/mDNS discovery runs in **Rift Daemon**, so Local Network permission must be
enabled for that app:

System Settings -> Privacy & Security -> Local Network -> enable "Rift Daemon"

The system prompt typically appears only once. If you denied it, you usually must re-enable it
in Settings.

Currently there's no way to reset Local Network access once an app's in the list.

## Notifications

Notifications permission is granted per app identity. Rift's user-visible notifications are
posted by the **Rift UI app**, so permission must be enabled there:

System Settings -> Notifications -> enable "Rift"

Reset (global):

```bash
tccutil reset Notifications
```

## Full Disk Access

Notification Center metadata is protected by Full Disk Access on current macOS releases. Only the dedicated **Rift Notification Extractor** app should receive this permission. The network-facing daemon and Flutter UI must not receive FDA.

See [NotificationExtractor.md](NotificationExtractor.md) for the fixed extractor API, build instructions, and security boundary.

