#!/bin/sh
# Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

# Host smoke check. Compiles the real device-smoke application plus a host
# implementation of `DeviceSmokeSeam` and runs it on the development host: no
# board, no ESP-IDF, no broker.
#
# The application sources import the portable Core packages, so this check
# consumes Core through `Tools/prepare-core.sh` and the report it writes. It
# reads no Core build tree and no Core tests.
#
# The application ends by requesting a restart; the host seam records that and
# exits, so the run is judged from the emitted JSON Lines, not the exit code.
#
# Exit status: 0 passed, 1 failed, 69 a required tool or the Core report is
# absent.

set -eu

script_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
repo_root=$(CDPATH='' cd -- "$script_dir/../.." && pwd)
app_dir="$repo_root/Applications/device-smoke-agent/main"
fixtures_dir="$repo_root/Applications/device-smoke-agent/fixtures"
seam_dir="$repo_root/Tests/host-seam"

for tool in swiftc clang node realpath; do
    command -v "$tool" >/dev/null 2>&1 || {
        echo "run-host-smoke-test: $tool is required" >&2
        exit 69
    }
done

scratch=${AXOLOTY_SCRATCH:-"$repo_root/.axoloty"}
report="$scratch/core-preparation.json"
if [ ! -f "$report" ]; then
    if ! "$repo_root/Tools/prepare-core.sh" >/dev/null 2>&1; then
        echo "run-host-smoke-test: Core preparation did not produce $report" >&2
        exit 69
    fi
fi
[ -f "$report" ] || {
    echo "run-host-smoke-test: Core preparation report is missing: $report" >&2
    exit 69
}

json_field() {
    node -e 'const fs=require("fs");const v=JSON.parse(fs.readFileSync(process.argv[1],"utf8"));let c=v;for(const k of process.argv[2].split("."))c=c[k];process.stdout.write(String(c));' "$report" "$1"
}

json_core_dir=$(json_field jsonCore.sourceDir)
macro_tool=$(json_field staticRuntimeMacro.executable)
macro_plugin=$(json_field staticRuntimeMacro.pluginModule)
wire_dir=$(json_field portablePackages.0.sourcePath)
object_model_dir=$(json_field portablePackages.1.sourcePath)
protocol_dir=$(json_field portablePackages.2.sourcePath)
coaty_models_dir=$(json_field portablePackages.3.sourcePath)
static_runtime_dir=$(json_field portablePackages.4.sourcePath)

work=${HOST_SMOKE_WORK:-$(mktemp -d)}
trap '[ -n "${HOST_SMOKE_WORK:-}" ] || rm -rf "$work"' EXIT

sources() {
    for source in "$1"/*.swift; do
        [ -f "$source" ] && printf '%s\n' "$source"
    done
}

# The portable packages are compiled in place from the prepared Core checkout,
# as the host, not as Embedded Swift.
swiftc -swift-version 6 -enable-experimental-feature Lifetimes -package-name IkigaJSON -parse-as-library -wmo \
    -module-name _JSONCore \
    -emit-module -emit-module-path "$work/_JSONCore.swiftmodule" \
    -c $(sources "$json_core_dir") $(sources "$json_core_dir/Parser") $(sources "$json_core_dir/SIMD") \
    -o "$work/_JSONCore.o"

compile_module() {
    module_name=$1
    module_dir=$2
    if [ "$module_name" = AxolotyStaticRuntime ]; then
        swiftc -swift-version 6 -enable-experimental-feature Lifetimes -parse-as-library -wmo \
            -module-name "$module_name" \
            -load-plugin-executable "$macro_tool#$macro_plugin" \
            -I "$work" \
            -emit-module -emit-module-path "$work/$module_name.swiftmodule" \
            -c $(sources "$module_dir") -o "$work/$module_name.o"
    else
        swiftc -swift-version 6 -enable-experimental-feature Lifetimes -parse-as-library -wmo \
            -module-name "$module_name" \
            -I "$work" \
            -emit-module -emit-module-path "$work/$module_name.swiftmodule" \
            -c $(sources "$module_dir") -o "$work/$module_name.o"
    fi
}

compile_module AxolotyWire "$wire_dir"
compile_module AxolotyObjectModel "$object_model_dir"
compile_module AxolotyProtocol "$protocol_dir"
compile_module AxolotyCoatyModels "$coaty_models_dir"
compile_module AxolotyStaticRuntime "$static_runtime_dir"

# The generated corpus and the carrier probe the application calls into.
node "$fixtures_dir/generate-embedded-corpus.mjs" \
    "$fixtures_dir/manifest.json" "$work/GeneratedCorpus.swift"

# The transport's host HAL, the same one the MQTT host seam check uses.
platform_main="$repo_root/Platforms/esp32c6-idf/main"
transport_main="$repo_root/Transports/mqtt-espidf/main"
clang -std=c11 -O2 -Wall -Wextra -Werror -I "$platform_main" -I "$transport_main" \
    -I "$repo_root/Transports/mqtt-espidf/include" -I "$repo_root/Interop" \
    -c "$script_dir/mqtt-host-hal.c" -o "$work/hal.o"
clang -std=c11 -O2 -Wall -Wextra -Werror -I "$platform_main" -I "$transport_main" \
    -c "$transport_main/mqtt_event_validation.c" -o "$work/validation.o"
clang -std=c11 -O2 -Wall -Wextra -Werror -I "$platform_main" -I "$transport_main" \
    -c "$platform_main/runtime_identity.c" -o "$work/identity.o"

# The real application sources plus the host seam. No production source changes
# for the host beyond the seam the application already accepts.
swiftc -swift-version 5 -enable-experimental-feature Lifetimes \
    -D EMBEDDED_MQTT_HOST_TEST \
    -I "$work" \
    -I "$repo_root/Applications/device-smoke-agent/include" \
    -I "$repo_root/Transports/mqtt-espidf/include" \
    -I "$repo_root/Interop" \
    $(sources "$app_dir") \
    "$transport_main/EmbeddedMQTTClient.swift" \
    "$transport_main/CarrierNetworkProbe.swift" \
    "$work/GeneratedCorpus.swift" \
    "$seam_dir/HostSmokeSeam.swift" "$seam_dir/HostSmokeMain.swift" \
    "$work"/*.o \
    -o "$work/host-smoke"

output="$work/host-smoke-output.jsonl"
"$work/host-smoke" > "$output" 2>&1 || true

node - "$output" <<'JS'
import fs from "node:fs";
const [path] = process.argv.slice(2);
const lines = fs.readFileSync(path, "utf8").split(/\r?\n/);
const records = lines.flatMap(line => {
  const start = line.indexOf("{");
  if (start < 0) return [];
  try { return [JSON.parse(line.slice(start))]; } catch { return []; }
});
const completion = records.find(record => record.caseId === "completion");
const restarted = records.some(record => record.host === "restart");
if (!completion) {
  console.error("run-host-smoke-test: no completion record was emitted");
  console.error(fs.readFileSync(path, "utf8").split(/\r?\n/).slice(-30).join("\n"));
  process.exit(1);
}
if (completion.status !== "completed" || completion.counts?.failed !== 0) {
  console.error(`run-host-smoke-test: completion status ${completion.status} counts ${JSON.stringify(completion.counts)}`);
  process.exit(1);
}
if (!restarted) {
  console.error("run-host-smoke-test: the application did not reach its restart event");
  process.exit(1);
}
console.log(`host smoke passed: ${completion.counts.passed} checks`);
JS
