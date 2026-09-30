#!/bin/sh
# Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

# Host check for per-profile build-directory isolation. verify.sh builds every
# profile in sequence; when two profiles shared one ESP-IDF build directory
# and one IDF target, the second build skipped `set-target` and reused the
# first profile's cached AXOLOTY_TRANSPORT_DIR, so Zenoh built MQTT sources or
# failed against the wrong component requirements.
#
# This exercises the real profile-build-env.sh helper while switching between
# the real MQTT and Zenoh profiles, and inspects the resolved directories and
# synthetic CMakeCache.txt fixtures written for the switch. It also probes
# Tools/release.sh through its --print-proof-root introspection flag, so a
# release path that stops sharing the per-profile rule fails here, and probes
# the flash.sh workspace guard. It needs only sh, node, and git: no board, no
# SDK, no broker.
#
# Exit status: 0 passed, 1 failed, 69 required tool missing.

set -eu

script_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
repo_root=$(git -C "$script_dir" rev-parse --show-toplevel)
helper="$repo_root/Platforms/esp32c6-idf/tools/profile-build-env.sh"

if ! command -v node >/dev/null 2>&1; then
    echo "profile isolation test requires node" >&2
    exit 69
fi

# shellcheck source=../../Platforms/esp32c6-idf/tools/profile-build-env.sh
. "$helper"

failures=0

# The assertions below pin the defaults, so ambient operator overrides must
# not leak in: every override case sets its own variables explicitly. The
# board variables are emptied for the same reason: on a host with a
# configured or attached board, an inherited device would carry a flash probe
# past the workspace guard into flash/proof checks and fail it for unrelated
# reasons. This script is standalone, so plain unsets are safe.
unset EMBEDDED_PROOF_ROOT EMBEDDED_BUILD_DIR EMBEDDED_EVIDENCE_DIR
unset AXOLOTY_DEVICE_PORT EMBEDDED_DEVICE

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

mqtt_profile="$repo_root/Profiles/esp32c6-mqtt"
zenoh_profile="$repo_root/Profiles/esp32c6-zenoh"
mqtt_transport="$repo_root/Transports/mqtt-espidf"
zenoh_transport="$repo_root/Transports/zenoh-pico"
application="$repo_root/Applications/device-smoke-agent"

# The two profiles share one application and one IDF target but select
# different transports. Confirm the fixture the test switches between.
for profile in "$mqtt_profile" "$zenoh_profile"; do
    if [ ! -f "$profile/profile.json" ]; then
        echo "FAIL: profile is missing profile.json: $profile" >&2
        exit 1
    fi
done

# 1. The default proof workspace differs per profile, so sequential profile
# builds never share a build directory unless the operator says so.
AXOLOTY_PROFILE_DIR="$mqtt_profile"
mqtt_root=$(axoloty_default_proof_root "$tmp/scratch")
AXOLOTY_PROFILE_DIR="$zenoh_profile"
zenoh_root=$(axoloty_default_proof_root "$tmp/scratch")
unset AXOLOTY_PROFILE_DIR
if [ "$mqtt_root" != "$zenoh_root" ] &&
    [ "$mqtt_root" = "$tmp/scratch/firmware-esp32c6-mqtt" ] &&
    [ "$zenoh_root" = "$tmp/scratch/firmware-esp32c6-zenoh" ]; then
    echo "ok: MQTT and Zenoh default to separate proof workspaces"
else
    echo "FAIL: MQTT ($mqtt_root) and Zenoh ($zenoh_root) do not isolate by default" >&2
    failures=$((failures + 1))
fi

# 2. Without a profile the historical shared default is unchanged.
shared_root=$(axoloty_default_proof_root "$tmp/scratch")
if [ "$shared_root" = "$tmp/scratch/firmware" ]; then
    echo "ok: no profile keeps the shared firmware default"
else
    echo "FAIL: no-profile default is $shared_root, expected $tmp/scratch/firmware" >&2
    failures=$((failures + 1))
fi

# 3. An explicit EMBEDDED_PROOF_ROOT wins for both profiles, exactly as every
# caller applies it.
AXOLOTY_PROFILE_DIR="$mqtt_profile"
mqtt_explicit=${EMBEDDED_PROOF_ROOT:-$(axoloty_default_proof_root "$tmp/scratch")}
AXOLOTY_PROFILE_DIR="$zenoh_profile"
zenoh_explicit=${EMBEDDED_PROOF_ROOT:-$(axoloty_default_proof_root "$tmp/scratch")}
unset AXOLOTY_PROFILE_DIR
EMBEDDED_PROOF_ROOT="$tmp/operator-shared"
AXOLOTY_PROFILE_DIR="$mqtt_profile"
mqtt_overridden=${EMBEDDED_PROOF_ROOT:-$(axoloty_default_proof_root "$tmp/scratch")}
AXOLOTY_PROFILE_DIR="$zenoh_profile"
zenoh_overridden=${EMBEDDED_PROOF_ROOT:-$(axoloty_default_proof_root "$tmp/scratch")}
unset AXOLOTY_PROFILE_DIR EMBEDDED_PROOF_ROOT
if [ "$mqtt_explicit" = "$mqtt_root" ] && [ "$zenoh_explicit" = "$zenoh_root" ] &&
    [ "$mqtt_overridden" = "$tmp/operator-shared" ] && [ "$zenoh_overridden" = "$tmp/operator-shared" ]; then
    echo "ok: operator EMBEDDED_PROOF_ROOT override is honored for both profiles"
else
    echo "FAIL: operator override was not honored ($mqtt_overridden, $zenoh_overridden)" >&2
    failures=$((failures + 1))
fi

write_cache() {
    dir=$1
    app_dir=$2
    transport_dir=$3
    mkdir -p "$dir"
    cat > "$dir/CMakeCache.txt" <<EOF
IDF_TARGET:STRING=esp32c6
AXOLOTY_APPLICATION_DIR:STRING=$app_dir
AXOLOTY_TRANSPORT_DIR:STRING=$transport_dir
EOF
    touch "$dir/sentinel"
}

# 4. Switching profiles evicts the stale cache: an MQTT-configured build
# directory selected for Zenoh is cleared before it can build MQTT sources.
stale_dir="$tmp/stale-build"
write_cache "$stale_dir" "$application" "$mqtt_transport"
export AXOLOTY_APPLICATION_DIR="$application"
export AXOLOTY_TRANSPORT_DIR="$zenoh_transport"
eviction_output=$(axoloty_clear_stale_profile_cache "$stale_dir")
if [ ! -e "$stale_dir/sentinel" ] && [ ! -e "$stale_dir/CMakeCache.txt" ]; then
    echo "ok: switching MQTT -> Zenoh evicts the stale build directory"
else
    echo "FAIL: stale MQTT cache survived a switch to Zenoh" >&2
    failures=$((failures + 1))
fi
case "$eviction_output" in
    *mqtt-espidf*zenoh-pico*)
        echo "ok: eviction names the cached and the selected transport"
        ;;
    *)
        echo "FAIL: eviction did not name both selections: $eviction_output" >&2
        failures=$((failures + 1))
        ;;
esac

# 5. A matching cache is preserved: rebuilding the same profile keeps its
# configured tree, including its IDF target.
fresh_dir="$tmp/fresh-build"
write_cache "$fresh_dir" "$application" "$zenoh_transport"
if axoloty_clear_stale_profile_cache "$fresh_dir" >/dev/null 2>&1 &&
    [ -f "$fresh_dir/sentinel" ] && [ -f "$fresh_dir/CMakeCache.txt" ]; then
    echo "ok: rebuilding Zenoh keeps its configured build directory"
else
    echo "FAIL: matching Zenoh cache was cleared" >&2
    failures=$((failures + 1))
fi
unset AXOLOTY_APPLICATION_DIR AXOLOTY_TRANSPORT_DIR

# 6. The selection must name the profile's own axes. A Zenoh build handed the
# MQTT transport is refused before it reaches any cache.
export AXOLOTY_PROFILE_DIR="$zenoh_profile"
export AXOLOTY_APPLICATION_DIR="$application"
export AXOLOTY_TRANSPORT_DIR="$mqtt_transport"
if axoloty_verify_profile_selection >/dev/null 2>&1; then
    echo "FAIL: Zenoh profile accepted the MQTT transport selection" >&2
    failures=$((failures + 1))
else
    echo "ok: Zenoh profile rejects the MQTT transport selection"
fi
export AXOLOTY_TRANSPORT_DIR="$zenoh_transport"
if axoloty_verify_profile_selection >/dev/null 2>&1; then
    echo "ok: Zenoh profile accepts its own selection"
else
    echo "FAIL: Zenoh profile rejected its own selection" >&2
    failures=$((failures + 1))
fi
export AXOLOTY_PROFILE_DIR="$mqtt_profile"
export AXOLOTY_TRANSPORT_DIR="$mqtt_transport"
if axoloty_verify_profile_selection >/dev/null 2>&1; then
    echo "ok: MQTT profile accepts its own selection"
else
    echo "FAIL: MQTT profile rejected its own selection" >&2
    failures=$((failures + 1))
fi
unset AXOLOTY_PROFILE_DIR AXOLOTY_APPLICATION_DIR AXOLOTY_TRANSPORT_DIR

# 7. The release path resolves its workspace through the same shared rule.
# --print-proof-root stops before any preparation, build, or device step, so
# this stays hardware-free. If release.sh ever reverts to the shared firmware
# root, both profiles print one path; if it inlines a divergent rule, the
# output stops matching the helper. Either way this fails. The workspace
# overrides are emptied so an operator's ambient EMBEDDED_* cannot stand in
# for the default under test.
mqtt_release_root=$(AXOLOTY_SCRATCH="$tmp/scratch" EMBEDDED_PROOF_ROOT= EMBEDDED_EVIDENCE_DIR= \
    "$repo_root/Tools/release.sh" \
    --profile esp32c6-mqtt --print-proof-root | sed -n 's/^proof_root=//p')
zenoh_release_root=$(AXOLOTY_SCRATCH="$tmp/scratch" EMBEDDED_PROOF_ROOT= EMBEDDED_EVIDENCE_DIR= \
    "$repo_root/Tools/release.sh" \
    --profile esp32c6-zenoh --print-proof-root | sed -n 's/^proof_root=//p')
AXOLOTY_PROFILE_DIR="$mqtt_profile"
mqtt_expected=$(axoloty_default_proof_root "$tmp/scratch")
AXOLOTY_PROFILE_DIR="$zenoh_profile"
zenoh_expected=$(axoloty_default_proof_root "$tmp/scratch")
unset AXOLOTY_PROFILE_DIR
if [ -n "$mqtt_release_root" ] && [ "$mqtt_release_root" = "$mqtt_expected" ] &&
    [ -n "$zenoh_release_root" ] && [ "$zenoh_release_root" = "$zenoh_expected" ] &&
    [ "$mqtt_release_root" != "$zenoh_release_root" ]; then
    echo "ok: release.sh resolves the shared per-profile workspace for both profiles"
else
    echo "FAIL: release.sh workspace diverged from the shared rule (mqtt: $mqtt_release_root; zenoh: $zenoh_release_root)" >&2
    failures=$((failures + 1))
fi

flash_tool="$repo_root/Platforms/esp32c6-idf/tools/flash.sh"

# 8. flash.sh refuses an ambiguous workspace before touching any board, so all
# three probes are hardware-free: no device and no toolchain is used (the
# board and workspace variables were emptied at the top of this script).
# 8a. No profile and no explicit workspace: the legacy shared default could
# hold any profile's image, so the flash is refused.
if AXOLOTY_SCRATCH="$tmp/scratch" "$flash_tool" >"$tmp/flash-refused.log" 2>&1; then
    echo "FAIL: flash.sh accepted the shared default workspace with no profile selection" >&2
    failures=$((failures + 1))
else
    refused_status=$?
    if [ "$refused_status" -eq 64 ] && grep -q 'shared default proof workspace' "$tmp/flash-refused.log"; then
        echo "ok: flash.sh refuses the shared default workspace with no profile selection"
    else
        echo "FAIL: flash.sh refusal was not the workspace guard (status $refused_status)" >&2
        failures=$((failures + 1))
    fi
fi
# 8b. An explicit caller-owned workspace (the run-network-test.sh shape) is
# allowed past the guard: it proceeds to the board check instead.
if EMBEDDED_PROOF_ROOT="$tmp/explicit-root" AXOLOTY_SCRATCH="$tmp/scratch" \
    "$flash_tool" >"$tmp/flash-explicit.log" 2>&1; then
    echo "FAIL: flash.sh unexpectedly succeeded with no board" >&2
    failures=$((failures + 1))
elif grep -q 'shared default proof workspace' "$tmp/flash-explicit.log"; then
    echo "FAIL: flash.sh refused an explicit caller-owned workspace" >&2
    failures=$((failures + 1))
elif grep -q 'AXOLOTY_DEVICE_PORT is unset' "$tmp/flash-explicit.log"; then
    echo "ok: flash.sh honors an explicit caller-owned workspace"
else
    echo "FAIL: flash.sh with an explicit workspace failed unexpectedly:" >&2
    cat "$tmp/flash-explicit.log" >&2
    failures=$((failures + 1))
fi
# 8c. A profile selection (the qualify.sh shape) resolves the profile's own
# workspace and is allowed past the guard the same way.
if AXOLOTY_PROFILE_DIR="$mqtt_profile" AXOLOTY_SCRATCH="$tmp/scratch" \
    "$flash_tool" >"$tmp/flash-profile.log" 2>&1; then
    echo "FAIL: flash.sh unexpectedly succeeded with no board" >&2
    failures=$((failures + 1))
elif grep -q 'shared default proof workspace' "$tmp/flash-profile.log"; then
    echo "FAIL: flash.sh refused a profile-selected workspace" >&2
    failures=$((failures + 1))
elif grep -q 'AXOLOTY_DEVICE_PORT is unset' "$tmp/flash-profile.log"; then
    echo "ok: flash.sh honors a profile-selected workspace"
else
    echo "FAIL: flash.sh with a profile selection failed unexpectedly:" >&2
    cat "$tmp/flash-profile.log" >&2
    failures=$((failures + 1))
fi

if [ "$failures" -ne 0 ]; then
    echo "profile isolation tests failed: $failures failure(s)" >&2
    exit 1
fi
echo "profile isolation tests passed"
