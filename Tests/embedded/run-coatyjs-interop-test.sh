#!/bin/sh
# Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

# Single-board interoperability check against the pinned CoatyJS reference
# agent. The device runs the default exchange scenario in one role; the
# reference agent plays the complement over the broker. Role A means the
# device advertises and answers a CoatyJS Discover; role B means the device
# discovers and answers a CoatyJS Advertise.
#
# The reference agent is not installed at test time. Mount the pinned image's
# `/agent` directory (it carries `embedded-interoperability-runner.js` and the
# `@coaty/core` 2.4.0 modules) at COATYJS_AGENT_DIR. For example:
#
#   podman create --name coatyjs-ref coatyswift-wire-coatyjs:2.4.0
#   podman cp coatyjs-ref:/agent /tmp/opencode/coatyjs-agent
#   podman rm coatyjs-ref
#
# Environment:
#   AXOLOTY_DEVICE_PORT    required; the board, never guessed.
#   EMBEDDED_COATY_ROLE    required; A or B (the device's role).
#   AXOLOTY_WIFI_SSID / AXOLOTY_WIFI_PASSWORD / AXOLOTY_MQTT_HOST  required.
#   COATYJS_AGENT_DIR      optional; default /coatyjs-agent.
#   AXOLOTY_MQTT_PORT / AXOLOTY_SCRATCH / AXOLOTY_PROOF_RUN_ID  passed through.
#
# Exit status: 0 passed, 1 failed, 64 bad usage, 69 a capability is absent.

set -eu

script_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
repo_root=$(CDPATH='' cd -- "$script_dir/../.." && pwd)
profile=esp32c6-mqtt

role=${EMBEDDED_COATY_ROLE:-}
case "$role" in
    A) scenario=embedded-requester ;;
    B) scenario=embedded-responder ;;
    *)
        echo "run-coatyjs-interop-test: EMBEDDED_COATY_ROLE must be A or B" >&2
        exit 64
        ;;
esac

if [ -z "${AXOLOTY_DEVICE_PORT:-}" ]; then
    echo "run-coatyjs-interop-test: AXOLOTY_DEVICE_PORT must name a board" >&2
    exit 69
fi
if [ -z "${AXOLOTY_WIFI_SSID:-}" ] || [ -z "${AXOLOTY_WIFI_PASSWORD:-}" ]; then
    echo "run-coatyjs-interop-test: AXOLOTY_WIFI_SSID and AXOLOTY_WIFI_PASSWORD are required; they are never guessed" >&2
    exit 69
fi
if [ -z "${AXOLOTY_MQTT_HOST:-}" ]; then
    echo "run-coatyjs-interop-test: AXOLOTY_MQTT_HOST is required; the broker is never guessed" >&2
    exit 69
fi

agent_dir=${COATYJS_AGENT_DIR:-/coatyjs-agent}
runner="$agent_dir/embedded-interoperability-runner.js"
if [ ! -f "$runner" ]; then
    echo "run-coatyjs-interop-test: no reference agent at $runner; mount the pinned CoatyJS image's /agent there" >&2
    exit 69
fi

device=$AXOLOTY_DEVICE_PORT
scratch=${AXOLOTY_SCRATCH:-"$repo_root/.axoloty"}
proof_run_id=${AXOLOTY_PROOF_RUN_ID:-coatyjs-interop}
root=${EMBEDDED_COATY_ROOT:-"$scratch/device/coatyjs-$(printf '%s' "$role" | tr '[:upper:]' '[:lower:]')"}
config="$root/axoloty_network_config.h"

cleanup() {
    rm -f "$config" "$root/platform/main/axoloty_network_config.h"
}
trap cleanup EXIT

AXOLOTY_DEVICE_ROLE="$role" node "$script_dir/generate-network-config.mjs" "$config"

AXOLOTY_DEVICE_ROLE="$role" \
AXOLOTY_PROOF_RUN_ID="$proof_run_id-$(printf '%s' "$role" | tr '[:upper:]' '[:lower:]')" \
    EMBEDDED_PROOF_ROOT="$root" \
    EMBEDDED_BUILD_DIR="$root/build" \
    EMBEDDED_EVIDENCE_DIR="$root/working-evidence" \
    AXOLOTY_NETWORK_CONFIG_HEADER="$config" \
    "$repo_root/Profiles/$profile/build.sh"

idf_root=${IDF_PATH:-/opt/esp/idf}
# shellcheck source=/dev/null
. "$idf_root/export.sh" >/dev/null 2>&1
esptool="$idf_root/components/esptool_py/esptool/esptool.py"
evidence="$root/working-evidence"
mkdir -p "$evidence"
python3 "$esptool" --port "$device" chip_id > "$evidence/device-info-raw.txt" 2>&1 || {
    echo "run-coatyjs-interop-test: could not query $device" >&2
    exit 1
}
node "$repo_root/Platforms/esp32c6-idf/tools/write-device-manifest.mjs" \
    "$device" "$evidence/device-info-raw.txt" "$evidence/device-manifest.json"

SERIAL_TOOLS="$script_dir/serial-tools.mjs" \
AGENT_VALIDATOR="$script_dir/agent-validator.mjs" \
EVIDENCE_WRITER="$script_dir/write-device-evidence.mjs" \
ESPTOOL="$esptool" \
RUNNER="$runner" \
SCENARIO="$scenario" \
ROLE="$role" \
PROFILE_NAME="$profile" \
EVIDENCE_DIR="$repo_root/docs/evidence" \
node --input-type=module - "$device" "$root" <<'JS'
import fs from "node:fs";
import path from "node:path";
import { execFileSync, spawn } from "node:child_process";

const { captureSerial, drainSerial } = await import(process.env.SERIAL_TOOLS);
const { createEmbeddedAgentValidator } = await import(process.env.AGENT_VALIDATOR);
const { deviceEvidenceRecord, writeDeviceEvidence } = await import(process.env.EVIDENCE_WRITER);

const [device, root] = process.argv.slice(2);
execFileSync("python3", [
  process.env.ESPTOOL, "--chip", "esp32c6", "--port", device,
  "--before", "default_reset", "--after", "no_reset", "write_flash", "@flash_args",
], { cwd: path.join(root, "build"), stdio: "inherit" });
await drainSerial(device);

const validator = createEmbeddedAgentValidator();
const controller = new AbortController();
const capture = captureSerial(device, 180, line => {
  console.log(`[device] ${line}`);
  validator.observe(line);
  return line.includes('"caseId":"completion"');
}, controller.signal);

// The reference agent connects first and subscribes, so the device never has
// to race it to the broker.
const runner = spawn("node", [process.env.RUNNER], {
  env: { ...process.env, BROKER_URL: `mqtt://${process.env.AXOLOTY_MQTT_HOST}:${process.env.AXOLOTY_MQTT_PORT ?? 1883}`, SCENARIO: process.env.SCENARIO },
  stdio: ["ignore", "pipe", "pipe"],
});
const runnerLines = [];
let readyResolve;
const ready = new Promise(resolve => { readyResolve = resolve; });
runner.stdout.on("data", chunk => {
  const text = chunk.toString();
  process.stdout.write(`[coatyjs] ${text}`);
  for (const line of text.trimEnd().split("\n")) { if (line) runnerLines.push(line); }
  if (text.includes('"state":"ready"')) readyResolve();
});
const errors = [];
runner.stderr.on("data", chunk => { process.stderr.write(`[coatyjs] ${chunk}`); errors.push(chunk.toString()); });
const runnerExit = new Promise((resolve, reject) => {
  runner.once("error", reject);
  runner.once("exit", (code, signal) => { if (code !== 0) controller.abort(); resolve({ code, signal }); });
});
await Promise.race([ready, new Promise((_, reject) => setTimeout(() => reject(new Error("CoatyJS runner did not become ready")), 15000))]);

execFileSync("python3", [process.env.ESPTOOL, "--chip", "esp32c6", "--port", device, "run"], { stdio: "inherit" });
const [lines, exit] = await Promise.all([capture, runnerExit]);
const validation = validator.result();
const evidenceDir = path.join(root, "working-evidence");
fs.writeFileSync(path.join(evidenceDir, `coatyjs-interop-${process.env.ROLE.toLowerCase()}-serial.log`), `${lines.join("\n")}\n`);
fs.writeFileSync(path.join(evidenceDir, `coatyjs-interop-${process.env.ROLE.toLowerCase()}-runner.jsonl`), `${runnerLines.join("\n")}\n`);
fs.writeFileSync(path.join(evidenceDir, `coatyjs-interop-${process.env.ROLE.toLowerCase()}-result.json`),
  `${JSON.stringify({ role: process.env.ROLE, scenario: process.env.SCENARIO, runnerExit: exit, errors, validation }, null, 2)}\n`);
if (exit.code !== 0 || !validation.passed) {
  throw new Error(`device ${process.env.ROLE}: runner exit ${exit.code}; ${validation.reason ?? "unknown"}`);
}

const provenance = JSON.parse(fs.readFileSync(path.join(evidenceDir, "build-provenance.json"), "utf8"));
const deviceRecord = JSON.parse(fs.readFileSync(path.join(evidenceDir, "device-manifest.json"), "utf8"));
const proof = {
  result: "passed",
  smoke: { validation },
  firmwareSha256: provenance.artifact.sha256,
  coreSha: provenance.core.sha,
};
const record = deviceEvidenceRecord(proof, deviceRecord, {
  profile: process.env.PROFILE_NAME,
  check: "coatyjs-interop",
  cases: "deterministic exchange cases against the pinned CoatyJS reference agent",
});
const output = path.join(process.env.EVIDENCE_DIR, `${process.env.PROFILE_NAME}-coatyjs-interop-${process.env.ROLE.toLowerCase()}.json`);
writeDeviceEvidence(record, output);
console.log(`device evidence written: ${output}`);
console.log("EMBEDDED COATYJS INTEROPERABILITY OK");
JS
