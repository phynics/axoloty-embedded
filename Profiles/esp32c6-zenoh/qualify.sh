#!/bin/sh
# Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

# Flash the esp32c6-zenoh profile, run its smoke protocol, and write a
# qualification evidence record. The board is read from AXOLOTY_DEVICE_PORT and
# is never guessed. The firmware image must already be built.
#
# The smoke protocol itself is the shared, transport-neutral one; a Zenoh
# image cannot link until the application carrier seam and the zenoh-pico
# backend land (see docs/zenoh-embedded.md). This script is the producer for
# the profile's device evidence and is unexecuted until then.
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

# Introspection for operators and the profile-isolation regression test. It is
# parsed before any device step so the probe stays hardware-free.
print_proof_root=0
case "${1:-}" in
    '') ;;
    --print-proof-root) print_proof_root=1 ;;
    *) echo "error: usage: qualify.sh [--print-proof-root]" >&2; exit 64 ;;
esac

if [ -z "${AXOLOTY_DEVICE_PORT:-}" ] && [ "$print_proof_root" -eq 0 ]; then
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

export AXOLOTY_PROFILE_DIR="$script_dir"
export AXOLOTY_APPLICATION_DIR="$repo_root/Applications/$application"
export AXOLOTY_TRANSPORT_DIR="$repo_root/Transports/$transport"
export AXOLOTY_CORPUS_MANIFEST="$AXOLOTY_APPLICATION_DIR/fixtures/manifest.json"

scratch=${AXOLOTY_SCRATCH:-"$repo_root/.axoloty"}
# One rule for the default proof workspace lives in the platform helper, and
# this qualification path shares it: the image flashed here is this profile's
# own build, never the other profile's. The platform directory is
# profile-derived, so ShellCheck cannot follow this source without -x, which
# CI does not pass; the disable is scoped to this line, and the file it names
# is covered by the profile-isolation regression test. Hand the flash tool the
# exact directories instead of letting it re-derive them.
# shellcheck disable=SC1091
# shellcheck source=../../Platforms/esp32c6-idf/tools/profile-build-env.sh
. "$repo_root/Platforms/$platform/tools/profile-build-env.sh"
default_proof_root=$(axoloty_default_proof_root "$scratch")
proof_root=${EMBEDDED_PROOF_ROOT:-"$default_proof_root"}
build_dir=${EMBEDDED_BUILD_DIR:-"$proof_root/build"}
evidence_dir=${EMBEDDED_EVIDENCE_DIR:-"$proof_root/working-evidence"}

if [ "$print_proof_root" -eq 1 ]; then
    printf 'proof_root=%s\nbuild_dir=%s\nevidence_dir=%s\n' "$proof_root" "$build_dir" "$evidence_dir"
    exit 0
fi

EMBEDDED_PROOF_ROOT="$proof_root" EMBEDDED_BUILD_DIR="$build_dir" \
    EMBEDDED_EVIDENCE_DIR="$evidence_dir" \
    "$repo_root/Platforms/$platform/tools/flash.sh"

proof="$evidence_dir/go-proof.json"
device_manifest="$evidence_dir/device-manifest.json"
evidence_out="$repo_root/docs/evidence/esp32c6-zenoh-embedded-zenoh-smoke.json"

if [ ! -f "$proof" ]; then
    echo "error: the smoke proof was not written: $proof" >&2
    exit 1
fi

EVIDENCE_OUT="$evidence_out" PROOF="$proof" DEVICE_MANIFEST="$device_manifest" \
    PROFILE_NAME="esp32c6-zenoh" CHECK_NAME="embedded-zenoh-smoke" node --input-type=module <<'JS'
import fs from "node:fs";

const proof = JSON.parse(fs.readFileSync(process.env.PROOF, "utf8"));
const device = JSON.parse(fs.readFileSync(process.env.DEVICE_MANIFEST, "utf8"));
if (proof.result !== "passed" || proof.smoke?.validation?.passed !== true) {
  throw new Error("refusing to write qualification evidence from a failed proof");
}
const counts = proof.smoke.validation.counts ?? {};
const passed = Number.isInteger(counts.passed) ? counts.passed : 0;
const unit = device.chipDescription
  ? `${device.chipDescription}${device.mac ? `, MAC ${device.mac}` : ""}`
  : device.device;
const record = {
  schemaVersion: 1,
  profile: process.env.PROFILE_NAME,
  check: process.env.CHECK_NAME,
  tier: "device",
  status: "passed",
  recordedAt: new Date().toISOString().slice(0, 10),
  device: unit,
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
