#!/bin/sh
# Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

# Single-board interoperability check against the Axoloty host runtime. The
# device runs the default exchange scenario in one role; the host peer plays
# the complement over the broker. It is the migrated `embedded-host-test`.
#
# Role A means the device advertises and answers a host Discover; role B means
# the device discovers and answers a host Advertise.
#
# The host peer is built by SwiftPM from the pinned Core revision in
# axoloty-core.lock.json. Nothing is read from a sibling Core checkout or from
# Core's tests, and this repository vendors no Core source.
#
# Environment:
#   AXOLOTY_DEVICE_PORT    required; the board, never guessed.
#   EMBEDDED_HOST_ROLE     optional; A (default) or B.
#   AXOLOTY_WIFI_SSID / AXOLOTY_WIFI_PASSWORD / AXOLOTY_MQTT_HOST  required.
#   AXOLOTY_MQTT_PORT / AXOLOTY_SCRATCH / AXOLOTY_PROOF_RUN_ID  passed through.
#   EMBEDDED_HOST_BUILD_DEADLINE  optional; host-ready wait in ms, 900000.
#   EMBEDDED_HOST_DEADLINE        optional; serial capture seconds, 240.
#
# Exit status: 0 passed, 1 failed, 64 bad usage, 69 a capability is absent.

set -eu

script_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
repo_root=$(CDPATH='' cd -- "$script_dir/../.." && pwd)
profile=esp32c6-mqtt

role=${EMBEDDED_HOST_ROLE:-A}
case "$role" in
    A) direction=host-requester ;;
    B) direction=host-responder ;;
    *)
        echo "run-host-interop-test: EMBEDDED_HOST_ROLE must be A or B" >&2
        exit 64
        ;;
esac

if [ -z "${AXOLOTY_DEVICE_PORT:-}" ]; then
    echo "run-host-interop-test: AXOLOTY_DEVICE_PORT must name a board" >&2
    exit 69
fi
if [ -z "${AXOLOTY_WIFI_SSID:-}" ] || [ -z "${AXOLOTY_WIFI_PASSWORD:-}" ]; then
    echo "run-host-interop-test: AXOLOTY_WIFI_SSID and AXOLOTY_WIFI_PASSWORD are required; they are never guessed" >&2
    exit 69
fi
if [ -z "${AXOLOTY_MQTT_HOST:-}" ]; then
    echo "run-host-interop-test: AXOLOTY_MQTT_HOST is required; the broker is never guessed" >&2
    exit 69
fi
if ! command -v swift >/dev/null 2>&1; then
    echo "run-host-interop-test: swift is required to build the host peer" >&2
    exit 69
fi
[ -f "$repo_root/Package.swift" ] || {
    echo "run-host-interop-test: the host peer manifest is missing at $repo_root/Package.swift" >&2
    exit 69
}

device=$AXOLOTY_DEVICE_PORT
scratch=${AXOLOTY_SCRATCH:-"$repo_root/.axoloty"}
proof_run_id=${AXOLOTY_PROOF_RUN_ID:-host-interop}
root=${EMBEDDED_AGENT_ROOT:-"$scratch/device/host-interop-$(printf '%s' "$role" | tr '[:upper:]' '[:lower:]')"}
config="$root/axoloty_network_config.h"
swift_build="$scratch/host-peer-swift-build"
ready="$root/host-$role.ready"

cleanup() {
    rm -f "$config" "$root/platform/main/axoloty_network_config.h" "$ready"
}
trap cleanup EXIT
rm -f "$ready"

AXOLOTY_DEVICE_ROLE="$role" node "$script_dir/generate-network-config.mjs" "$config"

AXOLOTY_DEVICE_ROLE="$role" \
AXOLOTY_PROOF_RUN_ID="$proof_run_id-$(printf '%s' "$role" | tr '[:upper:]' '[:lower:]')" \
    EMBEDDED_PROOF_ROOT="$root" \
    EMBEDDED_BUILD_DIR="$root/build" \
    EMBEDDED_EVIDENCE_DIR="$root/working-evidence" \
    AXOLOTY_NETWORK_CONFIG_HEADER="$config" \
    "$repo_root/Profiles/$profile/build.sh"

echo "== build host peer =="
swift build --package-path "$repo_root" --scratch-path "$swift_build" -c debug
host_peer="$swift_build/debug/EmbeddedHostPeer"
[ -x "$host_peer" ] || {
    echo "run-host-interop-test: host peer binary was not produced at $host_peer" >&2
    exit 1
}

idf_root=${IDF_PATH:-/opt/esp/idf}
# shellcheck source=/dev/null
. "$idf_root/export.sh" >/dev/null 2>&1
esptool="$idf_root/components/esptool_py/esptool/esptool.py"
evidence="$root/working-evidence"
mkdir -p "$evidence"
python3 "$esptool" --port "$device" chip_id > "$evidence/device-info-raw.txt" 2>&1 || {
    echo "run-host-interop-test: could not query $device" >&2
    exit 1
}
node "$repo_root/Platforms/esp32c6-idf/tools/write-device-manifest.mjs" \
    "$device" "$evidence/device-info-raw.txt" "$evidence/device-manifest.json"

SERIAL_TOOLS="$script_dir/serial-tools.mjs" \
AGENT_VALIDATOR="$script_dir/agent-validator.mjs" \
EVIDENCE_WRITER="$script_dir/write-device-evidence.mjs" \
ESPTOOL="$esptool" \
HOST_PEER="$host_peer" \
DIRECTION="$direction" \
ROLE="$role" \
READY_FILE="$ready" \
PROFILE_NAME="$profile" \
EVIDENCE_DIR="$repo_root/docs/evidence" \
BUILD_DEADLINE_MS="${EMBEDDED_HOST_BUILD_DEADLINE:-900000}" \
SERIAL_DEADLINE="${EMBEDDED_HOST_DEADLINE:-240}" \
DEVICE_SETTLE_MS="${EMBEDDED_HOST_DEVICE_SETTLE_MS:-40000}" \
node --input-type=module - "$device" "$root" <<'JS'
import fs from "node:fs";
import path from "node:path";
import { execFileSync, spawn } from "node:child_process";

const { captureSerial, configureSerial } = await import(process.env.SERIAL_TOOLS);
const { createEmbeddedAgentValidator } = await import(process.env.AGENT_VALIDATOR);
const { deviceEvidenceRecord, writeDeviceEvidence } = await import(process.env.EVIDENCE_WRITER);

const drain = async device => {
  configureSerial(device);
  const descriptor = fs.openSync(device, fs.constants.O_RDONLY | fs.constants.O_NONBLOCK);
  const until = Date.now() + 400;
  try {
    while (Date.now() < until) {
      const buffer = Buffer.alloc(4096);
      try { fs.readSync(descriptor, buffer, 0, buffer.length, null); }
      catch (error) { if (error.code !== "EAGAIN" && error.code !== "EWOULDBLOCK") throw error; }
      await new Promise(resolve => setTimeout(resolve, 25));
    }
  } finally { fs.closeSync(descriptor); }
};

const [device, root] = process.argv.slice(2);
execFileSync("python3", [
  process.env.ESPTOOL, "--chip", "esp32c6", "--port", device,
  "--before", "default_reset", "--after", "no_reset", "write_flash", "@flash_args",
], { cwd: path.join(root, "build"), stdio: "inherit" });
await drain(device);

const validator = createEmbeddedAgentValidator();
const controller = new AbortController();

const capture = captureSerial(device, Number(process.env.SERIAL_DEADLINE), line => {
  console.log(`[${process.env.ROLE}] ${line}`);
  validator.observe(line);
  return line.includes('"caseId":"completion"');
}, controller.signal);

// The device starts first so it is subscribed before the host peer acts. A
// host-requester waits for the device's repeated Advertise; a host-responder
// advertises once, because the runtime rejects a second identical Advertise as
// a duplicate, so the device must already be listening when it does.
execFileSync("python3", [process.env.ESPTOOL, "--chip", "esp32c6", "--port", device, "run"], { stdio: "inherit" });
await new Promise(resolve => setTimeout(resolve, Number(process.env.DEVICE_SETTLE_MS)));

let peer = null;
const peerOutput = [];
try {
  peer = spawn(process.env.HOST_PEER, [], {
    env: {
      ...process.env,
      WIRE_EMBEDDED_HOST_DIRECTION: process.env.DIRECTION,
      WIRE_BROKER_HOST: process.env.AXOLOTY_MQTT_HOST,
      WIRE_BROKER_PORT: process.env.AXOLOTY_MQTT_PORT ?? "1883",
      WIRE_READY_FILE: process.env.READY_FILE,
    },
    stdio: ["ignore", "pipe", "pipe"],
  });
  for (const stream of [peer.stdout, peer.stderr]) {
    stream.on("data", chunk => { process.stdout.write(`[host] ${chunk}`); peerOutput.push(chunk.toString()); });
  }
  const peerExit = new Promise((resolve, reject) => {
    peer.once("error", reject);
    peer.once("exit", (code, signal) => {
      if (code !== 0) controller.abort();
      resolve({ code, signal });
    });
  });

  const readyDeadline = Date.now() + Number(process.env.BUILD_DEADLINE_MS);
  while (!fs.existsSync(process.env.READY_FILE)) {
    if (peer.exitCode !== null) throw new Error(`host peer exited before readiness (${peer.exitCode})`);
    if (Date.now() >= readyDeadline) throw new Error("host peer did not become ready");
    await new Promise(resolve => setTimeout(resolve, 100));
  }

  const [lines, exit] = await Promise.all([capture, peerExit]);
  const validation = validator.result();
  const evidenceDir = path.join(root, "working-evidence");
  fs.writeFileSync(path.join(evidenceDir, `host-interop-${process.env.ROLE.toLowerCase()}-serial.log`), `${lines.join("\n")}\n`);
  fs.writeFileSync(path.join(evidenceDir, `host-interop-${process.env.ROLE.toLowerCase()}-host.log`), peerOutput.join(""));
  fs.writeFileSync(path.join(evidenceDir, `host-interop-${process.env.ROLE.toLowerCase()}-result.json`),
    `${JSON.stringify({ role: process.env.ROLE, direction: process.env.DIRECTION, hostExit: exit, validation }, null, 2)}\n`);
  if (exit.code !== 0 || !validation.passed) {
    throw new Error(`device ${process.env.ROLE}: host exit ${exit.code}; ${validation.reason ?? "unknown"}`);
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
    check: "host-interop",
    cases: "deterministic exchange cases against the Axoloty host runtime",
  });
  const output = path.join(process.env.EVIDENCE_DIR, `${process.env.PROFILE_NAME}-host-interop-${process.env.ROLE.toLowerCase()}.json`);
  writeDeviceEvidence(record, output);
  console.log(`device evidence written: ${output}`);
  console.log("EMBEDDED HOST INTEROPERABILITY OK");
} finally {
  controller.abort();
  if (peer && peer.exitCode === null) peer.kill("SIGTERM");
}
JS
