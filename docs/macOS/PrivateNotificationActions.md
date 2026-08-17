# Experimental macOS Private Notification Actions

Third-party source-notification actions on macOS are an experimental, development-only capability. They are currently unavailable on the tested host because no safe, entitlement-feasible path can enumerate and remove the exact Notification Center item represented by Rift's source record.

Normal builds do not compile private framework probes and continue to advertise macOS notifications with `isDismissible: false` and `isOpenable: false`. Private builds also advertise no action unless a future backend can prove exact targeting and verified removal.

## Build gate

The default build is the normal flavor:

```bash
daemon-cs/Rift.NotificationExtractor.macOS/Tools/build_macos_notification_extractor_app.sh
```

The private development flavor requires an explicit switch:

```bash
RIFT_DEV_PRIVATE_MACOS_NOTIFICATION_ACTIONS=1 \
  daemon-cs/Rift.NotificationExtractor.macOS/Tools/build_macos_notification_extractor_app.sh
```

`RIFT_DEV_PRIVATE_MACOS_NOTIFICATION_ACTIONS` accepts only `0` or `1` and defaults to `0`. The private flavor passes both `RIFT_PRIVATE_API` and `RIFT_PRIVATE_NOTIFICATION_ACTIONS` to the Swift compiler and inserts this diagnostic bundle marker before signing:

```text
RiftDevPrivateNotificationActionsEnabled = true
```

The normal flavor contains neither compiler condition nor marker. The build script also verifies that the Rift-owned sentinel `RIFT_PRIVATE_NOTIFICATION_ACTIONS_V1` is present only in the private broker and that the complete app signature is valid. The script refuses to overwrite an existing output bundle, so move or remove `dist/macos/Rift Notification Extractor.app` before changing flavors.

## Containment and request surface

Private probing is contained in the signed Notification Extractor XPC broker. The database worker remains read-only and does not receive native action operations.

The authenticated `request(Data) -> Data` XPC protocol recognizes three bounded native operations:

- `getNotificationActionBackendStatus`
- `getNotificationActionCapabilities`
- `dismissNotification`

Capability and dismissal requests require non-empty `notificationId` and `packageName` strings of at most 512 characters. Other operations continue to the existing extraction worker. The broker exposes no generic selector calls, raw private objects, arbitrary XPC forwarding, bundle-wide clearing, SQL, or process commands.

A normal build reports:

```json
{
  "backend": "none",
  "available": false,
  "canEnumerate": false,
  "canDismiss": false,
  "reason": "notCompiled"
}
```

A private build probes the installed frameworks, required classes and selectors, and its own code-signing entitlements. On the tested host it reports `backend: "private"`, `available: false`, and `reason: "privateEntitlementRequired"`. Exact capability and dismissal calls therefore return false without touching a notification.

No macOS `ILocalNotificationActionHandler` is registered while this backend is unavailable. The generic notification action routing remains unchanged, and the macOS observer continues to publish both action flags as false.

## Tested host

Research and runtime probing were performed on:

| Property | Value |
|---|---|
| macOS | 26.6 (build 25G72) |
| Architecture | arm64 |
| Installed framework version | UserNotificationsCore 640.6.5 |
| Xcode SDK used to build | macOS 26.5 |

The framework executables are supplied through the dyld shared cache on this OS. Their on-disk framework executable symlinks are intentionally unresolved, but `dlopen` loads both frameworks successfully.

## Notification service research

Read-only runtime enumeration established these relevant interfaces on the tested host:

- `UserNotificationsCore.NotificationSystemServiceClient`
  - `notificationRecordForIdentifier:bundleIdentifier:`
  - `removeNotificationRecordsForIdentifiers:bundleIdentifier:`
- `UNCNotificationCoreServiceClient`
  - repository enumeration and record-removal methods
- `NCNotificationRequest`
  - separate notification identifier and UUID concepts
- `NCNotificationDispatcher`
  - request withdrawal and destination dismissal methods used inside Notification Center

These names are runtime-probed only in the private build. They are recorded here as observations for the tested OS, not as a stable Apple contract. The service clients are Objective-C-visible wrappers over BoardServices/XPC rather than a self-contained in-process delivered store. Although the remove selector is scoped by identifiers and bundle identifier, its one-item behavior could not be qualified because the exact lookup precondition failed.

The live delivered-state path is owned by `/usr/sbin/usernoted` and Notification Center. `usernoted` publishes `com.apple.usernoted.notificationcenter`; Notification Center itself carries `com.apple.private.notificationcenter`. The installed service binary states that communication is denied when a connection lacks an accepted private Notification Center entitlement. The signed Rift research probe has none of those Apple-only entitlements and cannot legitimately acquire one.

`UserNotificationsCore` also exposes repository/system-service clients. A certificate-signed third-party probe could instantiate the system client, but it returned no record for a newly delivered test notification. The core repository enumeration call did not complete when invoked outside its intended service context. Neither route provided a usable third-party delivered-notification enumeration.

## Exact identity result

Rift currently derives `notificationId` from the Notification Center database row's `record.uuid`. Read-only inspection found that the same UUID is stored in the record property list as `uuid`.

For a UserNotifications-style source record, the property list also contained `req.iden`, but it was a different application request identifier. A legacy Script Editor test notification had the database UUID and no `req.iden` at all. The private service lookup returned no record for either the database UUID or the separate request identifier supplied with the exact bundle identifier.

Therefore the tested system does not provide Rift with a deterministic mapping from its database UUID to one live private service object. Title, body, app display name, and timestamp were deliberately not used as substitutes. The private remove selector was not invoked because doing so without exact resolution would violate the sibling-safety rule.

This leaves the research questions with the following outcome:

| Question | Tested result |
|---|---|
| Can a locally signed third-party process enumerate all delivered items? | No supported route found |
| Is a private repository/client present? | Yes, but not usable as a third-party exact delivered store |
| Does the database UUID map to the service record identifier? | Not established; observed request identifier differs |
| Is a single-record remove API present? | Yes at runtime, but exact authorized targeting is unavailable |
| Is an unavailable private entitlement involved? | Yes for Notification Center state access |
| Can disappearance be verified? | Not without first resolving the exact live object |
| Does it work after broker restart or without SIP changes? | Restart behavior is not applicable; no SIP change or injection was attempted |
| Is it qualified on other architectures or OS builds? | No; unknown builds and architectures fail closed |

## Accessibility fallback result

A certificate-signed Accessibility probe used `AXIsProcessTrustedWithOptions` with prompting disabled. It was not trusted on the test host. Without manual permission, it could not inspect Notification Center; no permission prompt was shown.

More importantly, an exact stable AX identity corresponding to the database UUID was not established without opening or manipulating Notification Center. The fallback stop rule therefore applies. Rift does not request Accessibility, open or focus Notification Center, synthesize input, or perform AppleScript GUI scripting.

## Failure behavior

The private runtime probe caches one fail-closed status for the broker process. Current local reasons are:

- `frameworkNotFound`
- `privateApiMismatch`
- `privateEntitlementRequired`
- `exactIdentityUnavailable`

Every state keeps `available`, `canEnumerate`, and `canDismiss` false. A framework, class, selector, entitlement, or identity mismatch cannot crash notification extraction or enable a peer-visible action.

A future implementation must still require exactly one native object matching both stable notification identity and bundle identifier, remove only that object, and verify its disappearance within a bounded interval before reporting success. Until all three conditions are demonstrated, unsupported is the intended result.

## Safety constraints

This work does not:

- mutate the Notification Center SQLite database;
- restart `usernoted`, `usernotificationsd`, or Notification Center;
- disable SIP;
- inject into another process;
- forge private entitlements;
- patch system binaries;
- use global mouse or keyboard automation;
- use AppleScript GUI scripting.

Private APIs are named plainly in private-only code and this research note. The build boundary is intended to isolate unsupported behavior, not conceal it from scanning.
