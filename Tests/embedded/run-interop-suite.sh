#!/bin/sh
# Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

# Runs the broker-sharing interoperability harnesses in sequence and reports a
# combined result. Each harness builds, flashes, and writes its own evidence.
#
# Broker-restart is deliberately not part of this suite. It needs port 1883
# free and manages its own mosquitto, so it runs as a separate step:
#
#   podman run --rm --network host ... Tests/embedded/run-broker-restart-test.sh
#
# The device must start before the host-responder peer and the CoatyJS
# responder in their harnesses; this suite does not change their internals.
#
# Environment:
#   AXOLOTY_DEVICE_PORT    required; board A, never guessed.
#   EMBEDDED_DEVICE_B      required; board B, never guessed.
#   AXOLOTY_WIFI_SSID / AXOLOTY_WIFI_PASSWORD / AXOLOTY_MQTT_HOST  required.
#   AXOLOTY_SCRATCH        optional; proof root, default <repo>/.axoloty.
#   AXOLOTY_PROOF_RUN_ID   optional; prefixes every harness run id.
#   SUITE_PLAN_ONLY=1      print the ordered plan and exit without hardware.
#   SUITE_ONLY=a,b         run only the named steps (comma-separated).
#
# Exit status: 0 all selected steps passed, 1 one or more failed, 64 bad usage,
# 69 a capability is absent.

set -eu

script_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
repo_root=$(CDPATH='' cd -- "$script_dir/../.." && pwd)

# Single-board steps run first. The two-board harnesses leave both boards
# running their images, and a looping board would contaminate a later
# single-board run; the two-board harnesses reflash both boards, so they are
# safe to run last in any order.
steps="coatyjs-a coatyjs-b host-a host-b agent-exchange last-will"

if [ -n "${SUITE_PLAN_ONLY:-}" ]; then
    echo "interop suite plan:"
    for step in $steps; do echo "  - $step"; done
    echo "  (broker-restart runs separately; it manages its own broker)"
    exit 0
fi

if [ -z "${AXOLOTY_DEVICE_PORT:-}" ] || [ -z "${EMBEDDED_DEVICE_B:-}" ]; then
    echo "run-interop-suite: AXOLOTY_DEVICE_PORT and EMBEDDED_DEVICE_B must name two boards" >&2
    exit 69
fi
if [ -z "${AXOLOTY_WIFI_SSID:-}" ] || [ -z "${AXOLOTY_WIFI_PASSWORD:-}" ]; then
    echo "run-interop-suite: AXOLOTY_WIFI_SSID and AXOLOTY_WIFI_PASSWORD are required; they are never guessed" >&2
    exit 69
fi
if [ -z "${AXOLOTY_MQTT_HOST:-}" ]; then
    echo "run-interop-suite: AXOLOTY_MQTT_HOST is required; the broker is never guessed" >&2
    exit 69
fi

scratch=${AXOLOTY_SCRATCH:-"$repo_root/.axoloty"}
suite_root="$scratch/interop-suite"
mkdir -p "$suite_root"

only=",$(printf '%s' "${SUITE_ONLY:-$steps}" | tr ' ' ','),"

passed=''
failed=''
skipped=''

run_step() {
    name=$1
    shift
    case "$only" in
        *",$name,"*) ;;
        *) skipped="$skipped $name"; return 0 ;;
    esac
    log="$suite_root/$name.log"
    echo "== $name =="
    if "$@" >"$log" 2>&1; then
        echo "PASS $name"
        passed="$passed $name"
    else
        code=$?
        echo "FAIL $name (exit $code); see $log"
        failed="$failed $name"
    fi
}

run_step agent-exchange "$script_dir/run-agent-test.sh"
run_step coatyjs-a env EMBEDDED_COATY_ROLE=A "$script_dir/run-coatyjs-interop-test.sh"
run_step coatyjs-b env EMBEDDED_COATY_ROLE=B "$script_dir/run-coatyjs-interop-test.sh"
run_step last-will "$script_dir/run-last-will-test.sh"
run_step host-a env EMBEDDED_HOST_ROLE=A "$script_dir/run-host-interop-test.sh"
run_step host-b env EMBEDDED_HOST_ROLE=B "$script_dir/run-host-interop-test.sh"

count() {
    printf '%s\n' $1 | grep -c . || true
}

echo "interop suite: $(count "$passed") passed, $(count "$failed") failed, $(count "$skipped") skipped"
[ -z "$failed" ] || exit 1
echo "EMBEDDED INTEROP SUITE OK"
