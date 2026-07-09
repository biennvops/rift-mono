#!/usr/bin/env bash
set -euo pipefail

# This script lives at: daemon-cs/Rift.Daemon.macOS/Tools/*.sh
# We want repo root: <repo>/ (not <repo>/daemon-cs).
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
template="$repo_root/daemon-cs/Rift.Daemon.macOS/Resources/com.rift.daemon.plist"

launch_agents_dir="$HOME/Library/LaunchAgents"
install_path="$launch_agents_dir/com.rift.daemon.plist"

app_src="$repo_root/dist/macos/Rift Daemon.app"
app_dst_dir="$HOME/Applications"
app_dst="$app_dst_dir/Rift Daemon.app"

mkdir -p "$launch_agents_dir"
mkdir -p "$HOME/Library/Logs/rift-daemon"
mkdir -p "$app_dst_dir"

if [[ -d "$app_src" ]]; then
  rm -rf "$app_dst"
  cp -R "$app_src" "$app_dst_dir/"
  echo "Installed app bundle: $app_dst"
else
  echo "WARNING: app bundle not found at: $app_src" >&2
  echo "Run: daemon-cs/Rift.Daemon.macOS/Tools/build_macos_daemon_app.sh" >&2
  echo "Then re-run this installer." >&2
fi

sed "s|@HOME@|$HOME|g" "$template" > "$install_path"

echo "Installed LaunchAgent plist: $install_path"
echo "Loading agent..."
launchctl unload "$install_path" >/dev/null 2>&1 || true
launchctl load "$install_path"

echo "Loaded. Check status:"
echo "  launchctl list | rg com.rift.daemon"
