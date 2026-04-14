#!/usr/bin/env bash
set -euo pipefail

# FILE: run-reconnect-history-tests.sh
# Purpose: Runs the required CodexMobile mobile regression slice on an available iPhone simulator.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT_PATH="$ROOT_DIR/CodexMobile.xcodeproj"
SCHEME="${SCHEME:-CodexMobile}"
DERIVED_DATA_PATH="${DERIVED_DATA_PATH:-/tmp/remodex-codexmobile-ci-derived}"
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

xcodebuild \
  -project "$PROJECT_PATH" \
  -scheme "$SCHEME" \
  -destination "$DESTINATION" \
  -derivedDataPath "$DERIVED_DATA_PATH" \
  test \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  "${ONLY_TESTING_ARGS[@]}"
