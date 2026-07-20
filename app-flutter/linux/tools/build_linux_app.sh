#!/usr/bin/env bash
set -euo pipefail

app_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

cd "$app_root"
flutter build linux --release

echo "Linux app bundle built under $app_root/build/linux"
