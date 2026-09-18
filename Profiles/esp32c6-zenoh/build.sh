#!/bin/sh
# Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

# Build the esp32c6-zenoh profile: one application, one platform, one transport.
# The profile selects the axes from profile.json and delegates to the platform
# build tool. It contains no firmware logic.
#
# Environment passes through: AXOLOTY_PROOF_RUN_ID, AXOLOTY_SCRATCH,
# AXOLOTY_SOURCE_DIR, EMBEDDED_PROOF_ROOT, EMBEDDED_BUILD_DIR,
# EMBEDDED_EVIDENCE_DIR, CMAKE_BUILD_PARALLEL_LEVEL.

set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo_root=$(git -C "$script_dir" rev-parse --show-toplevel)
profile="$script_dir/profile.json"

if [ ! -f "$profile" ]; then
    echo "error: profile.json is missing: $profile" >&2
    exit 64
fi

read_field() {
    node -e 'const p = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8")); const v = p[process.argv[2]]; if (typeof v !== "string" || v.length === 0) { process.exit(1); } process.stdout.write(v);' \
        "$profile" "$1"
}

application=$(read_field application)
platform=$(read_field platform)
transport=$(read_field transport)

export AXOLOTY_PROFILE_DIR="$script_dir"
export AXOLOTY_APPLICATION_DIR="$repo_root/Applications/$application"
export AXOLOTY_TRANSPORT_DIR="$repo_root/Transports/$transport"

if [ ! -d "$AXOLOTY_APPLICATION_DIR" ]; then
    echo "error: profile names application '$application', but it does not exist" >&2
    exit 64
fi
if [ ! -d "$AXOLOTY_TRANSPORT_DIR" ]; then
    echo "error: profile names transport '$transport', but it does not exist" >&2
    exit 64
fi
if [ ! -d "$repo_root/Platforms/$platform" ]; then
    echo "error: profile names platform '$platform', but it does not exist" >&2
    exit 64
fi

exec "$repo_root/Platforms/$platform/tools/build.sh" "$@"
