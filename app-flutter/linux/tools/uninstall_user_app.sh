#!/usr/bin/env bash
set -euo pipefail

install_dir="$HOME/.local/lib/rift"
applications_dir="$HOME/.local/share/applications"
icons_dir="$HOME/.local/share/icons/hicolor/256x256/apps"
autostart_dir="${XDG_CONFIG_HOME:-$HOME/.config}/autostart"

rm -rf "$install_dir"
rm -f \
  "$applications_dir/dev.rift.Rift.desktop" \
  "$icons_dir/dev.rift.Rift.png" \
  "$autostart_dir/dev.rift.Rift.desktop"

if command -v update-desktop-database >/dev/null 2>&1; then
  update-desktop-database "$applications_dir" >/dev/null 2>&1 || true
fi

if command -v gtk-update-icon-cache >/dev/null 2>&1; then
  gtk-update-icon-cache -f -t "$HOME/.local/share/icons/hicolor" >/dev/null 2>&1 || true
fi

echo "Removed the Rift Linux app, desktop entry, and login autostart."
