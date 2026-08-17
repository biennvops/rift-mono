#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
project="$repo_root/daemon-cs/Rift.NotificationExtractor.macOS/Rift.NotificationExtractor.macOS.csproj"
project_dir="$repo_root/daemon-cs/Rift.NotificationExtractor.macOS"
info_plist="$project_dir/Resources/RiftNotificationExtractor.Info.plist"
native_dir="$project_dir/Native"
private_notification_actions="${RIFT_DEV_PRIVATE_MACOS_NOTIFICATION_ACTIONS:-0}"
accessibility_notification_actions="${RIFT_MACOS_ACCESSIBILITY_NOTIFICATION_ACTIONS:-0}"

if [[ "$private_notification_actions" != "0" && "$private_notification_actions" != "1" ]]; then
  printf 'RIFT_DEV_PRIVATE_MACOS_NOTIFICATION_ACTIONS must be 0 or 1.\n' >&2
  exit 2
fi
if [[ "$accessibility_notification_actions" != "0" && "$accessibility_notification_actions" != "1" ]]; then
  printf 'RIFT_MACOS_ACCESSIBILITY_NOTIFICATION_ACTIONS must be 0 or 1.\n' >&2
  exit 2
fi
if [[ "$private_notification_actions" == "1" && "$accessibility_notification_actions" == "1" ]]; then
  printf 'Private and Accessibility notification-action flavors are mutually exclusive.\n' >&2
  exit 2
fi

runtime="${1:-}"
if [[ -z "$runtime" ]]; then
  if [[ "$(uname -m)" == "arm64" ]]; then
    runtime="osx-arm64"
  else
    runtime="osx-x64"
  fi
fi

out_root="$repo_root/dist/macos"
mkdir -p "$out_root"
publish_dir="$(mktemp -d "$out_root/notification-extractor-publish-$runtime.XXXXXX")"
trap 'rm -rf "$publish_dir"' EXIT
app_dir="$out_root/Rift Notification Extractor.app"
broker="$app_dir/Contents/MacOS/rift-notification-extractor"
worker="$app_dir/Contents/Helpers/rift-notification-extractor-worker"

if [[ -e "$app_dir" ]]; then
  echo "ERROR: '$app_dir' already exists; move or remove it before rebuilding." >&2
  exit 1
fi

mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Helpers"
cp "$info_plist" "$app_dir/Contents/Info.plist"

swift_args=(
  "$native_dir/XpcProtocol.swift"
  "$native_dir/PrivateNotificationActions.swift"
  "$native_dir/AccessibilityNotificationActions.swift"
  "$native_dir/NotificationActionRequestHandler.swift"
  "$native_dir/XpcBroker.swift"
  -framework Foundation
)
if [[ "$private_notification_actions" == "1" ]]; then
  swift_args+=(
    -D RIFT_PRIVATE_API
    -D RIFT_PRIVATE_NOTIFICATION_ACTIONS
  )
  plutil -insert RiftDevPrivateNotificationActionsEnabled -bool true "$app_dir/Contents/Info.plist"
fi
if [[ "$accessibility_notification_actions" == "1" ]]; then
  swift_args+=(
    -D RIFT_ACCESSIBILITY_NOTIFICATION_ACTIONS
    -framework ApplicationServices
    -framework AppKit
  )
  plutil -insert RiftAccessibilityNotificationActionsEnabled -bool true "$app_dir/Contents/Info.plist"
fi

dotnet publish "$project" -c Release -r "$runtime" --self-contained true -o "$publish_dir"
cp -R "$publish_dir/"* "$app_dir/Contents/Helpers/"

published_worker="$app_dir/Contents/Helpers/rift-notification-extractor"
if [[ ! -x "$published_worker" ]]; then
  echo "ERROR: publish did not produce the expected worker executable." >&2
  exit 1
fi
mv "$published_worker" "$worker"

xcrun swiftc "${swift_args[@]}" -o "$broker"

if [[ -n "${RIFT_CODESIGN_IDENTITY:-}" ]]; then
  codesign_identity="$RIFT_CODESIGN_IDENTITY"
elif /usr/bin/security find-identity -v -p codesigning "$HOME/Library/Keychains/login.keychain-db" 2>/dev/null | grep -Fq '"Rift Development Code Signing"'; then
  codesign_identity="Rift Development Code Signing"
else
  echo "ERROR: a certificate-backed code-signing identity is required." >&2
  echo "Run daemon-cs/Tools/setup_rift_dev_signing.sh for local development." >&2
  exit 1
fi
if ! deep_sign_output="$(
  codesign --force --deep --sign "$codesign_identity" --identifier com.rift.notification-extractor "$app_dir" 2>&1
)"; then
  printf '%s\n' "$deep_sign_output" >&2
  exit 1
fi
codesign --force --sign "$codesign_identity" --identifier com.rift.notification-extractor.worker "$worker"
codesign --force --sign "$codesign_identity" --identifier com.rift.notification-extractor "$app_dir"

broker_identifier="$(codesign -dvv "$broker" 2>&1 | awk -F= '$1 == "Identifier" && !found { print $2; found = 1 }')"
worker_identifier="$(codesign -dvv "$worker" 2>&1 | awk -F= '$1 == "Identifier" && !found { print $2; found = 1 }')"
if [[ "$broker_identifier" != "com.rift.notification-extractor" || "$worker_identifier" != "com.rift.notification-extractor.worker" ]]; then
  echo "ERROR: signed bundle identifiers are incorrect." >&2
  echo "Broker: $broker_identifier" >&2
  echo "Worker: $worker_identifier" >&2
  exit 1
fi
codesign --verify --deep --strict "$app_dir"

contains_private_sentinel() {
  /usr/bin/strings "$broker" | awk '
    index($0, "RIFT_PRIVATE_NOTIFICATION_ACTIONS_V1") { found = 1 }
    END { exit(found ? 0 : 1) }
  '
}

contains_accessibility_sentinel() {
  /usr/bin/strings "$broker" | awk '
    index($0, "RIFT_ACCESSIBILITY_NOTIFICATION_ACTIONS_V1") { found = 1 }
    END { exit(found ? 0 : 1) }
  '
}

if [[ "$private_notification_actions" == "1" ]]; then
  marker="$(plutil -extract RiftDevPrivateNotificationActionsEnabled raw "$app_dir/Contents/Info.plist")"
  if [[ "$marker" != "true" ]]; then
    printf 'ERROR: private notification-action bundle marker is missing.\n' >&2
    exit 1
  fi
  if ! contains_private_sentinel; then
    printf 'ERROR: private notification-action code was not compiled into the broker.\n' >&2
    exit 1
  fi
else
  if plutil -extract RiftDevPrivateNotificationActionsEnabled raw "$app_dir/Contents/Info.plist" >/dev/null 2>&1; then
    printf 'ERROR: normal extractor build contains the private notification-action marker.\n' >&2
    exit 1
  fi
  if contains_private_sentinel; then
    printf 'ERROR: normal extractor build contains private notification-action code.\n' >&2
    exit 1
  fi
fi

if [[ "$accessibility_notification_actions" == "1" ]]; then
  marker="$(plutil -extract RiftAccessibilityNotificationActionsEnabled raw "$app_dir/Contents/Info.plist")"
  if [[ "$marker" != "true" ]]; then
    printf 'ERROR: Accessibility notification-action bundle marker is missing.\n' >&2
    exit 1
  fi
  if ! contains_accessibility_sentinel; then
    printf 'ERROR: Accessibility notification-action code was not compiled into the broker.\n' >&2
    exit 1
  fi
else
  if plutil -extract RiftAccessibilityNotificationActionsEnabled raw "$app_dir/Contents/Info.plist" >/dev/null 2>&1; then
    printf 'ERROR: extractor build contains an unexpected Accessibility notification-action marker.\n' >&2
    exit 1
  fi
  if contains_accessibility_sentinel; then
    printf 'ERROR: extractor build contains unexpected Accessibility notification-action code.\n' >&2
    exit 1
  fi
fi

echo "Built: $app_dir"
if [[ "$private_notification_actions" == "1" ]]; then
  echo "Enabled development-only private notification-action probes."
fi
if [[ "$accessibility_notification_actions" == "1" ]]; then
  echo "Enabled optional Accessibility notification actions."
fi
echo "Install the extractor LaunchAgent before using the Mach service."
echo "Grant this app Full Disk Access after installing it at its stable path."
if [[ "$accessibility_notification_actions" == "1" ]]; then
  echo "Grant this app Accessibility only through an explicit user choice."
fi
