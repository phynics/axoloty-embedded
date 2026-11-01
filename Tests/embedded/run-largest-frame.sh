#!/bin/sh
# Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.
# Build one production sensor profile and prove on a board that its carrier moves
# the largest frame the application declares, and drops one byte more. The
# caller supplies the expected board MAC, device, private network environment
# and scratch, as for run-sensor-node.sh. A Zenoh profile also needs
# ZENOH_C_DIR, a zenoh-c install with include/ and lib/, to build the host helper.
set -eu
umask 077
script_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
repo_root=$(CDPATH='' cd -- "$script_dir/../.." && pwd)
device_runner_name=run-largest-frame
. "$script_dir/device-common.sh"
: "${AXOLOTY_DEVICE_PORT:?device required}" "${SENSOR_EXPECTED_MAC:?expected MAC required}" "${AXOLOTY_SCRATCH:?private scratch required}"
profile=${SENSOR_PROFILE:-esp32c6-sensor-node-mqtt}
case "$profile" in
  esp32c6-sensor-node-mqtt) network=esp32c6-mqtt ;;
  esp32c6-sensor-node-zenoh) network=esp32c6-zenoh ;;
  *) echo "unsupported sensor profile" >&2; exit 64 ;;
esac
require_network_env "$network"
require_broker_reachable "$network"
root="$AXOLOTY_SCRATCH/device/$profile"
config="$root/axoloty_network_config.h"
mkdir -p "$root/working-evidence"
trap 'rm -f "$config" "$root/platform/main/axoloty_network_config.h"' EXIT
if [ "$network" = esp32c6-zenoh ]; then
  : "${ZENOH_C_DIR:?a zenoh-c install (include/ and lib/) is required to build the host helper}"
  clang -std=c11 -Wall -Wextra -Werror -o "$root/zenoh-frame-io" "$script_dir/zenoh-frame-io.c" \
    -I"$ZENOH_C_DIR/include" -L"$ZENOH_C_DIR/lib" -lzenohc -Wl,-rpath,"$ZENOH_C_DIR/lib"
  FRAME_IO_HELPER="$root/zenoh-frame-io"
  export FRAME_IO_HELPER
fi
AXOLOTY_NETWORK_PROFILE="$network" node "$script_dir/generate-network-config.mjs" "$config"
AXOLOTY_PROOF_RUN_ID="$profile" EMBEDDED_PROOF_ROOT="$root" EMBEDDED_BUILD_DIR="$root/build" \
  EMBEDDED_EVIDENCE_DIR="$root/working-evidence" AXOLOTY_NETWORK_CONFIG_HEADER="$config" \
  CMAKE_BUILD_PARALLEL_LEVEL=4 "$repo_root/Profiles/$profile/build.sh"
load_esptool
write_device_manifest "$AXOLOTY_DEVICE_PORT" "$root/working-evidence"
EXPECTED_MAC="$SENSOR_EXPECTED_MAC" node - "$root/working-evidence/device-info-raw.txt" <<'JS'
const text = require('fs').readFileSync(process.argv[2], 'utf8');
const matches = text.match(/(?:[0-9a-f]{2}:){5}[0-9a-f]{2}/ig) || [];
if (!matches.some(mac => mac.toLowerCase() === process.env.EXPECTED_MAC.toLowerCase())) {
  console.error('device MAC does not match the expected board; refusing to flash'); process.exit(1);
}
JS
timeout 900 node "$script_dir/run-largest-frame.mjs" "$AXOLOTY_DEVICE_PORT" "$root" "$esptool" "$repo_root/Profiles/$profile/profile.json"
