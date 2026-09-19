#!/bin/sh
# Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

# Host check for the MQTT transport seam. Moved from the pre-split Axoloty MQTT
# host test. Compiles the real EmbeddedMQTTClient overlay, the real event
# validator, the real runtime identity, and a host-only C HAL. No board, no SDK,
# no broker.
#
# The test proves operation order and the 256/2048 bounds before the HAL is
# entered. It does not compile or link ESP-IDF and cannot be used by the
# production image.
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

"$compiler" -std=c11 -O2 -Wall -Wextra -Werror \
    -I "$platform_main" -I "$transport_main" \
    -c "$script_dir/mqtt-host-hal.c" -o "$tmp/hal.o"
"$compiler" -std=c11 -O2 -Wall -Wextra -Werror \
    -I "$platform_main" -I "$transport_main" \
    -c "$transport_main/mqtt_event_validation.c" -o "$tmp/validation.o"
"$compiler" -std=c11 -O2 -Wall -Wextra -Werror \
    -I "$platform_main" -I "$transport_main" \
    -c "$platform_main/runtime_identity.c" -o "$tmp/identity.o"
swiftc -D EMBEDDED_MQTT_HOST_TEST \
    "$transport_main/EmbeddedMQTTClient.swift" \
    "$script_dir/mqtt-host-test.swift" \
    "$tmp/hal.o" "$tmp/validation.o" "$tmp/identity.o" \
    -o "$tmp/embedded-mqtt-host-test"

# Nix's standalone Swift compiler does not always add the dispatch library to
# the executable search path. Native CI images already provide it.
swift_runtime=$(swiftc -print-target-info | awk -F'"' '/runtimeLibraryPaths/{getline; print $2; exit}')
dispatch_dir=$(dirname "$(find /nix/store -name libdispatch.so 2>/dev/null | head -1)")
LD_LIBRARY_PATH="${LD_LIBRARY_PATH:-}:$swift_runtime:$dispatch_dir" \
    "$tmp/embedded-mqtt-host-test"
echo "embedded MQTT host seam tests passed"
