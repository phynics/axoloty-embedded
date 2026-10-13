# Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.
# shellcheck shell=sh

# Steps every device runner shares. Source it after setting
# `device_runner_name` (the message prefix) and `repo_root`:
#
#   device_runner_name=run-agent-test
#   . "$script_dir/device-common.sh"
#
# Functions exit the runner on failure with the documented status: 69 when an
# operator capability is absent, 1 when a board cannot be queried.

# Fails with 69 unless the private network configuration is named. Wi-Fi
# credentials and the broker are never guessed.
require_network_env() {
    if [ -z "${AXOLOTY_WIFI_SSID:-}" ] || [ -z "${AXOLOTY_WIFI_PASSWORD:-}" ]; then
        echo "$device_runner_name: AXOLOTY_WIFI_SSID and AXOLOTY_WIFI_PASSWORD are required; they are never guessed" >&2
        exit 69
    fi
    case "${1:-esp32c6-mqtt}" in
        esp32c6-mqtt)
            if [ -z "${AXOLOTY_MQTT_HOST:-}" ]; then
                echo "$device_runner_name: AXOLOTY_MQTT_HOST is required; the broker is never guessed" >&2
                exit 69
            fi
            ;;
        esp32c6-zenoh)
            if [ -z "${AXOLOTY_ZENOH_HOST:-}" ]; then
                echo "$device_runner_name: AXOLOTY_ZENOH_HOST is required; the router is never guessed" >&2
                exit 69
            fi
            ;;
        *)
            echo "$device_runner_name: unsupported profile '$1'" >&2
            exit 64
            ;;
    esac
}

# Exits 69 unless the selected profile's broker accepts a TCP connection from
# this runner. Without this check a missing broker surfaced only inside the
# device connect step, after a full build and flash. `profile` is
# esp32c6-mqtt (default) or esp32c6-zenoh.
require_broker_reachable() {
    case "${1:-esp32c6-mqtt}" in
        esp32c6-mqtt) broker_host=${AXOLOTY_MQTT_HOST:-}; broker_port=${AXOLOTY_MQTT_PORT:-1883} ;;
        esp32c6-zenoh) broker_host=${AXOLOTY_ZENOH_HOST:-}; broker_port=${AXOLOTY_ZENOH_PORT:-7447} ;;
        *) echo "$device_runner_name: unsupported profile '$1'" >&2; exit 64 ;;
    esac
    if [ -z "$broker_host" ]; then
        echo "$device_runner_name: no broker host is configured for $1" >&2
        exit 69
    fi
    if ! BROKER_HOST="$broker_host" BROKER_PORT="$broker_port" node -e '
const net = require("net");
const socket = net.connect({ host: process.env.BROKER_HOST, port: Number(process.env.BROKER_PORT) });
const finish = ok => { try { socket.destroy(); } catch {} process.exit(ok ? 0 : 1); };
socket.setTimeout(5000);
socket.on("connect", () => finish(true));
socket.on("timeout", () => finish(false));
socket.on("error", () => finish(false));
'; then
        echo "$device_runner_name: broker $broker_host:$broker_port is not reachable; start it or fix the network before the build" >&2
        exit 69
    fi
}

# Exits 69 when a TCP port is already in use. The broker-restart harness starts
# its own mosquitto on this port and never touches another broker, so the port
# must be free before it runs.
require_broker_port_free() {
    free_port=${1:-1883}
    if BROKER_PORT="$free_port" node -e '
const net = require("net");
const socket = net.connect({ host: "127.0.0.1", port: Number(process.env.BROKER_PORT) });
const finish = ok => { try { socket.destroy(); } catch {} process.exit(ok ? 0 : 1); };
socket.setTimeout(1000);
socket.on("connect", () => finish(true));
socket.on("timeout", () => finish(false));
socket.on("error", () => finish(false));
'; then
        echo "$device_runner_name: port $free_port is already in use; stop the broker that owns it before this run" >&2
        exit 69
    fi
}

# Enters the ESP-IDF Python environment and sets `esptool` to its esptool.py.
load_esptool() {
    idf_root=${IDF_PATH:-/opt/esp/idf}
    # shellcheck source=/dev/null
    . "$idf_root/export.sh" >/dev/null 2>&1
    esptool="$idf_root/components/esptool_py/esptool/esptool.py"
}

# Queries one board and writes <evidence dir>/device-manifest.json.
# Requires load_esptool first.
write_device_manifest() {
    manifest_device=$1
    manifest_evidence=$2
    mkdir -p "$manifest_evidence"
    python3 "$esptool" --port "$manifest_device" chip_id > "$manifest_evidence/device-info-raw.txt" 2>&1 || {
        echo "$device_runner_name: could not query $manifest_device" >&2
        exit 1
    }
    node "$repo_root/Platforms/esp32c6-idf/tools/write-device-manifest.mjs" \
        "$manifest_device" "$manifest_evidence/device-info-raw.txt" "$manifest_evidence/device-manifest.json"
}
