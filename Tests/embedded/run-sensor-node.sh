#!/bin/sh
# Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.
# Build and run one production sensor profile. The caller supplies a compiled
# host peer, expected board MAC, device, private network environment and scratch.
set -eu
umask 077
script_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
repo_root=$(CDPATH='' cd -- "$script_dir/../.." && pwd)
device_runner_name=run-sensor-node
. "$script_dir/device-common.sh"
: "${AXOLOTY_DEVICE_PORT:?device required}" "${SENSOR_EXPECTED_MAC:?expected MAC required}" "${SENSOR_HOST_PEER:?compiled host peer required}" "${AXOLOTY_SCRATCH:?private scratch required}"
profile=${SENSOR_PROFILE:-esp32c6-sensor-node-mqtt}
case "$profile" in
  esp32c6-sensor-node-mqtt) network=esp32c6-mqtt ;;
  esp32c6-sensor-node-zenoh) network=esp32c6-zenoh ;;
  *) echo "unsupported sensor profile" >&2; exit 64 ;;
esac
require_network_env "$network"
require_broker_reachable "$network"
[ -x "$SENSOR_HOST_PEER" ] || { echo "host peer missing" >&2; exit 69; }
root="$AXOLOTY_SCRATCH/device/$profile"
config="$root/axoloty_network_config.h"
mkdir -p "$root/working-evidence"
trap 'rm -f "$config" "$root/platform/main/axoloty_network_config.h"' EXIT
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
timeout 1950 node "$script_dir/run-sensor-node.mjs" "$AXOLOTY_DEVICE_PORT" "$root" "$SENSOR_HOST_PEER" "$esptool" "$repo_root/Profiles/$profile/profile.json"
