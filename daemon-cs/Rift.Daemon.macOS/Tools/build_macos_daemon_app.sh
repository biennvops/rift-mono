#!/usr/bin/env bash
set -euo pipefail

# This script lives at: daemon-cs/Rift.Daemon.macOS/Tools/*.sh
# We want repo root: <repo>/ (not <repo>/daemon-cs).
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
project="$repo_root/daemon-cs/Rift.Daemon.macOS/Rift.Daemon.macOS.csproj"
xpc_native_dir="$repo_root/daemon-cs/Rift.NotificationExtractor.macOS/Native"

runtime="${1:-}"
if [[ -z "$runtime" ]]; then
  # Default to the current machine architecture.
  arch="$(uname -m)"
  if [[ "$arch" == "arm64" ]]; then
    runtime="osx-arm64"
  else
    runtime="osx-x64"
  fi
fi

out_root="$repo_root/dist/macos"
publish_dir="$out_root/publish-$runtime"
app_dir="$out_root/Rift Daemon.app"

echo "Publishing $project ($runtime) -> $publish_dir"
dotnet publish "$project" -c Release -r "$runtime" --self-contained true -o "$publish_dir"

echo "Assembling app bundle -> $app_dir"
rm -rf "$app_dir"

codesign_identity="${RIFT_CODESIGN_IDENTITY:--}"
codesign --force --sign "$codesign_identity" --identifier com.rift.daemon "$publish_dir/Rift.Daemon.macOS"
mkdir -p "$app_dir/Contents/MacOS"

cp "$repo_root/daemon-cs/Rift.Daemon.macOS/Resources/RiftDaemon.Info.plist" \
  "$app_dir/Contents/Info.plist"

# Copy the full publish output and provide a stable launcher name.
# Self-contained publish produces a native executable we can run without `dotnet`.
cp -R "$publish_dir/"* "$app_dir/Contents/MacOS/"

if [[ -f "$app_dir/Contents/MacOS/Rift.Daemon.macOS" ]]; then
  mv "$app_dir/Contents/MacOS/Rift.Daemon.macOS" "$app_dir/Contents/MacOS/rift-daemon"
  chmod +x "$app_dir/Contents/MacOS/rift-daemon"
else
  echo "ERROR: self-contained publish did not produce Rift.Daemon.macOS executable." >&2
  exit 1
fi

xcrun swiftc \
  "$xpc_native_dir/XpcProtocol.swift" \
  "$xpc_native_dir/XpcClientBridge.swift" \
  -emit-library \
  -framework Foundation \
  -module-name RiftNotificationXpcClient \
  -o "$app_dir/Contents/MacOS/librift-notification-xpc-client.dylib"

codesign --force --sign "$codesign_identity" "$app_dir/Contents/MacOS/librift-notification-xpc-client.dylib"
codesign --force --sign "$codesign_identity" --identifier com.rift.daemon "$app_dir/Contents/MacOS/rift-daemon"
codesign --verify --strict --verbose=2 "$app_dir/Contents/MacOS/librift-notification-xpc-client.dylib"
codesign --verify --strict --verbose=2 "$app_dir/Contents/MacOS/rift-daemon"

echo "Done."
echo "Next:"
echo "  1) Copy '$app_dir' to '$HOME/Applications/' (or keep in-place for dev)"
echo "  2) Install LaunchAgent via: daemon-cs/Rift.Daemon.macOS/Tools/install_launchagent.sh"
