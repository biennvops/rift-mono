#!/usr/bin/env bash
set -euo pipefail

if [[ -z "${RIFT_INSTALL_SMOKE_DBUS:-}" ]]; then
  exec env RIFT_INSTALL_SMOKE_DBUS=1 dbus-run-session -- "$0" "$@"
fi

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../" && pwd)"
test_root="$(mktemp -d)"
fake_home="$test_root/home"
runtime_dir="$test_root/run"
log_path="$test_root/daemon.log"
socket_path="$runtime_dir/rift-daemon/v0.1.sock"
daemon_pid=""

cleanup() {
  if [[ -n "$daemon_pid" ]] && kill -0 "$daemon_pid" >/dev/null 2>&1; then
    kill "$daemon_pid" >/dev/null 2>&1 || true
    wait "$daemon_pid" >/dev/null 2>&1 || true
  fi
  rm -rf "$test_root"
}
trap cleanup EXIT

mkdir -p "$fake_home" "$runtime_dir" "$test_root/bin"
chmod 700 "$runtime_dir"
export DOTNET_CLI_TELEMETRY_OPTOUT=1
export DOTNET_NOLOGO=1
export DOTNET_SKIP_FIRST_TIME_EXPERIENCE=1
cat > "$test_root/bin/systemctl" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$test_root/bin/systemctl"

app_root="$repo_root/app-flutter"
daemon_root="$repo_root/daemon-cs"
probe_project="$daemon_root/Tools/Rift.IpcProbe/Rift.IpcProbe.csproj"
probe_dll="$daemon_root/Tools/Rift.IpcProbe/bin/Debug/net10.0/Rift.IpcProbe.dll"
dotnet build "$probe_project" --no-restore >/dev/null

export HOME="$fake_home"
export XDG_CONFIG_HOME="$fake_home/.config"
export XDG_DATA_HOME="$fake_home/.local/share"
export XDG_RUNTIME_DIR="$runtime_dir"
export PATH="$test_root/bin:$PATH"
case "$(uname -m)" in
  x86_64) build_arch="x64"; daemon_runtime="linux-x64" ;;
  aarch64|arm64) build_arch="arm64"; daemon_runtime="linux-arm64" ;;
  *) echo "Unsupported Linux architecture: $(uname -m)" >&2; exit 1 ;;
esac
app_bundle="$app_root/build/linux/$build_arch/release/bundle"
daemon_publish="$repo_root/dist/linux/daemon-$daemon_runtime"

[[ -x "$app_bundle/rift" ]] || {
  echo "Release app bundle not found at $app_bundle/rift. Build it first." >&2
  exit 1
}
[[ -x "$daemon_publish/rift-daemon" ]] || {
  echo "Published daemon not found at $daemon_publish/rift-daemon. Build it first." >&2
  exit 1
}

desktop_dir="$HOME/.local/share/applications"
autostart_dir="$XDG_CONFIG_HOME/autostart"
daemon_unit="$XDG_CONFIG_HOME/systemd/user/rift-daemon.service"
app_install_dir="$HOME/.local/lib/rift"
daemon_install_dir="$HOME/.local/lib/rift-daemon"
data_dir="$HOME/.local/share/rift-daemon"

"$daemon_root/Rift.Daemon.Linux/Tools/install_user_service.sh" "$daemon_runtime"
"$app_root/linux/tools/install_user_app.sh"

desktop_file="$desktop_dir/dev.rift.Rift.desktop"
[[ -x "$app_install_dir/rift" ]]
[[ -x "$daemon_install_dir/rift-daemon" ]]
[[ -f "$desktop_file" && -f "$autostart_dir/dev.rift.Rift.desktop" && -f "$daemon_unit" ]]
desktop-file-validate "$desktop_file"
desktop-file-validate "$autostart_dir/dev.rift.Rift.desktop"
grep -Fq "Exec=\"$app_install_dir/rift\" %F" "$desktop_file"
grep -Fq "Exec=\"$app_install_dir/rift\" --background" "$autostart_dir/dev.rift.Rift.desktop"
grep -Fq "%h/.local/lib/rift-daemon/rift-daemon" "$daemon_unit"
while IFS= read -r -d '' native_library; do
  ! ldd "$native_library" 2>&1 | grep -q 'not found'
done < <(find "$app_install_dir" -type f \( -name '*.so' -o -name 'rift' \) -print0)

start_daemon() {
  "$daemon_install_dir/rift-daemon" >"$log_path" 2>&1 &
  daemon_pid=$!
  for _ in $(seq 1 60); do
    if [[ -S "$socket_path" ]]; then
      return
    fi
    if ! kill -0 "$daemon_pid" >/dev/null 2>&1; then
      cat "$log_path" >&2
      exit 1
    fi
    sleep 0.25
  done
  cat "$log_path" >&2
  echo "Installed daemon IPC socket did not become ready." >&2
  exit 1
}
probe() {
  RIFT_DAEMON_SOCKET="$socket_path" dotnet "$probe_dll" "$1"
}

start_daemon
first_info="$(probe rift.getDeviceInfo)"
printf '%s' "$first_info" | grep -Eq '"Platform"[[:space:]]*:[[:space:]]*"linux"'
printf '%s' "$first_info" | grep -Eq '"IdentityProtectionBackend"[[:space:]]*:[[:space:]]*"file"'
[[ "$(stat -c '%a' "$data_dir")" == "700" ]]
[[ "$(stat -c '%a' "$data_dir/riftd.sqlite3.rift-secrets.key")" == "600" ]]
first_device_id="$(printf '%s' "$first_info" | grep -oE 'rift-[a-z2-7]{32}' | head -1)"
[[ -n "$first_device_id" ]]
probe rift.listMediaPlayback | grep -q 'Playbacks'
stop_daemon() {
  kill "$daemon_pid"
  wait "$daemon_pid" || true
  daemon_pid=""
}
stop_daemon
start_daemon
second_info="$(probe rift.getDeviceInfo)"
second_device_id="$(printf '%s' "$second_info" | grep -oE 'rift-[a-z2-7]{32}' | head -1)"
[[ "$first_device_id" == "$second_device_id" ]]
stop_daemon

"$app_root/linux/tools/uninstall_user_app.sh"
"$daemon_root/Rift.Daemon.Linux/Tools/uninstall_user_service.sh"
[[ ! -e "$app_install_dir" && ! -e "$daemon_install_dir" ]]
[[ -d "$data_dir" ]]

echo "Installed Linux stack smoke test passed for $first_device_id"
