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
# A device run needs a board. Without one, this gate writes an `unexecuted`
# record with an accurate reason and stops. It never writes a passed device
# record without a real run, and it never substitutes the host result for a
# device result.
#
# The device image that drives the scenario from `app_main` and reads device
# resources is the deferred unit; the scenario core is already in the image,
# but the production application entry point runs the shared smoke protocol,
# not the scenario. Until that entry point exists, a named board still yields
# an `unexecuted` record naming exactly what is missing.
#
# Environment:
#   AXOLOTY_DEVICE_PORT   required to run on a board; never guessed.
#   AXOLOTY_SCRATCH       optional; proof root, default <repo>/.axoloty.
#
# Exit status: 0 a device run wrote a passed or failed record, 69 the gate ran
#              but this run could not drive the check and wrote an `unexecuted`
#              record, 64 bad usage.

set -eu

script_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
repo_root=$(git -C "$script_dir" rev-parse --show-toplevel)
profile="$script_dir/profile.json"
core_revision=$(node -e 'process.stdout.write(JSON.parse(require("fs").readFileSync(process.argv[1], "utf8")).core.revision)' "$profile")
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

# A board is present. The scenario core is composed into the image, but no
# application entry point drives it yet, so the device cannot produce the
# scenario stream. Record that precisely rather than flashing an image that
# will not emit it.
write_unexecuted "the scenario core is composed into the esp32c6-zenoh image and the host check exercises it, but no firmware entry point drives the scenario from app_main yet, so the named device produced no carrier scenario stream; that entry point is the next unit"
exit 69
