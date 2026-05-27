#!/usr/bin/env bash
set -euo pipefail

# FILE: check-sidebar-badge-performance.sh
# Purpose: Runs sidebar badge perf tests and fails when clock/CPU metrics regress past baseline.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT_PATH="$ROOT_DIR/CodexMobile.xcodeproj"
SCHEME="${SCHEME:-CodexMobile}"
HELPERS_PATH="$ROOT_DIR/scripts/xcode-test-helpers.sh"
BASELINE_PATH="${BASELINE_PATH:-$ROOT_DIR/Docs/Sidebar-RunBadge-Performance-Baseline.json}"
MAX_REGRESSION_PERCENT="${MAX_REGRESSION_PERCENT:-}"
DERIVED_DATA_PATH="${DERIVED_DATA_PATH:-/tmp/remodex-sidebar-performance-derived}"
RESULT_BUNDLE_PATH="${RESULT_BUNDLE_PATH:-}"

# shellcheck source=CodexMobile/scripts/xcode-test-helpers.sh
source "$HELPERS_PATH"

DESTINATION="${DESTINATION:-$(pick_ios_simulator_destination "$PROJECT_PATH" "$SCHEME" \
  "iPhone 17" \
  "iPhone 17 Pro" \
  "iPhone 16 Pro" \
  "iPhone 16")}"

print_usage() {
  cat <<EOF
Usage: BASELINE_PATH=/path/to/sidebar-baseline.json $0

Runs SidebarRunBadgePerformanceTests and compares xcresult metrics with a JSON baseline.

Environment:
  SCHEME                   Xcode scheme. Default: CodexMobile
  DESTINATION              xcodebuild destination. Default: platform=iOS Simulator,name=iPhone 17
  BASELINE_PATH            Required baseline JSON path. Default: $ROOT_DIR/Docs/Sidebar-RunBadge-Performance-Baseline.json
  MAX_REGRESSION_PERCENT   Optional override for the baseline max_regression_percent value.

Helpers:
  $0 --print-baseline-template
  $0 --help
EOF
}

print_baseline_template() {
  cat <<'EOF'
{
  "max_regression_percent": 12.0,
  "metrics": {
    "snapshot_clock_s": 0.0,
    "snapshot_cpu_time_s": 0.0,
    "large_timeline_clock_s": 0.0,
    "large_timeline_cpu_time_s": 0.0
  }
}
EOF
}

case "${1:-}" in
  "" ) ;;
  "-h"|"--help" )
    print_usage
    exit 0
    ;;
  "--print-baseline-template" )
    print_baseline_template
    exit 0
    ;;
  * )
    echo "Unknown argument: $1" >&2
    print_usage >&2
    exit 2
    ;;
esac

if [[ ! -f "$BASELINE_PATH" ]]; then
  cat >&2 <<EOF
Baseline file not found: $BASELINE_PATH

Provide an explicit baseline file before running the performance check:
  BASELINE_PATH=/path/to/sidebar-baseline.json $0

To see the required JSON shape:
  $0 --print-baseline-template
EOF
  exit 1
fi

if [[ -z "$RESULT_BUNDLE_PATH" ]]; then
  RESULT_BUNDLE_PATH="$(make_result_bundle_path "SidebarRunBadgePerformance")"
fi

echo "[sidebar-perf] destination: $DESTINATION"
echo "[sidebar-perf] baseline: $BASELINE_PATH"
echo "[sidebar-perf] result bundle: $RESULT_BUNDLE_PATH"

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
  -only-testing:CodexMobileTests/SidebarRunBadgePerformanceTests/testSidebarRunBadgeSnapshotPerformance \
  -only-testing:CodexMobileTests/SidebarRunBadgePerformanceTests/testSidebarRunBadgeSnapshotWithLargeTimelinePerformance

if [[ ! -d "$RESULT_BUNDLE_PATH" ]]; then
  echo "Unable to locate xcresult path at $RESULT_BUNDLE_PATH."
  exit 1
fi

compare_args=(
  "$ROOT_DIR/scripts/performance-metrics.py"
  compare
  --suite sidebar
  --xcresult "$RESULT_BUNDLE_PATH"
  --baseline "$BASELINE_PATH"
)

if [[ -n "$MAX_REGRESSION_PERCENT" ]]; then
  compare_args+=(--max-regression-percent "$MAX_REGRESSION_PERCENT")
fi

python3 "${compare_args[@]}"
