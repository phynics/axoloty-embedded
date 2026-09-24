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
    if [ -z "${AXOLOTY_MQTT_HOST:-}" ]; then
        echo "$device_runner_name: AXOLOTY_MQTT_HOST is required; the broker is never guessed" >&2
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
