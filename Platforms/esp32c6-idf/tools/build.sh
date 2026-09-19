#!/bin/sh
# Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

# Build one firmware image for the profile-selected application, platform, and
# transport. Core preparation remains in validate.sh.
#
# Environment:
#   AXOLOTY_APPLICATION_DIR  Absolute path to the selected application axis.
#   AXOLOTY_TRANSPORT_DIR    Absolute path to the selected transport axis.
#   AXOLOTY_PROOF_RUN_ID     Stable, filesystem-safe run identifier.
#   EMBEDDED_PROOF_ROOT      Caller-owned proof workspace.
#   EMBEDDED_BUILD_DIR       ESP-IDF build directory.
#   EMBEDDED_EVIDENCE_DIR    Evidence output directory.

set -eu

script_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
platform_dir=$(CDPATH='' cd -- "$script_dir/.." && pwd)
repo_root=$(git -C "$script_dir" rev-parse --show-toplevel)

if [ -z "${AXOLOTY_APPLICATION_DIR:-}" ] || [ ! -d "$AXOLOTY_APPLICATION_DIR" ]; then
    echo "error: AXOLOTY_APPLICATION_DIR must name the selected application directory" >&2
    exit 64
fi
if [ -z "${AXOLOTY_TRANSPORT_DIR:-}" ] || [ ! -d "$AXOLOTY_TRANSPORT_DIR" ]; then
    echo "error: AXOLOTY_TRANSPORT_DIR must name the selected transport directory" >&2
    exit 64
fi

scratch=${AXOLOTY_SCRATCH:-"$repo_root/.axoloty"}
proof_run_id=${AXOLOTY_PROOF_RUN_ID:-manual}
proof_root=${EMBEDDED_PROOF_ROOT:-"$scratch/firmware"}
build_dir=${EMBEDDED_BUILD_DIR:-"$proof_root/build"}
evidence_dir=${EMBEDDED_EVIDENCE_DIR:-"$proof_root/working-evidence"}
sdkconfig="$build_dir/sdkconfig"
build_project_dir="$proof_root/platform"
clean_room="$evidence_dir/clean-room.json"

if [ -z "$proof_run_id" ] ||
    ! printf '%s' "$proof_run_id" | grep -Eq '^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$'; then
    echo "error: AXOLOTY_PROOF_RUN_ID must be a stable filesystem-safe identifier" >&2
    exit 64
fi

mkdir -p "$build_dir" "$evidence_dir" "$proof_root"
# A retried build must not inherit a prior artifact, provenance record, or
# generated ESP-IDF project. Clearing them prevents a failed retry from being
# mistaken for a successful build.
rm -f "$evidence_dir/build-provenance.json" "$evidence_dir/axoloty-swift.bin" \
    "$evidence_dir/release-manifest.json"
rm -rf "$build_project_dir"
mkdir -p "$build_project_dir"
rm -f "$build_dir/flash_args" "$build_dir/axoloty-swift.bin"

EMBEDDED_PROOF_ROOT="$proof_root" EMBEDDED_BUILD_DIR="$build_dir" \
    EMBEDDED_EVIDENCE_DIR="$evidence_dir" "$platform_dir/tools/validate.sh"
report=$(realpath -e -- "$evidence_dir/preparation.json")

# ESP-IDF materializes managed_components and generated metadata beside the
# project. Build a writable copy under the proof root while retaining the
# original repository for provenance checks.
cp -a "$platform_dir/." "$build_project_dir/"

# Operator network configuration is a private build input: SSID, password,
# broker host, role, and scenario live in a generated header, never in the
# repository. The caller (a device-test harness) generates it into scratch
# and names it here; the platform copies it into the project it just built.
# Absent, the firmware compiles with AXOLOTY_NETWORK_CONFIGURED 0.
if [ -n "${AXOLOTY_NETWORK_CONFIG_HEADER:-}" ]; then
    if [ ! -f "$AXOLOTY_NETWORK_CONFIG_HEADER" ]; then
        echo "error: AXOLOTY_NETWORK_CONFIG_HEADER is not a file: $AXOLOTY_NETWORK_CONFIG_HEADER" >&2
        exit 64
    fi
    cp "$AXOLOTY_NETWORK_CONFIG_HEADER" "$build_project_dir/main/axoloty_network_config.h"
    echo "network config: private header injected into the build project"
fi

idf_path=${IDF_PATH:-/opt/esp/idf}
if [ ! -f "$idf_path/export.sh" ]; then
    echo "error: ESP-IDF export script is unavailable: $idf_path/export.sh" >&2
    exit 69
fi
# shellcheck source=/dev/null
. "$idf_path/export.sh" >/dev/null 2>&1

# ESP-IDF expands component requirements in a separate CMake sub-invocation
# that does not inherit -D cache variables. axoloty-source.cmake is included
# during that pass, so the report must also be in the environment or the pass
# fails with "AXOLOTY_PREPARATION_REPORT is required" before any target builds.
export AXOLOTY_PREPARATION_REPORT="$report"


: > "$evidence_dir/build.log"
cd "$build_project_dir"
if [ ! -f "$build_dir/CMakeCache.txt" ] ||
    ! grep -q '^IDF_TARGET:STRING=esp32c6$' "$build_dir/CMakeCache.txt"; then
    idf.py -B "$build_dir" -D SDKCONFIG="$sdkconfig" \
        -D AXOLOTY_APPLICATION_DIR="$AXOLOTY_APPLICATION_DIR" \
        -D AXOLOTY_TRANSPORT_DIR="$AXOLOTY_TRANSPORT_DIR" \
        -D AXOLOTY_PREPARATION_REPORT="$report" \
        set-target esp32c6 >> "$evidence_dir/build.log" 2>&1
fi

echo "== build firmware =="
echo "application: $AXOLOTY_APPLICATION_DIR"
echo "transport: $AXOLOTY_TRANSPORT_DIR"
echo "Core report: $report"
echo "parallelism: ${CMAKE_BUILD_PARALLEL_LEVEL:-default}"
set +e
idf.py -B "$build_dir" -D SDKCONFIG="$sdkconfig" build >> "$evidence_dir/build.log" 2>&1
build_status=$?
set -e
cat "$evidence_dir/build.log"
if [ "$build_status" -ne 0 ]; then
    echo "error: ESP-IDF build failed; see $evidence_dir/build.log" >&2
    exit "$build_status"
fi

artifact="$build_dir/axoloty-swift.bin"
if [ ! -f "$artifact" ]; then
    echo "error: ESP-IDF did not produce $artifact" >&2
    exit 1
fi

cp "$artifact" "$evidence_dir/axoloty-swift.bin"

node "$script_dir/write-provenance.mjs" \
    "$report" "$artifact" "$evidence_dir/build-provenance.json" \
    "$repo_root" "$build_dir" "$clean_room"

if [ -z "${AXOLOTY_PROFILE_DIR:-}" ]; then
    echo "error: AXOLOTY_PROFILE_DIR must name the selected profile; build through Profiles/<name>/build.sh" >&2
    exit 64
fi
# The release manifest is produced by the build, from the same report and
# provenance the build just wrote. The release path re-runs this after
# qualification so the manifest also carries the device evidence.
"$script_dir/write-release-manifest.sh" "$AXOLOTY_PROFILE_DIR"

echo "Firmware build passed"
echo "  artifact: $artifact"
echo "  provenance: $evidence_dir/build-provenance.json"
