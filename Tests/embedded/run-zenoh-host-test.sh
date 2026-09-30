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
# Tools/prepare-core.sh's.
#
# The report is a contract, not a hint. Every field the locked Core publishes is
# required, every path must be absolute, canonical, and inside the root the
# report names, and the header must match the reported digest. There is no
# locally generated module map and no optional digest: a fallback would let this
# check compile against something the firmware image will not compile against,
# which is the failure this seam exists to prevent. A report that does not
# satisfy the contract fails (1); only a missing report or a missing tool makes
# the check unable to run (69).
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
if ! command -v realpath >/dev/null 2>&1; then
    echo "embedded Zenoh host test requires realpath to check the reported paths" >&2
    exit 69
fi
if ! command -v sha256sum >/dev/null 2>&1; then
    echo "embedded Zenoh host test requires sha256sum to check the reported digest" >&2
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

# The report is the contract, and it is checked the same way the firmware build
# checks it. Every field the locked Core publishes is required, every path must
# be canonical and inside the root the report names, and the digest must be a
# 64-character hexadecimal string that matches the header. A report that does
# not satisfy all of that is a failed check, never a passing fallback: the
# whole point of this seam is that the firmware compiles against exactly the
# declarations Core published.
fail_contract() {
    echo "embedded Zenoh host test: malformed Core preparation report: $1" >&2
    exit 1
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

require_field() {
    # $1 dotted field, $2 what it is for.
    if ! value=$(json_field "$1"); then
        fail_contract "no $1. $2"
    fi
    printf '%s' "$value"
}

is_absolute() {
    case "$1" in
        /*) return 0 ;;
        *) return 1 ;;
    esac
}

# Resolve every component of a path, so a `..` segment, a `.` segment, or a
# symlink resolves the same way it does for the firmware build.
canonical_path() {
    realpath -- "$1"
}

is_canonical() {
    [ "$1" = "$(canonical_path "$1")" ]
}

inside_root() {
    # $1 path, $2 canonical root. A sibling directory that shares a prefix with
    # the root is outside it, which a prefix test without the slash would miss.
    case "$(canonical_path "$1")" in
        "$2"/*) return 0 ;;
        *) return 1 ;;
    esac
}

facade_header=$(require_field zenohCore.facadeHeader \
    "The Axoloty Zenoh facade header is Core-owned and this check compiles against it.")
facade_sha=$(require_field zenohCore.facadeHeaderSHA256 \
    "The locked Core publishes a digest for the header; without it the ABI is unverified.")
facade_module_map=$(require_field zenohCore.moduleMap \
    "Core generates the module map that binds the Swift module to the facade.")
core_source_dir=$(require_field core.sourceDir "The report must name the Core checkout it prepared.")
core_scratch_dir=$(require_field staticRuntimeMacro.scratchDir \
    "The report must name the caller-owned scratch the module map lives in.")

is_absolute "$facade_header" ||
    fail_contract "zenohCore.facadeHeader is not an absolute path: $facade_header"
is_absolute "$facade_module_map" ||
    fail_contract "zenohCore.moduleMap is not an absolute path: $facade_module_map"
[ ! -d "$facade_header" ] ||
    fail_contract "zenohCore.facadeHeader is a directory, not a file: $facade_header"
[ -f "$facade_header" ] ||
    fail_contract "zenohCore.facadeHeader is not an existing file: $facade_header"
[ -d "$core_source_dir" ] ||
    fail_contract "core.sourceDir is not an existing directory: $core_source_dir"
[ -d "$core_scratch_dir" ] ||
    fail_contract "staticRuntimeMacro.scratchDir is not an existing directory: $core_scratch_dir"

is_canonical "$facade_header" ||
    fail_contract "zenohCore.facadeHeader is not canonical: $facade_header"
is_canonical "$core_source_dir" ||
    fail_contract "core.sourceDir is not canonical: $core_source_dir"
is_canonical "$core_scratch_dir" ||
    fail_contract "staticRuntimeMacro.scratchDir is not canonical: $core_scratch_dir"
core_source_dir=$(canonical_path "$core_source_dir")
core_scratch_dir=$(canonical_path "$core_scratch_dir")
inside_root "$facade_header" "$core_source_dir" ||
    fail_contract "zenohCore.facadeHeader is outside the Core checkout: $facade_header"

case "$facade_sha" in
    *[!0-9a-f]* | "") fail_contract "zenohCore.facadeHeaderSHA256 is not 64 lowercase hexadecimal characters: $facade_sha" ;;
esac
[ "${#facade_sha}" -eq 64 ] ||
    fail_contract "zenohCore.facadeHeaderSHA256 is ${#facade_sha} characters, not 64: $facade_sha"
actual_sha=$(sha256sum "$facade_header" | cut -d' ' -f1)
[ "$actual_sha" = "$facade_sha" ] ||
    fail_contract "the facade header does not match the SHA-256 the report names (report $facade_sha, header $actual_sha)"

[ ! -d "$facade_module_map" ] ||
    fail_contract "zenohCore.moduleMap is a directory, not a file: $facade_module_map"
[ -f "$facade_module_map" ] ||
    fail_contract "zenohCore.moduleMap is not an existing file: $facade_module_map"
is_canonical "$facade_module_map" ||
    fail_contract "zenohCore.moduleMap is not canonical: $facade_module_map"
inside_root "$facade_module_map" "$core_scratch_dir" ||
    fail_contract "zenohCore.moduleMap is outside caller-owned scratch: $facade_module_map"

facade_include=$(CDPATH='' cd -- "$(dirname -- "$facade_header")" && pwd -P)
[ -f "$facade_include/axoloty_zenoh.h" ] ||
    fail_contract "the reported facade header is not axoloty_zenoh.h: $facade_header"
facade_modulemap="$facade_module_map"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT


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
