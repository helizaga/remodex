#!/usr/bin/env bash
set -euo pipefail

# FILE: run-connection-error-diagnostics.sh
# Purpose: Repeats the CodexService connection-error suite with stronger diagnostics for allocator crashes.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUNNER_PATH="$ROOT_DIR/scripts/run-reconnect-history-tests.sh"

MODE="${DIAGNOSTIC_MODE:-baseline}"
TEST_IDENTIFIER="${TEST_IDENTIFIER:-CodexMobileTests/CodexServiceConnectionErrorTests}"
TEST_ITERATIONS="${TEST_ITERATIONS:-}"
RESULT_BUNDLE_PATH="${RESULT_BUNDLE_PATH:-/tmp/remodex-connection-error-diagnostics.xcresult}"
DERIVED_DATA_PATH="${DERIVED_DATA_PATH:-/tmp/remodex-connection-error-diagnostics-derived}"
ERASE_SIMULATOR="${ERASE_SIMULATOR:-1}"
CLEAN_DERIVED_DATA="${CLEAN_DERIVED_DATA:-1}"

export ONLY_TESTING="$TEST_IDENTIFIER"
export PARALLEL_TESTING_ENABLED="${PARALLEL_TESTING_ENABLED:-NO}"
export MAX_PARALLEL_TESTING_WORKERS="${MAX_PARALLEL_TESTING_WORKERS:-1}"
export COLLECT_TEST_DIAGNOSTICS="${COLLECT_TEST_DIAGNOSTICS:-on-failure}"
export RUN_TESTS_UNTIL_FAILURE="${RUN_TESTS_UNTIL_FAILURE:-1}"
export TEST_REPETITION_RELAUNCH_ENABLED="${TEST_REPETITION_RELAUNCH_ENABLED:-YES}"
export RESULT_BUNDLE_PATH
export DERIVED_DATA_PATH
export ERASE_SIMULATOR
export CLEAN_DERIVED_DATA

case "$MODE" in
  baseline)
    export XCODEBUILD_TEST_ITERATIONS="${TEST_ITERATIONS:-50}"
    ;;
  asan)
    export XCODEBUILD_TEST_ITERATIONS="${TEST_ITERATIONS:-25}"
    export ENABLE_ADDRESS_SANITIZER=YES
    ;;
  scribble)
    export XCODEBUILD_TEST_ITERATIONS="${TEST_ITERATIONS:-20}"
    export MallocScribble=1
    export MallocStackLoggingNoCompact=1
    export SIMCTL_CHILD_MallocScribble=1
    export SIMCTL_CHILD_MallocStackLoggingNoCompact=1
    ;;
  gmalloc)
    export XCODEBUILD_TEST_ITERATIONS="${TEST_ITERATIONS:-10}"
    export DYLD_INSERT_LIBRARIES=/usr/lib/libgmalloc.dylib
    export MallocStackLoggingNoCompact=1
    export SIMCTL_CHILD_DYLD_INSERT_LIBRARIES=/usr/lib/libgmalloc.dylib
    export SIMCTL_CHILD_MallocStackLoggingNoCompact=1
    ;;
  zombie)
    export XCODEBUILD_TEST_ITERATIONS="${TEST_ITERATIONS:-10}"
    export NSZombieEnabled=YES
    export SIMCTL_CHILD_NSZombieEnabled=YES
    ;;
  *)
    echo "Unknown DIAGNOSTIC_MODE: $MODE" >&2
    echo "Supported modes: baseline, asan, scribble, gmalloc, zombie" >&2
    exit 1
    ;;
esac

echo "[codexmobile-diagnostics] mode: $MODE"
echo "[codexmobile-diagnostics] only-testing: $ONLY_TESTING"
echo "[codexmobile-diagnostics] xcodebuild-test-iterations: $XCODEBUILD_TEST_ITERATIONS"
echo "[codexmobile-diagnostics] result-bundle: $RESULT_BUNDLE_PATH"

"$RUNNER_PATH"
