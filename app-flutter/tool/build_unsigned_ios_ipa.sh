#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IPA_DIR="$ROOT_DIR/build/ios/ipa"
APP_PATH="$ROOT_DIR/build/ios/iphoneos/Runner.app"
IPA_PATH="$IPA_DIR/Runner-unsigned-release.ipa"

cd "$ROOT_DIR"

flutter build ios --release --no-codesign

rm -rf "$IPA_DIR"
mkdir -p "$IPA_DIR/Payload"
cp -R "$APP_PATH" "$IPA_DIR/Payload/"

(
  cd "$IPA_DIR"
  zip -r -y "$(basename "$IPA_PATH")" Payload >/dev/null
)

printf 'Built unsigned IPA: %s\n' "$IPA_PATH"
shasum -a 256 "$IPA_PATH"
