#!/bin/sh
# Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

# Two-board last-will check. Role A configures a Deadvertise last will and
# advertises its object; the harness then resets role A abnormally, the broker
# publishes the will, and role B (the observer) must report both
# `exchange:advertise` and `exchange:deadvertise`. A graceful exit would send
# DISCONNECT and suppress the will, so the reset is deliberate.
#
# Environment:
#   AXOLOTY_DEVICE_PORT    required; board A (the will author), never guessed.
#   EMBEDDED_DEVICE_B      required; board B (the observer), never guessed.
#   AXOLOTY_WIFI_SSID / AXOLOTY_WIFI_PASSWORD / AXOLOTY_MQTT_HOST  required.
#   AXOLOTY_MQTT_PORT      optional, default 1883.
#   AXOLOTY_SCRATCH / AXOLOTY_PROOF_RUN_ID  passed through.
#
# Exit status: 0 passed, 1 failed, 64 bad usage, 69 a capability is absent.

set -eu

script_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
repo_root=$(CDPATH='' cd -- "$script_dir/../.." && pwd)
profile=esp32c6-mqtt

if [ -z "${AXOLOTY_DEVICE_PORT:-}" ] || [ -z "${EMBEDDED_DEVICE_B:-}" ]; then
    echo "run-last-will-test: AXOLOTY_DEVICE_PORT and EMBEDDED_DEVICE_B must name two boards" >&2
    exit 69
fi
if [ -z "${AXOLOTY_WIFI_SSID:-}" ] || [ -z "${AXOLOTY_WIFI_PASSWORD:-}" ]; then
    echo "run-last-will-test: AXOLOTY_WIFI_SSID and AXOLOTY_WIFI_PASSWORD are required; they are never guessed" >&2
    exit 69
fi
if [ -z "${AXOLOTY_MQTT_HOST:-}" ]; then
    echo "run-last-will-test: AXOLOTY_MQTT_HOST is required; the broker is never guessed" >&2
    exit 69
fi

device_a=$AXOLOTY_DEVICE_PORT
device_b=$EMBEDDED_DEVICE_B
scratch=${AXOLOTY_SCRATCH:-"$repo_root/.axoloty"}
proof_run_id=${AXOLOTY_PROOF_RUN_ID:-last-will-test}
root_a=${EMBEDDED_AGENT_ROOT_A:-"$scratch/device/last-will-a"}
root_b=${EMBEDDED_AGENT_ROOT_B:-"$scratch/device/last-will-b"}
config_a="$root_a/axoloty_network_config.h"
config_b="$root_b/axoloty_network_config.h"

cleanup() {
    rm -f "$config_a" "$config_b" \
        "$root_a/platform/main/axoloty_network_config.h" \
        "$root_b/platform/main/axoloty_network_config.h"
}
trap cleanup EXIT

AXOLOTY_DEVICE_ROLE=A AXOLOTY_AGENT_SCENARIO=last-will \
    node "$script_dir/generate-network-config.mjs" "$config_a"
AXOLOTY_DEVICE_ROLE=B AXOLOTY_AGENT_SCENARIO=last-will \
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
        echo "run-last-will-test: could not query $unit_device" >&2
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
OBSERVER_SETTLE_MS="${EMBEDDED_LAST_WILL_OBSERVER_SETTLE_MS:-12000}" \
ADVERTISE_SETTLE_MS="${EMBEDDED_LAST_WILL_ADVERTISE_SETTLE_MS:-24000}" \
FORCE_RESETS="${EMBEDDED_LAST_WILL_FORCE_RESETS:-3}" \
node --input-type=module - "$device_a" "$device_b" "$root_a" "$root_b" <<'JS'
import fs from "node:fs";
import path from "node:path";
import { execFileSync } from "node:child_process";

const { captureSerial, configureSerial } = await import(process.env.SERIAL_TOOLS);
const { createEmbeddedAgentValidator, expectedLastWillTests } = await import(process.env.AGENT_VALIDATOR);
const { deviceEvidenceRecord, writeDeviceEvidence } = await import(process.env.EVIDENCE_WRITER);

const sleep = milliseconds => new Promise(resolve => setTimeout(resolve, milliseconds));

// Drain whatever the previous run left in the kernel tty buffer before capture
// so the validator's first line is the observer's own boot record.
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

const run = device => execFileSync("python3",
  [process.env.ESPTOOL, "--chip", "esp32c6", "--port", device, "run"], { stdio: "inherit" });
const flash = root => execFileSync("python3", [
  process.env.ESPTOOL, "--chip", "esp32c6", "--port", root.device,
  "--before", "default_reset", "--after", "no_reset", "write_flash", "@flash_args",
], { cwd: path.join(root.root, "build"), stdio: "inherit" });

const [deviceA, deviceB, rootA, rootB] = process.argv.slice(2);
const unitA = { role: "a", device: deviceA, root: rootA };
const unitB = { role: "b", device: deviceB, root: rootB, devicePath: path.join(rootB, "working-evidence/device-manifest.json") };

flash(unitA);
flash(unitB);
for (const unit of [unitA, unitB]) await drain(unit.device);

const controller = new AbortController();
const validator = createEmbeddedAgentValidator(expectedLastWillTests);
const capture = captureSerial(unitB.device, 180, line => {
  console.log(`[b] ${line}`);
  validator.observe(line);
  return line.includes('"caseId":"completion"');
}, controller.signal);

// The observer comes up first so it is subscribed before the advertiser exists.
run(unitB.device);
await sleep(Number(process.env.OBSERVER_SETTLE_MS));

// Role A advertises; each abnormal reset below drops its connection without a
// DISCONNECT, so the broker publishes the configured last will. The observer
// only acts on that will once it already holds the advertised object, so the
// reset repeats until the observer completes rather than trusting one fixed
// moment. Every reset is harmless once the observer has finished.
let completed = false;
capture.then(() => { completed = true; });
run(unitA.device);
let forcedResetAt;
for (let attempt = 0; attempt < Number(process.env.FORCE_RESETS) && !completed; attempt += 1) {
  await sleep(Number(process.env.ADVERTISE_SETTLE_MS));
  if (completed) break;
  forcedResetAt = new Date().toISOString();
  run(unitA.device);
}

const lines = await capture;
const validation = validator.result();
const evidenceDir = path.join(unitB.root, "working-evidence");
fs.writeFileSync(path.join(evidenceDir, "last-will-b-log.txt"), `${lines.join("\n")}\n`);
fs.writeFileSync(path.join(evidenceDir, "last-will-b-result.json"),
  `${JSON.stringify({ forcedResetAt, device: unitB.device, validation }, null, 2)}\n`);

if (!validation.passed) {
  throw new Error(`device b: ${validation.reason ?? "unknown"}`);
}

const provenance = JSON.parse(fs.readFileSync(path.join(evidenceDir, "build-provenance.json"), "utf8"));
const device = JSON.parse(fs.readFileSync(unitB.devicePath, "utf8"));
const proof = {
  result: "passed",
  smoke: { validation },
  firmwareSha256: provenance.artifact.sha256,
  coreSha: provenance.core.sha,
};
const record = deviceEvidenceRecord(proof, device, {
  profile: process.env.PROFILE_NAME,
  check: "last-will",
  cases: "deterministic last-will cases over serial JSON Lines",
});
const output = path.join(process.env.EVIDENCE_DIR, `${process.env.PROFILE_NAME}-last-will-b.json`);
writeDeviceEvidence(record, output);
console.log(`device evidence written: ${output}`);
console.log("EMBEDDED LAST WILL OK");
JS
