#!/bin/sh
# Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

# Two-board broker-restart check. The harness manages the broker itself: it
# starts mosquitto on the configured port, runs both roles, stops the broker,
# starts it again, and requires each role to reconnect a third time and then
# complete the Advertise/Discover/Resolve/Deadvertise exchange.
#
# The boards reach the broker only on the host's allowed port, and the harness
# runs with `--network host`, so the configured port must be free before the
# run: stop any other broker that owns it. The harness starts and stops its
# own mosquitto and never touches another one.
#
# Environment:
#   AXOLOTY_DEVICE_PORT    required; board A, never guessed.
#   EMBEDDED_DEVICE_B      required; board B, never guessed.
#   AXOLOTY_WIFI_SSID / AXOLOTY_WIFI_PASSWORD / AXOLOTY_MQTT_HOST  required.
#   AXOLOTY_MQTT_PORT      optional, default 1883; must be free.
#   EMBEDDED_LAST_WILL_*   not used here.
#   AXOLOTY_SCRATCH / AXOLOTY_PROOF_RUN_ID  passed through.
#
# Exit status: 0 passed, 1 failed, 64 bad usage, 69 a capability is absent.

set -eu

script_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
repo_root=$(CDPATH='' cd -- "$script_dir/../.." && pwd)
device_runner_name=run-broker-restart-test
. "$script_dir/device-common.sh"
profile=esp32c6-mqtt
broker_port=${AXOLOTY_MQTT_PORT:-1883}
mosquitto_bin=${MOSQUITTO:-/usr/sbin/mosquitto}

if [ -z "${AXOLOTY_DEVICE_PORT:-}" ] || [ -z "${EMBEDDED_DEVICE_B:-}" ]; then
    echo "run-broker-restart-test: AXOLOTY_DEVICE_PORT and EMBEDDED_DEVICE_B must name two boards" >&2
    exit 69
fi
require_network_env
if [ ! -x "$mosquitto_bin" ]; then
    echo "run-broker-restart-test: managed broker binary not found at $mosquitto_bin" >&2
    exit 69
fi

device_a=$AXOLOTY_DEVICE_PORT
device_b=$EMBEDDED_DEVICE_B
scratch=${AXOLOTY_SCRATCH:-"$repo_root/.axoloty"}
proof_run_id=${AXOLOTY_PROOF_RUN_ID:-broker-restart-test}
root_a=${EMBEDDED_AGENT_ROOT_A:-"$scratch/device/broker-restart-a"}
root_b=${EMBEDDED_AGENT_ROOT_B:-"$scratch/device/broker-restart-b"}
config_a="$root_a/axoloty_network_config.h"
config_b="$root_b/axoloty_network_config.h"
broker_config="$scratch/device/broker-restart-mosquitto.conf"

cleanup() {
    rm -f "$config_a" "$config_b" "$broker_config" \
        "$root_a/platform/main/axoloty_network_config.h" \
        "$root_b/platform/main/axoloty_network_config.h"
}
trap cleanup EXIT

mkdir -p "$(dirname -- "$broker_config")"
printf 'listener %s 0.0.0.0\nallow_anonymous true\npersistence false\n' "$broker_port" >"$broker_config"

AXOLOTY_DEVICE_ROLE=A AXOLOTY_AGENT_SCENARIO=broker-restart AXOLOTY_MQTT_PORT="$broker_port" \
    node "$script_dir/generate-network-config.mjs" "$config_a"
AXOLOTY_DEVICE_ROLE=B AXOLOTY_AGENT_SCENARIO=broker-restart AXOLOTY_MQTT_PORT="$broker_port" \
    node "$script_dir/generate-network-config.mjs" "$config_b"

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
MOSQUITTO_BIN="$mosquitto_bin" \
MOSQUITTO_CONFIG="$broker_config" \
BROKER_SETTLE_MS="${EMBEDDED_BROKER_RESTART_SETTLE_MS:-30000}" \
BROKER_DOWN_MS="${EMBEDDED_BROKER_RESTART_DOWN_MS:-2000}" \
node --input-type=module - "$device_a" "$device_b" "$root_a" "$root_b" <<'JS'
import fs from "node:fs";
import path from "node:path";
import { spawn } from "node:child_process";

const { captureSerial, drainSerial } = await import(process.env.SERIAL_TOOLS);
const { createEmbeddedAgentValidator, expectedBrokerRestartTests } = await import(process.env.AGENT_VALIDATOR);
const { writePassedDeviceEvidence } = await import(process.env.EVIDENCE_WRITER);
const { flashFirmware, runFirmware } = await import(process.env.ESPTOOL_TOOLS);

const sleep = milliseconds => new Promise(resolve => setTimeout(resolve, milliseconds));
const startBroker = () => spawn(process.env.MOSQUITTO_BIN, ["-c", process.env.MOSQUITTO_CONFIG], { stdio: ["ignore", "ignore", "pipe"] });
const stopBroker = async broker => {
  if (!broker || broker.exitCode !== null || broker.signalCode !== null) return;
  broker.kill("SIGKILL");
  await new Promise(resolve => broker.once("exit", resolve));
};

const [deviceA, deviceB, rootA, rootB] = process.argv.slice(2);
const units = [
  { role: "a", device: deviceA, root: rootA, devicePath: path.join(rootA, "working-evidence/device-manifest.json") },
  { role: "b", device: deviceB, root: rootB, devicePath: path.join(rootB, "working-evidence/device-manifest.json") },
];

let broker = startBroker();
const brokerErrors = [];
broker.stderr.on("data", chunk => brokerErrors.push(chunk.toString()));
await sleep(1000);
if (broker.exitCode !== null) throw new Error(`managed broker failed to start; is port ${process.env.AXOLOTY_MQTT_PORT ?? 1883} free?`);

for (const unit of units) {
  flashFirmware(process.env.ESPTOOL, unit.device, unit.root);
}
for (const unit of units) await drainSerial(unit.device);

const controller = new AbortController();
const capture = unit => {
  const validator = createEmbeddedAgentValidator(expectedBrokerRestartTests);
  return captureSerial(unit.device, 180, line => {
    console.log(`[${unit.role}] ${line}`);
    validator.observe(line);
    return line.includes('"caseId":"completion"');
  }, controller.signal).then(lines => ({ ...unit, lines, validation: validator.result() }), error => {
    controller.abort();
    throw error;
  });
};
const captures = units.map(capture);
for (const unit of units) {
  runFirmware(process.env.ESPTOOL, unit.device);
}

// Both roles connect, run their forced Wi-Fi reconnect, then wait for a third
// MQTT connect that only the broker restart below can produce.
await sleep(Number(process.env.BROKER_SETTLE_MS));
const stoppedAt = new Date().toISOString();
await stopBroker(broker);
await sleep(Number(process.env.BROKER_DOWN_MS));
broker = startBroker();
broker.stderr.on("data", chunk => brokerErrors.push(chunk.toString()));

const results = await Promise.all(captures);
const failures = [];
try {
  for (const result of results) {
    const evidenceDir = path.join(result.root, "working-evidence");
    fs.writeFileSync(path.join(evidenceDir, `broker-restart-${result.role}-log.txt`), `${result.lines.join("\n")}\n`);
    fs.writeFileSync(path.join(evidenceDir, `broker-restart-${result.role}-result.json`),
      `${JSON.stringify({ stoppedAt, role: result.role, device: result.device, brokerErrors, validation: result.validation }, null, 2)}\n`);
    if (!result.validation.passed) {
      failures.push(`device ${result.role}: ${result.validation.reason ?? "unknown"}`);
      continue;
    }
    writePassedDeviceEvidence({
      evidenceDir,
      devicePath: result.devicePath,
      validation: result.validation,
      profile: process.env.PROFILE_NAME,
      check: "broker-restart",
      cases: "deterministic broker-restart cases over serial JSON Lines",
      output: path.join(process.env.EVIDENCE_DIR, `${process.env.PROFILE_NAME}-broker-restart-${result.role}.json`),
    });
  }
} finally {
  await stopBroker(broker);
}
if (failures.length > 0) throw new Error(failures.join("; "));
console.log("EMBEDDED BROKER RESTART OK");
JS
