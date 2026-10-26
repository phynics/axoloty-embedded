#!/bin/sh
# Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

set -eu
repo_root=$(CDPATH='' cd -- "$(dirname -- "$0")/../.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

for profile in esp32c6-mqtt esp32c6-zenoh; do
    python3 "$repo_root/Tools/validate-composition.py" --repo-root "$repo_root" \
        --profile "$repo_root/Profiles/$profile/profile.json"
done

python3 - "$repo_root/Applications/device-smoke-agent/app.json" "$tmp/invalid.json" <<'PY'
import json, pathlib, sys
value = json.loads(pathlib.Path(sys.argv[1]).read_text())
value["requirements"]["carrier"].append("missing.required.capability")
pathlib.Path(sys.argv[2]).write_text(json.dumps(value))
PY
if python3 "$repo_root/Tools/validate-composition.py" --repo-root "$repo_root" \
    --app-manifest "$tmp/invalid.json" --emit-requirements "$tmp/Requirements.swift" \
    >"$tmp/invalid.log" 2>&1; then
    echo "FAIL: invalid required capability was accepted" >&2
    exit 1
fi
grep -F "unknown carrier capability name: missing.required.capability" "$tmp/invalid.log" >/dev/null || {
    cat "$tmp/invalid.log" >&2
    echo "FAIL: invalid capability was rejected for an unexpected reason" >&2
    exit 1
}
echo "profile composition: MQTT and Zenoh pass; invalid required capability is rejected"
