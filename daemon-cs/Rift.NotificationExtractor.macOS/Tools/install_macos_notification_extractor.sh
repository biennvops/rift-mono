#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
project_dir="$repo_root/daemon-cs/Rift.NotificationExtractor.macOS"
template="$project_dir/Resources/com.rift.notification-extractor.plist"
app_src="$repo_root/dist/macos/Rift Notification Extractor.app"
app_dst="$HOME/Applications/Rift Notification Extractor.app"
launch_agents_dir="$HOME/Library/LaunchAgents"
launch_agent="$launch_agents_dir/com.rift.notification-extractor.plist"
log_dir="$HOME/Library/Logs/rift-notification-extractor"
domain="gui/$(id -u)"

if [[ ! -d "$app_src" ]]; then
  echo "ERROR: extractor app bundle not found at '$app_src'." >&2
  echo "Run build_macos_notification_extractor_app.sh first." >&2
  exit 1
fi
if [[ -e "$app_dst" ]]; then
  echo "ERROR: '$app_dst' already exists; move or remove it before installing." >&2
  exit 1
fi

mkdir -p "$HOME/Applications" "$launch_agents_dir" "$log_dir"
cp -R "$app_src" "$app_dst"
sed "s|@HOME@|$HOME|g" "$template" > "$launch_agent"

launchctl bootout "$domain/com.rift.notification-extractor" >/dev/null 2>&1 || true
launchctl bootstrap "$domain" "$launch_agent"

echo "Installed app bundle: $app_dst"
echo "Installed LaunchAgent: $launch_agent"
echo "Grant Full Disk Access to the installed app before sending requests."
