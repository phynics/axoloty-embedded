# Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.
#
# Declarative carrier source list for the ESP32-C6 main component.
#
# The platform main component includes this file and compiles exactly these
# sources, so the profile's transport selection reaches the build. This file
# lists sources; it contains no build logic and no protocol rule.
#
# The platform sets AXOLOTY_TRANSPORT_MAIN_DIR before including this file.

set(AXOLOTY_TRANSPORT_SWIFT_SOURCES
    "${AXOLOTY_TRANSPORT_MAIN_DIR}/EmbeddedZenohClient.swift"
)

set(AXOLOTY_TRANSPORT_C_SOURCES
    "${AXOLOTY_TRANSPORT_MAIN_DIR}/zenoh_sample_validation.c"
)

# The pinned zenoh-pico wrapper component supplies the carrier seam backend.
set(AXOLOTY_TRANSPORT_IDF_REQUIRES "zenoh_pico")
