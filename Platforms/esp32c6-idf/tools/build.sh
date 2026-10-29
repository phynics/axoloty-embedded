#!/bin/sh
# Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

# Build one firmware image for the profile-selected application, platform, and
# transport. Core preparation remains in validate.sh.
#
# Environment:
#   AXOLOTY_PROFILE_DIR        Absolute path to the selected profile axis.
#   AXOLOTY_APPLICATION_DIR  Absolute path to the selected application axis.
#   AXOLOTY_TRANSPORT_DIR    Absolute path to the selected transport axis.
#   AXOLOTY_PROOF_RUN_ID     Stable, filesystem-safe run identifier.
#   EMBEDDED_PROOF_ROOT      Caller-owned proof workspace. Default:
#                            <scratch>/firmware-<profile> for the selected
#                            profile, so sequential profile builds never
#                            share a build directory unless the operator
#                            overrides it.
#   EMBEDDED_BUILD_DIR       ESP-IDF build directory.
#   EMBEDDED_EVIDENCE_DIR    Evidence output directory.

set -eu

script_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
platform_dir=$(CDPATH='' cd -- "$script_dir/.." && pwd)
repo_root=$(git -C "$script_dir" rev-parse --show-toplevel)
repo_root=$(realpath -e -- "$repo_root")

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
# shellcheck source=profile-build-env.sh
. "$script_dir/profile-build-env.sh"
if [ -z "${AXOLOTY_PROFILE_DIR:-}" ]; then
    echo "error: AXOLOTY_PROFILE_DIR must name the selected profile; build through Profiles/<name>/build.sh" >&2
    exit 64
fi
if [ -z "${AXOLOTY_REPOSITORY_ROOT:-}" ] || [ ! -d "$AXOLOTY_REPOSITORY_ROOT" ]; then
    echo "error: AXOLOTY_REPOSITORY_ROOT must name the firmware repository root" >&2
    exit 64
fi
AXOLOTY_REPOSITORY_ROOT=$(realpath -e -- "$AXOLOTY_REPOSITORY_ROOT")
if [ "$AXOLOTY_REPOSITORY_ROOT" != "$repo_root" ]; then
    echo "error: AXOLOTY_REPOSITORY_ROOT does not match the build checkout" >&2
    exit 64
fi
export AXOLOTY_REPOSITORY_ROOT AXOLOTY_PROFILE_DIR
default_proof_root=$(axoloty_default_proof_root "$scratch")
proof_root=${EMBEDDED_PROOF_ROOT:-"$default_proof_root"}
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

# The profile owns the application x platform x transport selection. Refuse a
# selection that names another profile's axes before it can reach the cache.
if ! axoloty_verify_profile_selection; then
    exit 64
fi

# Prepare the pinned Zenoh C dependency only for a profile that selected its
# transport. The ESP-IDF component requirements pass does not inherit cache
# variables, so the report path must be exported by the caller of idf.py.
# Other profiles do not fetch or prepare the Zenoh dependency.
selected_transport=$(basename "$AXOLOTY_TRANSPORT_DIR")
if [ "$selected_transport" = "zenoh-pico" ]; then
    if [ -z "${AXOLOTY_ZENOH_PICO_REPORT:-}" ]; then
        AXOLOTY_SCRATCH="$scratch" "$repo_root/Tools/prepare-zenoh-pico.sh" >/dev/null
        AXOLOTY_ZENOH_PICO_REPORT="$scratch/zenoh-pico-preparation.json"
    fi
    if [ ! -f "$AXOLOTY_ZENOH_PICO_REPORT" ]; then
        echo "error: AXOLOTY_ZENOH_PICO_REPORT is not a file: $AXOLOTY_ZENOH_PICO_REPORT" >&2
        exit 64
    fi
    AXOLOTY_ZENOH_PICO_REPORT=$(realpath -e -- "$AXOLOTY_ZENOH_PICO_REPORT")
    export AXOLOTY_ZENOH_PICO_REPORT
fi

mkdir -p "$build_dir" "$evidence_dir" "$proof_root"
# A retried build must not inherit a prior artifact, provenance record, or
# generated ESP-IDF project. Clearing them prevents a failed retry from being
# mistaken for a successful build.
rm -f "$evidence_dir/build-provenance.json" "$evidence_dir/axoloty-swift.bin" \
    "$evidence_dir/release-manifest.json" \
    "$evidence_dir/linked-static-storage-budget.json" \
    "$evidence_dir/static-storage-policy.json"
rm -rf "$build_project_dir"
mkdir -p "$build_project_dir"
rm -f "$build_dir/flash_args" "$build_dir/axoloty-swift.bin"

EMBEDDED_PROOF_ROOT="$proof_root" EMBEDDED_BUILD_DIR="$build_dir" \
    EMBEDDED_EVIDENCE_DIR="$evidence_dir" "$platform_dir/tools/validate.sh"
report=$(realpath -e -- "$evidence_dir/preparation.json")

# ESP-IDF materializes managed_components and generated metadata beside the
# project. Build a writable copy under the proof root while retaining the
# original repository for provenance checks. `cp -a` copies POSIX ACLs, and on
# a filesystem with default ACLs the container's `cp` fails with
# "preserving permissions ... Invalid argument" for every file. Preserving
# `mode` trips the same ACL path; preserve timestamps only. cp still derives
# each file's mode from the source through the umask, so execute bits survive.
cp -R --preserve=timestamps "$platform_dir/." "$build_project_dir/"

# IDF applies sdkconfig.defaults only when it first writes sdkconfig. An
# existing sdkconfig silently keeps the old defaults, so a changed default
# looked applied while the build kept using the previous value. Drop the
# whole build directory when the tracked defaults are newer.
if [ -f "$sdkconfig" ] && [ "$build_project_dir/sdkconfig.defaults" -nt "$sdkconfig" ]; then
    rm -rf "$build_dir"
fi
# A non-empty build directory without a CMake cache is the remains of a
# failed configure. IDF refuses to clean it and reports an error about the
# directory, so clear it here rather than making the retry fail the same way.
if [ -d "$build_dir" ] && [ ! -f "$build_dir/CMakeCache.txt" ] && [ -n "$(ls -A "$build_dir" 2>/dev/null)" ]; then
    rm -rf "$build_dir"
fi
# Profiles build in sequence, and two profiles share one IDF target. A build
# directory whose cached selection names the other profile's axes would
# otherwise keep building the wrong transport: the set-target below is skipped
# for the same target, and the stale cache survives. Clear it so the next
# configure starts from the current selection. An explicit EMBEDDED_BUILD_DIR
# is honored the same way; sharing one directory across profiles just rebuilds
# it every switch, loudly.
axoloty_clear_stale_profile_cache "$build_dir"
mkdir -p "$build_dir"

# Operator network configuration is a private build input: SSID, password,
# broker host, role, and scenario live in a generated header, never in the
# repository. The caller (a device-test harness) generates it into scratch.
# Stage it and invalidate only the staged bootstrap object so absent, changed,
# and removed headers are all reflected without retaining credential metadata.
axoloty_stage_network_config_header "${AXOLOTY_NETWORK_CONFIG_HEADER:-}" "$build_project_dir"

idf_path=${IDF_PATH:-/opt/esp/idf}
if [ ! -f "$idf_path/export.sh" ]; then
    echo "error: ESP-IDF export script is unavailable: $idf_path/export.sh" >&2
    exit 69
fi
# shellcheck source=/dev/null
. "$idf_path/export.sh" >/dev/null 2>&1

# ESP-IDF expands component requirements in a separate CMake sub-invocation
# that does not inherit -D cache variables. axoloty-source.cmake is included
# during that pass, so the report and the profile selection must also be in
# the environment or the pass fails with "AXOLOTY_PREPARATION_REPORT is
# required" before any target builds, or silently keeps the previous profile's
# axes.
export AXOLOTY_PREPARATION_REPORT="$report"
export AXOLOTY_APPLICATION_DIR
export AXOLOTY_TRANSPORT_DIR
export AXOLOTY_PROFILE_DIR AXOLOTY_REPOSITORY_ROOT

# SwiftSyntax macros execute on the host even when the target compiler emits
# Embedded Swift. Bootstrap them with the host toolchain before ESP-IDF
# configures the target compilation.
if [ -z "${AXOLOTY_EMBEDDED_MACRO_PLUGIN:-}" ]; then
    AXOLOTY_EMBEDDED_MACRO_PLUGIN=$(AXOLOTY_SCRATCH="$scratch" \
        sh "$repo_root/Tools/build-embedded-macro.sh")
fi
if [ ! -x "$AXOLOTY_EMBEDDED_MACRO_PLUGIN" ]; then
    echo "error: AXOLOTY_EMBEDDED_MACRO_PLUGIN is not an executable host plugin: $AXOLOTY_EMBEDDED_MACRO_PLUGIN" >&2
    exit 64
fi
export AXOLOTY_EMBEDDED_MACRO_PLUGIN
export AXOLOTY_PROFILE_DIR AXOLOTY_REPOSITORY_ROOT

# The scenario is an environment input for the component-requirements
# sub-invocation and a cache input for the normal configure. Pass both so a
# reused build directory cannot retain the opposite image mode.
qualification_scenario=${AXOLOTY_QUALIFICATION_CARRIER_SCENARIO:-0}
case "$qualification_scenario" in
    1|ON|on|TRUE|true) qualification_scenario=ON ;;
    0|OFF|off|FALSE|false) qualification_scenario=OFF ;;
    *) echo "error: AXOLOTY_QUALIFICATION_CARRIER_SCENARIO must be a boolean" >&2; exit 64 ;;
esac

heap_trace_calibration=${AXOLOTY_HEAP_TRACE_CALIBRATION:-0}
case "$heap_trace_calibration" in
    1|ON|on|TRUE|true) heap_trace_calibration=ON ;;
    0|OFF|off|FALSE|false) heap_trace_calibration=OFF ;;
    *) echo "error: AXOLOTY_HEAP_TRACE_CALIBRATION must be a boolean" >&2; exit 64 ;;
esac
if [ "$heap_trace_calibration" = ON ] && [ "$qualification_scenario" = ON ]; then
    echo "error: AXOLOTY_HEAP_TRACE_CALIBRATION cannot be combined with AXOLOTY_QUALIFICATION_CARRIER_SCENARIO" >&2
    exit 64
fi
export AXOLOTY_HEAP_TRACE_CALIBRATION="$heap_trace_calibration"
node -e 'require("fs").writeFileSync(process.argv[1], JSON.stringify({schema: 1, heapTraceCalibration: process.argv[2] === "ON", qualificationCarrierScenario: process.argv[3] === "ON"}, null, 2) + "\n");' \
    "$evidence_dir/allocator-calibration-config.json" "$heap_trace_calibration" "$qualification_scenario"


: > "$evidence_dir/build.log"
cd "$build_project_dir"
if [ ! -f "$build_dir/CMakeCache.txt" ] ||
    ! grep -q '^IDF_TARGET:STRING=esp32c6$' "$build_dir/CMakeCache.txt"; then
    idf.py -B "$build_dir" -D SDKCONFIG="$sdkconfig" \
        -D AXOLOTY_REPOSITORY_ROOT="$AXOLOTY_REPOSITORY_ROOT" \
        -D AXOLOTY_PROFILE_DIR="$AXOLOTY_PROFILE_DIR" \
        -D AXOLOTY_QUALIFICATION_CARRIER_SCENARIO="$qualification_scenario" \
        -D AXOLOTY_HEAP_TRACE_CALIBRATION="$heap_trace_calibration" \
        -D AXOLOTY_EMBEDDED_MACRO_PLUGIN="$AXOLOTY_EMBEDDED_MACRO_PLUGIN" \
        -D AXOLOTY_REPOSITORY_ROOT="$AXOLOTY_REPOSITORY_ROOT" \
        -D AXOLOTY_PROFILE_DIR="$AXOLOTY_PROFILE_DIR" \
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
idf.py -B "$build_dir" -D SDKCONFIG="$sdkconfig" \
    -D AXOLOTY_REPOSITORY_ROOT="$AXOLOTY_REPOSITORY_ROOT" \
    -D AXOLOTY_PROFILE_DIR="$AXOLOTY_PROFILE_DIR" \
    -D AXOLOTY_QUALIFICATION_CARRIER_SCENARIO="$qualification_scenario" \
    -D AXOLOTY_HEAP_TRACE_CALIBRATION="$heap_trace_calibration" \
    -D AXOLOTY_EMBEDDED_MACRO_PLUGIN="$AXOLOTY_EMBEDDED_MACRO_PLUGIN" \
    -D AXOLOTY_REPOSITORY_ROOT="$AXOLOTY_REPOSITORY_ROOT" \
    -D AXOLOTY_PROFILE_DIR="$AXOLOTY_PROFILE_DIR" \
    -D AXOLOTY_APPLICATION_DIR="$AXOLOTY_APPLICATION_DIR" \
    -D AXOLOTY_TRANSPORT_DIR="$AXOLOTY_TRANSPORT_DIR" \
    -D AXOLOTY_PREPARATION_REPORT="$report" \
    build >> "$evidence_dir/build.log" 2>&1
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

# Classify the configured image from its normalized CMake cache and enforce a
# configured app policy against this selected inventory before any artifact,
# provenance, or release manifest is published. Missing policy is explicit and
# receives no fabricated budget pass. C-only qualification records not-applicable.
"$repo_root/Tools/EmbeddedApplicationMacros/static-storage-build-gate.sh" \
    "$repo_root" "$AXOLOTY_APPLICATION_DIR" "$(basename -- "$AXOLOTY_PROFILE_DIR")" \
    "$build_dir" "$evidence_dir" 'esp-idf/main/libmain.a'

# A CBOR-only transport must link no JSON parser. Preparation and the build
# already omit `_JSONCore`; this proves the finished image carries none of it.
wire_profile=$(node -e 'const t = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8")); process.stdout.write(typeof t.wireProfile === "string" ? t.wireProfile : "");' \
    "$AXOLOTY_TRANSPORT_DIR/transport.json")
if [ "$wire_profile" = axoloty1CBOR ]; then
    if [ ! -f "$build_dir/axoloty-swift.map" ]; then
        echo "error: the linker map is required to prove a CBOR-only image links no _JSONCore" >&2
        exit 1
    fi
    if grep -qi 'jsoncore' "$build_dir/axoloty-swift.map"; then
        echo "error: the CBOR-only image links _JSONCore; see $build_dir/axoloty-swift.map" >&2
        exit 1
    fi
    echo "wire profile axoloty1CBOR: the linked image carries no _JSONCore"
fi

cp "$artifact" "$evidence_dir/axoloty-swift.bin"

node "$script_dir/write-provenance.mjs" \
    "$report" "$artifact" "$evidence_dir/build-provenance.json" \
    "$repo_root" "$build_dir" "$clean_room"

# The release manifest is produced by the build, from the same report and
# provenance the build just wrote. The release path re-runs this after
# qualification so the manifest also carries the device evidence.
# AXOLOTY_PROFILE_DIR was required before the build started.
"$script_dir/write-release-manifest.sh" "$AXOLOTY_PROFILE_DIR"

echo "Firmware build passed"
echo "  artifact: $artifact"
echo "  provenance: $evidence_dir/build-provenance.json"
