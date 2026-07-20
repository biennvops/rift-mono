#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
project="$repo_root/daemon-cs/Rift.NotificationExtractor.macOS/Rift.NotificationExtractor.macOS.csproj"
info_plist="$repo_root/daemon-cs/Rift.NotificationExtractor.macOS/Resources/RiftNotificationExtractor.Info.plist"

runtime="${1:-}"
if [[ -z "$runtime" ]]; then
  if [[ "$(uname -m)" == "arm64" ]]; then
    runtime="osx-arm64"
  else
    runtime="osx-x64"
  fi
fi

out_root="$repo_root/dist/macos"
publish_dir="$out_root/notification-extractor-publish-$runtime"
app_dir="$out_root/Rift Notification Extractor.app"
executable="$app_dir/Contents/MacOS/rift-notification-extractor"

if [[ -e "$app_dir" ]]; then
  echo "ERROR: '$app_dir' already exists; move or remove it before rebuilding." >&2
  exit 1
fi

mkdir -p "$app_dir/Contents/MacOS"
cp "$info_plist" "$app_dir/Contents/Info.plist"

dotnet publish "$project" -c Release -r "$runtime" --self-contained true -o "$publish_dir"
cp -R "$publish_dir/"* "$app_dir/Contents/MacOS/"

if [[ ! -x "$executable" ]]; then
  echo "ERROR: publish did not produce the expected executable." >&2
  exit 1
fi

codesign_identity="${RIFT_CODESIGN_IDENTITY:--}"
codesign --force --deep --sign "$codesign_identity" --identifier com.rift.notification-extractor "$app_dir"
codesign --verify --deep --strict --verbose=2 "$app_dir"

echo "Built: $app_dir"
echo "Grant this app Full Disk Access before running getStatus or scan operations."
