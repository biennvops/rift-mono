#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
template="$repo_root/daemon-cs/Rift.Daemon.Linux/Resources/rift-daemon.service"

runtime="${1:-}"
if [[ -z "$runtime" ]]; then
  case "$(uname -m)" in
    x86_64) runtime="linux-x64" ;;
    aarch64|arm64) runtime="linux-arm64" ;;
    *)
      echo "Unsupported Linux architecture: $(uname -m)" >&2
      exit 1
      ;;
  esac
fi

publish_dir="$repo_root/dist/linux/daemon-$runtime"
install_dir="$HOME/.local/lib/rift-daemon"
data_dir="$HOME/.local/share/rift-daemon"
unit_dir="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
unit_path="$unit_dir/rift-daemon.service"

if [[ ! -x "$publish_dir/rift-daemon" ]]; then
  echo "Published daemon not found at $publish_dir/rift-daemon." >&2
  echo "Run daemon-cs/Rift.Daemon.Linux/Tools/build_linux_daemon.sh $runtime first." >&2
  exit 1
fi

if ! command -v systemctl >/dev/null 2>&1; then
  echo "systemctl is required to install the Rift user service." >&2
  exit 1
fi

systemctl --user stop rift-daemon.service >/dev/null 2>&1 || true
rm -rf "$install_dir"
mkdir -p "$install_dir" "$data_dir" "$unit_dir"
chmod 700 "$data_dir"
cp -a "$publish_dir/." "$install_dir/"
install -m 0644 "$template" "$unit_path"

systemctl --user daemon-reload
systemctl --user enable --now rift-daemon.service

echo "Installed Rift daemon to $install_dir"
echo "Installed and started $unit_path"
echo "Check status with: systemctl --user status rift-daemon.service"
