#!/usr/bin/env bash
set -euo pipefail

# This script lives at: daemon-cs/Rift.Daemon.macOS/Tools/*.sh
# We want repo root: <repo>/ (not <repo>/daemon-cs).
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
project="$repo_root/daemon-cs/Rift.Daemon.macOS/Rift.Daemon.macOS.csproj"
xpc_native_dir="$repo_root/daemon-cs/Rift.NotificationExtractor.macOS/Native"
network_native_source="$repo_root/daemon-cs/Rift.Daemon.macOS/Native/NetworkMonitorShim.swift"

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

if [[ -n "${RIFT_CODESIGN_IDENTITY:-}" ]]; then
  codesign_identity="$RIFT_CODESIGN_IDENTITY"
elif /usr/bin/security find-identity -v -p codesigning "$HOME/Library/Keychains/login.keychain-db" 2>/dev/null | grep -Fq '"Rift Development Code Signing"'; then
  codesign_identity="Rift Development Code Signing"
else
  echo "ERROR: a certificate-backed code-signing identity is required." >&2
  echo "Run daemon-cs/Tools/setup_rift_dev_signing.sh for local development." >&2
  exit 1
fi
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

# MSBuild copies framework symlink targets as directories. Restore the canonical
# framework layout before signing so codesign does not see an ambiguous bundle.
media_remote_framework="$app_dir/Contents/MacOS/MediaRemoteAdapter/MediaRemoteAdapter.framework"
if [[ -d "$media_remote_framework/Versions/A" ]]; then
  rm -rf \
    "$media_remote_framework/MediaRemoteAdapter" \
    "$media_remote_framework/Resources" \
    "$media_remote_framework/Versions/Current"
  ln -s "Versions/Current/MediaRemoteAdapter" "$media_remote_framework/MediaRemoteAdapter"
  ln -s "Versions/Current/Resources" "$media_remote_framework/Resources"
  ln -s "A" "$media_remote_framework/Versions/Current"
fi

xcrun swiftc \
  "$xpc_native_dir/XpcProtocol.swift" \
  "$xpc_native_dir/XpcClientBridge.swift" \
  -emit-library \
  -framework Foundation \
  -module-name RiftNotificationXpcClient \
  -o "$app_dir/Contents/MacOS/librift-notification-xpc-client.dylib"

xcrun swiftc \
  "$network_native_source" \
  -emit-library \
  -framework Foundation \
  -framework Network \
  -module-name RiftNetworkMonitor \
  -o "$app_dir/Contents/MacOS/librift-network-monitor.dylib"

codesign --deep --force --sign "$codesign_identity" \
  --identifier com.rift.daemon "$app_dir"
codesign --verify --deep --strict --verbose=2 "$app_dir"

echo "Done."
echo "Next:"
echo "  1) Copy '$app_dir' to '$HOME/Applications/' (or keep in-place for dev)"
echo "  2) Install LaunchAgent via: daemon-cs/Rift.Daemon.macOS/Tools/install_launchagent.sh"
