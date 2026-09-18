#!/bin/sh
# Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

# Regression check for the Embedded Swift UnicodeDataTables/.got.plt linker
# integration. Moved from the pre-split Axoloty Swift linker probe check.
# Builds the profile firmware with AXOLOTY_SWIFT_UNICODE_LINKER_PROBE=ON and
# inspects the linked image. Needs the ESP-IDF toolchain, no board.
#
# Exit status: 0 passed, 1 failed, 69 required tool missing.

set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo_root=$(git -C "$script_dir" rev-parse --show-toplevel)
profile=${1:-esp32c6-mqtt}
profile_dir="$repo_root/Profiles/$profile"

if [ ! -x "$profile_dir/build.sh" ]; then
    echo "EMBEDDED SWIFT LINKER FAIL: profile has no executable build.sh: $profile" >&2
    exit 64
fi

idf_root=${IDF_PATH:-/opt/esp/idf}
if [ ! -f "$idf_root/export.sh" ]; then
    echo "embedded swift linker check requires ESP-IDF at $idf_root" >&2
    exit 69
fi
# shellcheck source=/dev/null
. "$idf_root/export.sh" >/dev/null 2>&1
if ! command -v idf.py >/dev/null 2>&1; then
    echo "embedded swift linker check requires idf.py after ESP-IDF activation" >&2
    exit 69
fi

proof_run_id=${AXOLOTY_PROOF_RUN_ID:-swift-linker}
scratch=${AXOLOTY_SCRATCH:-"$repo_root/.axoloty"}
proof_root=${EMBEDDED_PROOF_ROOT:-"$scratch/firmware-swift-linker"}
build_dir=${EMBEDDED_BUILD_DIR:-"$proof_root/build"}
project_dir="$proof_root/platform"

# Assemble the profile's firmware project first. The build refuses to run
# without Core preparation and writes the project under the proof root.
AXOLOTY_PROOF_RUN_ID="$proof_run_id" \
    EMBEDDED_PROOF_ROOT="$proof_root" \
    EMBEDDED_BUILD_DIR="$build_dir" \
    EMBEDDED_EVIDENCE_DIR="$proof_root/working-evidence" \
    "$profile_dir/build.sh"

# Re-run in the same build tree with the probe enabled. The application,
# transport, and Core-preparation cache entries survive from the build above.
cd "$project_dir" || exit 1
echo "== build (Unicode linker probe) =="
idf.py -B "$build_dir" \
    -DAXOLOTY_SWIFT_UNICODE_LINKER_PROBE=ON \
    build

elf="$build_dir/axoloty-swift.elf"
map="$build_dir/axoloty-swift.map"
sections="$build_dir/esp-idf/esp_system/ld/sections.ld"

test -f "$elf"
test -f "$map"
test -f "$sections"

nm_tool=${RISCV_NM:-riscv32-esp-elf-nm}
"$nm_tool" "$elf" | grep -q ' [TDR] _swift_stdlib_getNormData$'
"$nm_tool" "$elf" | grep -q ' [TDR] axoloty_unicode_linker_probe$'
grep -q 'libswiftUnicodeDataTables.a' "$map"
grep -q '\*(\.got \.got\.\* \.got\.plt \.got\.plt\.\*)' "$sections"
grep -q 'Swift UnicodeDataTables requires \.got/\.got\.plt' "$sections"
if grep -Eiq 'discarded output section.*\.got|orphan.*\.got' "$build_dir/log/"* 2>/dev/null; then
    echo "EMBEDDED SWIFT LINKER FAIL: GOT/PLT was discarded or orphaned" >&2
    exit 1
fi

echo "EMBEDDED SWIFT LINKER OK"
