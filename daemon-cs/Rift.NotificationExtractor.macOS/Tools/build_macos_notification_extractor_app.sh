#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
project="$repo_root/daemon-cs/Rift.NotificationExtractor.macOS/Rift.NotificationExtractor.macOS.csproj"
project_dir="$repo_root/daemon-cs/Rift.NotificationExtractor.macOS"
info_plist="$project_dir/Resources/RiftNotificationExtractor.Info.plist"
native_dir="$project_dir/Native"

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

dotnet publish "$project" -c Release -r "$runtime" --self-contained true -o "$publish_dir"
cp -R "$publish_dir/"* "$app_dir/Contents/Helpers/"

published_worker="$app_dir/Contents/Helpers/rift-notification-extractor"
if [[ ! -x "$published_worker" ]]; then
  echo "ERROR: publish did not produce the expected worker executable." >&2
  exit 1
fi
mv "$published_worker" "$worker"

xcrun swiftc \
  "$native_dir/XpcProtocol.swift" \
  "$native_dir/XpcBroker.swift" \
  -framework Foundation \
  -o "$broker"

if [[ -n "${RIFT_CODESIGN_IDENTITY:-}" ]]; then
  codesign_identity="$RIFT_CODESIGN_IDENTITY"
elif /usr/bin/security find-identity -v -p codesigning "$HOME/Library/Keychains/login.keychain-db" 2>/dev/null | grep -Fq '"Rift Development Code Signing"'; then
  codesign_identity="Rift Development Code Signing"
else
  echo "ERROR: a certificate-backed code-signing identity is required." >&2
  echo "Run daemon-cs/Tools/setup_rift_dev_signing.sh for local development." >&2
  exit 1
fi
codesign --force --sign "$codesign_identity" --identifier com.rift.notification-extractor.worker "$worker"
codesign --force --sign "$codesign_identity" --identifier com.rift.notification-extractor "$app_dir"

broker_identifier="$(codesign -dvv "$broker" 2>&1 | awk -F= '$1 == "Identifier" { print $2; exit }')"
worker_identifier="$(codesign -dvv "$worker" 2>&1 | awk -F= '$1 == "Identifier" { print $2; exit }')"
if [[ "$broker_identifier" != "com.rift.notification-extractor" || "$worker_identifier" != "com.rift.notification-extractor.worker" ]]; then
  echo "ERROR: signed bundle identifiers are incorrect." >&2
  echo "Broker: $broker_identifier" >&2
  echo "Worker: $worker_identifier" >&2
  exit 1
fi
codesign --verify --deep --strict --verbose=2 "$app_dir"

echo "Built: $app_dir"
echo "Install the extractor LaunchAgent before using the Mach service."
echo "Grant this app Full Disk Access after installing it at its stable path."
