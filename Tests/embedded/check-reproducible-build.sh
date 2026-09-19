#!/bin/sh
# Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

# Verify the profile firmware is bit-for-bit reproducible. Moved from the
# pre-split Axoloty Swift reproducible-build check. Builds the profile twice
# from clean proof roots, records the SHA-256 of axoloty-swift.bin, and fails
# when the two hashes differ. Needs the ESP-IDF toolchain, no board.
#
# Exit status: 0 passed, 1 failed, 69 required tool missing.

set -eu

script_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
repo_root=$(git -C "$script_dir" rev-parse --show-toplevel)
profile=${1:-esp32c6-mqtt}
profile_dir="$repo_root/Profiles/$profile"

if [ ! -x "$profile_dir/build.sh" ]; then
    echo "REPRODUCIBLE BUILD FAIL: profile has no executable build.sh: $profile" >&2
    exit 64
fi

idf_root=${IDF_PATH:-/opt/esp/idf}
if [ ! -f "$idf_root/export.sh" ]; then
    echo "reproducible build check requires ESP-IDF at $idf_root" >&2
    exit 69
fi
# shellcheck source=/dev/null
. "$idf_root/export.sh" >/dev/null 2>&1
if ! command -v idf.py >/dev/null 2>&1; then
    echo "reproducible build check requires idf.py after ESP-IDF activation" >&2
    exit 69
fi

scratch=${AXOLOTY_SCRATCH:-"$repo_root/.axoloty"}
proof_base=${EMBEDDED_PROOF_ROOT:-"$scratch/firmware-reproducible"}
out_dir=${EMBEDDED_OUTPUT_DIR:-"$scratch/reproducible"}
bin_name="axoloty-swift.bin"
report="$out_dir/reproducible-build.json"

mkdir -p "$out_dir"

sha_for_clean_build() {
    run=$1
    root="$proof_base/run-$run"
    rm -rf -- "$root"
    mkdir -p "$root"
    AXOLOTY_PROOF_RUN_ID="reproducible-$run" \
        EMBEDDED_PROOF_ROOT="$root" \
        EMBEDDED_BUILD_DIR="$root/build" \
        EMBEDDED_EVIDENCE_DIR="$root/working-evidence" \
        "$profile_dir/build.sh" >"$root/build-$run.log" 2>&1
    bin_path="$root/working-evidence/$bin_name"
    if [ ! -f "$bin_path" ]; then
        echo "REPRODUCIBLE BUILD FAIL: $bin_path not produced" >&2
        exit 1
    fi
    sha256sum "$bin_path" | awk '{print $1}'
}

echo "== build 1 =="
hash1=$(sha_for_clean_build 1)
echo "hash1: $hash1"

echo "== build 2 =="
hash2=$(sha_for_clean_build 2)
echo "hash2: $hash2"

if [ "$hash1" = "$hash2" ]; then
    result="REPRODUCIBLE BUILD OK"
    status=true
else
    result="REPRODUCIBLE BUILD FAIL"
    status=false
fi

cat >"$report" <<EOF
{
  "binary": "${bin_name}",
  "hash1": "${hash1}",
  "hash2": "${hash2}",
  "reproducible": ${status},
  "capturedAt": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
EOF

echo "$result"
if [ "$status" = "false" ]; then
    exit 1
fi
