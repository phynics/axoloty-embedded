#!/bin/sh
# Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

# Flash the esp32c6-mqtt profile, run its smoke protocol, and write a
# qualification evidence record. The board is read from AXOLOTY_DEVICE_PORT and
# is never guessed. The firmware image must already be built.
#
# Environment: AXOLOTY_DEVICE_PORT (required), plus the build/evidence
# variables understood by the platform flash tool.

set -eu

script_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
repo_root=$(git -C "$script_dir" rev-parse --show-toplevel)
profile="$script_dir/profile.json"

read_field() {
    node -e 'const p = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8")); const v = p[process.argv[2]]; if (typeof v !== "string" || v.length === 0) { process.exit(1); } process.stdout.write(v);' \
        "$profile" "$1"
}

application=$(read_field application)
platform=$(read_field platform)
transport=$(read_field transport)

if [ -z "${AXOLOTY_DEVICE_PORT:-}" ]; then
    echo "error: AXOLOTY_DEVICE_PORT must name the board; it is never guessed" >&2
    exit 64
fi

# Qualification is a compatibility claim for the locked Core. A preview builds
# an off-lock Axoloty candidate, so its smoke run is a build result, not a
# qualification, and this guard keeps it out of docs/evidence/.
if [ -n "${AXOLOTY_PREVIEW_CORE_REVISION:-}" ]; then
    echo "error: refusing to qualify a compatibility preview; a preview is not a compatibility claim" >&2
    exit 64
fi

export AXOLOTY_APPLICATION_DIR="$repo_root/Applications/$application"
export AXOLOTY_TRANSPORT_DIR="$repo_root/Transports/$transport"
export AXOLOTY_CORPUS_MANIFEST="$AXOLOTY_APPLICATION_DIR/fixtures/manifest.json"

"$repo_root/Platforms/$platform/tools/flash.sh"

scratch=${AXOLOTY_SCRATCH:-"$repo_root/.axoloty"}
proof_root=${EMBEDDED_PROOF_ROOT:-"$scratch/firmware"}
evidence_dir=${EMBEDDED_EVIDENCE_DIR:-"$proof_root/working-evidence"}
proof="$evidence_dir/go-proof.json"
device_manifest="$evidence_dir/device-manifest.json"
evidence_out="$repo_root/docs/evidence/esp32c6-mqtt-embedded-swift-smoke-v2.json"

if [ ! -f "$proof" ]; then
    echo "error: the smoke proof was not written: $proof" >&2
    exit 1
fi

EVIDENCE_OUT="$evidence_out" PROOF="$proof" DEVICE_MANIFEST="$device_manifest" \
    PROFILE_NAME="esp32c6-mqtt" CHECK_NAME="embedded-swift-smoke-v2" node --input-type=module <<'JS'
import fs from "node:fs";

const proof = JSON.parse(fs.readFileSync(process.env.PROOF, "utf8"));
const device = JSON.parse(fs.readFileSync(process.env.DEVICE_MANIFEST, "utf8"));
if (proof.result !== "passed" || proof.smoke?.validation?.passed !== true) {
  throw new Error("refusing to write qualification evidence from a failed proof");
}
const counts = proof.smoke.validation.counts ?? {};
const passed = Number.isInteger(counts.passed) ? counts.passed : 0;
const record = {
  schemaVersion: 1,
  profile: process.env.PROFILE_NAME,
  check: process.env.CHECK_NAME,
  tier: "device",
  status: "passed",
  recordedAt: new Date().toISOString().slice(0, 10),
  device: device.device,
  firmwareSHA256: proof.firmwareSha256,
  coreRevision: proof.coreSha,
  protocol: `${passed} deterministic cases over serial JSON Lines`,
  result: `${passed}/${passed} passed`,
};
const temporary = `${process.env.EVIDENCE_OUT}.tmp-${process.pid}`;
fs.writeFileSync(temporary, `${JSON.stringify(record, null, 2)}\n`, { mode: 0o644 });
fs.renameSync(temporary, process.env.EVIDENCE_OUT);
console.log(`qualification evidence written: ${process.env.EVIDENCE_OUT}`);
JS
