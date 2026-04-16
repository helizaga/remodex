#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"

shellcheck -x \
  "$ROOT_DIR/run-local-remodex.sh" \
  "$ROOT_DIR"/CodexMobile/scripts/*.sh \
  "$ROOT_DIR"/scripts/*.sh
