#!/bin/sh
# Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

# Qualify the esp32c6-sensor-node-mqtt profile: build it with a private network
# header, flash it, observe one sensor session from a compiled host peer, and
# write docs/evidence/esp32c6-sensor-node-mqtt-sensor-node-runtime.json. This
# profile has no smoke corpus and does not use flash.sh.
#
# Environment: AXOLOTY_DEVICE_PORT, SENSOR_EXPECTED_MAC, SENSOR_HOST_PEER (a
# compiled host peer), the Wi-Fi and carrier variables run-sensor-node.sh
# documents, and optionally AXOLOTY_SCRATCH. Exit 69 when a required capability
# is absent, which a verification tier reports as SKIP, never as a pass.

set -eu

script_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
repo_root=$(git -C "$script_dir" rev-parse --show-toplevel)

if [ -z "${AXOLOTY_DEVICE_PORT:-}" ]; then
    echo "error: AXOLOTY_DEVICE_PORT must name the board; it is never guessed" >&2
    exit 64
fi
if [ -n "${AXOLOTY_PREVIEW_CORE_REVISION:-}" ]; then
    echo "error: refusing to qualify a compatibility preview; a preview is not a compatibility claim" >&2
    exit 64
fi
if [ -z "${SENSOR_HOST_PEER:-}" ] || [ ! -x "$SENSOR_HOST_PEER" ]; then
    echo "qualify: SENSOR_HOST_PEER must name a compiled host peer; this run has none" >&2
    exit 69
fi

SENSOR_PROFILE=esp32c6-sensor-node-mqtt
AXOLOTY_SCRATCH=${AXOLOTY_SCRATCH:-"$repo_root/.axoloty"}
export SENSOR_PROFILE AXOLOTY_SCRATCH
exec "$repo_root/Tests/embedded/run-sensor-node.sh"
