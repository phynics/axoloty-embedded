#!/bin/sh
# Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

# On-device wire benchmark. Builds the standalone C benchmark firmware under
# Platforms/esp32c6-idf/benchmark, flashes it, and captures the JSON Lines it
# emits over serial. It is a measurement, not a pass/fail protocol check: it
# writes the measurement files, not an evidence record.
#
# The firmware is imported from phynics/axoloty `Embedded/benchmark/` at Core
# revision 827e598f3d97. It mirrors AxolotyWire's zero-allocation JSON scanning
# in C for a representative on-device measurement.
#
# Environment:
#   AXOLOTY_DEVICE_PORT       required; the board, never guessed.
#   AXOLOTY_SCRATCH           optional; proof root, default <repo>/.axoloty.
#   EMBEDDED_BENCHMARK_DEADLINE  optional; capture deadline in seconds, 120.
#
# Exit status: 0 recorded, 1 failed, 64 bad usage, 69 a capability is absent.

set -eu

script_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
repo_root=$(CDPATH='' cd -- "$script_dir/../.." && pwd)
project_dir="$repo_root/Platforms/esp32c6-idf/benchmark"

if [ -z "${AXOLOTY_DEVICE_PORT:-}" ]; then
    echo "run-benchmark-wire-device: AXOLOTY_DEVICE_PORT must name a board" >&2
    exit 69
fi
if [ ! -e "$AXOLOTY_DEVICE_PORT" ]; then
    echo "run-benchmark-wire-device: $AXOLOTY_DEVICE_PORT does not exist" >&2
    exit 69
fi
if [ ! -d "$project_dir" ]; then
    echo "run-benchmark-wire-device: benchmark project is missing at $project_dir" >&2
    exit 69
fi

device=$AXOLOTY_DEVICE_PORT
scratch=${AXOLOTY_SCRATCH:-"$repo_root/.axoloty"}
out_dir="$scratch/benchmark/working-evidence"
build_dir="$scratch/benchmark/build"
deadline=${EMBEDDED_BENCHMARK_DEADLINE:-120}

idf_root=${IDF_PATH:-/opt/esp/idf}
if [ ! -f "$idf_root/export.sh" ]; then
    echo "run-benchmark-wire-device: ESP-IDF is not present at $idf_root" >&2
    exit 69
fi
# shellcheck source=/dev/null
. "$idf_root/export.sh" >/dev/null 2>&1
esptool="$idf_root/components/esptool_py/esptool/esptool.py"

mkdir -p "$out_dir" "$build_dir"

echo "== build =="
idf.py -C "$project_dir" -B "$build_dir" -D "SDKCONFIG=$build_dir/sdkconfig" \
    set-target esp32c6 build

echo "== flash =="
(cd "$build_dir" && python3 "$esptool" --chip esp32c6 --port "$device" \
    --before default_reset --after no_reset write_flash "@flash_args" \
    > "$out_dir/flash.log" 2>&1)
python3 "$esptool" --chip esp32c6 --port "$device" run >> "$out_dir/flash.log" 2>&1

echo "== capture (deadline ${deadline}s) =="
SERIAL_TOOLS="$script_dir/serial-tools.mjs" \
node --input-type=module - "$device" "$deadline" "$out_dir" <<'JS'
import fs from "node:fs";
import path from "node:path";

const { captureSerial, configureSerial } = await import(process.env.SERIAL_TOOLS);
const [device, deadline, out] = process.argv.slice(2);
configureSerial(device);

const lines = [];
await captureSerial(device, Number(deadline), line => {
  lines.push(line);
  console.log(line);
  return line.includes('"benchmark":"complete"');
});

const results = lines.flatMap(line => {
  const start = line.indexOf("{");
  if (start < 0) return [];
  try { return [JSON.parse(line.slice(start))]; } catch { return []; }
});
fs.writeFileSync(path.join(out, "device-benchmark.json"), `${JSON.stringify(results, null, 2)}\n`);
fs.writeFileSync(path.join(out, "device-benchmark-raw.txt"), `${lines.join("\n")}\n`);
if (!results.some(record => record.benchmark === "complete")) {
  console.error("run-benchmark-wire-device: no completion marker was captured");
  process.exit(1);
}
console.log(`records: ${results.length}`);
JS

echo "== size report =="
idf.py -C "$project_dir" -B "$build_dir" -D "SDKCONFIG=$build_dir/sdkconfig" size \
    > "$out_dir/size.txt" 2>&1 || true

echo "results: $out_dir/device-benchmark.json"
echo "raw:     $out_dir/device-benchmark-raw.txt"
echo "size:    $out_dir/size.txt"
echo "BENCHMARK WIRE DEVICE OK"
