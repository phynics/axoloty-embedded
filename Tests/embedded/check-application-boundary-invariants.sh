#!/bin/sh
# Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

set -eu

script_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
repo_root=$(git -C "$script_dir" rev-parse --show-toplevel)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

fixture="$tmp/repo"
mkdir -p "$fixture/Tools" "$fixture/Applications/demo/main" "$fixture/Platforms/demo"
cp "$repo_root/Tools/check-invariants.sh" "$fixture/Tools/check-invariants.sh"
git -C "$fixture" init -q
printf '%s\n' 'let selected = "AXOLOTY_APPLICATION_DIR"' > "$fixture/Applications/demo/main/App.swift"
printf '%s\n' 'set(SELECTED_APPLICATION "$ENV{AXOLOTY_APPLICATION_DIR}")' > "$fixture/Platforms/demo/CMakeLists.txt"
git -C "$fixture" add .

run_check() {
    (cd "$fixture" && bash Tools/check-invariants.sh --application-boundary-only)
}

output=$(run_check 2>&1)
printf '%s\n' "$output" | grep -Fq 'ok       [platform-generic-application]'
printf '%s\n' "$output" | grep -Fq 'ok       [application-pure-swift]'

printf '%s\n' 'int app_private(void);' > "$fixture/Applications/demo/include.h"
git -C "$fixture" add Applications/demo/include.h
if output=$(run_check 2>&1); then
    echo 'FAIL: C header application fixture passed' >&2
    exit 1
fi
printf '%s\n' "$output" | grep -Fq '[application-pure-swift]'
rm "$fixture/Applications/demo/include.h"
git -C "$fixture" rm -q Applications/demo/include.h

printf '%s\n' '#include "Applications/demo/private.h"' > "$fixture/Platforms/demo/Probe.c"
git -C "$fixture" add Platforms/demo/Probe.c
if output=$(run_check 2>&1); then
    echo 'FAIL: named platform application probe fixture passed' >&2
    exit 1
fi
printf '%s\n' "$output" | grep -Fq '[platform-generic-application]'

printf '%s\n' 'check-application-boundary-invariants: all fixtures passed'

# The profile selector must bind the directory, not only app.json.name.
selected="$repo_root/Applications/device-smoke-agent"
node "$repo_root/Tools/select-profile-application.mjs" \
    "$repo_root/Profiles/esp32c6-mqtt" "$selected" >/dev/null
duplicate="$tmp/duplicate-app"
mkdir -p "$duplicate"
cp "$selected/app.json" "$duplicate/app.json"
if node "$repo_root/Tools/select-profile-application.mjs" \
    "$repo_root/Profiles/esp32c6-mqtt" "$duplicate" >/dev/null 2>&1; then
    echo 'FAIL: profile selector accepted a different directory with the same manifest name' >&2
    exit 1
fi

printf '%s\n' 'check-application-boundary-invariants: selection fixtures passed'
