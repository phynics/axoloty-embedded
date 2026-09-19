#!/bin/sh
# Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

# Device diagnostic: record the attached ESP32-C6 and the toolchain that
# queried it. This is not a qualification check: it produces no pass/fail and
# no evidence record, because it drives no protocol and nothing can fail.
# Qualification records name the unit through the manifest this writes.
#
# Environment:
#   AXOLOTY_DEVICE_PORT   required; the board to query, never guessed.
#   AXOLOTY_SCRATCH       optional; proof root, default <repo>/.axoloty.
#
# Exit status: 0 recorded, 1 failed, 64 bad usage, 69 a capability is absent.

set -eu

script_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
repo_root=$(CDPATH='' cd -- "$script_dir/../.." && pwd)

if [ -z "${AXOLOTY_DEVICE_PORT:-}" ]; then
    echo "run-device-info-test: AXOLOTY_DEVICE_PORT must name a board" >&2
    exit 69
fi
if [ ! -e "$AXOLOTY_DEVICE_PORT" ]; then
    echo "run-device-info-test: $AXOLOTY_DEVICE_PORT does not exist" >&2
    exit 69
fi

device=$AXOLOTY_DEVICE_PORT
scratch=${AXOLOTY_SCRATCH:-"$repo_root/.axoloty"}
evidence_dir=${EMBEDDED_EVIDENCE_DIR:-"$scratch/device/device-info/working-evidence"}
raw="$evidence_dir/device-info-raw.txt"
manifest="$evidence_dir/device-manifest.json"

idf_root=${IDF_PATH:-/opt/esp/idf}
if [ ! -f "$idf_root/export.sh" ]; then
    echo "run-device-info-test: ESP-IDF is not present at $idf_root" >&2
    exit 69
fi
# shellcheck source=/dev/null
. "$idf_root/export.sh" >/dev/null 2>&1

mkdir -p "$evidence_dir"
: > "$raw"

# Each query is appended with its own header so the raw log is self-describing,
# and a failed query is recorded rather than silently dropped.
raw_section() {
    header=$1
    shift
    printf '\n===== %s =====\n' "$header" >>"$raw"
    "$@" >>"$raw" 2>&1 || true
}

raw_section "esptool chip_id" esptool.py --port "$device" chip_id
if ! grep -Eiq 'ESP32-C6' "$raw"; then
    echo "run-device-info-test: $device is not an ESP32-C6 (see $raw)" >&2
    exit 1
fi
raw_section "esptool flash_id" esptool.py --port "$device" flash_id
raw_section "idf.py version" idf.py --version
raw_section "swift version" swift --version

node "$repo_root/Platforms/esp32c6-idf/tools/write-device-manifest.mjs" \
    "$device" "$raw" "$manifest"
echo "DEVICE INFO RECORDED $manifest"
