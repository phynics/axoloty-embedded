#!/bin/sh
# Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

# Recovery checks for the esp32c6-zenoh profile: `wifi-recovery` and
# `router-restart`.
#
# On Zenoh the device's own `wait_for_reconnect` is a connectivity wait that also
# succeeds on a session that never failed, so only the router can say that a
# session ended and the client came back. Each check runs the host
# interoperability exchange (role B) against a pinned zenohd that it starts
# itself with debug logging, keeps the router log, and reads the verdict from
# that log. A Core host peer then has to complete a full exchange.
#
#   wifi-recovery   The firmware forces one Wi-Fi drop at boot, before
#                   application traffic. The router must see the session end,
#                   the same client return within 15 s, and no lease expiry.
#   router-restart  After the device has connected, this script stops the router
#                   and starts a new process on the same port, before the host
#                   peer attaches. The same client must open a session on the new
#                   process within 30 s, and no lease expiry may follow.
#
# A loss in the middle of an exchange is not covered by either check.
#
# Environment:
#   AXOLOTY_RECOVERY_SCENARIO  wifi-recovery (default) or router-restart.
#   AXOLOTY_DEVICE_PORT        required; the board, never guessed.
#   AXOLOTY_WIFI_SSID / AXOLOTY_WIFI_PASSWORD / AXOLOTY_ZENOH_HOST  required.
#   AXOLOTY_ZENOH_PORT         optional, default 7447. The port must be free.
#   AXOLOTY_SCRATCH            optional.
#
# Exit status: 0 passed, 1 failed or the run did not pass, 64 bad usage,
#              69 a capability is absent.

set -eu

script_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
repo_root=$(CDPATH='' cd -- "$script_dir/../.." && pwd)
device_runner_name=run-recovery-test
. "$script_dir/device-common.sh"
profile=esp32c6-zenoh

scenario=${AXOLOTY_RECOVERY_SCENARIO:-wifi-recovery}
case "$scenario" in
    wifi-recovery | router-restart) ;;
    *)
        echo "run-recovery-test: AXOLOTY_RECOVERY_SCENARIO must be wifi-recovery or router-restart" >&2
        exit 64
        ;;
esac

if [ -z "${AXOLOTY_DEVICE_PORT:-}" ]; then
    echo "run-recovery-test: AXOLOTY_DEVICE_PORT must name a board" >&2
    exit 69
fi
require_network_env "$profile"

port=${AXOLOTY_ZENOH_PORT:-7447}
scratch=${AXOLOTY_SCRATCH:-"$repo_root/.axoloty"}
root="$scratch/device/$scenario"
router_log="$root/router.log"
router_pid_file="$root/router.pid"
run_log="$root/run.log"
status_file="$root/run.status"
mkdir -p "$root"
rm -f "$router_log" "$router_pid_file" "$run_log" "$status_file"

# A router left running by an operator would not write the log this check reads.
if (require_broker_reachable "$profile") >/dev/null 2>&1; then
    echo "run-recovery-test: a router already answers on port $port; stop it, this check starts its own" >&2
    exit 69
fi

zenohd_dir=$("$script_dir/provision-zenohd.sh" "$scratch/zenohd")

start_router() {
    (
        cd "$zenohd_dir"
        RUST_LOG=zenoh_transport=debug,zenoh_link_tcp=debug,zenohd=info \
            exec ./zenohd -l "tcp/0.0.0.0:$port" --no-multicast-scouting
    ) >>"$router_log" 2>&1 &
    echo "$!" >"$router_pid_file"
}

stop_router() {
    if [ -f "$router_pid_file" ]; then
        pid=$(cat "$router_pid_file")
        if kill -0 "$pid" 2>/dev/null; then kill "$pid" 2>/dev/null || true; fi
        # Wait for the process to go, so the port is free for a restart.
        for _ in 1 2 3 4 5 6 7 8 9 10; do
            kill -0 "$pid" 2>/dev/null || break
            sleep 1
        done
        rm -f "$router_pid_file"
    fi
}

watcher_pid=''
cleanup() {
    if [ -n "$watcher_pid" ] && kill -0 "$watcher_pid" 2>/dev/null; then kill "$watcher_pid" 2>/dev/null || true; fi
    stop_router
}
trap cleanup EXIT INT TERM

start_router
deadline=$(( $(date +%s) + 20 ))
until (require_broker_reachable "$profile") >/dev/null 2>&1; do
    [ -f "$router_pid_file" ] && kill -0 "$(cat "$router_pid_file")" 2>/dev/null ||
        { echo "run-recovery-test: the router exited" >&2; cat "$router_log" >&2; exit 1; }
    [ "$(date +%s)" -lt "$deadline" ] || { echo "run-recovery-test: the router did not listen on port $port" >&2; exit 1; }
    sleep 1
done

if [ "$scenario" = router-restart ]; then
    (
        # The device has finished its boot-time Wi-Fi drop once it reports the
        # reconnect. Wait a little longer, then replace the router. The host
        # peer attaches about 40 s after the device starts, so the new process
        # is up well before it.
        watch_deadline=$(( $(date +%s) + 600 ))
        until grep -q 'axoloty:milestone:reconnected' "$run_log" 2>/dev/null; do
            [ "$(date +%s)" -lt "$watch_deadline" ] || exit 0
            sleep 1
        done
        sleep 8
        stop_router
        sleep 6
        start_router
    ) &
    watcher_pid=$!
fi

host_record="$repo_root/docs/evidence/$profile-host-interop-b.json"
{
    status=0
    AXOLOTY_NETWORK_PROFILE="$profile" EMBEDDED_HOST_ROLE=B "$script_dir/run-host-interop-test.sh" || status=$?
    echo "$status" >"$status_file"
} 2>&1 | node "$script_dir/timestamp-lines.mjs" | tee "$run_log"

[ -z "$watcher_pid" ] || wait "$watcher_pid" 2>/dev/null || true
watcher_pid=''
cleanup
[ -f "$status_file" ] || echo 1 >"$status_file"

node "$script_dir/evaluate-recovery.mjs" "$scenario" "$run_log" "$router_log" "$status_file" "$host_record" \
    "$repo_root/docs/evidence/$profile-$scenario.json"
