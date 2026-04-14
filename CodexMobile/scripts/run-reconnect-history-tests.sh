#!/usr/bin/env bash
set -euo pipefail

# FILE: run-reconnect-history-tests.sh
# Purpose: Runs the narrow CodexMobile reconnect/history regression slice on an available iPhone simulator.

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

echo "[codexmobile-ci] destination: $DESTINATION"
echo "[codexmobile-ci] scheme: $SCHEME"

xcodebuild \
  -project "$PROJECT_PATH" \
  -scheme "$SCHEME" \
  -destination "$DESTINATION" \
  -derivedDataPath "$DERIVED_DATA_PATH" \
  test \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  -only-testing:CodexMobileTests/ContentViewModelReconnectTests \
  -only-testing:CodexMobileTests/CodexServiceConnectionErrorTests \
  -only-testing:CodexMobileTests/DesktopHandoffServiceTests \
  -only-testing:CodexMobileTests/CodexServiceIncomingRunIndicatorTests \
  -only-testing:CodexMobileTests/CodexServiceRelayHistoryNoticeTests \
  -only-testing:CodexMobileTests/CodexServiceCatchupRecoveryTests \
  -only-testing:CodexMobileTests/TurnConnectionRecoverySnapshotBuilderTests
