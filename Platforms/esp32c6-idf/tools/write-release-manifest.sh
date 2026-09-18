#!/bin/sh
# Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

# Produce the per-profile release manifest from what a completed build already
# wrote: the Core preparation report and the build provenance. The build calls
# this; the release path calls it again after qualification so the manifest
# carries the device evidence. It never fabricates a field.
#
# Environment, matching the platform build:
#   AXOLOTY_SCRATCH        Scratch root. Default: <repo>/.axoloty
#   EMBEDDED_PROOF_ROOT    Caller-owned proof workspace. Default: <scratch>/firmware
#   EMBEDDED_EVIDENCE_DIR  Evidence output directory.
#   AXOLOTY_PREVIEW_CORE_REVISION  Set only by the compatibility-preview path.

set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
platform_dir=$(CDPATH= cd -- "$script_dir/.." && pwd)
repo_root=$(git -C "$script_dir" rev-parse --show-toplevel)
profile_dir=${1:-}

if [ -z "$profile_dir" ] || [ ! -f "$profile_dir/profile.json" ]; then
    echo "error: usage: write-release-manifest.sh <profile-dir>" >&2
    exit 64
fi
profile_dir=$(CDPATH= cd -- "$profile_dir" && pwd)

scratch=${AXOLOTY_SCRATCH:-"$repo_root/.axoloty"}
proof_root=${EMBEDDED_PROOF_ROOT:-"$scratch/firmware"}
evidence_dir=${EMBEDDED_EVIDENCE_DIR:-"$proof_root/working-evidence"}
preparation="$evidence_dir/preparation.json"
provenance="$evidence_dir/build-provenance.json"
output="$evidence_dir/release-manifest.json"

for required in "$preparation" "$provenance"; do
    if [ ! -f "$required" ]; then
        echo "error: the build did not write $required; run the build first" >&2
        exit 1
    fi
done

set +e
node "$script_dir/write-release-manifest.mjs" \
    "$repo_root" "$profile_dir/profile.json" "$repo_root/axoloty-core.lock.json" \
    "$repo_root/VERSION" "$preparation" "$provenance" "$output"
node_status=$?
set -e

case "$node_status" in
    0) echo "release manifest written: $output" ;;
    3) echo "no release manifest: this is a development build against an off-lock Core" ;;
    *) exit "$node_status" ;;
esac
