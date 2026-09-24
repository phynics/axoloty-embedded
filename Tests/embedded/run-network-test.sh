#!/bin/sh
# Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

# Build the esp32c6-mqtt profile with a private network configuration, flash
# it, run the network smoke protocol over serial JSON Lines, validate it, and
# write a device evidence record.
#
# The configuration header is generated into scratch from operator environment
# variables and deleted when this script exits. Credentials are never tracked,
# printed, or reused.
#
# Environment:
#   AXOLOTY_DEVICE_PORT    required; names the board, never guessed.
#   AXOLOTY_WIFI_SSID      required.
#   AXOLOTY_WIFI_PASSWORD  required.
#   AXOLOTY_MQTT_HOST      required; broker reachable from the board.
#   AXOLOTY_MQTT_PORT      optional, default 1883.
#   AXOLOTY_SCRATCH / EMBEDDED_PROOF_ROOT / EMBEDDED_BUILD_DIR /
#   EMBEDDED_EVIDENCE_DIR / AXOLOTY_PROOF_RUN_ID  passed through.
#
# Exit status: 0 passed, 1 failed, 64 bad usage, 69 a capability is absent.

set -eu

script_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
repo_root=$(CDPATH='' cd -- "$script_dir/../.." && pwd)
device_runner_name=run-network-test
. "$script_dir/device-common.sh"
profile=esp32c6-mqtt

if [ -z "${AXOLOTY_DEVICE_PORT:-}" ]; then
    echo "run-network-test: AXOLOTY_DEVICE_PORT is unset; no board is attached" >&2
    exit 69
fi
require_network_env

scratch=${AXOLOTY_SCRATCH:-"$repo_root/.axoloty"}
proof_run_id=${AXOLOTY_PROOF_RUN_ID:-network-test}
proof_root=${EMBEDDED_PROOF_ROOT:-"$scratch/device/network"}
build_dir=${EMBEDDED_BUILD_DIR:-"$proof_root/build"}
evidence_dir=${EMBEDDED_EVIDENCE_DIR:-"$proof_root/working-evidence"}
config_header="$proof_root/axoloty_network_config.h"
corpus_manifest="$repo_root/Applications/device-smoke-agent/fixtures/manifest.json"

cleanup() {
    rm -f "$config_header" \
        "$proof_root/platform/main/axoloty_network_config.h"
}
trap cleanup EXIT

node "$script_dir/generate-network-config.mjs" "$config_header"

AXOLOTY_PROOF_RUN_ID="$proof_run_id" \
    EMBEDDED_PROOF_ROOT="$proof_root" \
    EMBEDDED_BUILD_DIR="$build_dir" \
    EMBEDDED_EVIDENCE_DIR="$evidence_dir" \
    AXOLOTY_NETWORK_CONFIG_HEADER="$config_header" \
    "$repo_root/Profiles/$profile/build.sh"

AXOLOTY_CORPUS_MANIFEST="$corpus_manifest" \
    EMBEDDED_VALIDATOR="$script_dir/network-validator.mjs" \
    EMBEDDED_VALIDATOR_FACTORY=createEmbeddedNetworkValidator \
    AXOLOTY_DEVICE_PORT="$AXOLOTY_DEVICE_PORT" \
    AXOLOTY_PROOF_RUN_ID="$proof_run_id" \
    EMBEDDED_PROOF_ROOT="$proof_root" \
    EMBEDDED_BUILD_DIR="$build_dir" \
    EMBEDDED_EVIDENCE_DIR="$evidence_dir" \
    "$repo_root/Platforms/esp32c6-idf/tools/flash.sh"

PROOF="$evidence_dir/go-proof.json" \
    DEVICE_MANIFEST="$evidence_dir/device-manifest.json" \
    EVIDENCE_OUT="$repo_root/docs/evidence/$profile-network-test.json" \
    PROFILE_NAME="$profile" \
    CHECK_NAME="network-test" \
    node "$script_dir/write-device-evidence.mjs"
