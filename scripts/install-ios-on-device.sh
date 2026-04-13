#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT_PATH="$ROOT_DIR/CodexMobile/CodexMobile.xcodeproj"
SCHEME="${REMODEX_IOS_SCHEME:-CodexMobile}"
CONFIGURATION="${REMODEX_IOS_CONFIGURATION:-Debug}"
DERIVED_DATA_PATH="${REMODEX_IOS_DERIVED_DATA_PATH:-/tmp/remodex-derived}"
LAUNCH_AFTER_INSTALL="true"
DEVICE_ID="${REMODEX_IOS_DEVICE_ID:-}"

usage() {
  cat <<'EOF'
Usage: ./scripts/install-ios-on-device.sh [--device <udid>] [--no-launch]

Builds the CodexMobile iPhone app for a connected device, installs it, and launches it.
If iOS rejects the install because an older copy was signed under a different application-identifier
prefix, the script uninstalls the stale app and retries automatically.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --device)
      DEVICE_ID="${2:-}"
      if [[ -z "$DEVICE_ID" ]]; then
        echo "[install-ios] --device requires a value" >&2
        exit 1
      fi
      shift 2
      ;;
    --no-launch)
      LAUNCH_AFTER_INSTALL="false"
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      if [[ -n "$DEVICE_ID" ]]; then
        echo "[install-ios] unexpected argument: $1" >&2
        usage >&2
        exit 1
      fi
      DEVICE_ID="$1"
      shift
      ;;
  esac
done

resolve_connected_iphone() {
  /usr/bin/python3 <<'PY'
import json
import subprocess
import sys

devices = json.loads(subprocess.check_output(["xcrun", "xcdevice", "list"], text=True))
phones = [
    device for device in devices
    if not device.get("simulator")
    and device.get("platform") == "com.apple.platform.iphoneos"
    and device.get("available")
]
if not phones:
    sys.exit(1)

device = phones[0]
print(device["identifier"])
print(device["name"])
PY
}

if [[ -z "$DEVICE_ID" ]]; then
  DEVICE_INFO_RAW="$(resolve_connected_iphone || true)"
  if [[ -z "$DEVICE_INFO_RAW" ]]; then
    echo "[install-ios] no connected iPhone detected" >&2
    echo "[install-ios] pass a device UDID as the first argument or set REMODEX_IOS_DEVICE_ID." >&2
    exit 1
  fi
  OLD_IFS="$IFS"
  IFS=$'\n'
  DEVICE_INFO=($DEVICE_INFO_RAW)
  IFS="$OLD_IFS"
  DEVICE_ID="${DEVICE_INFO[0]}"
  DEVICE_NAME="${DEVICE_INFO[1]:-$DEVICE_ID}"
else
  DEVICE_NAME="$DEVICE_ID"
fi

APP_PATH="$DERIVED_DATA_PATH/Build/Products/${CONFIGURATION}-iphoneos/${SCHEME}.app"
INSTALL_LOG="$(mktemp -t remodex-ios-install.XXXXXX.log)"
trap 'rm -f "$INSTALL_LOG"' EXIT

echo "[install-ios] device: $DEVICE_NAME ($DEVICE_ID)"
echo "[install-ios] scheme: $SCHEME"
echo "[install-ios] configuration: $CONFIGURATION"

xcodebuild \
  -project "$PROJECT_PATH" \
  -scheme "$SCHEME" \
  -configuration "$CONFIGURATION" \
  -destination "id=$DEVICE_ID" \
  -derivedDataPath "$DERIVED_DATA_PATH" \
  -allowProvisioningUpdates \
  build

if [[ ! -d "$APP_PATH" ]]; then
  echo "[install-ios] build succeeded but app bundle was not found at $APP_PATH" >&2
  exit 1
fi

BUNDLE_ID="$(defaults read "$APP_PATH/Info" CFBundleIdentifier)"
echo "[install-ios] bundle id: $BUNDLE_ID"

install_app() {
  xcrun devicectl device install app --device "$DEVICE_ID" "$APP_PATH" >"$INSTALL_LOG" 2>&1
}

if ! install_app; then
  cat "$INSTALL_LOG" >&2
  if rg -q "MismatchedApplicationIdentifierEntitlement|rejecting upgrade|does not match installed application's application-identifier string" "$INSTALL_LOG"; then
    echo "[install-ios] installed app was signed under a different application-identifier prefix; uninstalling stale copy and retrying."
    xcrun devicectl device uninstall app --device "$DEVICE_ID" "$BUNDLE_ID"
    install_app
  else
    exit 1
  fi
fi

cat "$INSTALL_LOG"

if [[ "$LAUNCH_AFTER_INSTALL" == "true" ]]; then
  xcrun devicectl device process launch --device "$DEVICE_ID" "$BUNDLE_ID"
fi
