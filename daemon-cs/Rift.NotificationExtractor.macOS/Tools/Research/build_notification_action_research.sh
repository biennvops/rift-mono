#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
source_dir="$repo_root/daemon-cs/Rift.NotificationExtractor.macOS/Tools/Research"
out_root="$repo_root/dist/macos/notification-action-research"

if [[ -n "${RIFT_CODESIGN_IDENTITY:-}" ]]; then
  codesign_identity="$RIFT_CODESIGN_IDENTITY"
elif /usr/bin/security find-identity -v -p codesigning "$HOME/Library/Keychains/login.keychain-db" 2>/dev/null | grep -Fq '"Rift Development Code Signing"'; then
  codesign_identity="Rift Development Code Signing"
else
  printf 'A certificate-backed code-signing identity is required.\n' >&2
  exit 1
fi

mkdir -p "$out_root"

build_app() {
  local name="$1"
  local identifier="$2"
  local source="$3"
  shift 3
  local app="$out_root/$name.app"
  local executable="$app/Contents/MacOS/$name"

  if [[ -e "$app" ]]; then
    printf 'Refusing to overwrite existing research app: %s\n' "$app" >&2
    exit 1
  fi
  mkdir -p "$app/Contents/MacOS"
  plutil -create xml1 "$app/Contents/Info.plist"
  plutil -insert CFBundleExecutable -string "$name" "$app/Contents/Info.plist"
  plutil -insert CFBundleIdentifier -string "$identifier" "$app/Contents/Info.plist"
  plutil -insert CFBundleName -string "$name" "$app/Contents/Info.plist"
  plutil -insert CFBundlePackageType -string APPL "$app/Contents/Info.plist"
  plutil -insert CFBundleShortVersionString -string 1.0 "$app/Contents/Info.plist"
  plutil -insert CFBundleVersion -string 1 "$app/Contents/Info.plist"
  xcrun swiftc -parse-as-library "$source" "$@" -o "$executable"
  codesign --force --sign "$codesign_identity" --identifier "$identifier" "$app"
}

build_app \
  "Rift Notification AX Research" \
  com.rift.notification-actions-research \
  "$source_dir/AccessibilityProbe.swift" \
  -framework ApplicationServices \
  -framework AppKit

for suffix in A B; do
  lower_suffix="$(printf '%s' "$suffix" | tr '[:upper:]' '[:lower:]')"
  build_app \
    "Rift Synthetic Notifications $suffix" \
    "com.rift.notification-research.$lower_suffix" \
    "$source_dir/SyntheticNotificationApp.swift" \
    -framework UserNotifications
done

xcrun swiftc \
  -parse-as-library \
  "$source_dir/PrivateRuntimeProbe.swift" \
  -framework Foundation \
  -framework Security \
  -o "$out_root/rift-private-notification-runtime-probe"
codesign \
  --force \
  --sign "$codesign_identity" \
  --identifier com.rift.private-notification-runtime-research \
  "$out_root/rift-private-notification-runtime-probe"

printf 'Built research tools under %s\n' "$out_root"
