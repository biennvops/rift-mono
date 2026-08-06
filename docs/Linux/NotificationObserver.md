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

Linux-origin notifications advertise `isDismissible: false` and `isOpenable: false`. There is no portable and safe v1 mapping from a remote Rift action to an arbitrary source application's notification action.

## Privacy and loop prevention

The D-Bus monitor is restricted to notification service traffic. Rift does not log notification title or body content from the monitor. The daemon's persisted notification-sync policy is loaded before local notifications are published, so disabled sync and package blacklists survive daemon restarts.

Notifications owned by the Rift desktop application (`dev.rift.Rift`) are ignored. This prevents a mirrored notification displayed by Rift from being observed and sent back to peers.

## Diagnostics

The observer requires `DBUS_SESSION_BUS_ADDRESS` in the systemd user-service environment and permission to become a monitor on that bus. Check the daemon log with:

```bash
journalctl --user -u rift-daemon.service
```

An unavailable session bus or denied monitor request disables Linux-origin notification publication but does not stop the Rift daemon. The observer retries after a delay.
