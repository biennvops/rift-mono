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

printf 'Built unsigned IPA: %s\n' "$IPA_PATH"
shasum -a 256 "$IPA_PATH"
