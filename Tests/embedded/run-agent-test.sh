#!/bin/sh
# Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

# Two-board agent exchange: build role A and role B images with a private
# network configuration, flash one role per board, run both concurrently, and
# validate each participant's serial stream. On success, one device evidence
# record per unit is written.
#
# Environment:
#   AXOLOTY_DEVICE_PORT    required; board A, never guessed.
#   EMBEDDED_DEVICE_B      required; board B, never guessed.
#   AXOLOTY_WIFI_SSID / AXOLOTY_WIFI_PASSWORD / AXOLOTY_MQTT_HOST  required.
#   AXOLOTY_MQTT_PORT      optional, default 1883.
#   AXOLOTY_SCRATCH / EMBEDDED_PROOF_RUN_ID  passed through.
#
# Exit status: 0 passed, 1 failed, 64 bad usage, 69 a capability is absent.

set -eu

script_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
repo_root=$(CDPATH='' cd -- "$script_dir/../.." && pwd)
device_runner_name=run-agent-test
. "$script_dir/device-common.sh"
profile=esp32c6-mqtt

if [ -z "${AXOLOTY_DEVICE_PORT:-}" ] || [ -z "${EMBEDDED_DEVICE_B:-}" ]; then
    echo "run-agent-test: AXOLOTY_DEVICE_PORT and EMBEDDED_DEVICE_B must name two boards" >&2
    exit 69
fi
require_network_env

device_a=$AXOLOTY_DEVICE_PORT
device_b=$EMBEDDED_DEVICE_B
scratch=${AXOLOTY_SCRATCH:-"$repo_root/.axoloty"}
proof_run_id=${AXOLOTY_PROOF_RUN_ID:-agent-test}
root_a=${EMBEDDED_AGENT_ROOT_A:-"$scratch/device/agent-a"}
root_b=${EMBEDDED_AGENT_ROOT_B:-"$scratch/device/agent-b"}
config_a="$root_a/axoloty_network_config.h"
config_b="$root_b/axoloty_network_config.h"

cleanup() {
    rm -f "$config_a" "$config_b" \
        "$root_a/platform/main/axoloty_network_config.h" \
        "$root_b/platform/main/axoloty_network_config.h"
}
trap cleanup EXIT

AXOLOTY_DEVICE_ROLE=A node "$script_dir/generate-network-config.mjs" "$config_a"
AXOLOTY_DEVICE_ROLE=B node "$script_dir/generate-network-config.mjs" "$config_b"

AXOLOTY_DEVICE_ROLE=A \
AXOLOTY_PROOF_RUN_ID="$proof_run_id-a" \
    EMBEDDED_PROOF_ROOT="$root_a" \
    EMBEDDED_BUILD_DIR="$root_a/build" \
    EMBEDDED_EVIDENCE_DIR="$root_a/working-evidence" \
    AXOLOTY_NETWORK_CONFIG_HEADER="$config_a" \
    "$repo_root/Profiles/$profile/build.sh"

AXOLOTY_DEVICE_ROLE=B \
AXOLOTY_PROOF_RUN_ID="$proof_run_id-b" \
    EMBEDDED_PROOF_ROOT="$root_b" \
    EMBEDDED_BUILD_DIR="$root_b/build" \
    EMBEDDED_EVIDENCE_DIR="$root_b/working-evidence" \
    AXOLOTY_NETWORK_CONFIG_HEADER="$config_b" \
    "$repo_root/Profiles/$profile/build.sh"

load_esptool
write_device_manifest "$device_a" "$root_a/working-evidence"
write_device_manifest "$device_b" "$root_b/working-evidence"

SERIAL_TOOLS="$script_dir/serial-tools.mjs" \
ESPTOOL_TOOLS="$script_dir/esptool-tools.mjs" \
AGENT_VALIDATOR="$script_dir/agent-validator.mjs" \
EVIDENCE_WRITER="$script_dir/write-device-evidence.mjs" \
ESPTOOL="$esptool" \
PROFILE_NAME="$profile" \
EVIDENCE_DIR="$repo_root/docs/evidence" \
node --input-type=module - "$device_a" "$device_b" "$root_a" "$root_b" <<'JS'
import fs from "node:fs";
import path from "node:path";

const { captureSerial, drainSerial } = await import(process.env.SERIAL_TOOLS);
const { createEmbeddedAgentValidator } = await import(process.env.AGENT_VALIDATOR);
const { writePassedDeviceEvidence } = await import(process.env.EVIDENCE_WRITER);
const { flashFirmware, runFirmware } = await import(process.env.ESPTOOL_TOOLS);

const [deviceA, deviceB, rootA, rootB] = process.argv.slice(2);
const units = [
  { role: "a", device: deviceA, root: rootA, devicePath: path.join(rootA, "working-evidence/device-manifest.json") },
  { role: "b", device: deviceB, root: rootB, devicePath: path.join(rootB, "working-evidence/device-manifest.json") },
];
const controller = new AbortController();

const capture = unit => {
  const validator = createEmbeddedAgentValidator();
  return captureSerial(unit.device, 180, line => {
    console.log(`[${unit.role}] ${line}`);
    // Record the whole stream even after a failed check: the failure is
    // asserted later, and the remaining records are what a diagnosis needs.
    validator.observe(line);
    return line.includes('"caseId":"completion"');
  }, controller.signal).then(lines => {
    // Both streams are recorded before any assertion, so one device's failure
    // never hides what the other device did.
    return { ...unit, lines, validation: validator.result() };
  }, error => {
    controller.abort();
    throw error;
  });
};

for (const unit of units) {
  flashFirmware(process.env.ESPTOOL, unit.device, unit.root);
}
for (const unit of units) {
  await drainSerial(unit.device);
}
const captures = units.map(capture);
for (const unit of units) {
  runFirmware(process.env.ESPTOOL, unit.device);
}

const results = await Promise.all(captures);
const failures = [];
for (const result of results) {
  const evidenceDir = path.join(result.root, "working-evidence");
  fs.writeFileSync(path.join(evidenceDir, `agent-${result.role}-log.txt`), `${result.lines.join("\n")}\n`);
  fs.writeFileSync(path.join(evidenceDir, `agent-${result.role}-result.json`),
    `${JSON.stringify({ role: result.role, device: result.device, validation: result.validation }, null, 2)}\n`);
  if (!result.validation.passed) {
    failures.push(`device ${result.role}: ${result.validation.reason ?? "unknown"}`);
    continue;
  }
  writePassedDeviceEvidence({
    evidenceDir,
    devicePath: result.devicePath,
    validation: result.validation,
    profile: process.env.PROFILE_NAME,
    check: "agent-test",
    cases: "deterministic exchange cases over serial JSON Lines",
    output: path.join(process.env.EVIDENCE_DIR, `${process.env.PROFILE_NAME}-agent-test-${result.role}.json`),
  });
}
if (failures.length > 0) {
  throw new Error(failures.join("; "));
}
console.log("EMBEDDED AGENT EXCHANGE OK");
JS
