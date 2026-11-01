#!/bin/sh
# Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.
# Compile the real Wi-Fi bootstrap against a stub asynchronous driver and check
# that teardown waits for the driver's disconnect and stop reports before deinit.

set -eu

script_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
repo_root=$(git -C "$script_dir" rev-parse --show-toplevel)
compiler=${CC:-}
if [ -z "$compiler" ]; then
    for candidate in cc clang gcc; do
        if command -v "$candidate" >/dev/null 2>&1; then compiler=$candidate; break; fi
    done
fi
if [ -z "$compiler" ] || ! command -v "$compiler" >/dev/null 2>&1; then
    echo "network cleanup test requires a C compiler ('$compiler')" >&2
    exit 69
fi

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

"$compiler" -std=gnu11 -O1 -g -Wall -Wextra -Werror \
    -I "$script_dir/fixtures/network-cleanup" \
    -I "$repo_root/Platforms/esp32c6-idf/main" \
    "$repo_root/Platforms/esp32c6-idf/main/network_bootstrap.c" \
    "$script_dir/network-cleanup-test.c" \
    -o "$tmp/network-cleanup-test"
"$tmp/network-cleanup-test"
