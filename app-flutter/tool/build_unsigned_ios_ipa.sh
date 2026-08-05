#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IPA_DIR="$ROOT_DIR/build/ios/ipa"
APP_PATH="$ROOT_DIR/build/ios/iphoneos/Runner.app"
IPA_PATH="$IPA_DIR/Runner-unsigned-release.ipa"
DEV_BACKGROUND_LOCATION="${RIFT_DEV_BACKGROUND_LOCATION:-0}"
DEV_REMOTE_MEDIA_SESSION="${RIFT_DEV_REMOTE_MEDIA_SESSION:-0}"
DEV_PRIVATE_DEVICE_NAME="${RIFT_DEV_PRIVATE_DEVICE_NAME:-0}"
IOS_BUILD_NUMBER="${RIFT_IOS_BUILD_NUMBER:-}"

if [[ "$DEV_BACKGROUND_LOCATION" != "0" && "$DEV_BACKGROUND_LOCATION" != "1" ]]; then
  printf 'RIFT_DEV_BACKGROUND_LOCATION must be 0 or 1.\n' >&2
  exit 2
fi
if [[ "$DEV_REMOTE_MEDIA_SESSION" != "0" && "$DEV_REMOTE_MEDIA_SESSION" != "1" ]]; then
  printf 'RIFT_DEV_REMOTE_MEDIA_SESSION must be 0 or 1.\n' >&2
  exit 2
fi
if [[ "$DEV_PRIVATE_DEVICE_NAME" != "0" && "$DEV_PRIVATE_DEVICE_NAME" != "1" ]]; then
  printf 'RIFT_DEV_PRIVATE_DEVICE_NAME must be 0 or 1.\n' >&2
  exit 2
fi
if [[ "$DEV_REMOTE_MEDIA_SESSION" == "1" && "$DEV_BACKGROUND_LOCATION" != "1" ]]; then
  printf 'RIFT_DEV_REMOTE_MEDIA_SESSION=1 requires RIFT_DEV_BACKGROUND_LOCATION=1.\n' >&2
  exit 2
fi
if [[ -n "$IOS_BUILD_NUMBER" && ! "$IOS_BUILD_NUMBER" =~ ^[0-9]+([.][0-9]+){0,2}$ ]]; then
  printf 'RIFT_IOS_BUILD_NUMBER must contain one to three numeric components.\n' >&2
  exit 2
fi

cd "$ROOT_DIR"

BUILD_ARGS=(ios --release --no-codesign)
if [[ -n "$IOS_BUILD_NUMBER" ]]; then
  BUILD_ARGS+=(--build-number="$IOS_BUILD_NUMBER")
fi
if [[ "$DEV_PRIVATE_DEVICE_NAME" == "1" ]]; then
  PRIVATE_DERIVED_DATA="$ROOT_DIR/build/ios/private-derived-$(date +%Y%m%d-%H%M%S)"
  flutter build "${BUILD_ARGS[@]}" --config-only
  xcodebuild \
    -workspace ios/Runner.xcworkspace \
    -scheme Runner \
    -configuration Release \
    -sdk iphoneos \
    -destination 'generic/platform=iOS' \
    -derivedDataPath "$PRIVATE_DERIVED_DATA" \
    CODE_SIGNING_ALLOWED=NO \
    CODE_SIGNING_REQUIRED=NO \
    CODE_SIGN_IDENTITY='' \
    SWIFT_ACTIVE_COMPILATION_CONDITIONS='$(inherited) RIFT_PRIVATE_API' \
    build
  APP_PATH="$PRIVATE_DERIVED_DATA/Build/Products/Release-iphoneos/Runner.app"
else
  flutter build "${BUILD_ARGS[@]}"
fi

if [[ "$DEV_BACKGROUND_LOCATION" == "1" ]]; then
  python3 - "$APP_PATH/Info.plist" "$DEV_REMOTE_MEDIA_SESSION" <<'PY'
import plistlib
import sys

path = sys.argv[1]
remote_media_session_enabled = sys.argv[2] == '1'
with open(path, 'rb') as source:
    plist = plistlib.load(source)

background_modes = list(plist.get('UIBackgroundModes', []))
if 'location' not in background_modes:
    background_modes.append('location')
if remote_media_session_enabled and 'audio' not in background_modes:
    background_modes.append('audio')
plist['UIBackgroundModes'] = background_modes
plist['RiftDevBackgroundLocationEnabled'] = True
if remote_media_session_enabled:
    plist['RiftDevRemoteMediaSessionEnabled'] = True
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
  if [[ "$DEV_REMOTE_MEDIA_SESSION" == "1" ]]; then
    printf 'Enabled development silent remote media session.\n'
  fi
fi

if [[ "$DEV_PRIVATE_DEVICE_NAME" == "1" ]]; then
  python3 - "$APP_PATH/Info.plist" <<'PY'
import plistlib
import sys

path = sys.argv[1]
with open(path, 'rb') as source:
    plist = plistlib.load(source)
plist['RiftDevPrivateDeviceNameEnabled'] = True
with open(path, 'wb') as destination:
    plistlib.dump(plist, destination, fmt=plistlib.FMT_BINARY)
PY
  if ! strings "$APP_PATH/Runner" | grep -F 'UserAssignedDeviceName' >/dev/null; then
    printf 'Private iOS device-name code was not compiled into Runner.\n' >&2
    exit 1
  fi
  printf 'Enabled private MobileGestalt device-name lookup.\n'
else
  if strings "$APP_PATH/Runner" | grep -F 'UserAssignedDeviceName' >/dev/null; then
    printf 'Normal iOS build unexpectedly contains private device-name code.\n' >&2
    exit 1
  fi
fi

rm -rf "$IPA_DIR"
mkdir -p "$IPA_DIR/Payload"
cp -R "$APP_PATH" "$IPA_DIR/Payload/"

(
  cd "$IPA_DIR"
  zip -r -y "$(basename "$IPA_PATH")" Payload >/dev/null
)

python3 - "$IPA_PATH" "$DEV_BACKGROUND_LOCATION" "$DEV_REMOTE_MEDIA_SESSION" "$DEV_PRIVATE_DEVICE_NAME" "$IOS_BUILD_NUMBER" <<'PY'
import plistlib
import sys
import zipfile

ipa_path = sys.argv[1]
keepalive_enabled = sys.argv[2] == '1'
remote_media_session_enabled = sys.argv[3] == '1'
private_device_name_enabled = sys.argv[4] == '1'
expected_build_number = sys.argv[5]

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

if expected_build_number and plist.get('CFBundleVersion') != expected_build_number:
    raise SystemExit(
        'IPA build number mismatch: expected '
        f'{expected_build_number}, found {plist.get("CFBundleVersion", "missing")}.'
    )
if expected_build_number:
    print(f'Verified IPA build number {expected_build_number}.')

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

if remote_media_session_enabled:
    missing = []
    if plist.get('RiftDevRemoteMediaSessionEnabled') is not True:
        missing.append('RiftDevRemoteMediaSessionEnabled=true')
    if 'audio' not in background_modes:
        missing.append('UIBackgroundModes=audio')
    if missing:
        raise SystemExit(
            'Development remote media IPA is missing required metadata: '
            + ', '.join(missing)
        )
    print('Verified development remote media session metadata in IPA.')
else:
    unexpected = []
    if 'RiftDevRemoteMediaSessionEnabled' in plist:
        unexpected.append('RiftDevRemoteMediaSessionEnabled')
    if 'audio' in background_modes:
        unexpected.append('UIBackgroundModes=audio')
    if unexpected:
        raise SystemExit(
            'IPA contains development remote media metadata while disabled: '
            + ', '.join(unexpected)
        )

if private_device_name_enabled:
    if plist.get('RiftDevPrivateDeviceNameEnabled') is not True:
        raise SystemExit(
            'Private device-name IPA is missing '
            'RiftDevPrivateDeviceNameEnabled=true.'
        )
    print('Verified private MobileGestalt device-name metadata in IPA.')
elif 'RiftDevPrivateDeviceNameEnabled' in plist:
    raise SystemExit(
        'Normal IPA contains RiftDevPrivateDeviceNameEnabled.'
    )
PY

printf 'Built unsigned IPA: %s\n' "$IPA_PATH"
shasum -a 256 "$IPA_PATH"
