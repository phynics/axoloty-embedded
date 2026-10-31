#!/bin/sh
# Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

# Wi-Fi recovery check for the esp32c6-zenoh profile.
#
# The firmware forces a Wi-Fi drop once at boot. On Zenoh, the device's own
# `wait_for_reconnect` is a connectivity wait that also succeeds on a session
# that never failed, so only the router can say that a session ended and the
# client came back. This check runs the host interoperability exchange (role B)
# against a pinned zenohd that it starts itself with debug logging, keeps the
# router log, and reads the verdict from that log: the router saw the session
# end, the same client returned within 15 s, no lease expiry followed, and the
# Core host peer then completed a full exchange.
#
# It covers the drop the firmware forces at boot, before application traffic. A
# loss in the middle of an exchange is not covered.
#
# Environment:
#   AXOLOTY_DEVICE_PORT    required; the board, never guessed.
#   AXOLOTY_WIFI_SSID / AXOLOTY_WIFI_PASSWORD / AXOLOTY_ZENOH_HOST  required.
#   AXOLOTY_ZENOH_PORT     optional, default 7447. The port must be free.
#   AXOLOTY_SCRATCH        optional.
#
# Exit status: 0 passed, 1 failed or the run did not pass, 64 bad usage,
#              69 a capability is absent.

set -eu

script_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
repo_root=$(CDPATH='' cd -- "$script_dir/../.." && pwd)
device_runner_name=run-wifi-recovery-test
. "$script_dir/device-common.sh"
profile=esp32c6-zenoh

if [ -z "${AXOLOTY_DEVICE_PORT:-}" ]; then
    echo "run-wifi-recovery-test: AXOLOTY_DEVICE_PORT must name a board" >&2
    exit 69
fi
require_network_env "$profile"

port=${AXOLOTY_ZENOH_PORT:-7447}
scratch=${AXOLOTY_SCRATCH:-"$repo_root/.axoloty"}
root="$scratch/device/wifi-recovery"
router_log="$root/router.log"
run_log="$root/run.log"
status_file="$root/run.status"
mkdir -p "$root"
rm -f "$router_log" "$run_log" "$status_file"

# A router left running by an operator would not write the log this check reads.
if (require_broker_reachable "$profile") >/dev/null 2>&1; then
    echo "run-wifi-recovery-test: a router already answers on port $port; stop it, this check starts its own" >&2
    exit 69
fi

zenohd_dir=$("$script_dir/provision-zenohd.sh" "$scratch/zenohd")
router_pid=''
cleanup() {
    if [ -n "$router_pid" ] && kill -0 "$router_pid" 2>/dev/null; then kill "$router_pid" 2>/dev/null || true; fi
}
trap cleanup EXIT INT TERM

(
    cd "$zenohd_dir"
    RUST_LOG=zenoh_transport=debug,zenoh_link_tcp=debug,zenohd=info \
        exec ./zenohd -l "tcp/0.0.0.0:$port" --no-multicast-scouting
) >"$router_log" 2>&1 &
router_pid=$!

deadline=$(( $(date +%s) + 20 ))
until (require_broker_reachable "$profile") >/dev/null 2>&1; do
    kill -0 "$router_pid" 2>/dev/null || { echo "run-wifi-recovery-test: the router exited" >&2; cat "$router_log" >&2; exit 1; }
    [ "$(date +%s)" -lt "$deadline" ] || { echo "run-wifi-recovery-test: the router did not listen on port $port" >&2; exit 1; }
    sleep 1
done

host_record="$repo_root/docs/evidence/$profile-host-interop-b.json"
{
    status=0
    AXOLOTY_NETWORK_PROFILE="$profile" EMBEDDED_HOST_ROLE=B "$script_dir/run-host-interop-test.sh" || status=$?
    echo "$status" >"$status_file"
} 2>&1 | node "$script_dir/timestamp-lines.mjs" | tee "$run_log"

cleanup
router_pid=''
[ -f "$status_file" ] || echo 1 >"$status_file"

node "$script_dir/evaluate-wifi-recovery.mjs" "$run_log" "$router_log" "$status_file" "$host_record" \
    "$repo_root/docs/evidence/$profile-wifi-recovery.json"
