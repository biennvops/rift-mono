#!/usr/bin/env bash
set -euo pipefail

# This script lives at: daemon-cs/Rift.Daemon.macOS/Tools/*.sh
# We want repo root: <repo>/ (not <repo>/daemon-cs).
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
project="$repo_root/daemon-cs/Rift.Daemon.macOS/Rift.Daemon.macOS.csproj"

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
dotnet publish "$project" -c Release -r "$runtime" --self-contained false -o "$publish_dir"

echo "Assembling app bundle -> $app_dir"
rm -rf "$app_dir"
mkdir -p "$app_dir/Contents/MacOS"

cp "$repo_root/daemon-cs/Rift.Daemon.macOS/Resources/RiftDaemon.Info.plist" \
  "$app_dir/Contents/Info.plist"

# Prefer apphost (native launcher) if present; otherwise fall back to dll.
if [[ -f "$publish_dir/Rift.Daemon.macOS" ]]; then
  cp "$publish_dir/Rift.Daemon.macOS" "$app_dir/Contents/MacOS/rift-daemon"
elif [[ -f "$publish_dir/Rift.Daemon.macOS.dll" ]]; then
  cp "$publish_dir/Rift.Daemon.macOS.dll" "$app_dir/Contents/MacOS/Rift.Daemon.macOS.dll"
  cat >"$app_dir/Contents/MacOS/rift-daemon" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec dotnet "$here/Rift.Daemon.macOS.dll"
EOF
  chmod +x "$app_dir/Contents/MacOS/rift-daemon"
else
  echo "ERROR: publish output did not contain Rift.Daemon.macOS or Rift.Daemon.macOS.dll" >&2
  exit 1
fi

chmod +x "$app_dir/Contents/MacOS/rift-daemon" || true

echo "Done."
echo "Next:"
echo "  1) Copy '$app_dir' to '$HOME/Applications/' (or keep in-place for dev)"
echo "  2) Install LaunchAgent via: daemon-cs/Rift.Daemon.macOS/Tools/install_launchagent.sh"
