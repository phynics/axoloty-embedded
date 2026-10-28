#!/usr/bin/env bash
# Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

set -euo pipefail

repo_root="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$repo_root"
for tool in clang node nm python3; do
    command -v "$tool" >/dev/null 2>&1 || {
        echo "run-heap-trace-calibration-test: required tool '$tool' is unavailable" >&2
        exit 69
    }
done

work="$(mktemp -d "${TMPDIR:-/tmp}/axoloty-heap-calibration.XXXXXX")"
trap 'rm -rf "$work"' EXIT HUP INT TERM
mkdir -p "$work/tmp" "$work/home"
artifact_dir="${AXOLOTY_HEAP_TRACE_CALIBRATION_ARTIFACT_DIR:-}"
if [ -n "$artifact_dir" ]; then mkdir -p "$artifact_dir"; fi
printf 'case\trunner_status\tvalidator_status\tcleanup\n' > "$work/outcomes.tsv"

clang -std=c11 -Wall -Wextra -Werror -ffunction-sections -fdata-sections \
    -Wl,--gc-sections -Wl,--wrap=malloc -Wl,--wrap=calloc -Wl,--wrap=free \
    -I Tests/embedded/heap-trace-status-stubs -I Interop \
    Platforms/esp32c6-idf/main/log_helper.c \
    Platforms/esp32c6-idf/main/heap_trace_platform_adapter.c \
    Platforms/esp32c6-idf/main/heap_trace_calibration.c \
    Tests/embedded/heap-trace-calibration-host-test.c \
    -o "$work/heap-trace-calibration-host-test"

if "$work/heap-trace-calibration-host-test" > "$work/records.csv" 2> "$work/normal-cleanup.log"; then
    runner_status=0
else
    runner_status=$?
fi
if [ "$runner_status" -ne 0 ]; then cat "$work/normal-cleanup.log" >&2; exit 1; fi
if node Tests/embedded/validate-heap-trace-calibration.mjs "$work/records.csv" > "$work/normal-validator.log" 2>&1; then
    validator_status=0
else
    validator_status=$?
fi
if [ "$validator_status" -ne 0 ]; then cat "$work/normal-validator.log" >&2; exit 1; fi
cat "$work/normal-cleanup.log" "$work/normal-validator.log"
printf 'normal\t%s\t%s\tPASS\n' "$runner_status" "$validator_status" >> "$work/outcomes.tsv"
for mode in begin end summary helper_summary final_summary miss_overflow null_malloc null_heap_caps null_calloc \
    null_overflow_partial null_overflow_near_capacity miss_malloc_unrelated \
    miss_heap_caps_unrelated miss_calloc_unrelated miss_calloc_reuse; do
    if "$work/heap-trace-calibration-host-test" "$mode" > "$work/$mode.csv" 2> "$work/$mode-cleanup.log"; then
        runner_status=0
    else
        runner_status=$?
    fi
    if [ "$runner_status" -eq 0 ]; then
        echo "run-heap-trace-calibration-test: observer fault '$mode' was accepted" >&2
        exit 1
    fi
    if [ "$mode" = miss_overflow ]; then
        if node Tests/embedded/validate-heap-trace-calibration.mjs --expect-failure "$work/$mode.csv" > "$work/$mode-validator.log" 2>&1; then
            echo "run-heap-trace-calibration-test: contradictory overflow fault '$mode' was accepted" >&2
            exit 1
        else
            validator_status=$?
        fi
    else
        if node Tests/embedded/validate-heap-trace-calibration.mjs --expect-failure "$work/$mode.csv" > "$work/$mode-validator.log" 2>&1; then
            validator_status=0
        else
            validator_status=$?
            cat "$work/$mode-validator.log" >&2
            exit 1
        fi
    fi
    if ! grep -q '^heap-trace-calibration-host: cleanup PASS$' "$work/$mode-cleanup.log"; then
        cat "$work/$mode-cleanup.log" >&2
        echo "run-heap-trace-calibration-test: observer fault '$mode' leaked an allocation" >&2
        exit 1
    fi
    printf '%s\t%s\t%s\tPASS\n' "$mode" "$runner_status" "$validator_status" >> "$work/outcomes.tsv"
    cat "$work/$mode-cleanup.log" "$work/$mode-validator.log"
done
node Tests/embedded/validate-heap-trace-calibration.mjs --self-test
node --input-type=module - "$work/records.csv" "$work" <<'JS'
import fs from "node:fs";
import { spawnSync } from "node:child_process";
const [input, outputDir] = process.argv.slice(2);
const rows = fs.readFileSync(input, "utf8").trimEnd().split("\n");
const sentinel = 4294967295;
const unavailable = { summary: 0, frees: 0, overflow: 0, mode: -1, mode_ok: 0, records: 0 };
const available = { summary: 1, frees: 0, overflow: 0, mode: 0, mode_ok: 1, records: 0 };
// These are contract fixtures, not target receipts. Vary every case position;
// a FAIL may describe a bad control even when the helper itself succeeds.
const scenarios = [
  ["end_ok_no_summary_sentinel", false, { ...unavailable, end: 0, alloc: sentinel }],
  ["end_ok_summary_sentinel", false, { ...available, end: 0, alloc: sentinel }],
  ["end_ok_no_summary_over_capacity", false, { ...unavailable, end: 0, alloc: 129 }],
  ["end_ok_no_summary_match_exceeds_output", false, { ...unavailable, end: 0, alloc: 0, matched: 1 }],
  ["end_ok_summary_over_capacity", false, { ...available, end: 0, alloc: 129, records: 128 }],
  ["end_ok_leaks", false, { ...available, end: 0, alloc: 0, mode: 1, mode_ok: 0 }],
  ["end_ok_overflow", false, { ...available, end: 0, alloc: 128, records: 128, overflow: 1 }],
  ["end_ok_wrong_records", false, { ...available, end: 0, alloc: 1 }],
  ["unknown_begin", false, { ...unavailable, begin: 12345, end: -2, end_called: 0, alloc: sentinel }],
  ["begin_failure", true, { ...unavailable, begin: -2, end: -2, end_called: 0, alloc: sentinel }],
  ["begin_failure_written_output", false, { ...unavailable, begin: -2, end: -2, end_called: 0, alloc: 0 }],
  ["stop_failure_no_summary", true, { ...unavailable, end: -2, alloc: sentinel }],
  ["helper_summary_failure", true, { ...available, end: -2, alloc: sentinel }],
  ["helper_mode_failure", true, { ...available, end: -2, alloc: sentinel, mode: 1, mode_ok: 0 }],
  ["overflow_no_summary", true, { ...unavailable, end: -3, alloc: sentinel }],
  ["overflow_summary", true, { ...available, end: -3, alloc: sentinel, overflow: 1, records: 128 }],
  ["overflow_wrong_mode", false, { ...available, end: -3, alloc: sentinel, overflow: 1, records: 128, mode: 1, mode_ok: 0 }],
  ["overflow_missing_flag", false, { ...available, end: -3, alloc: sentinel, records: 128 }],
  ["overflow_missing_records", false, { ...available, end: -3, alloc: sentinel, overflow: 1 }],
  ["missing_summary_nonzero_frees", false, { ...unavailable, end: 0, alloc: 1, frees: 1 }],
  ["missing_summary_nonzero_records", false, { ...unavailable, end: 0, alloc: 1, records: 1 }],
];
for (const count of [0, 1, 2, 128]) {
  scenarios.push([`end_ok_no_summary_count_${count}`, true, { ...unavailable, end: 0, alloc: count }]);
  scenarios.push([`end_ok_summary_count_${count}`, true, { ...available, end: 0, alloc: count, records: count }]);
}
for (const summary of [unavailable, available]) {
  for (const end of [-1, -42]) {
    scenarios.push([`invalid_end_${end}_summary_${summary.summary}`, false, { ...summary, end, alloc: sentinel }]);
  }
  for (const end of [-2, -3]) {
    scenarios.push([`failed_end_${end}_written_summary_${summary.summary}`, false, { ...summary, end, alloc: 0 }]);
  }
}
let checks = 0;
const outcomes = ["case\tscenario\texpected_status\tactual_status\tnormal_status"];
for (const [index, original] of rows.entries()) {
  const fields = Object.fromEntries(original.split(",").slice(1).map((field) => {
    const separator = field.indexOf("=");
    return [field.slice(0, separator), field.slice(separator + 1)];
  }));
  const matched = Math.min(Number(fields.expected), 128);
  const perCase = [
    ...scenarios,
    ["final_summary_failure_retains_live_matches", true, {
      ...unavailable, end: Number(fields.end), alloc: Number(fields.alloc), matched,
    }],
    ["stop_failure_retains_live_matches", true, { ...unavailable, end: -2, alloc: sentinel, matched }],
  ];
  for (const [name, valid, overrides] of perCase) {
    const changed = { ...fields, result: "FAIL", matched: 0, ...overrides };
    const mutated = [...rows];
    mutated[index] = "AXOLOTY_HEAP_CAL_V1," + Object.entries(changed).map(([k, v]) => `${k}=${v}`).join(",");
    const stem = `${outputDir}/contract-${index}-${name}`;
    fs.writeFileSync(`${stem}.csv`, `${mutated.join("\n")}\n`);
    const run = (expectFailure) => spawnSync(process.execPath,
      ["Tests/embedded/validate-heap-trace-calibration.mjs", ...(expectFailure ? ["--expect-failure"] : []), `${stem}.csv`],
      { encoding: "utf8" });
    const result = run(true);
    const normal = run(false);
    fs.writeFileSync(`${stem}-validator.log`, result.stdout + result.stderr +
      "normal validation:\n" + normal.stdout + normal.stderr);
    outcomes.push(`${fields.case}\t${name}\t${valid ? 0 : 1}\t${result.status}\t${normal.status}`);
    if (result.status !== (valid ? 0 : 1) || normal.status !== 1) {
      throw new Error(`${fields.case}/${name}: expected ${valid ? "accept" : "reject"}, got ${result.status}: ${result.stderr}`);
    }
    checks += 1;
  }
}
fs.writeFileSync(`${outputDir}/contract-outcomes.tsv`, `${outcomes.join("\n")}\n`);
console.log(`heap-trace-calibration-contract-matrix: PASS (${checks} CLI cases across all ${rows.length} positions)`);
JS
{
    echo 'I (22) boot: ESP-IDF v5.4.0'
    sed 's/^/I (29) app: /' "$work/records.csv"
    echo 'SMOKE_V2,case=boot,result=PASS'
} > "$work/raw-boot.log"
node Tests/embedded/validate-heap-trace-calibration.mjs --extract-raw "$work/raw-boot.log" "$work/extracted-calibration.csv"
node Tests/embedded/validate-heap-trace-calibration.mjs "$work/extracted-calibration.csv"
cp "$work/raw-boot.log" "$work/raw-boot.before.log"
if node Tests/embedded/validate-heap-trace-calibration.mjs --extract-raw "$work/raw-boot.log" "$work/raw-boot.log" > "$work/raw-overwrite-rejection.log" 2>&1; then
    echo "run-heap-trace-calibration-test: raw extraction allowed overwriting its source" >&2
    exit 1
fi
cmp "$work/raw-boot.before.log" "$work/raw-boot.log"
ln "$work/raw-boot.log" "$work/raw-boot-hardlink.log"
if node Tests/embedded/validate-heap-trace-calibration.mjs --extract-raw "$work/raw-boot.log" "$work/raw-boot-hardlink.log" > "$work/raw-hardlink-rejection.log" 2>&1; then
    echo "run-heap-trace-calibration-test: raw extraction allowed overwriting a hardlinked source" >&2
    exit 1
fi
cmp "$work/raw-boot.before.log" "$work/raw-boot.log"
echo "heap-trace-calibration-raw-preservation: PASS"
AXOLOTY_CORPUS_MANIFEST="$repo_root/Applications/device-smoke-agent/fixtures/manifest.json" \
    node --input-type=module - <<'JS'
import { createEmbeddedSwiftSmokeValidator, makeRecord } from "./Platforms/esp32c6-idf/tools/validate-smoke.mjs";
const validator = createEmbeddedSwiftSmokeValidator(new Set(["zero"]));
validator.observe(JSON.stringify(makeRecord(0, "boot", "boot", "started", 0)));
const consumed = validator.observe("AXOLOTY_HEAP_CAL_V1,case=zero,result=PASS,path=none,begin=0,end=0,end_called=1,alloc=0,frees=0,overflow=0,mode=0,mode_ok=1,summary=1");
const result = validator.result();
if (consumed || result.passed || !result.reason.includes("missing expected test records")) {
    throw new Error("calibration record was accepted as a smoke test case");
}
console.log("heap-trace-calibration-smoke-validator: PASS");
JS

clang -std=c11 -Wall -Wextra -Werror -DAXOLOTY_HEAP_TRACE_CALIBRATION=0 \
    -I Interop -c Platforms/esp32c6-idf/main/Esp32c6AppMain.c -o "$work/app-off.o"
if nm -u "$work/app-off.o" | grep -q axoloty_heap_trace_calibration_run; then
    echo "run-heap-trace-calibration-test: default-off app entry references calibration" >&2
    exit 1
fi
clang -std=c11 -Wall -Wextra -Werror -DAXOLOTY_HEAP_TRACE_CALIBRATION=1 \
    -I Interop -I Platforms/esp32c6-idf/main \
    -c Platforms/esp32c6-idf/main/Esp32c6AppMain.c -o "$work/app-on.o"
nm -u "$work/app-on.o" | grep -q axoloty_heap_trace_calibration_run

python3 - <<'PY'
from pathlib import Path

cmake = Path("Platforms/esp32c6-idf/main/CMakeLists.txt").read_text()
build = Path("Platforms/esp32c6-idf/tools/build.sh").read_text()
app_main = Path("Platforms/esp32c6-idf/main/Esp32c6AppMain.c").read_text()
checks = {
    "CMake defaults and caches the normalized flag": "CACHE BOOL" in cmake and 'set(AXOLOTY_HEAP_TRACE_CALIBRATION OFF)' in cmake,
    "CMake rejects C-only scenario combination": "cannot be combined with" in cmake,
    "calibration C source is conditional": 'if(AXOLOTY_HEAP_TRACE_CALIBRATION)' in cmake and 'heap_trace_calibration.c' in cmake,
    "build exports the flag to IDF sub-invocations": 'export AXOLOTY_HEAP_TRACE_CALIBRATION=' in build and '-D AXOLOTY_HEAP_TRACE_CALIBRATION=' in build,
    "configuration is recorded in evidence": 'allocator-calibration-config.json' in build,
    "calibration runs before shared application entry": app_main.index("axoloty_heap_trace_calibration_run()") < app_main.index("axoloty_application_main("),
}
for name, passed in checks.items():
    if not passed:
        raise SystemExit(f"run-heap-trace-calibration-test: failed: {name}")
print("heap-trace-calibration-build-wiring: PASS")
PY
if [ -n "$artifact_dir" ]; then
    cp "$work"/*.csv "$work"/*.log "$work"/*.tsv "$work"/heap-trace-calibration-host-test "$artifact_dir/"
fi
echo "heap-trace-calibration: PASS"
