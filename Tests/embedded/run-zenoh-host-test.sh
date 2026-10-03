#!/bin/sh
# Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

# Host check for the embedded Zenoh transport seam.
#
# Compiles the real carrier and probe sources against the real portable
# session module, the real bounded-sample validator, the real bounded receive
# queue, the real endpoint helper, and a host-only fake carrier. No board, no
# SDK, no broker, and no zenoh-pico.
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
# It proves lifecycle order, the 256/2048 bounds, application-owned
# multi-shape subscription cleanup when a later declaration fails, the
# unsupported last-will refusal, deadline-bounded router observation with
# already-connected, restored-before-entry, timeout and closed-session cases,
# 100-Hz wait conversion including a sub-tick remainder, error mapping,
# and the probe's honest record sequence. It does not compile or link
# zenoh-pico and cannot be used by the production image.
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

# The carrier is written against the portable session module, so this check
# compiles the same Core sources the firmware image compiles in place: the
# JSON core, AxolotyWire, then AxolotyZenohCore. It also compiles the exact
# application-owned profile-interest installer for its partial-failure test.
zenoh_core_dir=$(require_field zenohCore.sourceDir \
    "The portable session module is Core-owned and the carrier is written against it.")
wire_dir=$(require_field portablePackages.0.sourcePath \
    "AxolotyZenohCore imports AxolotyWire, so this check compiles it from the same report.")
json_core_dir=$(require_field jsonCore.sourceDir \
    "AxolotyWire imports the JSON core, so this check compiles it from the same report.")

for core_path in "$zenoh_core_dir" "$wire_dir"; do
    is_absolute "$core_path" ||
        fail_contract "a Core source path is not absolute: $core_path"
    [ -d "$core_path" ] ||
        fail_contract "a Core source path is not a directory: $core_path"
    is_canonical "$core_path" ||
        fail_contract "a Core source path is not canonical: $core_path"
    inside_root "$core_path" "$core_source_dir" ||
        fail_contract "a Core source path is outside the Core checkout: $core_path"
done
is_absolute "$json_core_dir" ||
    fail_contract "the JSON core source path is not absolute: $json_core_dir"
[ -d "$json_core_dir" ] ||
    fail_contract "the JSON core source path is not a directory: $json_core_dir"
is_canonical "$json_core_dir" ||
    fail_contract "the JSON core source path is not canonical: $json_core_dir"
inside_root "$json_core_dir" "$core_scratch_dir" ||
    fail_contract "the JSON core source path is outside caller-owned scratch: $json_core_dir"
[ "$(json_field portablePackages.0.name)" = "AxolotyWire" ] ||
    fail_contract "portablePackages.0 is not AxolotyWire"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# A private endpoint configuration for the real endpoint helper. The helper
# is device C with no SDK dependency, so it compiles on the host unchanged;
# the generated header supplies the operator values the device harness
# generates per run.
cat > "$tmp/axoloty_network_config.h" <<'EOF'
#ifndef AXOLOTY_NETWORK_CONFIG_H
#define AXOLOTY_NETWORK_CONFIG_H
#define AXOLOTY_NETWORK_CONFIGURED 1
static const char axoloty_zenoh_host[] = { '1', '2', '7', '.', '0', '.', '0', '.', '1', 0 };
static const unsigned int axoloty_zenoh_port = 7447U;
#endif
EOF

swift_sources() {
    for source in "$1"/*.swift; do
        [ -f "$source" ] && printf '%s\n' "$source"
    done
}

# The portable packages compile as the host, exactly as run-host-smoke-test.sh
# compiles them: same sources, same order, same Lifetimes feature.
swiftc -swift-version 6 -enable-experimental-feature Lifetimes -package-name IkigaJSON -parse-as-library -wmo \
    -module-name _JSONCore \
    -emit-module -emit-module-path "$tmp/_JSONCore.swiftmodule" \
    -c $(swift_sources "$json_core_dir") $(swift_sources "$json_core_dir/Parser") $(swift_sources "$json_core_dir/SIMD") \
    -o "$tmp/_JSONCore.o"
swiftc -swift-version 6 -enable-experimental-feature Lifetimes -parse-as-library -wmo \
    -module-name AxolotyWire \
    -I "$tmp" \
    -emit-module -emit-module-path "$tmp/AxolotyWire.swiftmodule" \
    -c $(swift_sources "$wire_dir") -o "$tmp/AxolotyWire.o"
swiftc -swift-version 6 -enable-experimental-feature Lifetimes -parse-as-library -wmo \
    -module-name AxolotyZenohCore \
    -I "$tmp" \
    -Xcc -fmodule-map-file="$facade_modulemap" \
    -emit-module -emit-module-path "$tmp/AxolotyZenohCore.swiftmodule" \
    -c $(swift_sources "$zenoh_core_dir") -o "$tmp/AxolotyZenohCore.o"

"$compiler" -std=c11 -O2 -Wall -Wextra -Werror \
    -I "$transport_main" -I "$facade_include" -I "$repo_root/Interop" \
    -c "$script_dir/zenoh-host-hal.c" -o "$tmp/hal.o"
"$compiler" -std=c11 -O2 -Wall -Wextra -Werror \
    -I "$transport_main" -I "$facade_include" \
    -c "$script_dir/zenoh-queue-test.c" -o "$tmp/queue-test.o"
# The carrier-diagnostics conformance vectors. Compiled against the production
# counters, so the properties the device gate relies on are checked in C where
# they can be observed exactly, and not approximated from Swift.
"$compiler" -std=c11 -O2 -Wall -Wextra -Werror \
    -I "$transport_main" \
    -c "$script_dir/carrier-diagnostics-test.c" -o "$tmp/diagnostics-test.o"
"$compiler" -std=c11 -O2 -Wall -Wextra -Werror \
    -I "$transport_main" \
    -c "$transport_main/zenoh_sample_validation.c" -o "$tmp/validation.o"
# The transport-neutral carrier counters the production image links. Compiled
# from the transport's own source with no Zenoh and no SDK header, exactly as
# the image compiles it, so the host seam checks the production counters rather
# than a stand-in.
"$compiler" -std=c11 -O2 -Wall -Wextra -Werror \
    -I "$transport_main" \
    -c "$transport_main/carrier_diagnostics.c" -o "$tmp/diagnostics.o"
"$compiler" -std=c11 -O2 -Wall -Wextra -Werror \
    -I "$transport_main" -I "$facade_include" \
    -c "$transport_main/zenoh_pico_queue.c" -o "$tmp/queue.o"
"$compiler" -std=c11 -O2 -Wall -Wextra -Werror \
    -I "$transport_main" -I "$tmp" -I "$repo_root/Platforms/esp32c6-idf/main" \
    -c "$transport_main/zenoh_endpoint.c" -o "$tmp/endpoint.o"
# The real carrier and probe sources the firmware image compiles. The host
# test flag exposes the host-only test module for the platform clock the
# carrier waits on; the device links the SDK originals through its bridging
# header instead. No test overlay: the host test exercises the production path.
swiftc -D EMBEDDED_ZENOH_HOST_TEST \
    -I "$tmp" \
    -I "$transport_main" \
    -I "$script_dir" \
    -I "$repo_root/Interop" \
    -Xcc -I"$transport_main" \
    -Xcc -fmodule-map-file="$facade_modulemap" \
    -Xcc -fmodule-map-file="$script_dir/zenoh_host_test.modulemap" \
    "$transport_main/ZenohCarrier.swift" \
    "$transport_main/ZenohNetworkProbe.swift" \
    "$repo_root/Applications/device-smoke-agent/main/ProfileInterest.swift" \
    "$script_dir/zenoh-host-test.swift" \
    "$tmp/hal.o" "$tmp/queue.o" "$tmp/queue-test.o" "$tmp/validation.o" "$tmp/endpoint.o" \
    "$tmp/diagnostics.o" "$tmp/diagnostics-test.o" \
    "$tmp/_JSONCore.o" "$tmp/AxolotyWire.o" "$tmp/AxolotyZenohCore.o" \
    -Xlinker -lpthread \
    -o "$tmp/embedded-zenoh-host-test"

# Nix's standalone Swift compiler does not always add the dispatch library to
# the executable search path. Native CI images already provide it.
swift_runtime=$(swiftc -print-target-info | awk -F'"' '/runtimeLibraryPaths/{getline; print $2; exit}')
dispatch_dir=$(dirname "$(find /nix/store -name libdispatch.so 2>/dev/null | head -1)")
LD_LIBRARY_PATH="${LD_LIBRARY_PATH:-}:$swift_runtime:$dispatch_dir" \
    "$tmp/embedded-zenoh-host-test"
echo "embedded Zenoh host seam tests passed"

# Compile the real key-expression conformance test from the exact prepared
# zenoh-pico pin. This independently proves the selected wildcard shapes with
# the production parser, not the fake facade's accept-all subscription stub.
pico_report=${AXOLOTY_ZENOH_PICO_REPORT:-"$scratch/zenoh-pico-preparation.json"}
if [ ! -f "$pico_report" ]; then
    if ! AXOLOTY_SCRATCH="$scratch" "$repo_root/Tools/prepare-zenoh-pico.sh" >/dev/null 2>&1; then
        echo "embedded Zenoh host test: zenoh-pico preparation did not produce $pico_report" >&2
        exit 69
    fi
fi
[ -f "$pico_report" ] || {
    echo "embedded Zenoh host test: pinned zenoh-pico report is missing: $pico_report" >&2
    exit 69
}
pico_dir=$(node -e 'process.stdout.write(JSON.parse(require("fs").readFileSync(process.argv[1], "utf8")).sourceDir)' "$pico_report")
is_absolute "$pico_dir" || fail_contract "zenoh-pico sourceDir is not absolute: $pico_dir"
[ -d "$pico_dir" ] || fail_contract "zenoh-pico sourceDir is not a directory: $pico_dir"
is_canonical "$pico_dir" || fail_contract "zenoh-pico sourceDir is not canonical: $pico_dir"
PICO_REPORT="$pico_report" PICO_LOCK="$repo_root/Platforms/esp32c6-idf/dependencies/zenoh-pico.lock.json" \
    PICO_SOURCE="$pico_dir" node --input-type=module <<'JS'
import crypto from "node:crypto";
import fs from "node:fs";
import { execFileSync } from "node:child_process";

const report = JSON.parse(fs.readFileSync(process.env.PICO_REPORT, "utf8"));
const lockBytes = fs.readFileSync(process.env.PICO_LOCK);
const lock = JSON.parse(lockBytes.toString("utf8"));
const pin = lock;
const revision = execFileSync("git", ["-C", process.env.PICO_SOURCE, "rev-parse", "HEAD"], { encoding: "utf8" }).trim();
const pinDigest = crypto.createHash("sha256").update(lockBytes).digest("hex");
if (report.schemaVersion !== 1 || report.status !== "prepared" ||
    report.revision !== pin.revision || report.version !== pin.version ||
    revision !== pin.revision || report.pinSha256 !== pinDigest) {
  throw new Error("pinned zenoh-pico parser input does not match the checked-in lock and prepared report");
}
JS

pico_work="$tmp/zenoh-pico-parser"
mkdir -p "$pico_work"
mkdir -p "$pico_work/.cmake/api/v1/query"
touch "$pico_work/.cmake/api/v1/query/codemodel-v2"
cmake -S "$pico_dir" -B "$pico_work" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_C_STANDARD=11 \
    -DBUILD_TESTING=ON \
    -DBUILD_SHARED_LIBS=OFF \
    -DBUILD_TOOLS=OFF \
    -DBUILD_EXAMPLES=OFF \
    -DZ_FEATURE_UNSTABLE_API=ON \
    >"$pico_work/configure.log" 2>&1 || {
        echo "embedded Zenoh host test: pinned zenoh-pico parser configuration failed" >&2
        tail -n 20 "$pico_work/configure.log" >&2
        exit 1
    }
cmake --build "$pico_work" --target z_keyexpr_test -j2 >"$pico_work/build.log" 2>&1 || {
    echo "embedded Zenoh host test: pinned zenoh-pico key-expression test build failed" >&2
    tail -n 20 "$pico_work/build.log" >&2
    exit 1
}
"$pico_work/tests/z_keyexpr_test"
zenoh_pico_library=$(python3 - "$pico_work" <<'PY'
import glob, json, os, sys
root = sys.argv[1]
index_path = sorted(glob.glob(os.path.join(root, ".cmake/api/v1/reply/index-*.json")))[-1]
index = json.load(open(index_path))
codemodel_name = index["reply"]["codemodel-v2"]["jsonFile"]
codemodel = json.load(open(os.path.join(root, ".cmake/api/v1/reply", codemodel_name)))
configuration = codemodel["configurations"][0]
for target_ref in configuration["targets"]:
    target = json.load(open(os.path.join(root, ".cmake/api/v1/reply", target_ref["jsonFile"])))
    if target["name"] != "zenohpico_static" or target["type"] != "STATIC_LIBRARY":
        continue
    artifact = target["artifacts"][0]["path"]
    print(os.path.join(root, artifact))
    break
else:
    raise SystemExit("pinned zenoh-pico codemodel has no static zenohpico target")
PY
)
"$compiler" -std=c11 -O2 -Wall -Wextra -Werror -DZENOH_LINUX \
    -I "$pico_dir/include" -I "$pico_work/include" \
    "$script_dir/zenoh-route-parser.c" \
    "$zenoh_pico_library" \
    -o "$pico_work/zenoh-route-parser-test"
"$pico_work/zenoh-route-parser-test"
echo "pinned zenoh-pico key-expression tests passed"
