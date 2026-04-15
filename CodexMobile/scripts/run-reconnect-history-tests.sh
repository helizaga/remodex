#!/usr/bin/env bash
set -euo pipefail

# FILE: run-reconnect-history-tests.sh
# Purpose: Runs the required CodexMobile mobile regression slice on an available iPhone simulator.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT_PATH="$ROOT_DIR/CodexMobile.xcodeproj"
SCHEME="${SCHEME:-CodexMobile}"
DERIVED_DATA_PATH="${DERIVED_DATA_PATH:-/tmp/remodex-codexmobile-ci-derived}"
RESULT_BUNDLE_PATH="${RESULT_BUNDLE_PATH:-}"
TIMEOUT_SECONDS="${TIMEOUT_SECONDS:-0}"
ITERATIONS="${ITERATIONS:-1}"
CLEAN_DERIVED_DATA="${CLEAN_DERIVED_DATA:-0}"
ERASE_SIMULATOR="${ERASE_SIMULATOR:-0}"
HELPERS_PATH="$ROOT_DIR/scripts/xcode-test-helpers.sh"

source "$HELPERS_PATH"

DESTINATION="${DESTINATION:-$(pick_ios_simulator_destination "$PROJECT_PATH" "$SCHEME" \
  "iPhone 17" \
  "iPhone 17 Pro" \
  "iPhone 16 Pro" \
  "iPhone 16")}"

if [[ -z "$DESTINATION" ]]; then
  echo "Unable to locate an available iOS Simulator destination."
  exit 1
fi

SIMULATOR_UDID="$(destination_udid "$DESTINATION")"

TEST_SUITES=(
  CodexApprovalStateTests
  CodexLifecycleDeallocationTests
  CodexSecurePairingStateTests
  CodexServiceCatchupRecoveryTests
  CodexServiceConnectionErrorTests
  CodexServiceIncomingRunIndicatorTests
  CodexServiceRelayHistoryNoticeTests
  ContentViewModelReconnectTests
  DesktopHandoffServiceTests
  TurnComposerSendAvailabilityTests
  TurnConnectionRecoverySnapshotBuilderTests
  TurnTimelineReducerTests
  TurnViewModelQueueTests
)

ONLY_TESTING_ARGS=()
for suite in "${TEST_SUITES[@]}"; do
  ONLY_TESTING_ARGS+=("-only-testing:CodexMobileTests/${suite}")
done

echo "[codexmobile-ci] destination: $DESTINATION"
echo "[codexmobile-ci] scheme: $SCHEME"
echo "[codexmobile-ci] suites: ${TEST_SUITES[*]}"
echo "[codexmobile-ci] derived-data: $DERIVED_DATA_PATH"
if [[ -n "$RESULT_BUNDLE_PATH" ]]; then
  echo "[codexmobile-ci] result-bundle: $RESULT_BUNDLE_PATH"
fi
if [[ "$TIMEOUT_SECONDS" -gt 0 ]]; then
  echo "[codexmobile-ci] timeout-seconds: $TIMEOUT_SECONDS"
fi

if [[ "$CLEAN_DERIVED_DATA" == "1" ]]; then
  rm -rf "$DERIVED_DATA_PATH"
fi

if [[ "$ERASE_SIMULATOR" == "1" && -n "$SIMULATOR_UDID" ]]; then
  echo "[codexmobile-ci] erasing simulator: $SIMULATOR_UDID"
  xcrun simctl shutdown "$SIMULATOR_UDID" >/dev/null 2>&1 || true
  xcrun simctl erase "$SIMULATOR_UDID"
fi

run_xcodebuild_once() {
  local iteration="$1"
  local cmd=(
    xcodebuild
    -project "$PROJECT_PATH"
    -scheme "$SCHEME"
    -destination "$DESTINATION"
    -derivedDataPath "$DERIVED_DATA_PATH"
  )

  if [[ -n "$RESULT_BUNDLE_PATH" ]]; then
    local result_bundle_path="$RESULT_BUNDLE_PATH"
    if [[ "$ITERATIONS" -gt 1 ]]; then
      local extension="${RESULT_BUNDLE_PATH##*.}"
      local stem="${RESULT_BUNDLE_PATH%.*}"
      if [[ "$stem" == "$RESULT_BUNDLE_PATH" ]]; then
        result_bundle_path="${RESULT_BUNDLE_PATH}.${iteration}"
      else
        result_bundle_path="${stem}.${iteration}.${extension}"
      fi
    fi
    rm -rf "$result_bundle_path"
    cmd+=(-resultBundlePath "$result_bundle_path")
  fi

  cmd+=(
    test
    CODE_SIGNING_ALLOWED=NO
    CODE_SIGNING_REQUIRED=NO
    "${ONLY_TESTING_ARGS[@]}"
  )

  if [[ "$TIMEOUT_SECONDS" -gt 0 ]]; then
    python3 - "$TIMEOUT_SECONDS" "${cmd[@]}" <<'PY'
import subprocess
import sys

timeout = int(sys.argv[1])
command = sys.argv[2:]
process = subprocess.Popen(command)
try:
    raise SystemExit(process.wait(timeout=timeout))
except subprocess.TimeoutExpired:
    process.terminate()
    try:
        process.wait(timeout=15)
    except subprocess.TimeoutExpired:
        process.kill()
        process.wait()
    raise SystemExit(124)
PY
  else
    "${cmd[@]}"
  fi
}

for ((iteration = 1; iteration <= ITERATIONS; iteration++)); do
  if [[ "$ITERATIONS" -gt 1 ]]; then
    echo "[codexmobile-ci] iteration $iteration/$ITERATIONS"
  fi
  run_xcodebuild_once "$iteration"
done
