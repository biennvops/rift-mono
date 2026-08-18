# Android Foreground Sync Notification Qualification

Status: partial physical qualification; the targeted release matrix still needs live peer-state control.

This record supplements the automated Flutter and Android tests for the foreground
service notification. It records the physical checks performed on a Pixel 6 Pro
running Android 17 (API 37) with the debug APK built from commit `ffdd578`.

## Results

| Check | Result | Evidence |
|---|---|---|
| Foreground promotion | Pass | `dumpsys activity services` reported `isForeground=true`, notification ID `4108`, and `connectedDevice` foreground-service type. |
| Notification identity and properties | Pass | `dumpsys notification` reported channel `rift.daemon`, ongoing/only-alert-once flags, low priority, private visibility, and a generic public version. |
| Connected multi-peer state | Pass | An existing four-peer trusted state rendered a count and bounded display names in notification `4108`; no second Rift foreground record appeared. |
| Duplicate service start | Pass | A duplicate `START_DAEMON_SERVICE` left the connected title/body unchanged and the service remained foreground. |
| Notification tap | Pass with route instrumentation | Tapping the notification launched the existing `MainActivity`; logcat showed the `rift://foreground-sync` intent with extras. The Flutter UI test surface does not expose enough semantics in the device dump to independently assert the final Devices label. |
| `POST_NOTIFICATIONS` denied | Pass | After revoking permission before app launch, Rift started and `dumpsys activity services` still reported the foreground service active. No notification update crash was observed. |
| Permission restoration | Pass | Granting permission again restored the notification record after the next service/status update. |
| Lock-screen public content | Partial | The native record exposed a generic public version without peer names. An interactive locked-screen capture was not performed. |
| Mirrored-notification separation | Partial | The physical notification dump contained `4108` and no `4110` record after foreground updates. Dedicated listener-event instrumentation was not available for this smoke run. |

## Pending physical scenarios

The following require controlled peer changes or a second operator/device and
were not claimed as passes here:

- zero trusted peers, trusted peers offline, and exactly one online peer;
- live peer disconnect, rename, reconnect, and the reconnecting copy;
- notification-listener loop prevention under an observed listener event;
- visual lock-screen verification of the public version.

Automated verification for this change passed with `flutter analyze`, the full
Flutter test suite, `:app:testDebugUnitTest`, and `tools/verify.sh changed`.
