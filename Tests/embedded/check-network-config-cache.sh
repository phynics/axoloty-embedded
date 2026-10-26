#!/bin/sh
# Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

# Exercise header staging and incremental object dependencies for the
# bootstrap, MQTT-shaped identity consumer, and production Zenoh endpoint.
# No ESP-IDF, broker, or hardware is required.

set -eu

script_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
repo_root=$(git -C "$script_dir" rev-parse --show-toplevel)
fixture_source="$script_dir/fixtures/network-config-cache"
production_cmake="$repo_root/Platforms/esp32c6-idf/main/CMakeLists.txt"
compiler=${CC:-cc}
if ! command -v "$compiler" >/dev/null 2>&1; then
    echo "network config cache check requires a C compiler ('$compiler')" >&2
    exit 69
fi
if ! command -v make >/dev/null 2>&1; then
    echo "network config cache check requires make" >&2
    exit 69
fi

# Keep this compiler repro tied to the production CMake wiring, which assigns
# OBJECT_DEPENDS to the actual selected translation units.
for production_dependency in \
    'PROPERTIES OBJECT_DEPENDS "${AXOLOTY_NETWORK_CONFIG_HEADER}"' \
    '"${CMAKE_CURRENT_LIST_DIR}/network_bootstrap.c"' \
    '"${AXOLOTY_TRANSPORT_MAIN_DIR}/mqtt_carrier_espidf.c"' \
    '"${AXOLOTY_TRANSPORT_MAIN_DIR}/zenoh_endpoint.c"'; do
    if ! grep -Fq "$production_dependency" "$production_cmake"; then
        echo "network config cache check: production CMake dependency is missing" >&2
        exit 1
    fi
done
echo "network config cache check: production CMake dependencies cover bootstrap and selected transports"

work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT HUP INT TERM

cat >"$work/mqtt_consumer.c" <<'C'
#if __has_include("axoloty_network_config.h")
#include "axoloty_network_config.h"
#else
#define AXOLOTY_NETWORK_CONFIGURED 0
static const char axoloty_runtime_identity[] = "";
#endif

const char *axoloty_test_runtime_identity(void) {
    return axoloty_runtime_identity;
}
C
cat >"$work/runner.c" <<'C'
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

int axoloty_network_configured(void);
const char *axoloty_test_runtime_identity(void);
int axoloty_zenoh_copy_endpoint(unsigned char *buffer, int capacity);

int main(int argc, char **argv) {
    if (argc != 2) return 2;
    int expected = atoi(argv[1]);
    char identity[32];
    char endpoint[64];
    if (expected == 0) {
        identity[0] = '\0';
    } else {
        snprintf(identity, sizeof(identity), "identity-%d", expected);
    }
    if (axoloty_network_configured() != expected) return 3;
    if (strcmp(axoloty_test_runtime_identity(), identity) != 0) return 4;
    int endpoint_length = axoloty_zenoh_copy_endpoint(
        (unsigned char *)endpoint, (int)sizeof(endpoint));
    if (expected == 0) return endpoint_length == -1 ? 0 : 5;
    char expected_endpoint[64];
    snprintf(expected_endpoint, sizeof(expected_endpoint),
             "tcp/router-%d:7447", expected);
    return endpoint_length == (int)strlen(expected_endpoint) &&
                   strcmp(endpoint, expected_endpoint) == 0
               ? 0
               : 6;
}
C

write_makefile() {
    explicit_header_dependency=$1
    cat >"$work/Makefile" <<MAKEFILE
CC := $compiler
PLATFORM := platform/main
ZENOH := $repo_root/Transports/zenoh-pico/main
MQTT := build/mqtt_consumer.c
HEADER_DEP := $explicit_header_dependency

build/network_bootstrap.o: \$(PLATFORM)/network_bootstrap.c \$(HEADER_DEP)
	\$(CC) -std=c11 -Wall -Wextra -Werror -MMD -MF build/network_bootstrap.d -MT \$@ -I \$(PLATFORM) -c \$< -o \$@

build/mqtt_consumer.o: \$(MQTT) \$(HEADER_DEP)
	\$(CC) -std=c11 -Wall -Wextra -Werror -MMD -MF build/mqtt_consumer.d -MT \$@ -I \$(PLATFORM) -c \$< -o \$@

build/zenoh_endpoint.o: \$(ZENOH)/zenoh_endpoint.c \$(HEADER_DEP)
	\$(CC) -std=c11 -Wall -Wextra -Werror -MMD -MF build/zenoh_endpoint.d -MT \$@ -I \$(PLATFORM) -I \$(ZENOH) -c \$< -o \$@

-include build/network_bootstrap.d build/mqtt_consumer.d build/zenoh_endpoint.d
all: build/network_bootstrap.o build/mqtt_consumer.o build/zenoh_endpoint.o
MAKEFILE
}

stage_source() {
    project="$work/platform"
    rm -rf -- "$project"
    mkdir -p "$project"
    cp -R --preserve=timestamps "$fixture_source/." "$project/"
    cp "$repo_root/Platforms/esp32c6-idf/main/network_bootstrap.h" \
        "$project/main/network_bootstrap.h"
    axoloty_stage_network_config_header "${1:-}" "$project"
}

compile_objects() {
    (cd "$work" && make -s -f Makefile all)
}

run_expected() {
    expected=$1
    "$compiler" -Wall -Wextra -Werror \
        "$work/runner.c" \
        "$work/build/network_bootstrap.o" \
        "$work/build/mqtt_consumer.o" \
        "$work/build/zenoh_endpoint.o" \
        -o "$work/runner"
    "$work/runner" "$expected"
}

. "$repo_root/Platforms/esp32c6-idf/tools/profile-build-env.sh"
mkdir -p "$work/build" "$work/baseline/build" "$work/baseline/platform/main"
cp -R --preserve=timestamps "$fixture_source/." "$work/baseline/platform/"
cp "$repo_root/Platforms/esp32c6-idf/main/network_bootstrap.h" \
    "$work/baseline/platform/main/network_bootstrap.h"
cp "$work/mqtt_consumer.c" "$work/build/mqtt_consumer.c"
write_makefile ""

# Reproduce the original depfile behavior: all three objects compile while the
# optional header is absent, so adding it later cannot invalidate any object.
cp "$work/Makefile" "$work/baseline/Makefile"
(cd "$work/baseline" && make -s -f Makefile all \
    CC="$compiler" PLATFORM=platform/main MQTT="$work/mqtt_consumer.c" \
    ZENOH="$repo_root/Transports/zenoh-pico/main")
link_baseline() {
    "$compiler" -Wall -Wextra -Werror \
        "$work/runner.c" \
        "$work/baseline/build/network_bootstrap.o" \
        "$work/baseline/build/mqtt_consumer.o" \
        "$work/baseline/build/zenoh_endpoint.o" \
        -o "$work/baseline-runner"
}
link_baseline
"$work/baseline-runner" 0
mkdir -p "$work/baseline/platform/main"
cat >"$work/private-config.h" <<'HEADER'
#define AXOLOTY_NETWORK_CONFIGURED 1
#define axoloty_runtime_identity "identity-1"
#define axoloty_zenoh_host "router-1"
#define axoloty_zenoh_port 7447
HEADER
cp "$work/private-config.h" "$work/baseline/platform/main/axoloty_network_config.h"
(cd "$work/baseline" && make -s -f Makefile all \
    CC="$compiler" PLATFORM=platform/main MQTT="$work/mqtt_consumer.c" \
    ZENOH="$repo_root/Transports/zenoh-pico/main")
link_baseline
if "$work/baseline-runner" 1 >/dev/null 2>&1; then
    echo "network config cache check: baseline unexpectedly refreshed consumer objects" >&2
    exit 1
fi
echo "network config cache check: original staging reproduced stale bootstrap and transport objects"

# The production CMake component uses OBJECT_DEPENDS for these same three
# consumers. Model that explicit input here while retaining compiler depfiles.
source_mtime_before=$(stat -c '%y' "$fixture_source/main/network_bootstrap.c")
write_makefile '$(PLATFORM)/axoloty_network_config.h'
stage_source
compile_objects
run_expected 0

cat >"$work/private-config.h" <<'HEADER'
#define AXOLOTY_NETWORK_CONFIGURED 1
#define axoloty_runtime_identity "identity-1"
#define axoloty_zenoh_host "router-1"
#define axoloty_zenoh_port 7447
HEADER
stage_source "$work/private-config.h"
compile_objects
run_expected 1

cat >"$work/private-config.h" <<'HEADER'
#define AXOLOTY_NETWORK_CONFIGURED 2
#define axoloty_runtime_identity "identity-2"
#define axoloty_zenoh_host "router-2"
#define axoloty_zenoh_port 7447
HEADER
stage_source "$work/private-config.h"
compile_objects
run_expected 2

stage_source
compile_objects
run_expected 0

source_mtime_after=$(stat -c '%y' "$fixture_source/main/network_bootstrap.c")
if [ "$source_mtime_before" != "$source_mtime_after" ]; then
    echo "network config cache check: fixture source timestamp changed" >&2
    exit 1
fi

echo "network config cache check passed: bootstrap, MQTT identity, and Zenoh endpoint absent -> present -> changed -> absent"
