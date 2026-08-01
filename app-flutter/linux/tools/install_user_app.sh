#!/usr/bin/env bash
set -euo pipefail

app_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

case "$(uname -m)" in
  x86_64) build_arch="x64" ;;
  aarch64|arm64) build_arch="arm64" ;;
  *)
    echo "Unsupported Linux architecture: $(uname -m)" >&2
    exit 1
    ;;
esac

bundle_dir="$app_root/build/linux/$build_arch/release/bundle"
install_dir="$HOME/.local/lib/rift"
applications_dir="$HOME/.local/share/applications"
icons_dir="$HOME/.local/share/icons/hicolor/256x256/apps"
autostart_dir="${XDG_CONFIG_HOME:-$HOME/.config}/autostart"
desktop_template="$app_root/linux/resources/dev.rift.Rift.desktop"
autostart_template="$app_root/linux/resources/dev.rift.Rift-autostart.desktop"
icon_source="$app_root/assets/dev.rift.Rift.png"

if [[ ! -x "$bundle_dir/rift" ]]; then
  echo "Linux app bundle not found at $bundle_dir." >&2
  echo "Run app-flutter/linux/tools/build_linux_app.sh first." >&2
  exit 1
fi

rm -rf "$install_dir"
mkdir -p "$install_dir" "$applications_dir" "$icons_dir" "$autostart_dir"
cp -a "$bundle_dir/." "$install_dir/"
install -m 0644 "$icon_source" "$icons_dir/dev.rift.Rift.png"

escaped_install_dir="${install_dir//&/\\&}"
sed "s|@EXEC@|\"$escaped_install_dir/rift\"|" \
  "$desktop_template" > "$applications_dir/dev.rift.Rift.desktop"
sed "s|@EXEC@|\"$escaped_install_dir/rift\" --background|" \
  "$autostart_template" > "$autostart_dir/dev.rift.Rift.desktop"
chmod 0644 \
  "$applications_dir/dev.rift.Rift.desktop" \
  "$autostart_dir/dev.rift.Rift.desktop"

if command -v update-desktop-database >/dev/null 2>&1; then
  update-desktop-database "$applications_dir" >/dev/null 2>&1 || true
fi

if command -v gtk-update-icon-cache >/dev/null 2>&1; then
  gtk-update-icon-cache -f -t "$HOME/.local/share/icons/hicolor" >/dev/null 2>&1 || true
fi

echo "Installed Rift to $install_dir"
echo "Installed desktop entry and login autostart for the current user."
