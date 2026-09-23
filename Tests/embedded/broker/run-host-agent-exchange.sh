#!/bin/sh
# Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

# Hardware-free host exchange. The real device-smoke application runs through
# its host seam, the real EmbeddedHostPeer runs against the pinned Core runtime,
# and an in-process TestMQTTBroker supplies an ephemeral broker when no operator
# broker is configured. No board, container broker, or fixed port is required.

set -eu

script_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
repo_root=$(git -C "$script_dir" rev-parse --show-toplevel)
if [ -n "${HOST_AGENT_EXCHANGE_WORK:-}" ]; then
    work=$HOST_AGENT_EXCHANGE_WORK
    mkdir -p "$work"
else
    work=$(mktemp -d)
fi
swift_build="$work/swift-build"
control_dir="$work/broker-control"
broker_ready="$work/broker-port"
peer_ready="$work/peer-ready"
host_output="$work/host-smoke.jsonl"
peer_output="$work/host-peer.log"
agent_control="$work/agent-control"

rm -rf "$control_dir"
rm -rf "$agent_control"
rm -f "$broker_ready" "$peer_ready" "$host_output" "$peer_output"
agent_pid=''
peer_pid=''
broker_pid=''

cleanup() {
    if [ -n "$agent_pid" ] && kill -0 "$agent_pid" 2>/dev/null; then kill "$agent_pid" 2>/dev/null || true; fi
    if [ -n "$peer_pid" ] && kill -0 "$peer_pid" 2>/dev/null; then kill "$peer_pid" 2>/dev/null || true; fi
    if [ -n "$broker_pid" ] && kill -0 "$broker_pid" 2>/dev/null; then
        printf '%s\n' stop > "$control_dir/command" 2>/dev/null || true
        kill "$broker_pid" 2>/dev/null || true
    fi
    [ -n "${HOST_AGENT_EXCHANGE_WORK:-}" ] || rm -rf "$work"
}
trap cleanup EXIT INT TERM

for tool in node swift swift-build; do
    command -v "$tool" >/dev/null 2>&1 || {
        echo "run-host-agent-exchange: $tool is required" >&2
        exit 69
    }
done

swift build --package-path "$repo_root" --scratch-path "$swift_build" -c debug
bin_dir=$(swift build --package-path "$repo_root" --scratch-path "$swift_build" --show-bin-path)

in_process=1
broker_host=${AXOLOTY_MQTT_HOST:-}
broker_port=${AXOLOTY_MQTT_PORT:-}
if [ -n "$broker_host" ]; then
    in_process=0
    broker_port=${broker_port:-1883}
else
    mkdir -p "$control_dir"
    HOST_AGENT_BROKER_READY_FILE="$broker_ready" \
    HOST_AGENT_BROKER_CONTROL_DIR="$control_dir" \
    HOST_AGENT_CLIENT_ID="axoloty-host-smoke-agent" \
        "$bin_dir/HostAgentExchange" >"$work/broker.log" 2>&1 &
    broker_pid=$!
    deadline=$(( $(date +%s) + 30 ))
    while [ ! -s "$broker_ready" ]; do
        [ "$(date +%s)" -lt "$deadline" ] || {
            echo "run-host-agent-exchange: in-process broker did not become ready" >&2
            exit 1
        }
        sleep 1
    done
    IFS= read -r broker_port < "$broker_ready"
    broker_host=127.0.0.1
fi

HOST_AGENT_BROKER_MODE=$([ "$in_process" -eq 1 ] && printf in-process || printf external) \
HOST_AGENT_CONTROL_DIR="$work/agent-control" \
HOST_AGENT_ROLE=1 \
HOST_AGENT_CLIENT_ID="axoloty-host-smoke-agent" \
WIRE_BROKER_HOST="$broker_host" \
WIRE_BROKER_PORT="$broker_port" \
    "$bin_dir/HostSmokeAgent" >"$host_output" 2>"$work/host-stderr.log" &
agent_pid=$!

wait_for_marker() {
    marker=$1
    timeout=${2:-90}
    deadline=$(( $(date +%s) + timeout ))
    while [ ! -f "$agent_control/$marker" ]; do
        if [ -n "$peer_pid" ] && ! kill -0 "$peer_pid" 2>/dev/null; then
            echo "run-host-agent-exchange: host peer exited while waiting for $marker" >&2
            cat "$peer_output" >&2 || true
            exit 1
        fi
        [ "$(date +%s)" -lt "$deadline" ] || {
            echo "run-host-agent-exchange: timed out waiting for $marker" >&2
            exit 1
        }
        sleep 1
    done
}

wait_for_marker subscribed
printf '%s\n' reconnect-requested > "$agent_control/reconnect-requested"
wait_for_marker reconnected
wait_for_marker advertised

# Start the peer after the first Advertise. The application must keep publishing
# that message until the late subscriber can discover it.
WIRE_EMBEDDED_HOST_DIRECTION=host-requester \
WIRE_BROKER_HOST="$broker_host" \
WIRE_BROKER_PORT="$broker_port" \
WIRE_READY_FILE="$peer_ready" \
    "$bin_dir/EmbeddedHostPeer" >"$peer_output" 2>&1 &
peer_pid=$!

deadline=$(( $(date +%s) + 30 ))
while [ ! -f "$peer_ready" ]; do
    if ! kill -0 "$peer_pid" 2>/dev/null; then
        echo "run-host-agent-exchange: host peer exited before readiness" >&2
        exit 1
    fi
    [ "$(date +%s)" -lt "$deadline" ] || {
        echo "run-host-agent-exchange: host peer did not become ready" >&2
        exit 1
    }
    sleep 1
done

wait_for_marker resolved 15

if [ "$in_process" -eq 1 ]; then
    printf '%s\n' inject-disconnect > "$control_dir/command"
    deadline=$(( $(date +%s) + 30 ))
    while [ ! -f "$control_dir/injected" ] || [ ! -f "$control_dir/will-observed" ]; do
        [ "$(date +%s)" -lt "$deadline" ] || {
            echo "run-host-agent-exchange: broker did not observe the injected last will" >&2
            exit 1
        }
        sleep 1
    done
fi
printf '%s\n' disconnect-requested > "$agent_control/disconnect-requested"

if ! wait "$agent_pid"; then
    echo "run-host-agent-exchange: host smoke agent failed" >&2
    cat "$host_output" >&2 || true
    cat "$work/host-stderr.log" >&2 || true
    exit 1
fi
agent_pid=''

if ! wait "$peer_pid"; then
    echo "run-host-agent-exchange: host peer failed" >&2
    cat "$peer_output" >&2 || true
    exit 1
fi
peer_pid=''

AGENT_VALIDATOR="$repo_root/Tests/embedded/agent-validator.mjs" \
PEER_OUTPUT="$peer_output" \
HOST_OUTPUT="$host_output" \
IN_PROCESS="$in_process" \
node --input-type=module - <<'JS'
import fs from "node:fs";

 (async () => {
  const { createEmbeddedAgentValidator } = await import(process.env.AGENT_VALIDATOR);
  const validator = createEmbeddedAgentValidator();
  for (const line of fs.readFileSync(process.env.HOST_OUTPUT, "utf8").split(/\r?\n/)) {
    const start = line.indexOf("{");
    if (start < 0) continue;
    let record;
    try { record = JSON.parse(line.slice(start)); } catch { continue; }
    if (typeof record.caseId === "string" || record.caseId === undefined && record.schemaVersion !== undefined) {
      validator.observe(line.slice(start));
    }
  }
  const result = validator.result();
  if (!result.passed) throw new Error(`host smoke validation failed: ${result.reason}`);
  const peer = fs.readFileSync(process.env.PEER_OUTPUT, "utf8");
  if (!peer.includes('"state":"passed"')) throw new Error("host peer did not report a passed exchange");
  if (process.env.IN_PROCESS === "1") {
    console.log(`host agent exchange passed: ${result.counts.passed} exchange checks; broker LWT observed`);
  } else {
    console.log(`host agent exchange passed: ${result.counts.passed} exchange checks`);
  }
})().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
JS
