#!/usr/bin/env bash
set -euo pipefail

pick_ios_simulator_destination() {
  shift 2
  local preferred_names=("$@")
  local devices_json
  devices_json="$(xcrun simctl list devices available --json)"

  DEVICES_JSON="$devices_json" python3 - "${preferred_names[@]}" <<'PY'
import json
import os
import sys

raw = os.environ.get("DEVICES_JSON", "")
preferred_names = sys.argv[1:]
payload = json.loads(raw)
entries = []

for runtime_identifier, devices in payload.get("devices", {}).items():
    if "iOS" not in runtime_identifier:
        continue
    os_version = runtime_identifier.rsplit("iOS-", 1)[-1].replace("-", ".")
    for device in devices:
        if not device.get("isAvailable", True):
            continue
        name = device.get("name", "")
        udid = device.get("udid", "")
        if not name or not udid:
            continue
        entries.append(
            {
                "name": name,
                "os": os_version,
                "destination": f"platform=iOS Simulator,id={udid}",
            }
        )

if not entries:
    sys.exit(1)

def version_key(entry):
    return tuple(int(part) for part in entry["os"].split("."))

for preferred_name in preferred_names:
    matches = [entry for entry in entries if entry["name"] == preferred_name]
    if matches:
        print(max(matches, key=version_key)["destination"])
        sys.exit(0)

iphone_entries = [entry for entry in entries if entry["name"].startswith("iPhone ")]
target_pool = iphone_entries or entries
print(max(target_pool, key=version_key)["destination"])
PY
}

make_result_bundle_path() {
  local prefix="$1"
  local bundle_dir
  bundle_dir="$(mktemp -d "/tmp/${prefix}.XXXXXX")"
  printf '%s/%s.xcresult\n' "$bundle_dir" "$prefix"
}
