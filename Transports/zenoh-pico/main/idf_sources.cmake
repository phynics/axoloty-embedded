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
    "${AXOLOTY_TRANSPORT_MAIN_DIR}/ZenohCarrier.swift"
    "${AXOLOTY_TRANSPORT_MAIN_DIR}/ZenohNetworkProbe.swift"
)

# The facade is implemented on the device. zenoh_pico_queue.c holds the bounded
# receive queue, its counters, and the session and subscriber registries; it
# includes no Zenoh and no SDK header, so the host seam can check it with no
# board. zenoh_pico_facade.c is the `axoloty_zenoh_*` entry points over the
# pinned zenoh-pico. zenoh_endpoint.c derives the operator-configured router
# endpoint from the private network configuration header.
# carrier_diagnostics.c holds the carrier counters without SDK or facade headers.
#
# zenoh_carrier_report.c and zenoh_carrier_scenario.c are the C-only
# qualification scenario: the bounded JSON Lines reporting shim and the
# carrier-mechanics steps the device gate drives. They are composed into the
# image so the Embedded C toolchain compiles the exact sources the
# qualification run executes, and the host check compiles the same files. They
# hold no protocol rule and no Zenoh type; the scenario drives only the
# Core-owned facade ABI and the transport's own counters.
set(AXOLOTY_TRANSPORT_C_SOURCES
    "${AXOLOTY_TRANSPORT_MAIN_DIR}/zenoh_sample_validation.c"
    "${AXOLOTY_TRANSPORT_MAIN_DIR}/zenoh_pico_queue.c"
    "${AXOLOTY_TRANSPORT_MAIN_DIR}/zenoh_pico_facade.c"
    "${AXOLOTY_TRANSPORT_MAIN_DIR}/zenoh_endpoint.c"
    "${AXOLOTY_TRANSPORT_MAIN_DIR}/carrier_diagnostics.c"
    "${AXOLOTY_TRANSPORT_MAIN_DIR}/zenoh_carrier_report.c"
    "${AXOLOTY_TRANSPORT_MAIN_DIR}/zenoh_carrier_scenario.c"
)

# The pinned zenoh-pico wrapper component supplies the carrier seam backend,
# and the prepared AxolotyZenohCore module supplies the portable session types
# the carrier is written against.
set(AXOLOTY_TRANSPORT_IDF_REQUIRES "zenoh_pico" "axoloty_zenoh_core")

# The C seam this transport declares is the Core-owned Axoloty Zenoh facade
# header, resolved by the platform from the `zenohCore` entry of the Core
# preparation report (phynics/axoloty#974). This transport never names a
# Core-relative path: the report is the only channel, and it is also the only
# place a checksum for the header exists.
#
# This file is read only when this transport is the selected one, so failing
# closed here fails the profile that asked for the facade and no other.
if(NOT DEFINED AXOLOTY_ZENOH_FACADE_INCLUDE_DIR OR
   "${AXOLOTY_ZENOH_FACADE_INCLUDE_DIR}" STREQUAL "")
    message(FATAL_ERROR
        "the Core preparation report has no zenohCore entry. The zenoh-pico "
        "backend implements the Core-owned axoloty_zenoh_* ABI, so Core must "
        "publish that contract in the preparation report "
        "(phynics/axoloty#974) and the lock must name a revision that carries it"
    )
endif()
if(NOT EXISTS "${AXOLOTY_ZENOH_FACADE_INCLUDE_DIR}/axoloty_zenoh.h")
    message(FATAL_ERROR
        "AXOLOTY_ZENOH_FACADE_INCLUDE_DIR does not contain axoloty_zenoh.h: ${AXOLOTY_ZENOH_FACADE_INCLUDE_DIR}"
    )
endif()
list(APPEND AXOLOTY_TRANSPORT_INCLUDE_DIRS "${AXOLOTY_ZENOH_FACADE_INCLUDE_DIR}")
