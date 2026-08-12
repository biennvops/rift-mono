# Windows notification observer

Rift's Windows notification source adapter observes third-party toast notifications through the supported `Windows.UI.Notifications.Management.UserNotificationListener` API. It runs in the user-session Flutter Windows process, not in the C# daemon.

## Runtime requirements

Notification capture is available only when all of these conditions hold:

- Windows 10 build 19041 (version 2004) or later;
- Rift is running with package identity from the sparse package-with-external-location build;
- the package declares `uap3:Capability Name="userNotificationListener"`;
- the user explicitly grants notification-listener access in Settings; and
- the local notification-sync preference is enabled.

The normal unpackaged Flutter build remains supported. It reports `unpackaged` for this source feature and continues to provide the rest of Rift's desktop functionality. The app never requests notification access during startup. The Settings action is the only path that calls `RequestAccessAsync()`.

The development identity workflow is documented in [`app-flutter/windows/identity/README.md`](../../app-flutter/windows/identity/README.md). It uses `MakeAppx.exe`, `SignTool.exe`, and `Add-AppxPackage -ExternalLocation`; development certificates and private keys remain outside source control.

## Source metadata

The source identifier is `windows:<UserNotification.Id>`. It is not derived from notification text, timestamps, or application names. Windows `Added` notifications are posted for new identifiers and updated for identifiers already tracked by the coordinator. `Removed` notifications retain the same identifier.

The observer forwards only normalized preview metadata:

- `AppInfo.AppUserModelId` as `packageName`, with package-family/`AppInfo.Id` fallbacks;
- `AppInfo.DisplayInfo.DisplayName` as `appName`;
- the first `ToastGeneric` text element as `title`;
- the remaining `ToastGeneric` text elements joined with newlines as `bodyPreview`, bounded to 256/1024 characters;
- `UserNotification.CreationTime` as the UTC `postedAt` value; and
- an optional registered application logo normalized to canonical PNG metadata through the shared notification-icon helper.

Raw toast XML, action arguments, input values, hidden payloads, arbitrary images, and launch parameters are not forwarded. While the packaged listener is running with allowed access, exact active Windows-origin records advertise `isDismissible: true` and `isOpenable: false`. These flags describe what the source process can currently execute for that specific record; they are not general platform capability flags. Rift-owned notifications are filtered by application identity, never by display name.

## Source actions

The C# daemon delivers an incoming peer Dismiss only to the connected user-session process that owns the connection-scoped notification-action executor lease. The coordinator claims that lease after package identity, listener access, and local policy checks pass; if another Rift process already owns it, the later process does not start notification observation or advertise Dismiss. The daemon releases ownership automatically when the IPC connection closes. The Dart coordinator accepts only `dismiss` for the local device and an exact `windows:<decimal uint32>` identity, then re-checks the tracked/active listener snapshot before calling the public `UserNotificationListener.RemoveNotification(id)` API. Invalid, overflowing, stale, or unavailable targets fail closed; Open, reply, and arbitrary actions remain unsupported.

The coordinator reports completion through `rift.reportLocalNotificationActionHandled`. It does not synthesize source removal: the normal `NotificationChanged(Removed)` event flows through `rift.notifyLocalNotificationEvent(removed)` and remains authoritative. Native errors are mapped to Rift's stable failure vocabulary; HRESULTs are not sent to peers.

## Lifecycle and recovery

The Dart coordinator subscribes to the native event channel, serializes source events FIFO, and maintains an in-memory identifier map. On startup and reconnect it calls `GetNotificationsAsync(NotificationKinds::Toast)` and compares the active snapshot with daemon records whose `sourceDeviceId` is the local device and whose `sourcePlatform` is `windows`.

This source-side reconciliation emits:

- `posted` for active notifications absent from daemon state;
- `updated` for active notifications already represented locally; and
- `removed` for local Windows source records absent from the active snapshot.

Remote-origin records are never compared with Windows' local active set. Receiver-side mirror cleanup remains the existing mirrored-notification reconciliation path.

If the Rift user-session process exits, observation and source-action execution stop. Incoming Windows actions then fail with `CapabilityUnavailable`; they are not queued waiting for the UI process to restart. No Windows background task or second Windows-only daemon protocol is used. All events continue through `rift.notifyLocalNotificationEvent` and the existing `notification.sync@1` contract.
