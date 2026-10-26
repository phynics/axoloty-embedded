#!/bin/sh
# Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.
# Compile and exercise the real ESP32-C6 platform callback through its public table.

set -eu

script_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
repo_root=$(git -C "$script_dir" rev-parse --show-toplevel)
compiler=${CC:-cc}
if ! command -v "$compiler" >/dev/null 2>&1; then
    echo "ROM console test requires a C compiler ('$compiler')" >&2
    exit 69
fi

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

sanitizers=''
if printf 'int main(void) { return 0; }\n' | "$compiler" -x c -fsanitize=address,undefined -o "$tmp/sanitizer-probe" - >/dev/null 2>&1; then
    sanitizers='-fsanitize=address,undefined'
fi

# Intentional word splitting passes optional sanitizer flags as compiler arguments.
# shellcheck disable=SC2086
"$compiler" -std=c11 -O1 -g -Wall -Wextra -Werror $sanitizers \
    -I "$script_dir/fixtures/rom-console" \
    -I "$repo_root/Interop" \
    -I "$repo_root/Platforms/esp32c6-idf/main" \
    "$repo_root/Platforms/esp32c6-idf/main/axoloty_platform_v1.c" \
    "$script_dir/rom-console-test.c" \
    -o "$tmp/rom-console-test"
"$tmp/rom-console-test"
