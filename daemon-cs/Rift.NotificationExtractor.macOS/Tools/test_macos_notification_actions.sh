#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
project_dir="$repo_root/daemon-cs/Rift.NotificationExtractor.macOS"
native_dir="$project_dir/Native"
tests_dir="$project_dir/Tests"
build_script="$project_dir/Tools/build_macos_notification_extractor_app.sh"
temp_dir="$(mktemp -d "${TMPDIR:-/tmp}/rift-notification-action-tests.XXXXXX")"
trap 'rm -rf -- "$temp_dir"' EXIT

contains_string() {
  /usr/bin/strings "$1" | /usr/bin/grep -F -- "$2" >/dev/null
}

broker_sources=(
  "$native_dir/XpcProtocol.swift"
  "$native_dir/PrivateNotificationActions.swift"
  "$native_dir/AccessibilityNotificationActions.swift"
  "$native_dir/NotificationActionRequestHandler.swift"
  "$native_dir/XpcBroker.swift"
)
test_sources=(
  "$native_dir/PrivateNotificationActions.swift"
  "$native_dir/AccessibilityNotificationActions.swift"
  "$native_dir/NotificationActionRequestHandler.swift"
  "$tests_dir/NotificationActionRequestHandlerTests.swift"
)

xcrun swiftc "${broker_sources[@]}" -framework Foundation -o "$temp_dir/broker-normal"
if contains_string "$temp_dir/broker-normal" 'RIFT_PRIVATE_NOTIFICATION_ACTIONS_V1'; then
  printf 'normal broker contains the private notification-action sentinel\n' >&2
  exit 1
fi
if contains_string "$temp_dir/broker-normal" 'RIFT_ACCESSIBILITY_NOTIFICATION_ACTIONS_V1'; then
  printf 'normal broker contains the Accessibility notification-action sentinel\n' >&2
  exit 1
fi

xcrun swiftc \
  -D RIFT_PRIVATE_API \
  -D RIFT_PRIVATE_NOTIFICATION_ACTIONS \
  "${broker_sources[@]}" \
  -framework Foundation \
  -o "$temp_dir/broker-private"
if ! contains_string "$temp_dir/broker-private" 'RIFT_PRIVATE_NOTIFICATION_ACTIONS_V1'; then
  printf 'private broker is missing the private notification-action sentinel\n' >&2
  exit 1
fi
if contains_string "$temp_dir/broker-private" 'RIFT_ACCESSIBILITY_NOTIFICATION_ACTIONS_V1'; then
  printf 'private broker contains the Accessibility notification-action sentinel\n' >&2
  exit 1
fi

xcrun swiftc \
  -D RIFT_ACCESSIBILITY_NOTIFICATION_ACTIONS \
  "${broker_sources[@]}" \
  -framework Foundation \
  -framework ApplicationServices \
  -framework AppKit \
  -o "$temp_dir/broker-accessibility"
if ! contains_string "$temp_dir/broker-accessibility" 'RIFT_ACCESSIBILITY_NOTIFICATION_ACTIONS_V1'; then
  printf 'Accessibility broker is missing its notification-action sentinel\n' >&2
  exit 1
fi
if contains_string "$temp_dir/broker-accessibility" 'RIFT_PRIVATE_NOTIFICATION_ACTIONS_V1'; then
  printf 'Accessibility broker contains the private notification-action sentinel\n' >&2
  exit 1
fi

xcrun swiftc \
  -parse-as-library \
  "${test_sources[@]}" \
  -framework Foundation \
  -framework Security \
  -o "$temp_dir/request-tests-normal"
"$temp_dir/request-tests-normal"

xcrun swiftc \
  -parse-as-library \
  -D RIFT_PRIVATE_API \
  -D RIFT_PRIVATE_NOTIFICATION_ACTIONS \
  "${test_sources[@]}" \
  -framework Foundation \
  -framework Security \
  -o "$temp_dir/request-tests-private"
"$temp_dir/request-tests-private"

xcrun swiftc \
  -parse-as-library \
  -D RIFT_ACCESSIBILITY_NOTIFICATION_ACTIONS \
  "${test_sources[@]}" \
  -framework Foundation \
  -framework ApplicationServices \
  -framework AppKit \
  -o "$temp_dir/request-tests-accessibility"
"$temp_dir/request-tests-accessibility"

invalid_output="$temp_dir/invalid-build-flag.log"
if RIFT_DEV_PRIVATE_MACOS_NOTIFICATION_ACTIONS=invalid "$build_script" >"$invalid_output" 2>&1; then
  printf 'invalid private notification-action build flag succeeded\n' >&2
  exit 1
fi
if ! /usr/bin/grep -Fq -- 'must be 0 or 1' "$invalid_output"; then
  printf 'invalid private notification-action build flag returned the wrong error\n' >&2
  exit 1
fi

invalid_accessibility_output="$temp_dir/invalid-accessibility-build-flag.log"
if RIFT_MACOS_ACCESSIBILITY_NOTIFICATION_ACTIONS=invalid "$build_script" >"$invalid_accessibility_output" 2>&1; then
  printf 'invalid Accessibility notification-action build flag succeeded\n' >&2
  exit 1
fi
if ! /usr/bin/grep -Fq -- 'must be 0 or 1' "$invalid_accessibility_output"; then
  printf 'invalid Accessibility notification-action build flag returned the wrong error\n' >&2
  exit 1
fi

combined_output="$temp_dir/combined-build-flags.log"
if RIFT_DEV_PRIVATE_MACOS_NOTIFICATION_ACTIONS=1 \
  RIFT_MACOS_ACCESSIBILITY_NOTIFICATION_ACTIONS=1 \
  "$build_script" >"$combined_output" 2>&1; then
  printf 'mutually exclusive notification-action build flags succeeded\n' >&2
  exit 1
fi
if ! /usr/bin/grep -Fq -- 'mutually exclusive' "$combined_output"; then
  printf 'combined notification-action build flags returned the wrong error\n' >&2
  exit 1
fi

if plutil -extract RiftDevPrivateNotificationActionsEnabled raw \
  "$project_dir/Resources/RiftNotificationExtractor.Info.plist" >/dev/null 2>&1; then
  printf 'source Info.plist contains the development-only private marker\n' >&2
  exit 1
fi
if plutil -extract RiftAccessibilityNotificationActionsEnabled raw \
  "$project_dir/Resources/RiftNotificationExtractor.Info.plist" >/dev/null 2>&1; then
  printf 'source Info.plist contains the optional Accessibility marker\n' >&2
  exit 1
fi

bash -n "$build_script"
bash -n "$project_dir/Tools/Research/build_notification_action_research.sh"
printf 'macOS notification action build tests passed\n'
