#!/bin/sh
# Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

# Device gate for the C-only Zenoh carrier scenario on the esp32c6-zenoh
# profile.
#
# It is the device producer for the scenario evidence record. The scenario
# core (`Transports/zenoh-pico/main/zenoh_carrier_scenario.c`) is composed
# into the profile image by the transport manifest, so the Embedded C
# toolchain compiles the exact sources the qualification run executes; the
# host check `Tests/embedded/run-zenoh-c-only-check.sh` exercises the same
# sources against the host fake carrier.
#
# This gate selects the carrier-scenario entry point at build time. It exports
# AXOLOTY_QUALIFICATION_CARRIER_SCENARIO, which makes the platform compile the
# transport's device entry point (`zenoh_carrier_scenario_device.c`) instead of
# the shared smoke application entry point, and adds the partition and image
# metadata components the entry point reads. The shared smoke image and the
# MQTT image are unchanged: they compile with the flag off.
#
# A device run needs a board and a reachable router. Without them, this gate
# writes an `unexecuted` record with an accurate reason and stops. It never
# writes a passed device record without a real run, and it never substitutes
# the host result for a device result. A device run cannot drive the
# router-absent step, so that step is recorded `unavailable`, and the record's
# `result` names the unavailable count instead of hiding it.
#
# Environment:
#   AXOLOTY_DEVICE_PORT    required to run on a board; never guessed.
#   AXOLOTY_WIFI_SSID      required to reach the router.
#   AXOLOTY_WIFI_PASSWORD  required to reach the router.
#   AXOLOTY_ZENOH_HOST     required; the router reachable from the board.
#   AXOLOTY_ZENOH_PORT     optional, default 7447.
#   AXOLOTY_SCRATCH / EMBEDDED_PROOF_ROOT / EMBEDDED_BUILD_DIR /
#   EMBEDDED_EVIDENCE_DIR / AXOLOTY_PROOF_RUN_ID  passed through.
#
# Exit status: 0 a device run wrote a passed record, 1 a device run wrote a
#              failed record or the gate could not complete, 69 the gate could
#              not drive the check and wrote an `unexecuted` record, 64 bad
#              usage.

set -eu

script_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
repo_root=$(git -C "$script_dir" rev-parse --show-toplevel)
profile_json="$script_dir/profile.json"
core_revision=$(node -e 'process.stdout.write(JSON.parse(require("fs").readFileSync(process.argv[1], "utf8")).core.revision)' "$profile_json")
evidence_out="$repo_root/docs/evidence/esp32c6-zenoh-c-only-carrier-scenario.json"

write_unexecuted() {
    reason="$1"
    mkdir -p "$(dirname -- "$evidence_out")"
    REASON="$reason" EVIDENCE_OUT="$evidence_out" CORE_REVISION="$core_revision" node --input-type=module <<'JS'
import fs from "node:fs";
const record = {
  schemaVersion: 1,
  profile: "esp32c6-zenoh",
  check: "c-only-carrier-scenario",
  tier: "device",
  status: "unexecuted",
  recordedAt: new Date().toISOString().slice(0, 10),
  coreRevision: process.env.CORE_REVISION,
  reason: process.env.REASON,
};
const temporary = `${process.env.EVIDENCE_OUT}.tmp-${process.pid}`;
fs.writeFileSync(temporary, `${JSON.stringify(record, null, 2)}\n`, { mode: 0o644 });
fs.renameSync(temporary, process.env.EVIDENCE_OUT);
console.log(`unexecuted evidence written: ${process.env.EVIDENCE_OUT}`);
JS
}

# Qualification is a compatibility claim for the locked Core. A preview builds
# an off-lock candidate, so its run is not a qualification.
if [ -n "${AXOLOTY_PREVIEW_CORE_REVISION:-}" ]; then
    echo "error: refusing to qualify a compatibility preview; a preview is not a compatibility claim" >&2
    exit 64
fi

# No board named means no device run. The gate records that honestly and
# stops. It does not fall back to the host scenario, because a host pass is
# not a device pass.
if [ -z "${AXOLOTY_DEVICE_PORT:-}" ]; then
    write_unexecuted "no device port was named (AXOLOTY_DEVICE_PORT is unset), so no ESP32-C6 board ran the C-only carrier scenario"
    exit 69
fi

if [ ! -e "$AXOLOTY_DEVICE_PORT" ]; then
    echo "error: AXOLOTY_DEVICE_PORT names $AXOLOTY_DEVICE_PORT, which does not exist" >&2
    exit 64
fi

# A board is present, but the scenario cannot reach a router without the
# private network configuration. Record the missing capability instead of
# flashing an image that cannot connect.
if [ -z "${AXOLOTY_WIFI_SSID:-}" ] || [ -z "${AXOLOTY_WIFI_PASSWORD:-}" ]; then
    write_unexecuted "the board was named, but AXOLOTY_WIFI_SSID and AXOLOTY_WIFI_PASSWORD are required to reach the router; they are never guessed"
    exit 69
fi
if [ -z "${AXOLOTY_ZENOH_HOST:-}" ]; then
    write_unexecuted "the board was named, but AXOLOTY_ZENOH_HOST is required because the router is never guessed"
    exit 69
fi

scratch=${AXOLOTY_SCRATCH:-"$repo_root/.axoloty"}
proof_run_id=${AXOLOTY_PROOF_RUN_ID:-carrier-scenario}
proof_root=${EMBEDDED_PROOF_ROOT:-"$scratch/device/carrier-scenario"}
build_dir=${EMBEDDED_BUILD_DIR:-"$proof_root/build"}
evidence_dir=${EMBEDDED_EVIDENCE_DIR:-"$proof_root/working-evidence"}
config_header="$proof_root/axoloty_network_config.h"
corpus_manifest="$repo_root/Applications/device-smoke-agent/fixtures/manifest.json"
smoke_result="$evidence_dir/swift-smoke-result.json"

cleanup() {
    rm -f "$config_header" \
        "$proof_root/platform/main/axoloty_network_config.h"
}
trap cleanup EXIT

AXOLOTY_NETWORK_PROFILE=esp32c6-zenoh \
    node "$repo_root/Tests/embedded/generate-network-config.mjs" "$config_header"

# The qualification flag is exported, not passed with -D: ESP-IDF expands the
# transport manifest in a sub-invocation that does not inherit cache variables,
# and the flag selects the device source and its components there.
build_status=0
AXOLOTY_QUALIFICATION_CARRIER_SCENARIO=1 \
    AXOLOTY_PROOF_RUN_ID="$proof_run_id" \
    EMBEDDED_PROOF_ROOT="$proof_root" \
    EMBEDDED_BUILD_DIR="$build_dir" \
    EMBEDDED_EVIDENCE_DIR="$evidence_dir" \
    AXOLOTY_NETWORK_CONFIG_HEADER="$config_header" \
    "$script_dir/build.sh" || build_status=$?
if [ "$build_status" -ne 0 ]; then
    write_unexecuted "the board was named, but the carrier-scenario qualification image did not build (exit $build_status); see $evidence_dir/build.log"
    exit 1
fi

# Reuse the shared flash and capture path. The carrier validator accepts the
# `unavailable` steps a bare device cannot drive and refuses a missing or
# failed step. flash.sh writes the result JSON even when validation fails.
flash_status=0
AXOLOTY_CORPUS_MANIFEST="$corpus_manifest" \
    EMBEDDED_VALIDATOR="$repo_root/Tests/embedded/carrier-validator.mjs" \
    EMBEDDED_VALIDATOR_FACTORY=createEmbeddedCarrierScenarioValidator \
    AXOLOTY_DEVICE_PORT="$AXOLOTY_DEVICE_PORT" \
    AXOLOTY_PROOF_RUN_ID="$proof_run_id" \
    EMBEDDED_PROOF_ROOT="$proof_root" \
    EMBEDDED_BUILD_DIR="$build_dir" \
    EMBEDDED_EVIDENCE_DIR="$evidence_dir" \
    "$repo_root/Platforms/esp32c6-idf/tools/flash.sh" || flash_status=$?

# flash.sh labels its GO proof with the shared smoke identity. This gate writes
# its own carrier device record, so drop the mislabeled proof rather than leave
# a reviewer a record that names the wrong protocol.
rm -f "$evidence_dir/go-proof.json"

if [ ! -f "$smoke_result" ]; then
    write_unexecuted "the board was named, but the flash and capture step produced no carrier scenario stream (flash exit $flash_status)"
    exit 1
fi

# Write the device record from what the run observed. A passed record names the
# unavailable count; a failed record names why. Either way the record is only
# written from a real captured stream.
set +e
RESULT_PATH="$smoke_result" \
    DEVICE_MANIFEST="$evidence_dir/device-manifest.json" \
    PROVENANCE="$evidence_dir/build-provenance.json" \
    EVIDENCE_OUT="$evidence_out" \
    CORE_REVISION="$core_revision" \
    node --input-type=module <<'JS'
import fs from "node:fs";
import path from "node:path";

function read(file) {
  try {
    return JSON.parse(fs.readFileSync(file, "utf8"));
  } catch {
    return null;
  }
}

const result = read(process.env.RESULT_PATH);
const validation = result?.validation ?? null;
if (!validation || typeof validation.passed !== "boolean") {
  process.stderr.write("qualify-carrier-scenario: the captured validation result is missing or malformed\n");
  process.exit(1);
}
const provenance = read(process.env.PROVENANCE);
const device = read(process.env.DEVICE_MANIFEST);
const counts = validation.counts ?? {};
const passed = Number.isInteger(counts.passed) ? counts.passed : 0;
const failed = Number.isInteger(counts.failed) ? counts.failed : 0;
const unavailable = Number.isInteger(counts.unavailable) ? counts.unavailable : 0;
const unit = device?.chipDescription
  ? `${device.chipDescription}${device.mac ? `, MAC ${device.mac}` : ""}`
  : device?.device ?? "unknown ESP32-C6";
const record = {
  schemaVersion: 1,
  profile: "esp32c6-zenoh",
  check: "c-only-carrier-scenario",
  tier: "device",
  status: validation.passed ? "passed" : "failed",
  recordedAt: new Date().toISOString().slice(0, 10),
  device: unit,
  firmwareSHA256: provenance?.artifact?.sha256 ?? provenance?.firmwareSha256,
  coreRevision: provenance?.core?.sha ?? process.env.CORE_REVISION,
  protocol: "13-step C-only carrier scenario over serial JSON Lines",
  result: `${passed} passed, ${unavailable} unavailable, ${failed} failed`,
};
if (!validation.passed) {
  record.reason = typeof validation.reason === "string" && validation.reason.length > 0
    ? validation.reason
    : "the carrier scenario stream did not validate";
}
if (Array.isArray(validation.unavailableSteps) && validation.unavailableSteps.length > 0) {
  record.unavailableSteps = validation.unavailableSteps;
}
const temporary = `${process.env.EVIDENCE_OUT}.tmp-${process.pid}`;
fs.mkdirSync(path.dirname(process.env.EVIDENCE_OUT), { recursive: true });
fs.writeFileSync(temporary, `${JSON.stringify(record, null, 2)}\n`, { mode: 0o644 });
fs.renameSync(temporary, process.env.EVIDENCE_OUT);
process.stdout.write(`device evidence written: ${process.env.EVIDENCE_OUT} (${record.status})\n`);
process.exit(validation.passed ? 0 : 1);
JS
record_status=$?
set -e
exit "$record_status"
