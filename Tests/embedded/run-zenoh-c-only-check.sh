#!/bin/sh
# Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

# Host check for the C-only Zenoh carrier scenario.
#
# Compiles the real scenario core, the real bounded report shim, the real
# transport-neutral counters, and the host-only fake carrier, then runs the
# whole qualification scenario and validates its JSON Lines stream. No board,
# no SDK, no broker, and no zenoh-pico.
#
# The scenario drives the Core-owned Axoloty Zenoh facade, so this check needs
# its header. That header comes from the `zenohCore` entry of the Core
# preparation report, exactly as the firmware build takes it; this check names
# no Core-relative path.
#
# It proves the scenario drives cold boot, session lifecycle, bidirectional
# traffic, router absent-then-present, queue saturation, continuous traffic,
# maximum and oversized payload, clean shutdown, and repeated reconnect
# through the facade contract, and that its steps and counter snapshot form a
# complete, well-formed JSON Lines record. It does not compile or link
# zenoh-pico, it measures no device resource, and it is not a device result.
#
# The device gate in Profiles/esp32c6-zenoh/qualify-carrier-scenario.sh runs
# the scenario core on a real board and validates the same JSON Lines shape.
# This host run is the reference stream that gate compares against; it is not a
# substitute for it.
#
# Exit status: 0 passed, 1 failed, 69 required tool or input missing.

set -eu

script_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
repo_root=$(git -C "$script_dir" rev-parse --show-toplevel)
transport_main="$repo_root/Transports/zenoh-pico/main"

compiler=${CC:-clang}
for tool in "$compiler" node; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        echo "C-only carrier scenario check requires '$tool'" >&2
        exit 69
    fi
done

scratch=${AXOLOTY_SCRATCH:-"$repo_root/.axoloty"}
report=${AXOLOTY_PREPARATION_REPORT:-"$scratch/core-preparation.json"}
if [ ! -f "$report" ]; then
    if ! "$repo_root/Tools/prepare-core.sh" >/dev/null 2>&1; then
        echo "C-only carrier scenario check: Core preparation did not produce $report" >&2
        exit 69
    fi
fi
[ -f "$report" ] || {
    echo "C-only carrier scenario check: Core preparation report is missing: $report" >&2
    exit 69
}

# The report is a contract. The facade header path and its digest are the only
# source of the declarations this check compiles against; a fallback would let
# it compile against something the firmware will not.
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

facade_header=$(json_field zenohCore.facadeHeader) || {
    echo "C-only carrier scenario check: the report names no zenohCore.facadeHeader" >&2
    exit 1
}
facade_sha=$(json_field zenohCore.facadeHeaderSHA256) || {
    echo "C-only carrier scenario check: the report names no zenohCore.facadeHeaderSHA256" >&2
    exit 1
}
[ -f "$facade_header" ] || {
    echo "C-only carrier scenario check: the reported facade header does not exist: $facade_header" >&2
    exit 1
}
actual_sha=$(sha256sum "$facade_header" | cut -d' ' -f1)
[ "$actual_sha" = "$facade_sha" ] || {
    echo "C-only carrier scenario check: the facade header does not match the reported digest" >&2
    exit 1
}
facade_include=$(CDPATH='' cd -- "$(dirname -- "$facade_header")" && pwd -P)

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

"$compiler" -std=c11 -O2 -Wall -Wextra -Werror \
    -I "$transport_main" -I "$facade_include" \
    -c "$transport_main/carrier_diagnostics.c" -o "$tmp/diagnostics.o"
# The host fake also carries the shared sample-validation guard vectors, so the
# one function they need is linked rather than stubbed. No test overlay: the
# scenario exercises the production sources.
"$compiler" -std=c11 -O2 -Wall -Wextra -Werror \
    -I "$transport_main" \
    -c "$transport_main/zenoh_sample_validation.c" -o "$tmp/validation.o"
"$compiler" -std=c11 -O2 -Wall -Wextra -Werror \
    -I "$transport_main" \
    -c "$transport_main/zenoh_carrier_report.c" -o "$tmp/report.o"
"$compiler" -std=c11 -O2 -Wall -Wextra -Werror \
    -I "$transport_main" -I "$facade_include" \
    -c "$transport_main/zenoh_carrier_scenario.c" -o "$tmp/scenario.o"
"$compiler" -std=c11 -O2 -Wall -Wextra -Werror \
    -I "$transport_main" -I "$facade_include" \
    -c "$script_dir/zenoh-host-hal.c" -o "$tmp/hal.o"
"$compiler" -std=c11 -O2 -Wall -Wextra -Werror \
    -I "$transport_main" -I "$facade_include" \
    -c "$script_dir/zenoh-c-only-runner.c" -o "$tmp/runner.o"

"$compiler" "$tmp/diagnostics.o" "$tmp/report.o" "$tmp/scenario.o" "$tmp/validation.o" \
    "$tmp/hal.o" "$tmp/runner.o" -o "$tmp/zenoh-c-only-runner"

# The gate passes the measured flash size through here; a bare host run leaves
# it zero and the summary records that no image was measured.
#
# AXOLOTY_KEEP_STREAM copies the raw JSON Lines stream somewhere durable, so a
# reviewer can read the exact stream a run produced instead of trusting the
# summary line. It defaults to the temporary directory, which is discarded.
stream=$tmp/scenario.jsonl
AXOLOTY_SCENARIO_FLASH_BYTES="${AXOLOTY_SCENARIO_FLASH_BYTES:-634880}" \
    "$tmp/zenoh-c-only-runner" > "$stream"
if [ -n "${AXOLOTY_KEEP_STREAM:-}" ]; then
    cp "$stream" "$AXOLOTY_KEEP_STREAM"
fi

node "$script_dir/validate-carrier-runner.mjs" "$stream" > "$tmp/validation.json" || {
    echo "C-only carrier scenario check: the scenario stream did not validate" >&2
    cat "$stream" >&2
    cat "$tmp/validation.json" >&2
    exit 1
}

echo "C-only carrier scenario: $(node -e '
const fs = require("fs");
const record = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
const summary = record.summary;
process.stdout.write(`${summary.steps} steps, ${summary.passed} passed, ${summary.unavailable} unavailable, ${summary.failed} failed`);
' "$tmp/validation.json")"
