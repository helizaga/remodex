#!/usr/bin/env bash
set -euo pipefail

# FILE: run-reconnect-history-tests.sh
# Purpose: Runs the required CodexMobile mobile regression slice on an available iPhone simulator.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT_PATH="$ROOT_DIR/CodexMobile.xcodeproj"
SCHEME="${SCHEME:-CodexMobile}"
DERIVED_DATA_PATH="${DERIVED_DATA_PATH:-/tmp/remodex-codexmobile-ci-derived}"
CLONED_SOURCE_PACKAGES_DIR="${CLONED_SOURCE_PACKAGES_DIR:-}"
RESULT_BUNDLE_PATH="${RESULT_BUNDLE_PATH:-}"
CRASH_ARTIFACTS_DIR="${CRASH_ARTIFACTS_DIR:-}"
TIMEOUT_SECONDS="${TIMEOUT_SECONDS:-0}"
ITERATIONS="${ITERATIONS:-1}"
CLEAN_DERIVED_DATA="${CLEAN_DERIVED_DATA:-0}"
ERASE_SIMULATOR="${ERASE_SIMULATOR:-0}"
COLLECT_TEST_DIAGNOSTICS="${COLLECT_TEST_DIAGNOSTICS:-}"
PARALLEL_TESTING_ENABLED="${PARALLEL_TESTING_ENABLED:-}"
MAX_PARALLEL_TESTING_WORKERS="${MAX_PARALLEL_TESTING_WORKERS:-}"
XCODEBUILD_TEST_ITERATIONS="${XCODEBUILD_TEST_ITERATIONS:-1}"
RUN_TESTS_UNTIL_FAILURE="${RUN_TESTS_UNTIL_FAILURE:-0}"
TEST_REPETITION_RELAUNCH_ENABLED="${TEST_REPETITION_RELAUNCH_ENABLED:-}"
ENABLE_ADDRESS_SANITIZER="${ENABLE_ADDRESS_SANITIZER:-}"
DUMP_SIMULATOR_CRASH_LOGS_ON_FAILURE="${DUMP_SIMULATOR_CRASH_LOGS_ON_FAILURE:-1}"
ONLY_TESTING="${ONLY_TESTING:-}"
HELPERS_PATH="$ROOT_DIR/scripts/xcode-test-helpers.sh"

# shellcheck source=CodexMobile/scripts/xcode-test-helpers.sh
source "$HELPERS_PATH"

expand_user_path() {
  local path="$1"

  if [[ -z "$path" ]]; then
    printf '%s\n' ""
  elif [[ "$path" == "~" ]]; then
    printf '%s\n' "$HOME"
  elif [[ $path == \~/* ]]; then
    printf '%s\n' "$HOME/${path#~/}"
  else
    printf '%s\n' "$path"
  fi
}

CLONED_SOURCE_PACKAGES_DIR="$(expand_user_path "$CLONED_SOURCE_PACKAGES_DIR")"
DERIVED_DATA_PATH="$(expand_user_path "$DERIVED_DATA_PATH")"
RESULT_BUNDLE_PATH="$(expand_user_path "$RESULT_BUNDLE_PATH")"
CRASH_ARTIFACTS_DIR="$(expand_user_path "$CRASH_ARTIFACTS_DIR")"

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
if [[ -n "$ONLY_TESTING" ]]; then
  IFS=',' read -r -a requested_specs <<<"$ONLY_TESTING"
  for spec in "${requested_specs[@]}"; do
    spec="$(xargs <<<"$spec")"
    if [[ -n "$spec" ]]; then
      ONLY_TESTING_ARGS+=("-only-testing:${spec}")
    fi
  done
else
  for suite in "${TEST_SUITES[@]}"; do
    ONLY_TESTING_ARGS+=("-only-testing:CodexMobileTests/${suite}")
  done
fi

echo "[codexmobile-ci] destination: $DESTINATION"
echo "[codexmobile-ci] scheme: $SCHEME"
echo "[codexmobile-ci] xcode-select: $(xcode-select -p)"
echo "[codexmobile-ci] xcodebuild: $(xcodebuild -version | tr '\n' ' ' | sed 's/  */ /g')"
echo "[codexmobile-ci] macos: $(sw_vers -productVersion) ($(sw_vers -buildVersion))"
if [[ -n "$ONLY_TESTING" ]]; then
  echo "[codexmobile-ci] only-testing: $ONLY_TESTING"
else
  echo "[codexmobile-ci] suites: ${TEST_SUITES[*]}"
fi
echo "[codexmobile-ci] derived-data: $DERIVED_DATA_PATH"
if [[ -n "$SIMULATOR_UDID" ]]; then
  echo "[codexmobile-ci] simulator-udid: $SIMULATOR_UDID"
  echo "[codexmobile-ci] simulator: $(xcrun simctl list devices available | rg "$SIMULATOR_UDID" -m 1 || true)"
fi
if [[ -n "$CLONED_SOURCE_PACKAGES_DIR" ]]; then
  echo "[codexmobile-ci] source-packages: $CLONED_SOURCE_PACKAGES_DIR"
fi
if [[ -n "$RESULT_BUNDLE_PATH" ]]; then
  echo "[codexmobile-ci] result-bundle: $RESULT_BUNDLE_PATH"
fi
if [[ -n "$CRASH_ARTIFACTS_DIR" ]]; then
  echo "[codexmobile-ci] crash-artifacts: $CRASH_ARTIFACTS_DIR"
fi
if [[ "$TIMEOUT_SECONDS" -gt 0 ]]; then
  echo "[codexmobile-ci] timeout-seconds: $TIMEOUT_SECONDS"
fi
if [[ -n "$COLLECT_TEST_DIAGNOSTICS" ]]; then
  echo "[codexmobile-ci] collect-test-diagnostics: $COLLECT_TEST_DIAGNOSTICS"
fi
if [[ "$XCODEBUILD_TEST_ITERATIONS" -gt 1 ]]; then
  echo "[codexmobile-ci] xcodebuild-test-iterations: $XCODEBUILD_TEST_ITERATIONS"
fi
if [[ "$RUN_TESTS_UNTIL_FAILURE" == "1" ]]; then
  echo "[codexmobile-ci] run-tests-until-failure: enabled"
fi
if [[ -n "$TEST_REPETITION_RELAUNCH_ENABLED" ]]; then
  echo "[codexmobile-ci] test-repetition-relaunch-enabled: $TEST_REPETITION_RELAUNCH_ENABLED"
fi
if [[ -n "$ENABLE_ADDRESS_SANITIZER" ]]; then
  echo "[codexmobile-ci] address-sanitizer: $ENABLE_ADDRESS_SANITIZER"
fi

if [[ "$CLEAN_DERIVED_DATA" == "1" ]]; then
  rm -rf "$DERIVED_DATA_PATH"
fi

if [[ "$ERASE_SIMULATOR" == "1" && -n "$SIMULATOR_UDID" ]]; then
  echo "[codexmobile-ci] erasing simulator: $SIMULATOR_UDID"
  xcrun simctl shutdown "$SIMULATOR_UDID" >/dev/null 2>&1 || true
  xcrun simctl erase "$SIMULATOR_UDID"
fi

dump_recent_simulator_crash_logs() {
  local host_reports_dir="$HOME/Library/Logs/DiagnosticReports"
  local simulator_reports_dir="$HOME/Library/Developer/CoreSimulator/Devices/$SIMULATOR_UDID/data/Library/Logs/CrashReporter"
  local patterns=("CodexMobile" "xctest")
  local report

  echo "[codexmobile-ci] recent crash reports:"
  for report_dir in "$host_reports_dir" "$simulator_reports_dir"; do
    [[ -d "$report_dir" ]] || continue
    while IFS= read -r report; do
      echo "[codexmobile-ci] crash-report: $report"
      sed -n '1,120p' "$report"
    done < <(
      find "$report_dir" -type f \( -name '*.ips' -o -name '*.crash' \) -mmin -30 2>/dev/null \
        | while IFS= read -r candidate; do
            for pattern in "${patterns[@]}"; do
              if [[ "$(basename "$candidate")" == *"$pattern"* ]]; then
                printf '%s\n' "$candidate"
                break
              fi
            done
          done \
        | sort -r \
        | head -n 5
    )
  done
}

collect_failure_artifacts() {
  local artifacts_dir="$1"
  local host_reports_dir="$HOME/Library/Logs/DiagnosticReports"
  local simulator_reports_dir="$HOME/Library/Developer/CoreSimulator/Devices/$SIMULATOR_UDID/data/Library/Logs/CrashReporter"
  local test_logs_dir="$DERIVED_DATA_PATH/Logs/Test"
  local report

  [[ -n "$artifacts_dir" ]] || return 0
  mkdir -p "$artifacts_dir"

  if [[ -d "$test_logs_dir" ]]; then
    mkdir -p "$artifacts_dir/test-logs"
    cp -R "$test_logs_dir/." "$artifacts_dir/test-logs/" 2>/dev/null || true
  fi

  for report_dir in "$host_reports_dir" "$simulator_reports_dir"; do
    [[ -d "$report_dir" ]] || continue
    while IFS= read -r report; do
      cp "$report" "$artifacts_dir/" 2>/dev/null || true
    done < <(
      find "$report_dir" -type f \( -name '*.ips' -o -name '*.crash' \) -mmin -30 2>/dev/null |
        while IFS= read -r candidate; do
          local candidate_name
          candidate_name="$(basename "$candidate")"
          if [[ "$candidate_name" == *CodexMobile* || "$candidate_name" == *xctest* ]]; then
            printf '%s\n' "$candidate"
          fi
        done |
        sort -r |
        head -n 20
    )
  done
}

run_xcodebuild_once() {
  local iteration="$1"
  local cmd=(
    xcodebuild
    -project "$PROJECT_PATH"
    -scheme "$SCHEME"
    -destination "$DESTINATION"
    -derivedDataPath "$DERIVED_DATA_PATH"
  )

  if [[ -n "$CLONED_SOURCE_PACKAGES_DIR" ]]; then
    mkdir -p "$CLONED_SOURCE_PACKAGES_DIR"
    cmd+=(-clonedSourcePackagesDirPath "$CLONED_SOURCE_PACKAGES_DIR")
  fi

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
    -destination-timeout 60
    test
    CODE_SIGNING_ALLOWED=NO
    CODE_SIGNING_REQUIRED=NO
    "${ONLY_TESTING_ARGS[@]}"
  )

  if [[ -n "$COLLECT_TEST_DIAGNOSTICS" ]]; then
    cmd+=(-collect-test-diagnostics "$COLLECT_TEST_DIAGNOSTICS")
  fi

  if [[ -n "$PARALLEL_TESTING_ENABLED" ]]; then
    cmd+=(-parallel-testing-enabled "$PARALLEL_TESTING_ENABLED")
  fi

  if [[ -n "$MAX_PARALLEL_TESTING_WORKERS" ]]; then
    cmd+=(-maximum-parallel-testing-workers "$MAX_PARALLEL_TESTING_WORKERS")
  fi

  if [[ "$XCODEBUILD_TEST_ITERATIONS" -gt 1 ]]; then
    cmd+=(-test-iterations "$XCODEBUILD_TEST_ITERATIONS")
  fi

  if [[ "$RUN_TESTS_UNTIL_FAILURE" == "1" ]]; then
    cmd+=(-run-tests-until-failure)
  fi

  if [[ -n "$TEST_REPETITION_RELAUNCH_ENABLED" ]]; then
    cmd+=(-test-repetition-relaunch-enabled "$TEST_REPETITION_RELAUNCH_ENABLED")
  fi

  if [[ -n "$ENABLE_ADDRESS_SANITIZER" ]]; then
    cmd+=(-enableAddressSanitizer "$ENABLE_ADDRESS_SANITIZER")
  fi

  printf '[codexmobile-ci] command:'
  printf ' %q' "${cmd[@]}"
  printf '\n'

  local status=0

  if [[ "$TIMEOUT_SECONDS" -gt 0 ]]; then
    python3 - "$TIMEOUT_SECONDS" "${cmd[@]}" <<'PY' || status=$?
import subprocess
import sys
import os
import signal

timeout = int(sys.argv[1])
command = sys.argv[2:]
process = subprocess.Popen(command, start_new_session=True)
try:
    raise SystemExit(process.wait(timeout=timeout))
except subprocess.TimeoutExpired:
    os.killpg(process.pid, signal.SIGTERM)
    try:
        process.wait(timeout=15)
    except subprocess.TimeoutExpired:
        os.killpg(process.pid, signal.SIGKILL)
        process.wait()
    raise SystemExit(124)
PY
  else
    "${cmd[@]}" || status=$?
  fi

  if [[ "$status" -ne 0 ]]; then
    collect_failure_artifacts "$CRASH_ARTIFACTS_DIR"
    if [[ "$DUMP_SIMULATOR_CRASH_LOGS_ON_FAILURE" == "1" ]]; then
      dump_recent_simulator_crash_logs
    fi
    return "$status"
  fi
}

for ((iteration = 1; iteration <= ITERATIONS; iteration++)); do
  if [[ "$ITERATIONS" -gt 1 ]]; then
    echo "[codexmobile-ci] iteration $iteration/$ITERATIONS"
  fi
  run_xcodebuild_once "$iteration"
done
