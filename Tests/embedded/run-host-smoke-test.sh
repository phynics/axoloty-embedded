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
clang -std=c11 -O2 -Wall -Wextra -Werror -I "$platform_main" -I "$transport_main" \
    -I "$repo_root/Transports/mqtt-espidf/include" -I "$repo_root/Interop" \
    -c "$transport_main/axoloty_carrier_v1.c" -o "$work/carrier-table.o"
clang -std=c11 -O2 -Wall -Wextra -Werror -I "$repo_root/Interop" \
    -c "$repo_root/Interop/axoloty_application_entry_v1.c" -o "$work/application-entry-helper.o"
clang -std=c11 -O2 -Wall -Wextra -Werror -I "$repo_root/Interop" \
    -c "$script_dir/abi-host-tables.c" -o "$work/abi-host-tables.o"

# Requirements come from the application manifest; the macro plugin expands the
# application's pure-Swift entry exactly as the firmware build does.
plugin=$(sh "$repo_root/Tools/build-embedded-macro.sh")
python3 "$repo_root/Tools/validate-composition.py" --repo-root "$repo_root" \
    --app-manifest "$repo_root/Applications/device-smoke-agent/app.json" \
    --emit-requirements "$work/ApplicationRequirements.swift"

# The real application sources plus the host seam. No production source changes
# for the host beyond the seam the application already accepts. The dedicated
# exchange build enters the same generated application entry but skips the
# unrelated corpus after exercising startDeviceSmoke.
compile_host_app() {
    output=$1
    exchange_define=$2
    swiftc -swift-version 5 -enable-experimental-feature Lifetimes \
        -D EMBEDDED_MQTT_HOST_TEST \
        $exchange_define \
        -I "$work" \
        -I "$repo_root/Applications/device-smoke-agent/include" \
        -I "$repo_root/Transports/mqtt-espidf/include" \
        -I "$repo_root/Interop" \
        -import-objc-header "$script_dir/abi-host-fixture.h" \
        -load-plugin-executable "$plugin#EmbeddedApplicationMacroImplementation" \
        "$repo_root/Sources/EmbeddedCapabilities/EmbeddedApplicationMacro.swift" \
        "$repo_root/Sources/EmbeddedCapabilities/EmbeddedApplicationDefinition.swift" \
        "$repo_root/Sources/EmbeddedCapabilities/EmbeddedApplicationEntryAdapter.swift" \
        "$repo_root/Sources/EmbeddedCapabilities/EmbeddedCapabilities.swift" \
        "$repo_root/Sources/EmbeddedCapabilities/EmbeddedRequirements.swift" \
        "$work/ApplicationRequirements.swift" \
        $(sources "$app_dir") \
        "$transport_main/EmbeddedMQTTClient.swift" \
        "$transport_main/CarrierNetworkProbe.swift" \
        "$work/GeneratedCorpus.swift" \
        "$seam_dir/HostSmokeSeam.swift" "$seam_dir/HostExchangeTrace.swift" "$seam_dir/HostSmokeMain.swift" \
        "$work"/*.o \
        -o "$output"
}

if [ "${HOST_SMOKE_EXCHANGE_ONLY:-0}" = 1 ]; then
    compile_host_app "$work/host-smoke" "-D HOST_AGENT_EXCHANGE"
    exchange_binary="$work/host-smoke"
else
    compile_host_app "$work/host-smoke" ""
    compile_host_app "$work/host-smoke-exchange" "-D HOST_AGENT_EXCHANGE"
    exchange_binary="$work/host-smoke-exchange"
fi

if [ "${HOST_SMOKE_EXCHANGE_ONLY:-0}" != 1 ]; then
    output="$work/host-smoke-output.jsonl"
    "$work/host-smoke" > "$output" 2>&1 || true
    abi_output="$work/host-smoke-abi-output.jsonl"
    HOST_SMOKE_ABI=1 "$work/host-smoke" > "$abi_output" 2>&1 || true
    configured_seam_output="$work/host-smoke-configured-seam-output.jsonl"
    HOST_SMOKE_CONFIGURED_SEAM=1 "$work/host-smoke" > "$configured_seam_output" 2>&1 || true
    configured_abi_output="$work/host-smoke-configured-abi-output.jsonl"
    HOST_SMOKE_ABI=1 HOST_SMOKE_CONFIGURED_ABI=1 "$work/host-smoke" > "$configured_abi_output" 2>&1 || true
fi

# Exercise startDeviceSmoke(capabilities) through the generated entry and the
# production DeviceSmokeCapabilityBridge with deterministic host callbacks.
# The seam baseline uses the same protocol fixture and virtual clock. A second
# last-will scenario verifies configure mapping plus bounded partial-install
# cleanup without replacing the successful exchange trace.
exchange_abi_output="$work/host-exchange-abi-output.jsonl"
HOST_SMOKE_EXCHANGE_ABI=1 HOST_SMOKE_EXCHANGE_TRACE=1 HOST_SMOKE_EXCHANGE_VIRTUAL_CLOCK=1 \
    HOST_SMOKE_EXCHANGE_ROLE=1 HOST_SMOKE_EXCHANGE_SCENARIO=0 \
    timeout --signal=TERM --kill-after=5s 30s "$exchange_binary" > "$exchange_abi_output" 2>&1 || true
exchange_seam_output="$work/host-exchange-seam-output.jsonl"
HOST_SMOKE_EXCHANGE_SEAM=1 HOST_SMOKE_EXCHANGE_TRACE=1 HOST_SMOKE_EXCHANGE_VIRTUAL_CLOCK=1 \
    HOST_SMOKE_EXCHANGE_ROLE=1 HOST_SMOKE_EXCHANGE_SCENARIO=0 \
    timeout --signal=TERM --kill-after=5s 30s "$exchange_binary" > "$exchange_seam_output" 2>&1 || true
lastwill_abi_output="$work/host-lastwill-abi-output.jsonl"
HOST_SMOKE_EXCHANGE_ABI=1 HOST_SMOKE_EXCHANGE_TRACE=1 HOST_SMOKE_EXCHANGE_VIRTUAL_CLOCK=1 \
    HOST_SMOKE_EXCHANGE_ROLE=1 HOST_SMOKE_EXCHANGE_SCENARIO=1 HOST_MQTT_FAIL_SUBSCRIBE_AT=2 \
    timeout --signal=TERM --kill-after=5s 30s "$exchange_binary" > "$lastwill_abi_output" 2>&1 || true
lastwill_seam_output="$work/host-lastwill-seam-output.jsonl"
HOST_SMOKE_EXCHANGE_SEAM=1 HOST_SMOKE_EXCHANGE_TRACE=1 HOST_SMOKE_EXCHANGE_VIRTUAL_CLOCK=1 \
    HOST_SMOKE_EXCHANGE_ROLE=1 HOST_SMOKE_EXCHANGE_SCENARIO=1 HOST_MQTT_FAIL_SUBSCRIBE_AT=2 \
    timeout --signal=TERM --kill-after=5s 30s "$exchange_binary" > "$lastwill_seam_output" 2>&1 || true

if [ "${HOST_SMOKE_EXCHANGE_ONLY:-0}" != 1 ]; then
node - "$output" "$abi_output" "$configured_seam_output" "$configured_abi_output" <<'JS'
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
const abiPath = process.argv[3];
const abiLines = fs.readFileSync(abiPath, "utf8").split(/\r?\n/);
const abiRecords = abiLines.flatMap(line => {
  const start = line.indexOf("{");
  if (start < 0) return [];
  try { return [JSON.parse(line.slice(start))]; } catch { return []; }
});
const abiCompletion = abiRecords.find(record => record.caseId === "completion");
if (!abiCompletion) {
  console.error("run-host-smoke-test: the ABI entry emitted no completion record");
  console.error(fs.readFileSync(abiPath, "utf8").split(/\r?\n/).slice(-30).join("\n"));
  process.exit(1);
}
if (abiCompletion.status !== "completed" || abiCompletion.counts?.failed !== 0) {
  console.error(`run-host-smoke-test: ABI completion status ${abiCompletion.status} counts ${JSON.stringify(abiCompletion.counts)}`);
  process.exit(1);
}
if (!abiRecords.some(record => record.host === "restart")) {
  console.error("run-host-smoke-test: the ABI entry did not reach its restart event");
  process.exit(1);
}
if (JSON.stringify(abiCompletion.counts) !== JSON.stringify(completion.counts)) {
  console.error("run-host-smoke-test: seam and ABI runs disagree");
  console.error(`seam ${JSON.stringify(completion.counts)}`);
  console.error(`abi  ${JSON.stringify(abiCompletion.counts)}`);
  process.exit(1);
}
function parse(path) {
  return fs.readFileSync(path, "utf8").split(/\r?\n/).flatMap(line => {
    const start = line.indexOf("{");
    if (start < 0) return [];
    try { return [JSON.parse(line.slice(start))]; } catch { return []; }
  });
}
const configuredSeam = parse(process.argv[4]);
const configuredABI = parse(process.argv[5]);
const configuredSeamCompletion = configuredSeam.find(record => record.caseId === "completion");
const configuredABICompletion = configuredABI.find(record => record.caseId === "completion");
const networkRecords = records => records.filter(record =>
  record.caseId?.startsWith("network:") || record.caseId === "completion" || record.host === "restart");
const deterministicRecords = records => networkRecords(records).map(({ metrics, ...record }) => record);
if (!configuredSeamCompletion || !configuredABICompletion ||
    configuredSeamCompletion.status !== "completed" || configuredABICompletion.status !== "completed" ||
    configuredSeamCompletion.counts?.failed !== 0 || configuredABICompletion.counts?.failed !== 0 ||
    JSON.stringify(deterministicRecords(configuredSeam)) !== JSON.stringify(deterministicRecords(configuredABI))) {
  console.error("run-host-smoke-test: configured seam and ABI records disagree");
  console.error(`seam ${JSON.stringify(deterministicRecords(configuredSeam))}`);
  console.error(`abi  ${JSON.stringify(deterministicRecords(configuredABI))}`);
  process.exit(1);
}
console.log(`host smoke passed: ${completion.counts.passed} checks (seam and ABI entry)`);
console.log(`configured ABI bridge passed: ${networkRecords(configuredABI).filter(record => record.caseId?.startsWith("network:")).length} network records match seam baseline`);
JS
fi

node - "$exchange_abi_output" "$exchange_seam_output" "$lastwill_abi_output" "$lastwill_seam_output" <<'JS'
import fs from "node:fs";
const paths = process.argv.slice(2);
const records = paths.map(path => fs.readFileSync(path, "utf8").split(/\r?\n/).flatMap(line => {
  const start = line.indexOf("{");
  if (start < 0) return [];
  try { return [JSON.parse(line.slice(start))]; } catch { return []; }
}));
const trace = values => values.filter(record => typeof record.exchangeCallback === "string")
  .map(record => record.exchangeCallback);
for (let index = 0; index < records.length; index += 2) {
  const abiTrace = trace(records[index]);
  const seamTrace = trace(records[index + 1]);
  if (abiTrace.length === 0 || JSON.stringify(abiTrace) !== JSON.stringify(seamTrace)) {
    console.error(`run-host-smoke-test: ABI and seam exchange traces differ for ${index === 0 ? "exchange" : "last-will cleanup"}`);
    console.error(`ABI  ${JSON.stringify(abiTrace)}`);
    console.error(`seam ${JSON.stringify(seamTrace)}`);
    process.exit(1);
  }
}
const exchange = trace(records[0]);
function assertOrder(values, expected, label) {
  let cursor = 0;
  for (const operation of expected) {
    const found = values.indexOf(operation, cursor);
    if (found < 0) {
      console.error(`run-host-smoke-test: ${label} trace has an invalid order at ${operation}`);
      process.exit(1);
    }
    cursor = found + 1;
  }
}
assertOrder(exchange, ["networkPrepare", "supportsLastWill", "configureLastWill", "connect",
                       "milestone:connected", "subscribe", "milestone:subscribed",
                       "networkReconnect", "waitForReconnect", "milestone:reconnected",
                       "publish", "milestone:advertised", "pollOneEvent",
                       "milestone:resolved", "disconnect", "networkCleanup"], "successful exchange");
for (const operation of ["supportsLastWill", "connect", "subscribe", "publish", "pollOneEvent",
                         "waitForReconnect", "disconnect", "networkPrepare", "networkReconnect",
                         "networkCleanup", "milestone:connected", "milestone:subscribed",
                         "milestone:reconnected", "milestone:advertised", "milestone:resolved"]) {
  if (!exchange.includes(operation)) {
    console.error(`run-host-smoke-test: successful application bridge trace lacks ${operation}`);
    process.exit(1);
  }
}
const lastwill = trace(records[2]);
assertOrder(lastwill, ["networkPrepare", "supportsLastWill", "configureLastWill", "connect",
                       "milestone:connected", "subscribe", "unsubscribe", "disconnect",
                       "networkCleanup"], "last-will cleanup");
for (const operation of ["supportsLastWill", "configureLastWill", "connect", "subscribe",
                         "unsubscribe", "disconnect", "networkCleanup"]) {
  if (!lastwill.includes(operation)) {
    console.error(`run-host-smoke-test: last-will cleanup trace lacks ${operation}`);
    process.exit(1);
  }
}
for (const values of [records[0], records[2]]) {
  if (!values.some(record => record.host === "restart")) {
    console.error("run-host-smoke-test: ABI-backed application exchange did not reach restart");
    process.exit(1);
  }
}
console.log(`application bridge exchange passed: ${exchange.length} ordered callbacks and milestones match seam baseline`);
console.log(`application bridge last-will cleanup passed: ${lastwill.length} ordered callbacks match seam baseline`);
JS
