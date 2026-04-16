#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"

if ! command -v actionlint >/dev/null 2>&1; then
  echo "[workflow-lint] missing required command: actionlint" >&2
  echo "[workflow-lint] install actionlint or run this check in CI." >&2
  exit 1
fi

cd "$ROOT_DIR"
actionlint
