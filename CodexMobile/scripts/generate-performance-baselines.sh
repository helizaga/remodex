#!/usr/bin/env bash
set -euo pipefail

# FILE: generate-performance-baselines.sh
# Purpose: Runs the focused perf suites and refreshes the checked-in JSON baselines.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT_PATH="$ROOT_DIR/CodexMobile.xcodeproj"
SCHEME="${SCHEME:-CodexMobile}"
HELPERS_PATH="$ROOT_DIR/scripts/xcode-test-helpers.sh"
DERIVED_DATA_PATH="${DERIVED_DATA_PATH:-/tmp/remodex-performance-baselines-derived}"
TURNVIEW_BASELINE_PATH="${TURNVIEW_BASELINE_PATH:-$ROOT_DIR/Docs/TurnView-Performance-Baseline.json}"
SIDEBAR_BASELINE_PATH="${SIDEBAR_BASELINE_PATH:-$ROOT_DIR/Docs/Sidebar-RunBadge-Performance-Baseline.json}"
TURNVIEW_MAX_REGRESSION_PERCENT="${TURNVIEW_MAX_REGRESSION_PERCENT:-10.0}"
SIDEBAR_MAX_REGRESSION_PERCENT="${SIDEBAR_MAX_REGRESSION_PERCENT:-12.0}"

# shellcheck source=CodexMobile/scripts/xcode-test-helpers.sh
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

TURNVIEW_RESULT_BUNDLE_PATH="${TURNVIEW_RESULT_BUNDLE_PATH:-$(make_result_bundle_path "TurnViewPerformanceBaseline")}"
SIDEBAR_RESULT_BUNDLE_PATH="${SIDEBAR_RESULT_BUNDLE_PATH:-$(make_result_bundle_path "SidebarRunBadgePerformanceBaseline")}"

echo "[perf-baselines] destination: $DESTINATION"
echo "[perf-baselines] scheme: $SCHEME"

echo "[perf-baselines] running TurnView performance suite"
xcodebuild \
  -quiet \
  -project "$PROJECT_PATH" \
  -scheme "$SCHEME" \
  -destination "$DESTINATION" \
  -derivedDataPath "$DERIVED_DATA_PATH" \
  -resultBundlePath "$TURNVIEW_RESULT_BUNDLE_PATH" \
  test \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  -only-testing:CodexMobileUITests/CodexMobileUITests/testTurnTimelineScrollingPerformance \
  -only-testing:CodexMobileUITests/CodexMobileUITests/testTurnStreamingAppendPerformance

python3 "$ROOT_DIR/scripts/performance-metrics.py" baseline \
  --suite turnview \
  --xcresult "$TURNVIEW_RESULT_BUNDLE_PATH" \
  --output "$TURNVIEW_BASELINE_PATH" \
  --max-regression-percent "$TURNVIEW_MAX_REGRESSION_PERCENT"

echo "[perf-baselines] running sidebar badge performance suite"
xcodebuild \
  -quiet \
  -project "$PROJECT_PATH" \
  -scheme "$SCHEME" \
  -destination "$DESTINATION" \
  -derivedDataPath "$DERIVED_DATA_PATH" \
  -resultBundlePath "$SIDEBAR_RESULT_BUNDLE_PATH" \
  test \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  -only-testing:CodexMobileTests/SidebarRunBadgePerformanceTests/testSidebarRunBadgeSnapshotPerformance \
  -only-testing:CodexMobileTests/SidebarRunBadgePerformanceTests/testSidebarRunBadgeSnapshotWithLargeTimelinePerformance

python3 "$ROOT_DIR/scripts/performance-metrics.py" baseline \
  --suite sidebar \
  --xcresult "$SIDEBAR_RESULT_BUNDLE_PATH" \
  --output "$SIDEBAR_BASELINE_PATH" \
  --max-regression-percent "$SIDEBAR_MAX_REGRESSION_PERCENT"

echo "[perf-baselines] baseline refresh complete"
