#!/bin/sh
# Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

# Host check for the embedded Zenoh transport seam.
#
# Compiles the real EmbeddedZenohClient overlay, the real bounded-sample
# validator, the real bounded receive queue, and a host-only fake carrier. No
# board, no SDK, no broker, and no zenoh-pico.
#
# The C seam under test is the Core-owned Axoloty Zenoh facade, so this check
# needs its header and the module map Core generates for it. Both come from the
# `zenohCore` entry of the Core preparation report, exactly as the firmware
# build takes them; this check names no Core-relative path. Point
# AXOLOTY_PREPARATION_REPORT at that report, or let it default to
# Tools/prepare-core.sh's. Without it, the check reports that it could not run
# (69) instead of passing quietly.
#
# It proves operation order, handle lifetime, the 256/2048 bounds, and the
# bounded queue with its drop counters. It does not compile or link zenoh-pico
# and cannot be used by the production image.
#
# Exit status: 0 passed, 1 failed, 69 required tool or input missing.

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
if ! command -v node >/dev/null 2>&1; then
    echo "embedded Zenoh host test requires node to read the Core preparation report" >&2
    exit 69
fi

# The same preparation report the firmware build reads. Its `zenohCore` entry is
# the only source of the header path, its SHA-256, and the module map; see
# Platforms/esp32c6-idf/cmake/axoloty-source.cmake.
scratch=${AXOLOTY_SCRATCH:-"$repo_root/.axoloty"}
report=${AXOLOTY_PREPARATION_REPORT:-"$scratch/core-preparation.json"}
if [ ! -f "$report" ]; then
    if ! "$repo_root/Tools/prepare-core.sh" >/dev/null 2>&1; then
        echo "embedded Zenoh host test: Core preparation did not produce $report" >&2
        exit 69
    fi
fi
[ -f "$report" ] || {
    echo "embedded Zenoh host test: Core preparation report is missing: $report" >&2
    exit 69
}

json_field() {
    node -e '
const fs = require("fs");
const document = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
let value = document;
for (const key of process.argv[2].split(".")) {
    if (value === undefined || value === null || !(key in value)) process.exit(1);
    value = value[key];
}
if (typeof value !== "string" || value === "") process.exit(1);
process.stdout.write(value);
' "$report" "$1"
}

if ! facade_header=$(json_field zenohCore.facadeHeader); then
    echo "embedded Zenoh host test: the Core preparation report has no zenohCore.facadeHeader" >&2
    echo "Prepare a Core revision that publishes the Zenoh consumer contract" >&2
    echo "(phynics/axoloty#974); the lock must name it." >&2
    exit 69
fi
facade_sha=$(json_field zenohCore.facadeHeaderSHA256) || facade_sha=''
facade_module_map=$(json_field zenohCore.moduleMap) || facade_module_map=''
if [ ! -f "$facade_header" ]; then
    echo "embedded Zenoh host test: the reported facade header is missing: $facade_header" >&2
    exit 69
fi
facade_include=$(dirname "$facade_header")
if [ ! -f "$facade_include/axoloty_zenoh.h" ]; then
    echo "embedded Zenoh host test: the reported facade header is not axoloty_zenoh.h" >&2
    exit 69
fi
facade_include=$(CDPATH='' cd -- "$facade_include" && pwd -P)
facade_header="$facade_include/axoloty_zenoh.h"

# The reported digest is checked, not trusted. A Core that moved its facade ABI
# under an unchanged path must not compile here.
if [ -n "$facade_sha" ]; then
    actual_sha=$(sha256sum "$facade_header" | cut -d' ' -f1)
    if [ "$actual_sha" != "$facade_sha" ]; then
        echo "embedded Zenoh host test: the facade header does not match the" >&2
        echo "SHA-256 the Core preparation report names" >&2
        exit 1
    fi
fi

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# The facade header is Core's, so the Swift overlay imports a module map that
# points at it. The header is linked, never copied: the ABI stays Core's single
# source. Core's generated module map names the header by absolute path and is
# preferred; the local map below is the equivalent for a report that carries no
# module map.
if [ -n "$facade_module_map" ] && [ -f "$facade_module_map" ]; then
    facade_modulemap="$facade_module_map"
else
    ln -s "$facade_header" "$tmp/axoloty_zenoh.h"
    cat > "$tmp/CAxolotyZenoh.modulemap" <<'MODULEMAP'
module CAxolotyZenoh {
    header "axoloty_zenoh.h"
    export *
}
MODULEMAP
    facade_modulemap="$tmp/CAxolotyZenoh.modulemap"
fi

"$compiler" -std=c11 -O2 -Wall -Wextra -Werror \
    -I "$transport_main" -I "$facade_include" -I "$repo_root/Interop" \
    -c "$script_dir/zenoh-host-hal.c" -o "$tmp/hal.o"
"$compiler" -std=c11 -O2 -Wall -Wextra -Werror \
    -I "$transport_main" -I "$facade_include" \
    -c "$script_dir/zenoh-queue-test.c" -o "$tmp/queue-test.o"
"$compiler" -std=c11 -O2 -Wall -Wextra -Werror \
    -I "$transport_main" \
    -c "$transport_main/zenoh_sample_validation.c" -o "$tmp/validation.o"
"$compiler" -std=c11 -O2 -Wall -Wextra -Werror \
    -I "$transport_main" -I "$facade_include" \
    -c "$transport_main/zenoh_pico_queue.c" -o "$tmp/queue.o"
swiftc -D EMBEDDED_ZENOH_HOST_TEST \
    -I "$transport_main" \
    -I "$script_dir" \
    -I "$repo_root/Interop" \
    -Xcc -fmodule-map-file="$facade_modulemap" \
    -Xcc -fmodule-map-file="$script_dir/zenoh_host_test.modulemap" \
    "$transport_main/EmbeddedZenohClient.swift" \
    "$script_dir/zenoh-host-test.swift" \
    "$tmp/hal.o" "$tmp/queue.o" "$tmp/queue-test.o" "$tmp/validation.o" \
    -o "$tmp/embedded-zenoh-host-test"

# Nix's standalone Swift compiler does not always add the dispatch library to
# the executable search path. Native CI images already provide it.
swift_runtime=$(swiftc -print-target-info | awk -F'"' '/runtimeLibraryPaths/{getline; print $2; exit}')
dispatch_dir=$(dirname "$(find /nix/store -name libdispatch.so 2>/dev/null | head -1)")
LD_LIBRARY_PATH="${LD_LIBRARY_PATH:-}:$swift_runtime:$dispatch_dir" \
    "$tmp/embedded-zenoh-host-test"
echo "embedded Zenoh host seam tests passed"
