# Linux Notification Observer

Rift's Linux daemon observes new desktop notifications on the user session D-Bus and mirrors preview metadata to trusted peers that negotiated `notification.sync@1`.

## Observation boundary

The observer monitors the standard `org.freedesktop.Notifications` interface for:

- `Notify` method calls and their returned notification IDs;
- replacement notifications, represented as `notification.updated`;
- `NotificationClosed` signals, represented as `notification.removed`.

Linux provides no portable API for enumerating the currently active notification set. Rift therefore starts from the point when its observer attaches and does not replay historical notifications after a daemon restart.

Applications that publish notifications only through a desktop portal may not be visible through the standard interface on every desktop environment. This limitation must be recorded during runtime qualification rather than silently treating notification sync as complete.

## Mirrored fields

Rift uses the `desktop-entry` hint as `packageName` when available and falls back to the notification's application name. It mirrors only the application identity, title, bounded body preview, receipt timestamp, and source-scoped notification ID. Icons, custom hints, inline reply, and arbitrary notification actions are omitted.

## Source actions

After a `Notify` reply establishes a stable native target, Linux-origin notifications advertise `isDismissible: true` and `isOpenable: false` while the user-session D-Bus control path is available. `isDismissible` describes the source daemon's ability to execute Dismiss for that exact notification; it is not inferred from the Linux platform name.

A remote Dismiss resolves the full Rift identity `linux:<notification-server-owner>:<native-id>`. The daemon atomically marks the target as closing, verifies the current owner of `org.freedesktop.Notifications` with `org.freedesktop.DBus.GetNameOwner`, and sends `CloseNotification(uint32)` to the verified unique owner. If the server owner changed, the daemon does not close anything and returns `CapabilityUnavailable`; this prevents a restarted server from reusing a native integer ID for an unrelated notification. Only one concurrent close is allowed for a target, and a failed native close restores it to active.

A successful `CloseNotification` produces `notification.actionResult`; it does not synthesize source removal. The normal `NotificationClosed(id, reason)` signal remains authoritative, removes the registry target, and produces one `notification.removed` event. Open, reply, and arbitrary notification actions remain unsupported.

## Privacy and loop prevention

The D-Bus monitor is restricted to notification service traffic. Rift does not log notification title or body content from the monitor. The daemon's persisted notification-sync policy is loaded before local notifications are published, so disabled sync and package blacklists survive daemon restarts.

Notifications owned by the Rift desktop application (`dev.rift.Rift`) are ignored. This prevents a mirrored notification displayed by Rift from being observed and sent back to peers.

## Diagnostics

The observer requires `DBUS_SESSION_BUS_ADDRESS` in the systemd user-service environment and permission to become a monitor on that bus. Check the daemon log with:

```bash
journalctl --user -u rift-daemon.service
```

An unavailable session bus or denied monitor request disables Linux-origin notification publication but does not stop the Rift daemon. The observer retries after a delay.
