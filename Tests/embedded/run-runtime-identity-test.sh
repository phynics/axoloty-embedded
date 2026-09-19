#!/bin/sh
# Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

# Host check for the ESP32-C6 platform runtime identity. Moved from the
# pre-split Axoloty runtime-identity selftest. Needs a C compiler only: no
# board, no SDK, no broker.
#
# Exit status: 0 passed, 1 failed, 69 required tool missing.

set -eu

script_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
repo_root=$(git -C "$script_dir" rev-parse --show-toplevel)
platform_main="$repo_root/Platforms/esp32c6-idf/main"

compiler=${CC:-cc}
if ! command -v "$compiler" >/dev/null 2>&1; then
    echo "embedded runtime identity test requires a C compiler ('$compiler')" >&2
    exit 69
fi

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

"$compiler" -std=c11 -Wall -Wextra -Werror \
    -I "$platform_main" \
    "$platform_main/runtime_identity.c" \
    "$script_dir/runtime-identity-test.c" \
    -o "$tmp/runtime-identity-test"
"$tmp/runtime-identity-test"
echo "embedded runtime identity host tests passed"
