#!/usr/bin/env bash
set -euo pipefail

# FILE: check-turnview-performance.sh
# Purpose: Runs TurnView UI perf tests and fails if key metrics regress beyond baseline.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT_PATH="$ROOT_DIR/CodexMobile.xcodeproj"
SCHEME="${SCHEME:-CodexMobile}"
HELPERS_PATH="$ROOT_DIR/scripts/xcode-test-helpers.sh"
BASELINE_PATH="${BASELINE_PATH:-$ROOT_DIR/Docs/TurnView-Performance-Baseline.json}"
MAX_REGRESSION_PERCENT="${MAX_REGRESSION_PERCENT:-}"
DERIVED_DATA_PATH="${DERIVED_DATA_PATH:-/tmp/remodex-turnview-performance-derived}"
RESULT_BUNDLE_PATH="${RESULT_BUNDLE_PATH:-}"

source "$HELPERS_PATH"

DESTINATION="${DESTINATION:-$(pick_ios_simulator_destination "$PROJECT_PATH" "$SCHEME" \
  "iPhone 17" \
  "iPhone 17 Pro" \
  "iPhone 16 Pro" \
  "iPhone 16")}"

if [[ ! -f "$BASELINE_PATH" ]]; then
  echo "Baseline file not found: $BASELINE_PATH"
  exit 1
fi

if [[ -z "$RESULT_BUNDLE_PATH" ]]; then
  RESULT_BUNDLE_PATH="$(make_result_bundle_path "TurnViewPerformance")"
fi

echo "[turnview-perf] destination: $DESTINATION"
echo "[turnview-perf] baseline: $BASELINE_PATH"
echo "[turnview-perf] result bundle: $RESULT_BUNDLE_PATH"

xcodebuild \
  -quiet \
  -project "$PROJECT_PATH" \
  -scheme "$SCHEME" \
  -destination "$DESTINATION" \
  -derivedDataPath "$DERIVED_DATA_PATH" \
  -resultBundlePath "$RESULT_BUNDLE_PATH" \
  test \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  -only-testing:CodexMobileUITests/CodexMobileUITests/testTurnTimelineScrollingPerformance \
  -only-testing:CodexMobileUITests/CodexMobileUITests/testTurnStreamingAppendPerformance

if [[ ! -d "$RESULT_BUNDLE_PATH" ]]; then
  echo "Unable to locate xcresult path at $RESULT_BUNDLE_PATH."
  exit 1
fi

compare_args=(
  "$ROOT_DIR/scripts/performance-metrics.py"
  compare
  --suite turnview
  --xcresult "$RESULT_BUNDLE_PATH"
  --baseline "$BASELINE_PATH"
)

if [[ -n "$MAX_REGRESSION_PERCENT" ]]; then
  compare_args+=(--max-regression-percent "$MAX_REGRESSION_PERCENT")
fi

python3 "${compare_args[@]}"
