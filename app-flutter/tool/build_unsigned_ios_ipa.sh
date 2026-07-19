#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IPA_DIR="$ROOT_DIR/build/ios/ipa"
APP_PATH="$ROOT_DIR/build/ios/iphoneos/Runner.app"
IPA_PATH="$IPA_DIR/Runner-unsigned-release.ipa"
DEV_BACKGROUND_LOCATION="${RIFT_DEV_BACKGROUND_LOCATION:-0}"

if [[ "$DEV_BACKGROUND_LOCATION" != "0" && "$DEV_BACKGROUND_LOCATION" != "1" ]]; then
  printf 'RIFT_DEV_BACKGROUND_LOCATION must be 0 or 1.\n' >&2
  exit 2
fi

cd "$ROOT_DIR"

flutter build ios --release --no-codesign

if [[ "$DEV_BACKGROUND_LOCATION" == "1" ]]; then
  python3 - "$APP_PATH/Info.plist" <<'PY'
import plistlib
import sys

path = sys.argv[1]
with open(path, 'rb') as source:
    plist = plistlib.load(source)

background_modes = list(plist.get('UIBackgroundModes', []))
if 'location' not in background_modes:
    background_modes.append('location')
plist['UIBackgroundModes'] = background_modes
plist['RiftDevBackgroundLocationEnabled'] = True
plist['NSLocationWhenInUseUsageDescription'] = (
    'Development builds use location updates to keep nearby-device connections active while Rift is backgrounded.'
)
plist['NSLocationAlwaysAndWhenInUseUsageDescription'] = (
    'Development builds use location updates to keep nearby-device connections active while Rift is backgrounded.'
)

with open(path, 'wb') as destination:
    plistlib.dump(plist, destination, fmt=plistlib.FMT_BINARY)
PY
  printf 'Enabled development background-location keepalive.\n'
fi

rm -rf "$IPA_DIR"
mkdir -p "$IPA_DIR/Payload"
cp -R "$APP_PATH" "$IPA_DIR/Payload/"

(
  cd "$IPA_DIR"
  zip -r -y "$(basename "$IPA_PATH")" Payload >/dev/null
)

python3 - "$IPA_PATH" "$DEV_BACKGROUND_LOCATION" <<'PY'
import plistlib
import sys
import zipfile

ipa_path = sys.argv[1]
keepalive_enabled = sys.argv[2] == '1'

with zipfile.ZipFile(ipa_path) as archive:
    info_plist_paths = [
        name
        for name in archive.namelist()
        if name.startswith('Payload/') and name.endswith('.app/Info.plist')
    ]
    if len(info_plist_paths) != 1:
        raise SystemExit(
            f'Expected one app Info.plist in IPA, found {len(info_plist_paths)}.'
        )
    plist = plistlib.loads(archive.read(info_plist_paths[0]))

location_usage_keys = (
    'NSLocationWhenInUseUsageDescription',
    'NSLocationAlwaysAndWhenInUseUsageDescription',
)
background_modes = plist.get('UIBackgroundModes', [])

if keepalive_enabled:
    missing = [key for key in location_usage_keys if not plist.get(key)]
    if plist.get('RiftDevBackgroundLocationEnabled') is not True:
        missing.append('RiftDevBackgroundLocationEnabled=true')
    if 'location' not in background_modes:
        missing.append('UIBackgroundModes=location')
    if missing:
        raise SystemExit(
            'Development keepalive IPA is missing required metadata: '
            + ', '.join(missing)
        )
    print('Verified development keepalive metadata in IPA.')
else:
    unexpected = [key for key in location_usage_keys if key in plist]
    if 'RiftDevBackgroundLocationEnabled' in plist:
        unexpected.append('RiftDevBackgroundLocationEnabled')
    if 'location' in background_modes:
        unexpected.append('UIBackgroundModes=location')
    if unexpected:
        raise SystemExit(
            'Normal IPA contains development location metadata: '
            + ', '.join(unexpected)
        )
    print('Verified normal IPA contains no development location metadata.')
PY

printf 'Built unsigned IPA: %s\n' "$IPA_PATH"
shasum -a 256 "$IPA_PATH"
