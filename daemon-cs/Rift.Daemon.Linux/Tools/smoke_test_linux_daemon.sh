#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
daemon_project="$repo_root/daemon-cs/Rift.Daemon.Linux/Rift.Daemon.Linux.csproj"
probe_project="$repo_root/daemon-cs/Tools/Rift.IpcProbe/Rift.IpcProbe.csproj"
test_root="$(mktemp -d)"
runtime_dir="$test_root/run"
data_dir="$test_root/data"
socket_path="$runtime_dir/rift-daemon/v0.1.sock"
daemon_pid=""
systemctl_path="$(command -v systemctl || true)"
restart_user_daemon=false

cleanup() {
  if [[ -n "$daemon_pid" ]] && kill -0 "$daemon_pid" >/dev/null 2>&1; then
    kill "$daemon_pid" >/dev/null 2>&1 || true
    wait "$daemon_pid" >/dev/null 2>&1 || true
  fi
  rm -rf "$test_root"
  if [[ "$restart_user_daemon" == true ]]; then
    "$systemctl_path" --user start rift-daemon.service >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

if [[ -n "$systemctl_path" ]] && "$systemctl_path" --user is-active --quiet rift-daemon.service; then
  "$systemctl_path" --user stop rift-daemon.service
  restart_user_daemon=true
fi
if command -v ss >/dev/null 2>&1 && ss -H -ltn 'sport = :9140' | grep -q .; then
  echo "TCP port 9140 is already in use by a non-systemd process; stop it before running this smoke test." >&2
  exit 1
fi

mkdir -p "$runtime_dir" "$data_dir"
chmod 700 "$runtime_dir"

dotnet build "$daemon_project" --no-restore >/dev/null
dotnet build "$probe_project" >/dev/null

start_daemon() {
  local log_path="$1"
  XDG_RUNTIME_DIR="$runtime_dir" \
  XDG_DATA_HOME="$data_dir" \
  DBUS_SESSION_BUS_ADDRESS="unix:path=$test_root/missing-session-bus" \
    dotnet run --project "$daemon_project" --no-build >"$log_path" 2>&1 &
  daemon_pid=$!

  for _ in $(seq 1 40); do
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
  echo "Rift daemon IPC socket did not become ready." >&2
  exit 1
}

stop_daemon() {
  kill "$daemon_pid"
  wait "$daemon_pid" || true
  daemon_pid=""
}

probe() {
  RIFT_DAEMON_SOCKET="$socket_path" \
    dotnet run --project "$probe_project" --no-build -- "$1"
}

start_daemon "$test_root/daemon-first.log"
first_info="$(probe rift.getDeviceInfo)"
first_device_id="$(printf '%s' "$first_info" | grep -oE 'rift-[a-z2-7]{32}' | head -1)"
[[ -n "$first_device_id" ]]
printf '%s' "$first_info" | grep -Eq '"Platform"[[:space:]]*:[[:space:]]*"linux"'
printf '%s' "$first_info" | grep -Eq '"IdentityProtectionBackend"[[:space:]]*:[[:space:]]*"file"'
[[ "$(stat -c '%a' "$data_dir/rift-daemon/riftd.sqlite3.rift-secrets.key")" == "600" ]]
probe rift.listMediaPlayback | grep -q 'Playbacks'
stop_daemon

start_daemon "$test_root/daemon-second.log"
second_info="$(probe rift.getDeviceInfo)"
second_device_id="$(printf '%s' "$second_info" | grep -oE 'rift-[a-z2-7]{32}' | head -1)"
[[ "$first_device_id" == "$second_device_id" ]]
stop_daemon

echo "Linux daemon smoke test passed for $first_device_id"
