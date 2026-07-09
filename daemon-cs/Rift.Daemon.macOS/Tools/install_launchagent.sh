#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
template="$repo_root/daemon-cs/Rift.Daemon.macOS/Resources/com.rift.daemon.plist"

launch_agents_dir="$HOME/Library/LaunchAgents"
install_path="$launch_agents_dir/com.rift.daemon.plist"

mkdir -p "$launch_agents_dir"
mkdir -p "$HOME/Library/Logs/rift-daemon"

sed "s|@HOME@|$HOME|g" "$template" > "$install_path"

echo "Installed LaunchAgent plist: $install_path"
echo "Loading agent..."
launchctl unload "$install_path" >/dev/null 2>&1 || true
launchctl load "$install_path"

echo "Loaded. Check status:"
echo "  launchctl list | rg com.rift.daemon"

