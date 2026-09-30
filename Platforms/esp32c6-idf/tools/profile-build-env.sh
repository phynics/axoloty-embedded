#!/bin/sh
# Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.
#
# Profile build-directory isolation for the ESP32-C6 platform.
#
# verify.sh builds every profile in sequence. When two profiles share one
# ESP-IDF build directory and one IDF target, the second build skips
# `set-target` and reuses the first profile's cached AXOLOTY_TRANSPORT_DIR, so
# Zenoh builds MQTT sources or fails against the wrong component requirements.
# This file is sourced, never executed, and holds the one rule every caller
# shares: the default proof workspace is per profile, and a build directory
# whose cached selection names another profile is cleared before it can be
# reused.
#
# Provided:
#   axoloty_default_proof_root <scratch>
#       Echo the default proof workspace. When AXOLOTY_PROFILE_DIR names the
#       selected profile, the default is <scratch>/firmware-<profile>; without
#       a profile it stays <scratch>/firmware. An explicit EMBEDDED_PROOF_ROOT
#       always wins; callers apply it with ${EMBEDDED_PROOF_ROOT:-$(...)}.
#   axoloty_verify_profile_selection
#       Return 0 only when AXOLOTY_APPLICATION_DIR and AXOLOTY_TRANSPORT_DIR
#       name the application and transport that AXOLOTY_PROFILE_DIR/profile.json
#       selects, on the platform it selects. Needs node, like the profile
#       build scripts. Prints the mismatch to stderr and returns 64.
#   axoloty_clear_stale_profile_cache <build_dir>
#       When <build_dir>/CMakeCache.txt caches a selection that differs from
#       AXOLOTY_APPLICATION_DIR or AXOLOTY_TRANSPORT_DIR, remove the whole
#       build directory so the next configure starts from the current
#       selection, and say so. A matching cache is left untouched.

axoloty_default_proof_root() {
    scratch=${1:-}
    if [ -z "$scratch" ]; then
        echo "error: axoloty_default_proof_root requires the scratch root" >&2
        return 64
    fi
    profile_name=''
    if [ -n "${AXOLOTY_PROFILE_DIR:-}" ]; then
        profile_name=$(basename -- "$AXOLOTY_PROFILE_DIR")
    fi
    case "$profile_name" in
        ''|'.'|'/'|'-')
            printf '%s\n' "$scratch/firmware"
            ;;
        *)
            printf '%s\n' "$scratch/firmware-$profile_name"
            ;;
    esac
}

axoloty_verify_profile_selection() {
    if [ -z "${AXOLOTY_PROFILE_DIR:-}" ]; then
        echo "error: AXOLOTY_PROFILE_DIR must name the selected profile; build through Profiles/<name>/build.sh" >&2
        return 64
    fi
    if [ ! -f "$AXOLOTY_PROFILE_DIR/profile.json" ]; then
        echo "error: AXOLOTY_PROFILE_DIR has no profile.json: $AXOLOTY_PROFILE_DIR" >&2
        return 64
    fi
    if ! command -v node >/dev/null 2>&1; then
        echo "error: node is required to verify the profile selection" >&2
        return 69
    fi
    selection=$(node -e '
const fs = require("fs");
const p = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
for (const field of ["application", "platform", "transport"]) {
    const v = p[field];
    if (typeof v !== "string" || v.length === 0) { process.exit(2); }
    process.stdout.write(v + "\n");
}' "$AXOLOTY_PROFILE_DIR/profile.json") || {
        echo "error: $AXOLOTY_PROFILE_DIR/profile.json does not select an application, platform, and transport" >&2
        return 64
    }
    application=$(printf '%s\n' "$selection" | sed -n '1p')
    platform=$(printf '%s\n' "$selection" | sed -n '2p')
    transport=$(printf '%s\n' "$selection" | sed -n '3p')
    repo_root=$(git -C "$AXOLOTY_PROFILE_DIR" rev-parse --show-toplevel 2>/dev/null) || {
        echo "error: cannot find the repository root from $AXOLOTY_PROFILE_DIR" >&2
        return 1
    }
    mismatch=0
    if [ "${AXOLOTY_APPLICATION_DIR:-}" != "$repo_root/Applications/$application" ]; then
        echo "error: AXOLOTY_APPLICATION_DIR (${AXOLOTY_APPLICATION_DIR:-unset}) does not match the profile application '$application'" >&2
        mismatch=1
    fi
    if [ "${AXOLOTY_TRANSPORT_DIR:-}" != "$repo_root/Transports/$transport" ]; then
        echo "error: AXOLOTY_TRANSPORT_DIR (${AXOLOTY_TRANSPORT_DIR:-unset}) does not match the profile transport '$transport'" >&2
        mismatch=1
    fi
    if [ ! -d "$repo_root/Platforms/$platform" ]; then
        echo "error: profile selects platform '$platform', but Platforms/$platform does not exist" >&2
        mismatch=1
    fi
    [ "$mismatch" -eq 0 ]
}

axoloty_cached_selection() {
    cache_file=${1:-}
    variable=${2:-}
    [ -n "$cache_file" ] && [ -f "$cache_file" ] || return 1
    sed -n "s/^$variable:[^=]*=//p" "$cache_file" | head -1
}

axoloty_clear_stale_profile_cache() {
    build_dir=${1:-}
    if [ -z "$build_dir" ] || [ ! -f "$build_dir/CMakeCache.txt" ]; then
        return 0
    fi
    stale=''
    cached_application=$(axoloty_cached_selection "$build_dir/CMakeCache.txt" AXOLOTY_APPLICATION_DIR || true)
    if [ -n "$cached_application" ] && [ "$cached_application" != "${AXOLOTY_APPLICATION_DIR:-}" ]; then
        stale="$stale AXOLOTY_APPLICATION_DIR (cached: $cached_application; selected: ${AXOLOTY_APPLICATION_DIR:-unset})"
    fi
    cached_transport=$(axoloty_cached_selection "$build_dir/CMakeCache.txt" AXOLOTY_TRANSPORT_DIR || true)
    if [ -n "$cached_transport" ] && [ "$cached_transport" != "${AXOLOTY_TRANSPORT_DIR:-}" ]; then
        stale="$stale AXOLOTY_TRANSPORT_DIR (cached: $cached_transport; selected: ${AXOLOTY_TRANSPORT_DIR:-unset})"
    fi
    if [ -n "$stale" ]; then
        echo "profile selection changed;$stale; cleared stale build directory $build_dir"
        rm -rf -- "$build_dir"
    fi
    return 0
}
