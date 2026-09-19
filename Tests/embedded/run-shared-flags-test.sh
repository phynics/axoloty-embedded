#!/bin/sh
# Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

# Host check for the ESP32-C6 platform shared flags. Split out of the pre-split
# Axoloty MQTT client selftest. Needs a C compiler and pthreads only: no board,
# no SDK, no broker.
#
# Exit status: 0 passed, 1 failed, 69 required tool missing.

set -eu

script_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
repo_root=$(git -C "$script_dir" rev-parse --show-toplevel)
platform_main="$repo_root/Platforms/esp32c6-idf/main"

compiler=${CC:-cc}
if ! command -v "$compiler" >/dev/null 2>&1; then
    echo "embedded shared flags test requires a C compiler ('$compiler')" >&2
    exit 69
fi

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

"$compiler" -std=c11 -O2 -Wall -Wextra -Werror -pthread \
    -I "$platform_main" \
    "$script_dir/shared-flags-test.c" \
    -o "$tmp/shared-flags-test"
"$tmp/shared-flags-test"
echo "embedded shared flags host tests passed"
