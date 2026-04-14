#!/usr/bin/env bash
set -euo pipefail

pick_ios_simulator_destination() {
  local project_path="$1"
  local scheme="$2"
  shift 2
  local preferred_names=("$@")
  local destinations
  destinations="$(xcodebuild -project "$project_path" -scheme "$scheme" -showdestinations 2>/dev/null)"

  DESTINATIONS="$destinations" python3 - "${preferred_names[@]}" <<'PY'
import os
import re
import sys

raw = os.environ.get("DESTINATIONS", "")
preferred_names = sys.argv[1:]
entries = []
pattern = re.compile(r"\{ (?P<body>.+) \}|\{(?P<body_compact>.+)\}")

for line in raw.splitlines():
    if "platform:iOS Simulator" not in line:
        continue
    match = pattern.search(line.strip())
    if not match:
        continue
    body = match.group("body") or match.group("body_compact") or ""
    fields = {}
    for part in body.split(", "):
        if ":" not in part:
            continue
        key, value = part.split(":", 1)
        fields[key.strip()] = value.strip()
    name = fields.get("name", "")
    os_version = fields.get("OS", "")
    if not name or not os_version:
        continue
    entries.append(
        {
            "name": name,
            "os": os_version,
            "destination": f"platform=iOS Simulator,OS={os_version},name={name}",
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
