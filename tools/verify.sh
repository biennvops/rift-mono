#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
log_dir="${RIFT_AGENT_LOG_DIR:-$repo_root/logs/agent}"
mkdir -p "$log_dir"

usage() {
  printf '%s\n' \
    "Usage: tools/verify.sh <target>" \
    "Targets: daemon-cs daemon-dart app-flutter tests-conformance tests-interop all"
}

run_step() {
  local name="$1"
  shift
  local log_path="$log_dir/$name.log"
  local display_path="$log_path"
  local status

  if [[ "$log_path" == "$repo_root/"* ]]; then
    display_path="${log_path#"$repo_root/"}"
  fi

  if "$@" >"$log_path" 2>&1; then
    printf 'PASS %s\n' "$name"
    return 0
  else
    status=$?
    printf 'FAIL %s (exit %s; log: %s)\n' "$name" "$status" "$display_path"
    printf '%s\n' 'Relevant failure output:'
    if ! grep -Ei '(^|[^[:alnum:]])(error|fatal|failed|failure|exception|assert)([^[:alnum:]]|$)' "$log_path" | tail -80; then
      tail -80 "$log_path"
    fi
    return "$status"
  fi
}

run_daemon_cs_build() {
  case "$(uname -s)" in
    Darwin)
      dotnet build "$repo_root/daemon-cs/Rift.Daemon.macOS/Rift.Daemon.macOS.csproj"
      dotnet build "$repo_root/daemon-cs/Rift.NotificationExtractor.macOS/Rift.NotificationExtractor.macOS.csproj"
      ;;
    Linux)
      dotnet build "$repo_root/daemon-cs/Rift.Daemon.Linux/Rift.Daemon.Linux.csproj"
      ;;
    *)
      dotnet build "$repo_root/daemon-cs/Rift.Daemon.sln"
      ;;
  esac
}

run_daemon_cs_tests() {
  dotnet test "$repo_root/daemon-cs/Rift.Daemon.Tests/Rift.Daemon.Tests.csproj"
}

run_daemon_dart_restore() {
  cd "$repo_root/daemon-dart"
  flutter pub get
}

run_daemon_dart_analyze() {
  cd "$repo_root/daemon-dart"
  dart analyze
}

run_daemon_dart_tests() {
  cd "$repo_root/daemon-dart"
  flutter test --no-pub
}

run_app_flutter_restore() {
  cd "$repo_root/app-flutter"
  flutter pub get
}

run_app_flutter_analyze() {
  cd "$repo_root/app-flutter"
  flutter analyze --no-pub
}

run_app_flutter_tests() {
  cd "$repo_root/app-flutter"
  flutter test --no-pub
}

run_conformance_restore() {
  cd "$repo_root/tests-conformance"
  flutter pub get
}

run_conformance_tests() {
  cd "$repo_root/tests-conformance"
  dart run runners/dart/runner.dart
}

run_interop_restore() {
  cd "$repo_root/tests-interop"
  flutter pub get
}

run_interop_tests() {
  cd "$repo_root/tests-interop"
  flutter test --no-pub
}

run_target() {
  local target="$1"
  local failed=0

  case "$target" in
    daemon-cs)
      run_step daemon-cs-build run_daemon_cs_build || {
        printf '%s\n' 'SKIP daemon-cs-tests (build failed)'
        return 1
      }
      run_step daemon-cs-tests run_daemon_cs_tests || failed=1
      ;;
    daemon-dart)
      run_step daemon-dart-restore run_daemon_dart_restore || {
        printf '%s\n' 'SKIP daemon-dart-analyze, daemon-dart-tests (restore failed)'
        return 1
      }
      run_step daemon-dart-analyze run_daemon_dart_analyze || failed=1
      run_step daemon-dart-tests run_daemon_dart_tests || failed=1
      ;;
    app-flutter)
      run_step app-flutter-restore run_app_flutter_restore || {
        printf '%s\n' 'SKIP app-flutter-analyze, app-flutter-tests (restore failed)'
        return 1
      }
      run_step app-flutter-analyze run_app_flutter_analyze || failed=1
      run_step app-flutter-tests run_app_flutter_tests || failed=1
      ;;
    tests-conformance)
      run_step tests-conformance-restore run_conformance_restore || {
        printf '%s\n' 'SKIP tests-conformance (restore failed)'
        return 1
      }
      run_step tests-conformance run_conformance_tests || failed=1
      ;;
    tests-interop)
      run_step tests-interop-restore run_interop_restore || {
        printf '%s\n' 'SKIP tests-interop (restore failed)'
        return 1
      }
      run_step tests-interop run_interop_tests || failed=1
      ;;
    all)
      for target in daemon-cs daemon-dart app-flutter tests-conformance tests-interop; do
        run_target "$target" || failed=1
      done
      ;;
    *)
      usage
      return 2
      ;;
  esac

  return "$failed"
}

if [[ $# -ne 1 ]]; then
  usage
  exit 2
fi

run_target "$1"
