#!/bin/sh
# Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

# Build the SwiftSyntax plugin on the host before the Embedded Swift CMake
# configure step. Its output stays under the caller-owned scratch directory.

set -eu

script_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
repo_root=$(git -C "$script_dir" rev-parse --show-toplevel)
scratch=${AXOLOTY_SCRATCH:-"$repo_root/.axoloty"}
build_dir="$scratch/embedded-application-macro-build"

if ! command -v swift >/dev/null 2>&1; then
    echo "error: swift 6.4 is required to build EmbeddedApplicationMacroImplementation" >&2
    exit 69
fi
mkdir -p "$scratch"
swift build \
    --package-path "$repo_root/Tools/EmbeddedApplicationMacros" \
    --build-path "$build_dir" \
    --configuration release \
    --product embedded-application-macro-probe >&2

bin_dir=$(swift build \
    --package-path "$repo_root/Tools/EmbeddedApplicationMacros" \
    --build-path "$build_dir" \
    --configuration release \
    --show-bin-path) || {
    echo "error: SwiftPM could not report the macro plugin bin directory" >&2
    exit 1
}
plugins=$(find "$bin_dir" -maxdepth 2 -type f \
    \( -name EmbeddedApplicationMacroImplementation -o -name EmbeddedApplicationMacroImplementation-tool \) \
    -perm -u+x -print)
count=$(printf '%s\n' "$plugins" | awk 'NF { count += 1 } END { print count + 0 }')
if [ "$count" -ne 1 ]; then
    echo "error: expected one executable EmbeddedApplicationMacroImplementation plugin under SwiftPM bin directory '$bin_dir'; found $count" >&2
    printf '%s\n' "$plugins" >&2
    exit 1
fi
plugin=$plugins
printf '%s\n' "$plugin"
