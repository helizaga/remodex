#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"

if ! command -v swiftformat >/dev/null 2>&1; then
  echo "[swift-lint] missing required command: swiftformat" >&2
  echo "[swift-lint] install swiftformat or run this check in CI." >&2
  exit 1
fi

if ! command -v swiftlint >/dev/null 2>&1; then
  echo "[swift-lint] missing required command: swiftlint" >&2
  echo "[swift-lint] install swiftlint or run this check in CI." >&2
  exit 1
fi

cd "$ROOT_DIR"

SWIFT_PATHS=(
  CodexMobile/CodexMobile
  CodexMobile/CodexMobileTests
  CodexMobile/CodexMobileUITests
  CodexMobile/RemodexMenuBar
)

swiftformat --lint "${SWIFT_PATHS[@]}" --config "$ROOT_DIR/.swiftformat"
swiftlint lint --strict --quiet --config "$ROOT_DIR/.swiftlint.yml"
