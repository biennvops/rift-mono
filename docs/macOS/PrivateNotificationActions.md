# Experimental macOS Notification Actions

macOS notification dismissal is available only in an explicit Accessibility build and only for records that the current Accessibility tree exposes as one individually actionable notification. The default Rift build still compiles no notification-action backend and advertises `isDismissible: false` and `isOpenable: false`.

The private-framework experiment remains unavailable. It identified the internal removal identity but did not provide an entitlement-feasible way for Rift to resolve or mutate the live object.

## Final backend decision

| Backend | Exact identity | Remove one | Verify target and siblings | Permission or entitlement | Final result |
|---|---:|---:|---:|---|---|
| Public `UserNotifications` | No third-party enumeration | No | No | Normal app authorization | Unsupported |
| Private native | Internal tuple identified, but unavailable to Rift | API exists, not safely callable | No authorized live enumeration | Apple-private Notification Center entitlement | Unsupported |
| Accessibility | Yes, DB UUID equals AX identifier | Yes, when individually exposed | Yes | Explicit Accessibility grant | Optional, fail-closed |

The Accessibility result is deliberately conditional. A notification is dismissible only while all of these are true:

1. The extractor app is trusted for Accessibility.
2. Notification Center is running.
3. Exactly one `AXNotificationCenterBanner` or `AXNotificationCenterAlert` has an `AXIdentifier` equal to the Rift database UUID.
4. That element exposes exactly one individual Close action.
5. After the action, the target UUID is absent and every other notification UUID visible before the action remains present.

Closed Notification Center, a collapsed stack, an ambiguous UUID, missing permission, a missing Close action, or failed verification all produce `CapabilityUnavailable` without retargeting another notification.

## Build flavors

The default build remains action-free:

```bash
daemon-cs/Rift.NotificationExtractor.macOS/Tools/build_macos_notification_extractor_app.sh
```

The optional Accessibility flavor requires an explicit switch:

```bash
RIFT_MACOS_ACCESSIBILITY_NOTIFICATION_ACTIONS=1 \
  daemon-cs/Rift.NotificationExtractor.macOS/Tools/build_macos_notification_extractor_app.sh
```

This flavor compiles only public `ApplicationServices` and AppKit APIs. It adds the diagnostic bundle marker:

```text
RiftAccessibilityNotificationActionsEnabled = true
```

It never prompts at daemon or extractor startup. The user must explicitly add and enable the installed **Rift Notification Extractor** in **System Settings → Privacy & Security → Accessibility**. Notification extraction continues to require only Full Disk Access; dismissal remains unavailable when Accessibility is not granted.

The private development flavor remains separately gated:

```bash
RIFT_DEV_PRIVATE_MACOS_NOTIFICATION_ACTIONS=1 \
  daemon-cs/Rift.NotificationExtractor.macOS/Tools/build_macos_notification_extractor_app.sh
```

It adds:

```text
RiftDevPrivateNotificationActionsEnabled = true
```

Both variables accept only `0` or `1`. The private and Accessibility flavors are mutually exclusive. The build verifies the corresponding Rift-owned binary sentinel and bundle marker, verifies that other flavor sentinels are absent, and validates the complete app signature. The source Info.plist contains neither marker.

The build script refuses to overwrite `dist/macos/Rift Notification Extractor.app`; move or remove a prior generated bundle before changing flavors.

## Containment and request surface

The signed, authenticated extractor XPC broker owns notification actions. The read-only C# database worker never receives a native action operation.

The broker recognizes three bounded native operations:

- `getNotificationActionBackendStatus`
- `getNotificationActionCapabilities`
- `dismissNotification`

Capability and dismissal requests require non-empty `notificationId` and `packageName` strings of at most 512 characters. Extraction operations continue to the private worker. The broker exposes no generic selector invocation, raw private objects, arbitrary XPC forwarding, paths, SQL, process commands, bundle-wide clearing, or UI coordinates.

The macOS daemon derives both fields from its locally retained `NotificationSyncRecord`. A remote peer supplies only the protocol notification ID and action; peer-supplied title, body, bundle, AX query, or native identifier is never targeting authority.

A default build reports:

```json
{
  "backend": "none",
  "available": false,
  "canEnumerate": false,
  "canDismiss": false,
  "reason": "notCompiled"
}
```

An Accessibility build reports `backend: "accessibility"`. Its status is unavailable with `accessibilityNotTrusted` or `notificationCenterUnavailable`; per-record capability still remains false until exact identity and an individual Close action resolve.

## Tested host

| Property | Value |
|---|---|
| macOS | 26.6 (build 25G72) |
| Architecture | arm64 |
| UserNotificationsCore | 640.6.5 |
| Xcode SDK | macOS 26.5 |

The private framework executables are supplied through the dyld shared cache on this OS. Their on-disk executable symlinks are unresolved, but `dlopen` loads the frameworks. All private names and AX observations below are version-specific runtime evidence, not stable Apple contracts.

## Public API result

A source app can query and remove only its own delivered notifications through `UNUserNotificationCenter`. Rift is a separate process observing notifications from other apps, so the public API cannot enumerate or dismiss those source notifications. It also cannot verify sibling preservation for a third-party source.

The source-owned public API was used only as an independent oracle for synthetic test notifications after AX actions.

## Private API experiment

Read-only runtime enumeration found these relevant interfaces:

- `UserNotificationsCore.NotificationSystemServiceClient`
  - `notificationRecordForIdentifier:bundleIdentifier:`
  - `removeNotificationRecordsForIdentifiers:bundleIdentifier:`
- `UNCNotificationCoreServiceClient`
  - bundle enumeration, exact lookup, and record-removal methods
- `UNCNotificationSystemServiceConnection`
  - exact lookup and removal over a BoardServices connection
- `UNSNotificationRecord`
  - request `identifier`, but no source UUID accessor
- `NCNotificationRequest`
  - distinct `notificationIdentifier`, `uuid`, and `sourceInfo`
- `NCNotificationDispatcher`
  - UUID lookup, request withdrawal, and destination dismissal methods inside Notification Center

The system service client instantiated in a certificate-signed third-party process, but exact lookups logged `No endpoint in system service client` and returned no record. The repository client did not complete outside its intended service context. `NCNotificationDispatcher` operates on Notification Center's in-process destinations rather than a third-party delivered store.

No private mutation method was invoked because authorized exact live-object resolution did not succeed.

## Controlled identity correlation

Two signed synthetic source apps posted only `RIFT-RESEARCH-*` content. Source A used UUID `11A3E333-A5A3-47BF-AD69-056E523AD0EA`; source B used `FD59D6FB-82CD-4A16-8EB2-179B245EA590`.

| Test | Rift DB UUID | `req.iden` | system `ident` | source | bundle | posted UTC |
|---|---|---|---|---|---|---|
| A, one item | `3033f1a6-ffbf-4e96-a56e-3ef0210fa424` | `RIFT-RESEARCH-A-ONE` | `BD0F-209F` | A | `com.rift.notification-research.a` | `2026-08-17T12:01:27.306201Z` |
| B, different 1 | `a2e8fe2e-9aa6-472e-af5c-45beeccfaf1d` | `RIFT-RESEARCH-B-ONE` | `A94D-57DE` | A | `com.rift.notification-research.a` | `2026-08-17T12:03:51.373920Z` |
| B, different 2 | `54bbe65c-218d-4e91-82f9-606e9e2363e0` | `RIFT-RESEARCH-B-TWO` | `589F-07B9` | A | `com.rift.notification-research.a` | `2026-08-17T12:03:51.390644Z` |
| C, same title 1 | `f2cbcb40-4b77-4078-b565-63a64d797223` | `RIFT-RESEARCH-C-ONE` | `B267-C957` | A | `com.rift.notification-research.a` | `2026-08-17T12:03:51.402710Z` |
| C, same title 2 | `9a69609c-1de6-4978-af5e-8978e1a6affd` | `RIFT-RESEARCH-C-TWO` | `2894-6120` | A | `com.rift.notification-research.a` | `2026-08-17T12:03:51.414152Z` |
| D, identical 1 | `fe2369d3-7a84-4f23-8f5e-956d78764795` | `RIFT-RESEARCH-D-ONE` | `E7E8-C407` | A | `com.rift.notification-research.a` | `2026-08-17T12:03:51.428725Z` |
| D, identical 2 | `825b95c8-7e33-4308-b700-f96c2888bb6e` | `RIFT-RESEARCH-D-TWO` | `FEAB-F49E` | A | `com.rift.notification-research.a` | `2026-08-17T12:03:51.443204Z` |
| E, app A | `2c31ac2c-4afa-4b0f-8b2f-150318bc5d1e` | `RIFT-RESEARCH-E-A` | `5DBD-389D` | A | `com.rift.notification-research.a` | `2026-08-17T12:03:51.456216Z` |
| E, app B | `a3f0f3bb-eeb0-46e9-9ffa-e6bce4509772` | `RIFT-RESEARCH-E-B` | `D5B0-D10B` | B | `com.rift.notification-research.b` | `2026-08-17T12:03:51.469866Z` |

Each record plist also contained `app`, `date`, `orig`, `styl`, `req.dest`, `srce`, and `uuid`. The `delivered.list` table stored DB UUIDs, not internal `ident` values.

`usernoted` logged its own pre-delivery exact-removal lookup as:

```text
removeDeliveredNotification(similarTo: [ident], source: source UUID)
```

The real internal tuple is therefore `ident + source UUID`. The DB UUID, request identifier, internal `ident`, and source UUID are four distinct identities. The internal `ident` is not present in Rift's read-only row or plist; diagnostic unified logs are neither durable nor a production targeting authority.

Private lookup with DB UUID + bundle, request identifier + bundle, and internal `ident` + bundle all failed outside the intended service host. The private outcome is both:

- `UNRESOLVABLE` from Rift's database identity to an authorized live service object; and
- `UNAUTHORIZED` for the system Notification Center connection required to obtain that object.

## Entitlement boundary

`usernoted` publishes `com.apple.usernoted.notificationcenter`. Its installed binary contains the fail-closed message:

```text
Connection does not have the proper entitlement (...) to connect to the system notification center. All communication will be denied.
```

Read-only arm64e disassembly ties the system-center branch to:

```text
com.apple.private.notificationcenter-system
```

Notification Center itself is Apple-signed with `com.apple.private.notificationcenter`; `usernoted` carries `com.apple.private.notificationcenter.server`. The signed Rift probes had none of these entitlements. No entitlement was forged, and this branch of the experiment stopped there.

## Accessibility experiment

Accessibility permission was first checked with prompting disabled and correctly returned `notTrusted`. Permission was then granted manually to the signed research app. Rift's implementation also checks without prompting; permission remains an explicit user choice.

The macOS 26 AX hierarchy produced these states:

| UI state | AX result | Capability |
|---|---|---|
| Notification Center closed | Delivered history absent from tree | False |
| Transient banner | `AXNotificationCenterBanner`; exact DB UUID; individual Close | Potentially true, but DB visibility timing is not dependable for a later peer action |
| Collapsed app stack | `AXNotificationCenterBannerStack`; `AXPress`, Show Details, Clear All | False |
| Expanded app stack | One `AXNotificationCenterBanner` per record; exact DB UUID; individual Close | True per exact record |
| Permission revoked or process absent | Tree unavailable | False |

For an individual synthetic notification, the 36-character AX identifier exactly matched the uppercase Rift DB UUID. For example, the AX identifier hash matched `DAD7FE5E-89B1-4164-9FE7-2E5F0716D40D`, not its request ID, internal `ident`, or source UUID.

The individual element exposed `AXPress` and custom Close/Show Details actions. The implementation never selects `AXPress`, Show Details, or Clear All. On the tested English host, the custom Close action begins `Name:Close`; an unknown localization or action representation fails closed.

### Removal qualification

| Scenario | Result |
|---|---|
| Unique history item | Exact target disappeared; source app no longer listed it; pinned sibling remained |
| Same app, identical visible content | D1 disappeared; D2 remained delivered |
| Same content, two source apps | E-A disappeared; E-B remained delivered |
| Already removed target | `unresolvable`; no action; sibling remained |
| Collapsed stack | No individual Close; no mutation |
| New item appearing during verification | Allowed only if every pre-existing sibling remains |
| Any pre-existing sibling disappears during verification | Failure, even if the target also disappeared |

The backend serializes action checks, resolves exactly one UUID immediately before mutation, and polls at bounded 100 ms intervals for at most two seconds. Success requires target absence plus preservation of every other visible UUID captured before the action.

## Dynamic capability behavior

The macOS observer asks the authenticated broker for per-record capability. It publishes `isDismissible: true` only when that exact UUID is individually actionable. It periodically rechecks tracked records so expanding a stack can upgrade capability and collapsing the stack, closing Notification Center, revoking Accessibility, or losing the extractor can downgrade it.

Upgrades are bounded to the 64 most recent non-dismissible tracked records per poll. Every record currently advertised as dismissible is always rechecked, so stale action buttons are removed fail-closed. `isOpenable` remains false.

Before performing a remote request, the daemon rechecks capability and the broker resolves the UUID again. A race cannot retarget a sibling.

## Failure reasons

Relevant local backend reasons include:

- `notCompiled`
- `frameworkNotFound`
- `privateApiMismatch`
- `privateEntitlementRequired`
- `exactIdentityUnavailable`
- `accessibilityNotTrusted`
- `notificationCenterUnavailable`
- `accessibilityIdentityAmbiguous`
- `accessibilityNoIndividualCloseAction`
- `accessibilityActionFailed`
- `verificationFailed`

Only a verified Accessibility removal becomes protocol success. All other states map to `CapabilityUnavailable` at the peer boundary.

## Safety constraints

This work does not:

- mutate Notification Center SQLite data;
- restart `usernoted`, `usernotificationsd`, or Notification Center;
- disable SIP;
- inject into another process;
- forge private entitlements;
- patch system binaries;
- use global mouse or keyboard events;
- use coordinates, OCR, screen scraping, AppleScript, or System Events;
- invoke Clear All or bundle-wide notification removal.

Private APIs remain plainly named, development-only, and off by default. Accessibility is separately gated, uses the semantic AX tree directly, and never silently requests permission.
