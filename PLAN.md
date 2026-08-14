# Rift Mono — Review 3 Sprint

## Unified Orbit Devices Hub + Media-Reactive Peers

### Goal

Overhaul the **desktop Devices Hub** so the orbit/focus visual language becomes the actual Devices experience instead of a secondary detail page.

The final desktop model should be:

```text
Devices
│
├── Trusted       ← default mode
│    │
│    ├── This Device at center
│    ├── trusted peers orbit around it
│    └── select trusted peer
│          ↓
│       focus in-place
│       capability/media satellites
│
└── Nearby
     │
     ├── This Device at center
     ├── discovered peers orbit around it
     └── select nearby peer
           ↓
        pairing-focused state
```

This is a **Review 3 UI sprint**, not a protocol or architecture redesign.

Continue working on:

```text
feat/desktop-device-focus-view
```

Do **not** merge to `main` as part of this task.

---

## 1. Priority order

Implement in this order and preserve a usable build after every stage:

```text
P0  Trusted orbit becomes desktop Devices main screen
P0  Trusted peer focus happens in-place
P0  Nearby becomes a separate orbit mode
P0  Slow orbit motion + interaction freeze

P1  Media replaces redundant Info node
P1  Playback-reactive peer accent + animation

P2  STRETCH: pairing entirely inside Nearby focus
P2  STRETCH: paired peer transitions Nearby → Trusted
```

**Do not start the stretch work until P0 and P1 are stable.**

If time runs out after playback-reactive peers, stop there.

That is already a complete Review 3 experience.

---

# 2. Read before changing code

Read the current branch versions of:

```text
AGENTS.md

app-flutter/lib/screens/trusted_devices_screen.dart
app-flutter/lib/screens/device_detail_screen.dart
app-flutter/lib/screens/pairing_screen.dart

app-flutter/lib/widgets/device_focus/device_focus_view.dart
app-flutter/lib/widgets/device_focus/device_core.dart
app-flutter/lib/widgets/device_focus/device_focus_node.dart
app-flutter/lib/widgets/device_focus/device_focus_node_panel.dart
app-flutter/lib/widgets/device_focus/device_focus_layout.dart
app-flutter/lib/widgets/device_focus/device_focus_background.dart
app-flutter/lib/widgets/device_focus/device_focus_connector_painter.dart

app-flutter/lib/src/ui/motion.dart
app-flutter/lib/src/ui/indexed_transition_stack.dart
app-flutter/lib/src/ui/app_shell.dart

app-flutter/lib/src/ipc/json_rpc_client.dart

app-flutter/lib/src/media_playback/
```

Read the relevant existing tests before changing public widget APIs.

Especially:

```text
app-flutter/test/trusted_devices_screen_test.dart
app-flutter/test/device_detail_screen_test.dart
app-flutter/test/app_shell_test.dart
```

and existing media playback / IPC tests.

---

# 3. Desktop only

This overhaul is for the existing desktop experiment.

Use the same desktop breakpoint already used by `TrustedDevicesScreen`.

For mobile:

```text
KEEP CURRENT DEVICES UI
```

Do not attempt to fit the orbit experience onto phones in this sprint.

Do not regress existing mobile navigation or pairing.

---

# 4. Replace desktop master/detail with one scene

The current desktop architecture:

```text
┌──────────────────┬────────────────────────┐
│ device lists     │ selected detail        │
│                  │ DeviceFocusView        │
└──────────────────┴────────────────────────┘
```

should disappear from the desktop presentation.

Replace it with:

```text
┌───────────────────────────────────────────┐
│ Devices Hub              [Trusted][Nearby]│
│                                           │
│                                           │
│              ORBIT SCENE                  │
│                                           │
│                                           │
│                           secondary tools │
└───────────────────────────────────────────┘
```

There should no longer be a permanent selected-device second pane.

The existing `DeviceDetailScreen` may remain for:

* mobile;
* compatibility/regression coverage;
* temporary fallback while implementation is in progress.

Do not delete it just because desktop no longer uses it as the primary path.

---

# 5. Add Devices Hub mode

Introduce a small presentation enum, for example:

```dart
enum DeviceHubMode {
  trusted,
  nearby,
}
```

Default:

```dart
DeviceHubMode.trusted
```

Desktop header should provide an obvious segmented switch:

```text
[ Trusted ] [ Nearby ]
```

Use the existing Rift theme.

Mode transition:

```text
~250–350 ms

fade
+
very small scale/position interpolation
```

No full-page dramatic slide.

Respect reduced motion.

---

# 6. Preserve existing device functionality

Do not lose existing behavior while removing the card-heavy desktop layout.

The new hub still needs access to:

* discovery start/stop;
* manual connection;
* pending pairing state;
* blocked peer management;
* retry/error state;
* trust revocation;
* local-device information where currently useful.

Not every one of those needs to live inside the orbit.

Low-frequency controls such as:

```text
Manual connection
Blocked devices
Pending pairing management
```

may remain as compact header actions, popovers, dialogs, or secondary management panels.

Do **not** force them into orbit nodes merely for visual consistency.

The primary orbit should stay uncluttered.

---

# 7. New reusable orbit scene

Create a focused reusable layer rather than putting all geometry directly into `TrustedDevicesScreen`.

Suggested structure:

```text
app-flutter/lib/widgets/device_hub/
    device_hub_view.dart
    device_orbit_scene.dart
    device_orbit_peer.dart
    device_orbit_layout.dart
    device_orbit_background.dart
```

Exact naming may differ.

Do not build a general physics system.

The component only needs to understand:

```text
local center device
peer nodes
orbit geometry
selection
hover/focus
orbit phase
accent/state
```

---

# 8. Orbit scene model

Keep the UI model small.

Example concept:

```dart
class OrbitPeerPresentation {
  final String deviceId;
  final String displayName;
  final String platform;

  final bool isOnline;
  final Color? accentColor;

  final OrbitPeerActivity activity;
}
```

Possible activity:

```dart
enum OrbitPeerActivity {
  none,
  mediaPaused,
  mediaPlaying,
}
```

Do not replace the repository's daemon/domain peer models.

This is presentation-only.

---

# 9. Trusted overview

Trusted mode should start with:

```text
THIS DEVICE
```

at the center.

Around it:

```text
trusted peers
```

on the orbit.

Only:

```text
trustState == trusted
```

belongs in this constellation.

Do not include:

* discovered peers;
* blocked peers;
* pairing-pending peers.

Those have separate semantics.

---

# 10. This Device core

The local device becomes the topology origin.

Display:

* appropriate platform icon;
* local display name if available;
* `This Device`.

It should visually resemble the existing Device Focus core without pretending it is a remote connection.

Suggested:

```text
      [ icon ]

    MacBook Pro
    This Device
```

Do not show an `Online` label for the local device unless it genuinely improves clarity.

---

# 11. Trusted peer orbit nodes

Create a smaller device presentation than the focused `DeviceCore`.

Each peer should show at minimum:

```text
platform icon
display name
connection state
```

Example:

```text
   ╭─────────╮
   │   💻    │
   │ Desktop │
   ╰─────────╯
```

Circular or rounded device cores are preferred over recreating the old rectangular list cards.

Online/offline remains readable by more than color alone.

Possible treatment:

```text
online:
normal opacity
connection dot/ring

offline:
reduced accent
subdued ring
"Offline" semantic/status
```

---

# 12. Deterministic orbit layout

Do not let devices jump around when peer lists refresh.

Assign stable phase ordering using stable identity.

Preferred:

```text
sort by deviceId
```

or derive a stable phase from device ID.

Never use list arrival order from discovery/network events.

Concept:

```dart
angle =
    globalOrbitAngle +
    stablePeerPhase;
```

---

# 13. One orbit first

For the expected Review 3 setup, one elliptical/circular orbit is sufficient.

Support roughly:

```text
1–8 peers
```

cleanly.

If the number is larger than the layout can reasonably display:

* shrink spacing within sensible bounds; or
* introduce a second orbit only if implementation stays simple.

Do not spend Review 3 time building arbitrary multi-ring packing.

---

# 14. Responsive orbit geometry

Use:

```dart
LayoutBuilder
```

Calculate from actual scene dimensions:

```text
scene center
orbit radius X
orbit radius Y
local core size
peer core size
```

The scene must remain safe while:

* resizing the window;
* resizing/collapsing the Rift sidebar;
* opening panels;
* changing mode.

Avoid magic coordinates tied to one demo resolution.

---

# 15. Trusted peer selection

Clicking a trusted orbit peer should **not navigate to another page**.

Instead:

```text
Trusted Overview
      ↓ click peer
freeze orbit
      ↓
Selected peer becomes focus
      ↓
existing Device Focus information/actions appear
```

The user remains inside Devices Hub.

---

# 16. Trusted focus state

Conceptually:

```text
OVERVIEW

     Peer A       Peer B

          THIS DEVICE

     Peer C       Peer D


              ↓ select Peer B


FOCUS

        [ Power ]

[Clipboard]  PEER B  [Files]

       [Security]
       [Identity]
       [Media]
       [Capabilities]
```

Reuse the components already built for Device Focus.

Do **not** rewrite all node panel/action behavior.

The current Device Focus already owns the useful concepts for Power, Clipboard, Files, Security, Identity, Capabilities, callbacks, and reduced-motion handling.

---

# 17. Refactor Device Focus only as needed

Prefer extracting/reusing its scene internals over copying 700+ lines into the new hub.

A reasonable structure:

```text
DeviceFocusView
    │
    └── DeviceFocusScene
           ├── core
           ├── nodes
           ├── connectors
           ├── panels
           └── background
```

Then:

```text
old desktop detail wrapper    → DeviceFocusScene
new Devices Hub focus state   → DeviceFocusScene
```

Alternatively, make the current widget safely embeddable if that produces a smaller diff.

Avoid a large architectural rewrite.

---

# 18. Selected peer transition

For Review 3, aim for the selected peer to feel like it becomes the focused device.

Ideal sequence:

```text
0 ms
orbit freezes at current angle

0–250 ms
other peers fade slightly
This Device fades/scales down
selected peer moves/scales toward center

~200–500 ms
focus connectors/rings emerge

~300–700 ms
capability nodes fan out
```

If moving the exact orbit widget to center becomes disproportionately complex, acceptable fallback:

```text
selected peer scales/fades
→ centered Device Focus core crossfades in
```

Do **not** build a generic Hero/shared-element framework for this sprint.

---

# 19. Exiting trusted focus

Close/back action should reverse coherently:

```text
satellite panels close
nodes fade
selected device returns to orbit
This Device returns
orbit resumes
```

When exact reverse geometry is too costly, use a restrained crossfade/scale.

Important behavior:

```text
focus close ≠ navigate away
```

It returns to Trusted overview.

---

# 20. Orbit movement

Use **one global orbit animation**.

Suggested:

```text
one revolution:
120 seconds
```

Reasonable range:

```text
90–150 seconds
```

Do not give each peer independent random movement.

All peers should feel like one constellation.

---

# 21. Orbit movement implementation

Prefer:

```dart
AnimationController(
  duration: const Duration(seconds: 120),
)..repeat();
```

Then geometry uses:

```text
controller.value × 2π
```

The animation should primarily repaint/reposition the orbit scene.

Do not call `setState()` on the complete Devices Hub sixty times per second if avoidable.

Use:

```text
AnimatedBuilder
CustomPainter
Transform.translate
```

or another isolated solution.

---

# 22. Pause orbit during interaction

Orbit movement must freeze when:

```text
pointer hovers any orbit peer
keyboard focus is inside orbit interaction
a peer is selected/focused
a pairing focus is active
reduced motion is enabled
```

Recommended behavior:

```text
hover enters
→ stop controller without resetting value

hover leaves
→ resume from same phase
```

Do not snap back to angle zero.

Multiple interaction reasons should compose correctly.

For example, if:

```text
hover ends
but peer remains focused
```

the orbit must remain paused.

A small set of pause reasons or equivalent state is preferable to scattered `.stop()` / `.repeat()` calls.

---

# 23. Tests and infinite orbit animation

Do not allow the repeating orbit controller to make:

```dart
pumpAndSettle()
```

hang forever.

Recommended architecture:

* orbit scene receives an `Animation<double>`/phase;
* production parent owns the repeating controller;
* tests can inject an `AlwaysStoppedAnimation<double>`;
* application continuous orbit may additionally be disabled under the existing test environment if needed.

This makes layout testable without coupling tests to wall-clock animation.

---

# 24. Nearby mode

Nearby uses the same visual grammar but different semantics.

Center:

```text
This Device
```

Orbit:

```text
discovered/unpaired peers only
```

Do not show trusted peers in Nearby.

Do not show blocked peers as ordinary nearby peers.

---

# 25. Nearby scene states

Support:

### Discovery active, devices found

```text
This Device
+
orbiting discovered peers
+
subtle scanning background
```

### Discovery active, no devices

```text
This Device
+
radar/scanning rings
+
"Looking for nearby devices…"
```

### Discovery disabled

```text
This Device
+
stationary/subdued scene
+
"Discovery paused"
+
[ Start Discovery ]
```

Do not show a blank white list card.

---

# 26. Nearby controls

Keep access to:

```text
Start/Stop discovery
Manual connection
```

A compact header layout is enough:

```text
Devices Hub         [Trusted][Nearby]

                    [Scan on/off] [Manual]
```

Do not overload the center device with utility buttons.

---

# 27. Nearby peer selection

Selecting a discovered peer should visually focus it.

Baseline Review 3 behavior:

```text
Nearby orbit
    ↓ click
orbit freezes
    ↓
selected nearby peer moves/becomes centered
    ↓
small pairing info/action set appears
```

At minimum show:

* display name;
* platform if available;
* address/endpoint where useful;
* Pair action.

The actual security/pairing semantics remain the existing implementation.

---

# 28. Baseline pairing behavior

Until stretch scope is reached:

```text
Nearby Focus
    ↓ Pair
existing PairingScreen / pairing flow
```

is acceptable.

Do not duplicate:

* trust establishment;
* fingerprint verification;
* accept/reject logic;
* pairing timeout/error handling.

Presentation may change.

Security logic does not.

---

# 29. Replace `Info` with Media

Remove the generic `Info` satellite from the trusted Device Focus experience.

Its important metadata can live elsewhere:

```text
connection state → center/core
last seen        → Identity or Security/Status details
status freshness → Power where relevant
```

Introduce:

```dart
DeviceFocusNodeKind.media
```

instead.

---

# 30. Media node visibility

Prefer stable layout.

If the peer advertises:

```text
media.playback
```

show a Media node even when nothing is playing.

Idle:

```text
Nothing playing
Media
```

Paused:

```text
Song Title
Paused
```

Playing:

```text
Song Title
Playing
```

This prevents the entire radial layout from rearranging every time music starts/stops.

If the peer does not advertise media playback capability:

```text
no Media node
```

---

# 31. Playback state source

Do not modify protocol or daemon.

The Flutter client already supports mirrored playback state and playback events.

The Devices Hub should:

1. call:

```text
rift.listMediaPlayback
```

on initial load/reconnect;

2. subscribe to:

```text
onMediaPlaybackPosted
onMediaPlaybackUpdated
onMediaPlaybackRemoved
```

3. maintain current playback state keyed by:

```text
sourceDeviceId + playbackId
```

4. update only affected peer presentation where practical.

Do not poll media state continuously.

---

# 32. Playback selection per device

A peer can expose multiple playback sessions.

For each device:

1. collect playback records whose:

```text
sourceDeviceId == peer.deviceId
```

2. sort by newest:

```text
updatedAt
```

3. choose the newest record whose:

```text
playbackState != stopped
```

4. if none remain:

```text
no current playback
```

This matches the deterministic rule already used by Rift's remote playback coordinator.

Paused sessions remain eligible.

---

# 33. Media panel

Expanded Media node should show available metadata:

```text
artwork
title
artist
album
application
playback state
```

Optional, only if already cheap from current record:

```text
position / duration
```

Do not implement a constantly ticking progress clock in this sprint unless the current data/event cadence makes it trivial.

Playback controls are **not required** for Review 3.

The focus here is visualization.

---

# 34. Artwork handling

Artwork is presentation data embedded in mirrored playback records.

Decode defensively.

Expected general shape may include:

```text
media type
base64 image payload
size/digest metadata
```

Never assume artwork is present.

Failure cases:

```text
missing
invalid Base64
invalid image
unsupported format
decode failure
```

must gracefully fall back to normal Rift appearance.

Do not let bad artwork break Devices Hub.

---

# 35. No new palette package

Do not add a package merely to extract album colors.

Use Flutter/Dart image APIs.

Suggested flow:

```text
artwork bytes
    ↓
decode to low-resolution image
    ↓
sample pixels
    ↓
derive representative accent
    ↓
normalize for UI
```

Keep it lightweight.

---

# 36. Palette extraction

A simple deterministic algorithm is enough.

Suggested:

1. decode image at a small size, e.g.:

```text
24×24
or
32×32
```

2. sample opaque pixels;

3. ignore:

```text
very low alpha
near-black
near-white
extremely low-saturation gray
```

where useful;

4. group/quantize similar RGB colors;

5. favor colors with useful saturation;

6. select representative accent;

7. normalize through HSL/HSLColor to sensible UI bounds.

Example target bounds:

```text
saturation: avoid completely gray
lightness: avoid too dark / too bright
```

Do not attempt sophisticated image clustering for this sprint.

---

# 37. Cache extracted colors

Artwork must not be decoded on every media update.

Cache by stable artwork identity.

Prefer:

```text
artwork sha256
```

if available.

Otherwise use another stable playback/artwork key.

Concept:

```dart
Map<String, Color> _artworkAccentCache;
```

Keep cache bounded if practical.

Eight or sixteen recent accents is more than enough.

---

# 38. Media accent scope

Album art affects only the corresponding peer's local presentation.

Allowed:

```text
peer core accent
peer orbit outline
peer glow
peer connector
Media node
subtle bloom around that peer
```

Do not recolor:

```text
Rift sidebar
global theme
entire Devices Hub
other peers
```

---

# 39. Media appearance state machine

Use a simple visual rule:

```text
NO MEDIA
normal Rift accent

PAUSED
album-derived accent
static soft glow

PLAYING
album-derived accent
soft glow
subtle continuous activity motion
```

This makes playback state readable without text.

---

# 40. Playing animation

Do not continuously pulse the entire peer bigger/smaller.

Preferred playing indication:

```text
soft glow
+
slow rotating highlight/arc around peer ring
```

Optional Media node detail:

```text
tiny restrained equalizer bars
```

Choose one or both only if visually clean.

The rotating playback highlight should be much faster than the device orbit but still restrained.

Example:

```text
4–8 second revolution
```

No blinking.

No strobe.

---

# 41. Paused state

Paused keeps:

```text
album color
static glow
```

but all playback-specific motion stops.

This creates a useful visual relationship:

```text
Playing = color + light + motion
Paused  = color + light
```

---

# 42. Track change

When title/artwork changes:

```text
old accent
    ↓
400–600 ms interpolation
    ↓
new accent
```

Artwork in the panel should crossfade.

Do not snap colors abruptly.

Use:

```text
ColorTween
AnimatedContainer
TweenAnimationBuilder
```

or equivalent.

---

# 43. Playback ends

When playback becomes:

```text
stopped
```

or is removed and no other active/paused session exists:

```text
media accent
    ↓
crossfade
    ↓
normal Rift accent
```

Media node remains available if the capability exists:

```text
Nothing playing
```

---

# 44. Playback state in Trusted overview

The playback effect should be visible **before selecting the peer**.

Example:

```text
         Pixel
     ╭──────────╮
     │   icon   │  ← album accent glow
     ╰──────────╯
       ◜     ◝      ← moving arc if playing
```

That is a major goal of this sprint.

The user should glance at the trusted constellation and see which device is actively playing media.

---

# 45. Playback state while focused

When the playback-active peer becomes focused:

* its accent carries into the center core;
* connector/rings use the media accent where appropriate;
* Media satellite reflects the current session;
* playing motion remains visible but restrained;
* paused freezes playback-specific motion.

Do not reset to default primary color just because the peer changed layouts.

---

# 46. Orbit + playback animation isolation

There may now be two continuous animations:

```text
global device orbit
playing-media ring
```

Keep them isolated.

Do not rebuild the full scene for both.

Orbit:

```text
only geometry transforms/repaint
```

Playback:

```text
only playback-active peer decoration
```

When nothing is playing and no orbit interaction is happening:

```text
only slow orbit animation exists
```

When orbit is paused and nothing is playing:

```text
continuous animation cost should approach zero
```

---

# 47. Reduced motion

When:

```dart
MediaQuery.disableAnimations == true
```

render:

```text
orbit stationary
playing peer uses album color + static glow
paused peer uses album color + static glow
track changes update without spatial animation
focus changes use immediate/short fade
```

Playing vs paused must remain distinguishable through text/icon state if motion is unavailable.

Do not depend solely on animation for semantics.

---

# 48. Hover/focus behavior

Orbit peer nodes should remain usable while moving.

On hover:

```text
orbit freezes
peer receives normal hover emphasis
```

Do not combine moving target + hover translation.

Keep hover movement tiny:

```text
~2 px
or
~1.02 scale
```

Keyboard focus also freezes the orbit.

---

# 49. Stable interaction geometry

A peer must not suddenly change orbit slot because:

* playback starts;
* playback pauses;
* battery updates;
* display name updates;
* media artwork changes.

Orbit identity is based on:

```text
deviceId
```

only.

---

# 50. Existing Device Focus actions remain functional

When a trusted peer is focused, preserve PR 2 actions:

```text
Clipboard → targeted Activity
Files → Send File
Files → View Transfers
Security → Revoke Trust
```

Do not regress peer-targeted Activity behavior while moving focus into the main scene.

The current Device Focus already exposes these action callbacks.

---

# 51. Revoke Trust behavior

From focused trusted peer:

```text
Security
→ Revoke Trust
→ existing confirmation
```

After successful revoke:

```text
focus closes
peer disappears from Trusted orbit
```

If the peer is rediscovered later:

```text
it may appear in Nearby according to existing discovery semantics
```

No special animation required for Review 3.

---

# 52. Presence changes

Trusted orbit should update in place:

```text
online → offline
offline → online
```

Do not remove trusted peers merely because they go offline.

Peer position remains stable.

Only connection styling changes.

---

# 53. Discovery changes

Nearby orbit may add/remove peers while scanning.

Use stable keys.

For newly discovered device:

```text
fade/scale into its orbit position
```

For lost nearby device:

```text
fade/scale out
```

Keep this simple.

Do not build elaborate particle effects.

---

# 54. Pairing-pending semantics

Do not accidentally treat:

```text
pairing_pending
```

as a normal trusted orbit peer.

If existing pairing produces a pending trust record, present it either:

* inside active Nearby pairing focus; or
* through compact pending management UI.

Only fully:

```text
trusted
```

peers enter Trusted orbit.

---

# 55. STRETCH — in-scene pairing

Only after core sprint completion.

Replace the ordinary pairing modal presentation on desktop with an in-scene pairing state.

Reuse existing pairing logic/state machine.

Concept:

```text
Nearby focus

          Pixel
            ◎

      Fingerprint
    XXXX-XXXX-XXXX

    [ Cancel ] [ Pair ]
```

Do not reimplement authentication logic inside the orbit widget.

---

# 56. STRETCH — pairing animation

Possible sequence:

```text
Nearby overview
      ↓
select peer
      ↓
peer moves to center
      ↓
pairing UI enters around peer
      ↓
pairing succeeds
```

Success:

```text
green/primary success ring expands once
pairing controls fade
```

Then transition to Trusted.

---

# 57. STRETCH — Nearby → Trusted migration

Desired visual story:

```text
Nearby
  ○ Pixel
     ↓ pairing succeeds
  ◎ Pixel
     ↓
peer fades/moves out of Nearby
     ↓
Trusted mode becomes active
     ↓
Pixel appears in its trusted orbit slot
     ↓
brief success bloom
```

Exact shared-element continuity is optional.

Do not build a generic overlay/hero framework under deadline.

A convincing two-stage transition is acceptable:

```text
Nearby success exit
→ mode crossfade
→ Trusted peer entry
```

The semantic continuity matters more than exact pixel tracking.

---

# 58. STRETCH — newly paired peer entry

Track:

```dart
String? recentlyPairedDeviceId;
```

or equivalent transient state.

When the Trusted orbit first renders that peer:

```text
scale ~0.8 → 1
opacity 0 → 1
one expanding connection ring
```

Then clear the transient state.

Do not continuously emphasize it.

---

# 59. Suggested state ownership

`TrustedDevicesScreen` already owns:

* trusted peers;
* discovered peers;
* discovery;
* pairing entry;
* presence updates.

Keep it as the high-level Devices Hub state owner.

Add only necessary UI state such as:

```text
hub mode
selected trusted device ID
selected nearby device ID
orbit pause/focus state
mirrored playback cache
recently paired peer ID
```

Do not introduce another state-management package.

---

# 60. Media state ownership

For this sprint, the Devices Hub may maintain its own lightweight playback map based on:

```text
listMediaPlayback
+
media playback streams
```

Do not modify platform media coordinators just to expose their private caches.

Those coordinators have different responsibilities; the Hub needs UI state.

If the implementation naturally produces a small reusable playback selector helper, that is fine.

Avoid a large new media architecture.

---

# 61. Clean up `Info`

Before deleting `DeviceFocusNodeKind.info`, audit every piece of information it exposes.

Move genuinely useful data.

Suggested:

```text
Connection status
    → core

Last seen
    → Identity panel

Status freshness
    → Power panel / appropriate status
```

Then remove:

```dart
DeviceFocusNodeKind.info
```

and its panel logic.

Do not silently lose meaningful information.

---

# 62. Accessibility

Orbit UI must remain understandable without visual motion.

Add semantics such as:

```text
"Pixel 9, trusted device, online"
"Desktop, trusted device, offline"
"MacBook, playing Blinding Lights by The Weeknd"
```

Media state must be spoken/textual:

```text
Playing
Paused
Nothing playing
```

Orbit order should not determine semantic navigation unpredictably.

Prefer stable logical ordering by peer identity/display ordering.

---

# 63. Keyboard basics

For this Review 3 sprint:

* Tab reaches mode selector;
* Tab reaches orbit peer nodes;
* Enter/Space selects;
* Escape should close trusted/nearby focus where practical;
* focus freezes orbit.

Full arrow-key spatial navigation remains a later task.

Do not expand scope into the earlier keyboard-navigation milestone.

---

# 64. Performance constraints

Avoid:

```text
setState() on entire TrustedDevicesScreen every orbit frame
palette extraction every playback update
full-resolution artwork decoding for palette extraction
multiple independent orbit controllers
random geometry every frame
animated giant blur layers
continuous whole-scene shadows
```

Prefer:

```text
one orbit controller
small decoded artwork
cached color
RepaintBoundary
AnimatedBuilder
Transform
CustomPainter
stable keys
```

---

# 65. New tests — Trusted overview

Add coverage proving:

```text
desktop Devices opens Trusted mode by default
This Device appears at center
trusted peers appear as orbit nodes
discovered peers do not appear in Trusted orbit
old desktop master/detail layout is not active
```

Use stable keys such as:

```text
device-hub-mode-trusted
device-hub-mode-nearby
device-hub-local-core
trusted-orbit-peer-<deviceId>
```

---

# 66. New tests — Trusted focus

Test:

1. render trusted overview;
2. select a trusted orbit peer;
3. pump transition;
4. verify peer focus is active;
5. verify Device Focus nodes/actions appear;
6. close focus;
7. verify Trusted overview returns.

Ensure no old route/detail page navigation occurs.

---

# 67. New tests — Nearby

Test:

```text
switch Trusted → Nearby
```

Verify:

* discovered peer appears;
* trusted peer is absent from Nearby orbit;
* local core remains;
* discovery state is represented;
* selecting discovered peer exposes Pair action.

---

# 68. New tests — orbit phase/layout

Test the geometry component with controlled orbit phases.

For example:

```text
phase 0.0
phase 0.25
```

Verify peer positions change.

Then test:

```text
same peer list + same phase
```

produces stable geometry.

Do not assert fragile exact pixels unless testing the layout helper directly.

---

# 69. New tests — orbit pause

Test conceptual pause conditions:

```text
hover
focus
trusted focus
nearby focus
reduced motion
```

Production repeating animation must not make the test suite hang.

---

# 70. New tests — media session selection

Build synthetic playback records.

Verify:

### One playing

Chosen.

### One paused

Chosen.

### Stopped

Ignored.

### Playing + paused

Most recently updated non-stopped record wins.

### Two active sessions

Newest `updatedAt` wins.

### Removed current session

Next eligible session becomes current.

### No remaining playback

Peer returns to idle media state.

---

# 71. New tests — source device isolation

Given:

```text
Peer A playback
Peer B playback
```

verify:

```text
Peer A only uses A's media
Peer B only uses B's media
```

No cross-device artwork/accent leakage.

Identity must use:

```text
sourceDeviceId
```

---

# 72. New tests — Media node

For peer with:

```text
media.playback
```

verify Media node exists.

Without current playback:

```text
Nothing playing
```

With playing:

```text
title
Playing
```

With paused:

```text
title
Paused
```

Peer without capability does not show the Media node.

---

# 73. New tests — palette extraction

Test the palette helper independently.

Use tiny deterministic test images.

Cover:

```text
solid red-ish image
solid blue-ish image
transparent image
black/white-heavy image
invalid bytes
missing artwork
```

Verify:

* no exception;
* valid image returns usable accent;
* invalid input falls back safely;
* cache works where practical.

Do not assert exact perceptual values too tightly.

---

# 74. New tests — playing/paused presentation

Do not test glow pixels.

Expose semantic/testable state.

Possible keys:

```text
orbit-peer-media-playing-<id>
orbit-peer-media-paused-<id>
device-focus-media-playing
```

Verify:

```text
playing
paused
none
```

map to the correct presentation state.

Animation internals should remain implementation detail.

---

# 75. Existing regression tests

Keep existing tests for:

* trusted peer data updates;
* peer lost;
* reconnect;
* device status;
* trust revocation;
* Clipboard action;
* File Send action;
* Transfer Activity targeting;
* reduced motion;
* mobile classic UI;
* pairing behavior;
* notification/activity routing.

Do not weaken them merely because desktop composition changed.

Adjust expected desktop widget structure where the redesign intentionally supersedes it.

---

# 76. Manual Review 3 dogfood checklist

Before calling the sprint complete, test the actual desktop app.

### Trusted

* open Devices;
* Trusted is immediately the main scene;
* This Device is centered;
* peers orbit;
* online/offline is readable;
* hover freezes orbit;
* leaving hover resumes from the same position;
* select each peer;
* focus appears in place;
* close returns to overview.

### Existing actions

From focused peer:

```text
Clipboard
Files
Security
```

exercise existing actions.

---

### Nearby

* switch to Nearby;
* start discovery;
* watch discovered peers appear;
* select a peer;
* Pair is available;
* stop discovery;
* empty/paused scene still looks intentional.

---

### Media

Use a trusted device currently playing something.

Verify:

```text
correct peer gets album accent
correct title/artist
playing animation visible
other peers unchanged
```

Pause playback:

```text
motion stops
accent/glow remains
```

Resume:

```text
activity animation resumes
```

Change track:

```text
artwork/title/accent crossfade
```

Stop playback:

```text
peer returns to Rift accent
Media says Nothing playing
```

---

### Multiple playback sessions

If practical, run two media apps on one source.

Confirm deterministic current-session selection.

---

### Resizing

Test:

* wide window;
* narrow desktop;
* sidebar expanded;
* sidebar collapsed;
* sidebar resized;
* focus open while resizing.

No overlap/overflow.

---

### Reduced motion

With reduced animation enabled:

* orbit stationary;
* mode switch usable;
* peer selection usable;
* playing/paused still understandable;
* media accent remains;
* no endlessly ticking decorative animations beyond what accessibility allows.

---

# 77. Review 3 stop conditions

Stop adding features once these work:

```text
✓ Trusted full-screen orbit
✓ trusted focus in-place
✓ Nearby orbit
✓ orbit moves + freezes appropriately
✓ Media node
✓ album-reactive peer visuals
✓ playing vs paused state
✓ existing actions still work
✓ tests pass
```

At that point **do not risk the build** to squeeze in pairing migration.

Pairing animation is bonus.

---

# 78. Explicit non-goals

Do not implement during this sprint:

* mobile orbit UI;
* vNext work;
* protocol changes;
* daemon changes for UI purposes;
* new media protocol;
* new playback controls;
* global album-art theming;
* radial blocked devices;
* radial pending-pairing management unless required by stretch pairing;
* arbitrary multi-ring physics;
* drag-and-drop file sending;
* spatial arrow-key navigation;
* file transfer progress animation;
* operation connector pulses;
* true card/core Hero framework;
* app-wide motion cleanup;
* huge design-system refactor.

Those belong to the post-Review-3 roadmap.

---

# 79. Recommended implementation sequence

### Stage 1 — New desktop shell

1. Add `DeviceHubMode`.
2. Replace desktop master/detail composition.
3. Add Trusted/Nearby mode control.
4. Keep mobile branch untouched.
5. Preserve secondary management controls.

**Checkpoint:** app runs with static Trusted scene.

---

### Stage 2 — Trusted orbit

1. Add orbit layout.
2. Add local center core.
3. Add trusted peer orbit nodes.
4. Stable peer phases.
5. Online/offline presentation.
6. Responsive geometry.

**Checkpoint:** Trusted constellation is usable but stationary.

---

### Stage 3 — Trusted focus in place

1. Add selection state.
2. Freeze orbit.
3. Transition selected peer toward focus.
4. Reuse/extract Device Focus scene.
5. Preserve Clipboard/File/Security actions.
6. Exit focus back to overview.

**Checkpoint:** no more desktop second page.

---

### Stage 4 — Nearby

1. Reuse orbit scene.
2. Render discovered peers.
3. Discovery active/idle empty states.
4. Add Pair-focused state.
5. Keep existing pairing implementation.

**Checkpoint:** both main Devices modes work.

---

### Stage 5 — Orbit motion

1. Add global phase controller.
2. 90–150 second period.
3. Pause on hover.
4. Pause on keyboard focus.
5. Pause while peer-focused.
6. Disable motion for reduced-motion.
7. Keep widget tests deterministic.

**Checkpoint:** constellation feels alive but remains usable.

---

### Stage 6 — Media

1. Replace `Info` with `Media`.
2. Add playback state map.
3. Initial `listMediaPlayback`.
4. Subscribe to posted/updated/removed.
5. Select newest non-stopped playback per peer.
6. Render Media panel/state.
7. Add artwork handling.
8. Add cached palette extraction.
9. Apply peer-local accent.
10. Add playing ring/highlight motion.
11. Paused = static glow.
12. Track/end transitions.

**Checkpoint:** Review 3 primary scope complete.

---

### Stage 7 — STRETCH pairing choreography

Only now:

1. embed pairing presentation into Nearby focus;
2. success animation;
3. switch to Trusted;
4. animate newly trusted peer into orbit;
5. success bloom.

Do not compromise Stage 1–6 stability to complete this.

---

# 80. Validation

Run targeted tests continuously.

Before completion:

```bash
dart format --output=none --set-exit-if-changed app-flutter/lib app-flutter/test
```

Then:

```bash
tools/verify.sh app-flutter
```

from repository root.

Inspect focused failures in:

```text
logs/agent/
```

Do not dump full verification logs into the conversation.

---

# 81. Definition of done — primary scope

The Review 3 implementation is complete when:

* [x] Desktop Devices Hub no longer uses the old permanent master/detail layout.
* [x] Trusted is the default Devices mode.
* [x] Nearby is a separate mode.
* [x] This Device is the center of both overview scenes.
* [x] Trusted peers orbit the local device.
* [x] Nearby/discovered peers use a separate orbit.
* [x] Trusted and nearby devices never mix into one cluttered constellation.
* [x] Orbit placement is stable by device identity.
* [x] Orbit moves slowly as one coherent constellation.
* [x] Orbit pauses during pointer/keyboard interaction.
* [x] Orbit pauses while a peer is focused.
* [x] Reduced-motion renders a stationary scene.
* [x] Selecting a trusted peer focuses it **inside the same Devices screen**.
* [x] Existing Device Focus capability/action functionality survives.
* [x] Closing peer focus returns to Trusted overview.
* [x] Selecting a nearby peer presents pairing action in-place.
* [x] Existing pairing semantics still work.
* [x] Generic `Info` node is removed/replaced.
* [x] Media node uses mirrored playback state.
* [x] Multiple playback sessions use newest non-stopped selection.
* [ ] Playing media applies album-derived peer-local accent.
* [ ] Playing state has subtle continuous playback motion.
* [ ] Paused state retains accent/glow but removes playback motion.
* [ ] No playback returns to ordinary Rift accent.
* [ ] Track changes animate rather than snap.
* [ ] Invalid/missing artwork safely falls back.
* [ ] Palette results are cached.
* [ ] Global Rift theme is never recolored from album art.
* [x] Existing mobile Devices behavior remains usable.
* [x] Existing Activity/File/Clipboard actions remain functional.
* [x] No protocol/daemon changes are required.
* [x] Relevant widget/unit tests pass.
* [x] `tools/verify.sh app-flutter` passes.
* [ ] Manual desktop dogfood shows no major overflow, interaction, or obvious CPU regressions.

---

# 82. Stretch definition of done

Only if time permits:

* [ ] Desktop pairing presentation remains inside Nearby orbit scene.
* [ ] Pairing success receives a brief one-shot animation.
* [ ] Successful peer leaves Nearby presentation.
* [ ] Hub transitions automatically to Trusted.
* [ ] Newly trusted peer visibly enters its trusted orbit slot.
* [ ] No authentication/pairing logic was duplicated.
* [ ] Failure/cancel paths return cleanly to Nearby.

---

# 83. Agent completion report

When finished, report:

### Implemented

State which of these stages completed:

```text
1 Desktop shell
2 Trusted orbit
3 Trusted focus
4 Nearby orbit
5 Orbit motion
6 Media visuals
7 Pairing choreography
```

### Deferred

Explicitly list unfinished stretch work.

### Media behavior

Document:

* current-session selection rule;
* artwork fallback behavior;
* palette extraction approach;
* playing vs paused visuals.

### Performance

Describe:

* how orbit animation is isolated;
* how palette extraction is cached;
* whether any sustained idle CPU concern was observed.

### Tests

List targeted tests and final:

```text
tools/verify.sh app-flutter
```

result.

### Manual verification

Record actual desktop scenarios exercised.
