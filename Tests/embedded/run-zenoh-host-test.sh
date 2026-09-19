#!/bin/sh
# Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

# Host check for the embedded Zenoh transport seam.
#
# Compiles the real EmbeddedZenohClient overlay, the real bounded-sample
# validator, and a host-only fake carrier. No board, no SDK, no broker, and no
# zenoh-pico.
#
# The test proves operation order and the 256/2048 bounds before the carrier
# seam is entered. It does not compile or link zenoh-pico and cannot be used by
# the production image.
#
# Exit status: 0 passed, 1 failed, 69 required tool missing.

set -eu

script_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
repo_root=$(git -C "$script_dir" rev-parse --show-toplevel)
transport_main="$repo_root/Transports/zenoh-pico/main"

compiler=${CC:-clang}
if ! command -v "$compiler" >/dev/null 2>&1; then
    echo "embedded Zenoh host test requires a C compiler ('$compiler')" >&2
    exit 69
fi
if ! command -v swiftc >/dev/null 2>&1; then
    echo "embedded Zenoh host test requires swiftc" >&2
    exit 69
fi

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

"$compiler" -std=c11 -O2 -Wall -Wextra -Werror \
    -I "$transport_main" \
    -c "$script_dir/zenoh-host-hal.c" -o "$tmp/hal.o"
"$compiler" -std=c11 -O2 -Wall -Wextra -Werror \
    -I "$transport_main" \
    -c "$transport_main/zenoh_sample_validation.c" -o "$tmp/validation.o"
swiftc -D EMBEDDED_ZENOH_HOST_TEST \
    "$transport_main/EmbeddedZenohClient.swift" \
    "$script_dir/zenoh-host-test.swift" \
    "$tmp/hal.o" "$tmp/validation.o" \
    -o "$tmp/embedded-zenoh-host-test"

# Nix's standalone Swift compiler does not always add the dispatch library to
# the executable search path. Native CI images already provide it.
swift_runtime=$(swiftc -print-target-info | awk -F'"' '/runtimeLibraryPaths/{getline; print $2; exit}')
dispatch_dir=$(dirname "$(find /nix/store -name libdispatch.so 2>/dev/null | head -1)")
LD_LIBRARY_PATH="${LD_LIBRARY_PATH:-}:$swift_runtime:$dispatch_dir" \
    "$tmp/embedded-zenoh-host-test"
echo "embedded Zenoh host seam tests passed"
