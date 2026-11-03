#!/bin/sh
# Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

# A device runner whose firmware build fails must not leave the previous run's
# results where the next reader looks for them. This check runs the sensor-node
# and largest-frame runners against a throwaway copy of the harness whose
# profile build always fails, after seeding the evidence directory with a
# passing run. It then asserts that no passing result remains and that an
# `unexecuted` record says why. No board, toolchain or network is used.
#
# Exit status: 0 passed, 1 failed, 69 required tool missing.

set -eu

command -v node >/dev/null 2>&1 || { echo "check-failed-build-results: node is required" >&2; exit 69; }
real_root=$(CDPATH='' cd -- "$(dirname -- "$0")/../.." && pwd)
work=$(mktemp -d "${TMPDIR:-/tmp}/axoloty-failed-build.XXXXXX")
listener_pid=''
cleanup() {
    if [ -n "$listener_pid" ]; then kill "$listener_pid" 2>/dev/null || true; fi
    rm -rf "$work"
}
trap cleanup EXIT INT TERM

fail() { echo "check-failed-build-results: $*" >&2; exit 1; }

# The runners refuse to start unless the broker accepts a TCP connection.
node -e '
const server = require("net").createServer(socket => socket.destroy());
server.listen(0, "127.0.0.1", () => { console.log(server.address().port); });
setInterval(() => {}, 1000);
' >"$work/port" &
listener_pid=$!
tries=0
until [ -s "$work/port" ]; do
    tries=$((tries + 1))
    [ "$tries" -lt 50 ] || fail "the stand-in broker did not start"
    sleep 0.1
done
port=$(cat "$work/port")

profile=esp32c6-sensor-node-mqtt
fake="$work/repo"
mkdir -p "$fake/Tests/embedded" "$fake/Profiles/$profile" "$fake/docs/evidence" "$work/scratch"
for name in device-common.sh generate-network-config.mjs write-unexecuted-evidence.mjs evidence-record.mjs \
    run-sensor-node.sh run-largest-frame.sh; do
    cp "$real_root/Tests/embedded/$name" "$fake/Tests/embedded/$name"
done
printf '{"core":{"revision":"0000000000000000000000000000000000000000"}}\n' >"$fake/axoloty-core.lock.json"
# The profile build fails the way a real one can, after the harness has started.
printf '#!/bin/sh\nexit 3\n' >"$fake/Profiles/$profile/build.sh"
chmod +x "$fake/Profiles/$profile/build.sh"
printf '#!/bin/sh\nexit 0\n' >"$work/host-peer"
chmod +x "$work/host-peer"

evidence="$work/scratch/device/$profile/working-evidence"

run_case() {
    runner=$1
    check=$2
    shift 2
    mkdir -p "$evidence"
    # The previous run passed, and said so.
    for name in sensor-result.json frame-result.json; do
        printf '{"passed":true}\n' >"$evidence/$name"
    done
    for name in sensor-serial.log sensor-host.log frame-serial.log swift-smoke-result.json go-proof.json device-manifest.json; do
        printf 'stale\n' >"$evidence/$name"
    done
    rm -f "$fake/docs/evidence/$profile-$check.json"

    status=0
    env AXOLOTY_DEVICE_PORT=/dev/null SENSOR_EXPECTED_MAC=00:00:00:00:00:00 SENSOR_HOST_PEER="$work/host-peer" \
        AXOLOTY_SCRATCH="$work/scratch" SENSOR_PROFILE="$profile" \
        AXOLOTY_WIFI_SSID=ssid AXOLOTY_WIFI_PASSWORD=password \
        AXOLOTY_MQTT_HOST=127.0.0.1 AXOLOTY_MQTT_PORT="$port" "$@" \
        "$fake/Tests/embedded/$runner" >"$work/$runner.log" 2>&1 || status=$?
    [ "$status" -eq 3 ] || { cat "$work/$runner.log" >&2; fail "$runner exited $status, expected the build's status 3"; }

    for name in sensor-result.json sensor-serial.log sensor-host.log frame-result.json frame-serial.log \
        swift-smoke-result.json go-proof.json device-manifest.json; do
        [ ! -e "$evidence/$name" ] || fail "$runner left $name from the previous run after a failed build"
    done
    record="$fake/docs/evidence/$profile-$check.json"
    [ -f "$record" ] || fail "$runner wrote no unexecuted record at $record"
    node -e '
const record = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
if (record.status !== "unexecuted" || record.check !== process.argv[2] || record.profile !== process.argv[3] || !/build failed \(exit 3\)/.test(record.reason)) {
  console.error(JSON.stringify(record)); process.exit(1);
}
' "$record" "$check" "$profile" || fail "$runner wrote a record that is not an unexecuted build failure"
    echo "ok   $runner leaves no result of the previous run after a failed build ($check)"
}

run_case run-sensor-node.sh sensor-node-runtime
run_case run-sensor-node.sh sensor-node-recovery SENSOR_MODE=recovery
run_case run-sensor-node.sh sensor-node-recovery-cycles SENSOR_MODE=recovery SENSOR_OUTAGE_CYCLES=2
run_case run-largest-frame.sh sensor-node-largest-frame
