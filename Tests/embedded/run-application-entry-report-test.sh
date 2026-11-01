#!/bin/sh
# Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.
# Compile the real platform entry and entry reporter against stand-ins for the
# application dispatcher and platform table, and check a failed entry is reported.

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
    echo "application entry report test requires a C compiler ('$compiler')" >&2
    exit 69
fi

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

"$compiler" -std=c11 -O1 -g -Wall -Wextra -Werror \
    -DAXOLOTY_HEAP_TRACE_CALIBRATION=0 \
    -I "$repo_root/Interop" \
    -I "$repo_root/Platforms/esp32c6-idf/main" \
    "$repo_root/Platforms/esp32c6-idf/main/Esp32c6AppMain.c" \
    "$repo_root/Platforms/esp32c6-idf/main/application_entry_report.c" \
    "$script_dir/application-entry-report-test.c" \
    -o "$tmp/application-entry-report-test"
"$tmp/application-entry-report-test"

# The smoke validator must turn the line into the failure, not "missing boot record".
if command -v node >/dev/null 2>&1; then
    AXOLOTY_CORPUS_MANIFEST="$repo_root/Applications/device-smoke-agent/fixtures/manifest.json" \
    VALIDATOR="$repo_root/Platforms/esp32c6-idf/tools/validate-smoke.mjs" \
        node --input-type=module -e '
import assert from "node:assert/strict";
const { createEmbeddedSwiftTestValidator } = await import(process.env.VALIDATOR);
const validator = createEmbeddedSwiftTestValidator();
validator.observe("I (300) boot: nothing structured");
validator.observe("axoloty:application-entry-failed status=-105 name=trace-start-failed");
const result = validator.result();
assert.equal(result.passed, false);
assert.match(result.diagnostic, /application-entry-failed status=-105 name=trace-start-failed/);
console.log("smoke validator names the failed application entry");
'
fi
