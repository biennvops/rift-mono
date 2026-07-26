#!/usr/bin/env bash
set -euo pipefail

install_dir="$HOME/.local/lib/rift-daemon"
unit_dir="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
unit_path="$unit_dir/rift-daemon.service"

if command -v systemctl >/dev/null 2>&1; then
  systemctl --user disable --now rift-daemon.service >/dev/null 2>&1 || true
fi

rm -f "$unit_path"
rm -rf "$install_dir"

if command -v systemctl >/dev/null 2>&1; then
  systemctl --user daemon-reload
fi

echo "Removed the Rift daemon user service and binaries."
echo "Identity and trust data in $HOME/.local/share/rift-daemon were preserved."
