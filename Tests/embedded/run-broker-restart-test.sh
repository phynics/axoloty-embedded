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
profile=esp32c6-mqtt
broker_port=${AXOLOTY_MQTT_PORT:-1883}
mosquitto_bin=${MOSQUITTO:-/usr/sbin/mosquitto}

if [ -z "${AXOLOTY_DEVICE_PORT:-}" ] || [ -z "${EMBEDDED_DEVICE_B:-}" ]; then
    echo "run-broker-restart-test: AXOLOTY_DEVICE_PORT and EMBEDDED_DEVICE_B must name two boards" >&2
    exit 69
fi
if [ -z "${AXOLOTY_WIFI_SSID:-}" ] || [ -z "${AXOLOTY_WIFI_PASSWORD:-}" ]; then
    echo "run-broker-restart-test: AXOLOTY_WIFI_SSID and AXOLOTY_WIFI_PASSWORD are required; they are never guessed" >&2
    exit 69
fi
if [ -z "${AXOLOTY_MQTT_HOST:-}" ]; then
    echo "run-broker-restart-test: AXOLOTY_MQTT_HOST is required; the broker is never guessed" >&2
    exit 69
fi
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

idf_root=${IDF_PATH:-/opt/esp/idf}
# shellcheck source=/dev/null
. "$idf_root/export.sh" >/dev/null 2>&1
esptool="$idf_root/components/esptool_py/esptool/esptool.py"
write_unit_manifest() {
    unit_device=$1
    unit_root=$2
    unit_evidence="$unit_root/working-evidence"
    mkdir -p "$unit_evidence"
    python3 "$esptool" --port "$unit_device" chip_id > "$unit_evidence/device-info-raw.txt" 2>&1 || {
        echo "run-broker-restart-test: could not query $unit_device" >&2
        exit 1
    }
    node "$repo_root/Platforms/esp32c6-idf/tools/write-device-manifest.mjs" \
        "$unit_device" "$unit_evidence/device-info-raw.txt" "$unit_evidence/device-manifest.json"
}

write_unit_manifest "$device_a" "$root_a"
write_unit_manifest "$device_b" "$root_b"

SERIAL_TOOLS="$script_dir/serial-tools.mjs" \
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
import { execFileSync, spawn } from "node:child_process";

const { captureSerial, configureSerial } = await import(process.env.SERIAL_TOOLS);
const { createEmbeddedAgentValidator, expectedBrokerRestartTests } = await import(process.env.AGENT_VALIDATOR);
const { deviceEvidenceRecord, writeDeviceEvidence } = await import(process.env.EVIDENCE_WRITER);

const sleep = milliseconds => new Promise(resolve => setTimeout(resolve, milliseconds));
const drain = async device => {
  configureSerial(device);
  const descriptor = fs.openSync(device, fs.constants.O_RDONLY | fs.constants.O_NONBLOCK);
  const until = Date.now() + 400;
  try {
    while (Date.now() < until) {
      const buffer = Buffer.alloc(4096);
      try {
        fs.readSync(descriptor, buffer, 0, buffer.length, null);
      } catch (error) {
        if (error.code !== "EAGAIN" && error.code !== "EWOULDBLOCK") throw error;
      }
      await new Promise(resolve => setTimeout(resolve, 25));
    }
  } finally {
    fs.closeSync(descriptor);
  }
};

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
  const flashDirectory = path.join(unit.root, "build");
  execFileSync("python3", [
    process.env.ESPTOOL, "--chip", "esp32c6", "--port", unit.device,
    "--before", "default_reset", "--after", "no_reset", "write_flash", "@flash_args",
  ], { cwd: flashDirectory, stdio: "inherit" });
}
for (const unit of units) await drain(unit.device);

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
  execFileSync("python3", [process.env.ESPTOOL, "--chip", "esp32c6", "--port", unit.device, "run"], { stdio: "inherit" });
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
    const provenance = JSON.parse(fs.readFileSync(path.join(evidenceDir, "build-provenance.json"), "utf8"));
    const device = JSON.parse(fs.readFileSync(result.devicePath, "utf8"));
    const proof = {
      result: "passed",
      smoke: { validation: result.validation },
      firmwareSha256: provenance.artifact.sha256,
      coreSha: provenance.core.sha,
    };
    const record = deviceEvidenceRecord(proof, device, {
      profile: process.env.PROFILE_NAME,
      check: "broker-restart",
      cases: "deterministic broker-restart cases over serial JSON Lines",
    });
    const output = path.join(process.env.EVIDENCE_DIR, `${process.env.PROFILE_NAME}-broker-restart-${result.role}.json`);
    writeDeviceEvidence(record, output);
    console.log(`device evidence written: ${output}`);
  }
} finally {
  await stopBroker(broker);
}
if (failures.length > 0) throw new Error(failures.join("; "));
console.log("EMBEDDED BROKER RESTART OK");
JS
