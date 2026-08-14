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

The source identifier is `windows:<UserNotification.Id>`. It is not derived from notification text, timestamps, or application names. Active notifications absent from the preceding successful snapshot are posted, changed notifications retain the same identifier and are updated, and identifiers absent from a successful snapshot are removed.

The observer forwards only normalized preview metadata:

- `AppInfo.AppUserModelId` as `packageName`, with package-family/`AppInfo.Id` fallbacks;
- `AppInfo.DisplayInfo.DisplayName` as `appName`;
- the first `ToastGeneric` text element as `title`;
- the remaining `ToastGeneric` text elements joined with newlines as `bodyPreview`, bounded to 256/1024 characters;
- `UserNotification.CreationTime` as the UTC `postedAt` value; and
- an optional registered application logo normalized to canonical PNG metadata through the shared notification-icon helper.

Raw toast XML, action arguments, input values, hidden payloads, arbitrary images, and launch parameters are not forwarded. Exact active Windows-origin records advertise `isDismissible: true` only while the packaged observer owns the daemon's action-executor lease, listener access is allowed, and the latest snapshot confirms an actionable target; `isOpenable` remains false. These flags describe what the source process can currently execute for that specific record; they are not general platform capability flags. Rift-owned notifications are filtered by application identity, never by display name.

## Source actions

The C# daemon delivers an incoming peer Dismiss only to the connected user-session process that owns the connection-scoped notification-action executor lease. The coordinator claims that lease after package identity, listener access, and local policy checks pass; if another Rift process already owns it, the later process does not observe or advertise Dismiss and retries the lease at the two-second polling interval. Each retry revalidates the local prerequisites before observation begins, allowing an already-connected standby to take over after the owner exits. The daemon releases ownership automatically when the IPC connection closes. The Dart coordinator accepts only `dismiss` for the local device and an exact `windows:<decimal uint32>` identity, then re-checks the tracked/active snapshot before calling the public `UserNotificationListener.RemoveNotification(id)` API. Invalid, overflowing, stale, or unavailable targets fail closed; Open, reply, and arbitrary actions remain unsupported.

After a successful native removal, the coordinator reports completion through `rift.reportLocalNotificationActionHandled` and immediately obtains another active snapshot. It publishes a source removal only when that snapshot confirms the identifier is absent; it does not assume that native success alone removed the record. Native errors are mapped to Rift's stable failure vocabulary; HRESULTs are not sent to peers.

## Lifecycle and recovery

The Dart coordinator serializes snapshot polls and source actions FIFO and maintains an in-memory identifier map. It calls `GetNotificationsAsync(NotificationKinds::Toast)` at startup, on reconnect, immediately after a successful remote Dismiss, and every two seconds while running. It deliberately does not subscribe to `UserNotificationListener.NotificationChanged`: that subscription crashes the per-user Windows Push Notifications service on affected Windows 11 builds, while enumeration remains healthy.

Startup and reconnect compare the active snapshot with daemon records whose `sourceDeviceId` is the local device and whose `sourcePlatform` is `windows`. Later polls diff against the preceding successful snapshot. This source-side reconciliation emits:

- `posted` for newly active notifications;
- `updated` only when normalized metadata for an active identifier changes; and
- `removed` for locally tracked Windows source records absent from a successful active snapshot.

A failed snapshot is non-authoritative for presence, so Rift keeps tracked records instead of removing them, but it immediately republishes those records with Dismiss unavailable until a successful snapshot restores the exact native mapping. If Windows enumerates a notification but its metadata cannot be extracted, Rift likewise retains its identity with Dismiss unavailable, without publishing incomplete data or accepting a remote action until a complete snapshot is available. Remote-origin records are never compared with Windows' local active set. Receiver-side mirror cleanup remains the existing mirrored-notification reconciliation path.

Polling makes ordinary Windows notification posts, updates, and user-initiated removals visible with up to approximately two seconds of source-side latency. A successful remote Dismiss does not wait for the next scheduled poll because it triggers immediate reconciliation.

If listener access, native snapshot enumeration, or a graceful observer shutdown makes action execution unavailable, the coordinator publishes `updated` records with `isDismissible: false` before releasing its lease. If the IPC owner disappears abruptly, the daemon invalidates the stored local Windows records and broadcasts the same capability downgrade. If the Rift user-session process exits, observation and source-action execution stop. Incoming Windows actions then fail with `CapabilityUnavailable`; they are not queued waiting for the UI process to restart. No Windows background task or second Windows-only daemon protocol is used. All events continue through `rift.notifyLocalNotificationEvent` and the existing `notification.sync@1` contract.
