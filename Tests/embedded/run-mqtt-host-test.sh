#!/bin/sh
# Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

# Host check for the MQTT transport seam. Moved from the pre-split Axoloty MQTT
# host test. Compiles the real EmbeddedMQTTClient overlay, the real event
# validator, the real runtime identity, and a host-only C HAL. No board, no SDK,
# no broker.
#
# The test proves operation order and the composed bounds before the HAL is
# entered, and the real carrier's receive path at those bounds. It does not
# compile or link ESP-IDF and cannot be used by the production image.
#
# Exit status: 0 passed, 1 failed, 69 required tool missing.

set -eu

script_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
repo_root=$(git -C "$script_dir" rev-parse --show-toplevel)
platform_main="$repo_root/Platforms/esp32c6-idf/main"
transport_main="$repo_root/Transports/mqtt-espidf/main"

compiler=${CC:-clang}
if ! command -v "$compiler" >/dev/null 2>&1; then
    echo "embedded MQTT host test requires a C compiler ('$compiler')" >&2
    exit 69
fi
if ! command -v swiftc >/dev/null 2>&1; then
    echo "embedded MQTT host test requires swiftc" >&2
    exit 69
fi

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# The carrier is sized to the bounds the composition takes from the selected
# application, so the same check runs at the bounds of two applications: the
# smoke agent's 256/2048 and the sensor node's 128/512.
cat > "$tmp/axoloty_network_config.h" <<'EOF'
#define AXOLOTY_NETWORK_CONFIGURED 1
static const char axoloty_runtime_identity[] = "";
static const char axoloty_mqtt_host[] = "127.0.0.1";
static const unsigned short axoloty_mqtt_port = 1883;
EOF

swift_runtime=$(swiftc -print-target-info | awk -F'"' '/runtimeLibraryPaths/{getline; print $2; exit}')
dispatch_dir=""
# Nix's standalone Swift compiler does not always add the dispatch library to
# the executable search path. Native CI images already provide it.
if [ "$(uname -s)" = "Linux" ] && [ -d /nix/store ]; then
    dispatch_dir=$(dirname "$(find /nix/store -name libdispatch.so 2>/dev/null | head -1)")
fi

for bounds_profile in esp32c6-mqtt esp32c6-sensor-node-mqtt; do
    out="$tmp/$bounds_profile"
    mkdir -p "$out"
    python3 "$repo_root/Tools/validate-composition.py" --repo-root "$repo_root" \
        --profile "$repo_root/Profiles/$bounds_profile/profile.json" \
        --emit-carrier-bounds-header "$out/axoloty_carrier_bounds.h" \
        --emit-carrier-bounds-swift "$out/CarrierBounds.swift" >/dev/null

    "$compiler" -std=c11 -O2 -Wall -Wextra -Werror \
        -I "$out" -I "$platform_main" -I "$transport_main" -I "$repo_root/Transports/mqtt-espidf/include" -I "$repo_root/Interop" \
        -c "$script_dir/mqtt-host-hal.c" -o "$out/hal.o"
    "$compiler" -std=c11 -O2 -Wall -Wextra -Werror \
        -I "$out" -I "$platform_main" -I "$transport_main" \
        -c "$transport_main/mqtt_event_validation.c" -o "$out/validation.o"
    "$compiler" -std=c11 -O2 -Wall -Wextra -Werror \
        -I "$platform_main" -I "$transport_main" \
        -c "$platform_main/runtime_identity.c" -o "$out/identity.o"
    swiftc -D EMBEDDED_MQTT_HOST_TEST \
        -I "$repo_root/Transports/mqtt-espidf/include" \
        -I "$out" -I "$transport_main" \
        -I "$script_dir" \
        -I "$repo_root/Interop" \
        -Xcc -fmodule-map-file="$script_dir/mqtt_host_test.modulemap" \
        "$transport_main/EmbeddedMQTTClient.swift" \
        "$out/CarrierBounds.swift" \
        "$script_dir/mqtt-host-test.swift" \
        "$out/hal.o" "$out/validation.o" "$out/identity.o" \
        -o "$out/embedded-mqtt-host-test"
    LD_LIBRARY_PATH="${LD_LIBRARY_PATH:-}:$swift_runtime:$dispatch_dir" \
        "$out/embedded-mqtt-host-test"

    # The real carrier source, against stand-ins for ESP-MQTT and FreeRTOS.
    "$compiler" -std=c11 -O2 -Wall -Wextra -Werror \
        -I "$script_dir/mqtt-carrier-stubs" -I "$out" -I "$tmp" -I "$platform_main" -I "$transport_main" \
        -I "$repo_root/Transports/mqtt-espidf/include" -I "$repo_root/Interop" \
        "$transport_main/mqtt_carrier_espidf.c" "$transport_main/mqtt_event_validation.c" \
        "$platform_main/runtime_identity.c" \
        "$script_dir/mqtt-carrier-host-test.c" \
        -o "$out/mqtt-carrier-host-test"
    "$out/mqtt-carrier-host-test"
    echo "embedded MQTT host seam tests passed at the bounds of $bounds_profile"
done
echo "embedded MQTT host seam tests passed"
