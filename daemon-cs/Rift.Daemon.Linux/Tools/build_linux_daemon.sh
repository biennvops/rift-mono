#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
project="$repo_root/daemon-cs/Rift.Daemon.Linux/Rift.Daemon.Linux.csproj"

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

echo "Publishing $project ($runtime) -> $publish_dir"
rm -rf "$publish_dir"
dotnet publish "$project" -c Release -r "$runtime" --self-contained true -o "$publish_dir"

published_executable="$publish_dir/Rift.Daemon.Linux"
if [[ ! -x "$published_executable" ]]; then
  echo "Self-contained publish did not produce $published_executable." >&2
  exit 1
fi

mv "$published_executable" "$publish_dir/rift-daemon"
chmod +x "$publish_dir/rift-daemon"

echo "Linux daemon published to $publish_dir"
