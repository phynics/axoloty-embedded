# Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.
#
# ESP-IDF component wrapper for a pinned zenoh-pico checkout.
#
# zenoh-pico ships no ESP-IDF component and is not on the Espressif component
# registry (phynics/axoloty#797, #813). This wrapper compiles a checkout
# prepared by Tools/prepare-zenoh-pico.sh into the firmware with the v1 feature
# profile from docs/dependencies/zenoh.md.
#
# The build never fetches. AXOLOTY_ZENOH_PICO_REPORT is the only source of the
# prepared path and revision, exactly as Tools/prepare-core.sh is for Core.
#
# The generated-header tokens below are taken from the pinned tree's
# include/zenoh-pico/config.h.in and include/zenoh-pico.h.in, and the source
# list mirrors its top-level CMakeLists.txt plus cmake/platforms/espidf.cmake.
#
# UNVERIFIED: no ESP-IDF toolchain was available, so this wrapper has never
# been configured or compiled. The assumptions that can be checked cheaply fail
# closed: a missing template, a missing listed source, or a missing report is a
# configure error, not a silent misbuild.

if(NOT DEFINED AXOLOTY_ZENOH_PICO_REPORT OR "${AXOLOTY_ZENOH_PICO_REPORT}" STREQUAL "")
    if(DEFINED ENV{AXOLOTY_ZENOH_PICO_REPORT})
        set(AXOLOTY_ZENOH_PICO_REPORT "$ENV{AXOLOTY_ZENOH_PICO_REPORT}")
    endif()
endif()
if(NOT IS_ABSOLUTE "${AXOLOTY_ZENOH_PICO_REPORT}" OR NOT EXISTS "${AXOLOTY_ZENOH_PICO_REPORT}")
    message(FATAL_ERROR
        "AXOLOTY_ZENOH_PICO_REPORT must name a prepared zenoh-pico report; "
        "run Tools/prepare-zenoh-pico.sh first"
    )
endif()
file(READ "${AXOLOTY_ZENOH_PICO_REPORT}" AXOLOTY_ZENOH_PICO_JSON)
string(JSON AXOLOTY_ZENOH_PICO_SCHEMA GET "${AXOLOTY_ZENOH_PICO_JSON}" schemaVersion)
string(JSON AXOLOTY_ZENOH_PICO_STATUS GET "${AXOLOTY_ZENOH_PICO_JSON}" status)
string(JSON AXOLOTY_ZENOH_PICO_DIR GET "${AXOLOTY_ZENOH_PICO_JSON}" sourceDir)
string(JSON AXOLOTY_ZENOH_PICO_VERSION GET "${AXOLOTY_ZENOH_PICO_JSON}" version)
string(JSON AXOLOTY_ZENOH_PICO_REVISION GET "${AXOLOTY_ZENOH_PICO_JSON}" revision)
if(NOT AXOLOTY_ZENOH_PICO_SCHEMA EQUAL 1 OR NOT AXOLOTY_ZENOH_PICO_STATUS STREQUAL "prepared")
    message(FATAL_ERROR "the zenoh-pico preparation report is not a prepared report")
endif()
if(NOT IS_ABSOLUTE "${AXOLOTY_ZENOH_PICO_DIR}" OR NOT IS_DIRECTORY "${AXOLOTY_ZENOH_PICO_DIR}")
    message(FATAL_ERROR "the zenoh-pico preparation report sourceDir is not a directory")
endif()
file(REAL_PATH "${AXOLOTY_ZENOH_PICO_DIR}" AXOLOTY_ZENOH_PICO_DIR_REAL)
if(NOT "${AXOLOTY_ZENOH_PICO_DIR}" STREQUAL "${AXOLOTY_ZENOH_PICO_DIR_REAL}")
    message(FATAL_ERROR "the zenoh-pico preparation report sourceDir must be canonical")
endif()
if(NOT AXOLOTY_ZENOH_PICO_REVISION MATCHES "^[0-9a-f]{40}$")
    message(FATAL_ERROR "the zenoh-pico preparation report revision is not a full commit SHA")
endif()

# Project version tokens used by include/zenoh-pico.h.in.
if(NOT AXOLOTY_ZENOH_PICO_VERSION MATCHES "^([0-9]+)\\.([0-9]+)\\.([0-9]+)")
    message(FATAL_ERROR "the pinned zenoh-pico version is not semantic: ${AXOLOTY_ZENOH_PICO_VERSION}")
endif()
set(ZENOH_PICO "${AXOLOTY_ZENOH_PICO_VERSION}")
set(ZENOH_PICO_MAJOR "${CMAKE_MATCH_1}")
set(ZENOH_PICO_MINOR "${CMAKE_MATCH_2}")
set(ZENOH_PICO_PATCH "${CMAKE_MATCH_3}")
set(ZENOH_PICO_TWEAK 0)

# v1 feature profile from docs/dependencies/zenoh.md: client mode over TCP with
# publication and subscription only. The tuning values are that document's
# starting points, not a measured optimum; the hardware gate sets the final
# numbers. Every token in config.h.in is set so the generated header has no
# leftover @...@ placeholder.
set(FRAG_MAX_SIZE 1024)
set(BATCH_UNICAST_SIZE 1024)
set(BATCH_MULTICAST_SIZE 2048)
set(Z_CONFIG_SOCKET_TIMEOUT 100)
set(Z_TRANSPORT_LEASE 10000)
set(Z_TRANSPORT_LEASE_EXPIRE_FACTOR 3)
set(Z_RUNTIME_MAX_TASKS 8)
set(Z_RUNTIME_IDLE_READ_TASK_SLEEP 0)
set(Z_TRANSPORT_ACCEPT_TIMEOUT 1000)
set(Z_TRANSPORT_CONNECT_TIMEOUT 10000)
set(Z_FEATURE_UNSTABLE_API 0)
set(Z_FEATURE_CONNECTIVITY 0)
set(Z_FEATURE_MULTI_THREAD 1)
set(Z_FEATURE_PUBLICATION 1)
set(Z_FEATURE_ADVANCED_PUBLICATION 0)
set(Z_FEATURE_SUBSCRIPTION 1)
set(Z_FEATURE_ADVANCED_SUBSCRIPTION 0)
set(Z_FEATURE_QUERY 0)
set(Z_FEATURE_QUERYABLE 0)
set(Z_FEATURE_LIVELINESS 0)
set(Z_FEATURE_RAWETH_TRANSPORT 0)
set(Z_FEATURE_INTEREST 1)
set(Z_FEATURE_LINK_TCP 1)
set(Z_FEATURE_LINK_BLUETOOTH 0)
set(Z_FEATURE_LINK_WS 0)
set(Z_FEATURE_LINK_SERIAL 0)
set(Z_FEATURE_LINK_SERIAL_USB 0)
set(Z_FEATURE_LINK_TLS 0)
set(Z_FEATURE_SCOUTING 0)
set(Z_FEATURE_LINK_UDP_MULTICAST 0)
set(Z_FEATURE_LINK_UDP_UNICAST 1)
set(Z_FEATURE_MULTICAST_TRANSPORT 0)
set(Z_FEATURE_UNICAST_TRANSPORT 1)
set(Z_FEATURE_FRAGMENTATION 1)
set(Z_FEATURE_ENCODING_VALUES 1)
set(Z_FEATURE_TCP_NODELAY 1)
set(Z_FEATURE_LOCAL_SUBSCRIBER 0)
set(Z_FEATURE_LOCAL_QUERYABLE 0)
set(Z_FEATURE_SESSION_CHECK 1)
set(Z_FEATURE_BATCHING 1)
set(Z_FEATURE_BATCH_TX_MUTEX 0)
set(Z_FEATURE_BATCH_PEER_MUTEX 0)
set(Z_FEATURE_MATCHING 0)
set(Z_FEATURE_RX_CACHE 0)
set(Z_FEATURE_UNICAST_PEER 0)
set(Z_FEATURE_AUTO_RECONNECT 1)
set(Z_FEATURE_MULTICAST_DECLARATIONS 0)
set(Z_FEATURE_ADMIN_SPACE 0)
# The espidf platform profile sets no ZP_SYSTEM_PLATFORM_HEADER, so this is
# deliberately left unset and the generated header leaves it undefined.

# --- Generated headers -----------------------------------------------------
# Both zenoh-pico.h and config.h are configure_file outputs, not usable
# checked-in sources, and must exist before idf_component_register.
foreach(template IN ITEMS
    "${AXOLOTY_ZENOH_PICO_DIR}/include/zenoh-pico.h.in"
    "${AXOLOTY_ZENOH_PICO_DIR}/include/zenoh-pico/config.h.in"
)
    if(NOT EXISTS "${template}")
        message(FATAL_ERROR
            "zenoh-pico wrapper assumption is wrong: ${template} is missing. "
            "The pinned tree layout changed; reconcile this wrapper before building."
        )
    endif()
endforeach()

set(AXOLOTY_ZENOH_PICO_GENERATED_INCLUDE "${CMAKE_CURRENT_BINARY_DIR}/include")
file(MAKE_DIRECTORY "${AXOLOTY_ZENOH_PICO_GENERATED_INCLUDE}/zenoh-pico")
configure_file(
    "${AXOLOTY_ZENOH_PICO_DIR}/include/zenoh-pico.h.in"
    "${AXOLOTY_ZENOH_PICO_GENERATED_INCLUDE}/zenoh-pico.h" @ONLY
)
configure_file(
    "${AXOLOTY_ZENOH_PICO_DIR}/include/zenoh-pico/config.h.in"
    "${AXOLOTY_ZENOH_PICO_GENERATED_INCLUDE}/zenoh-pico/config.h" @ONLY
)

# --- Sources ---------------------------------------------------------------
# Mirrors the upstream file(GLOB_RECURSE ...) sets, the explicit additions,
# and the espidf platform source list. Compiled sources are internally guarded
# by their Z_FEATURE_* config, so the full set is correct for the profile.
set(AXOLOTY_ZENOH_PICO_SOURCES "")
foreach(pattern IN ITEMS
    "src/api/*.c"
    "src/collections/*.c"
    "src/net/*.c"
    "src/protocol/*.c"
    "src/runtime/*.c"
    "src/session/*.c"
    "src/transport/*.c"
    "src/utils/*.c"
    "src/system/common/*.c"
    "src/link/config/*.c"
    "src/link/multicast/*.c"
    "src/link/unicast/*.c"
    "src/link/transport/common/*.c"
)
    file(GLOB_RECURSE _globbed CONFIGURE_DEPENDS "${AXOLOTY_ZENOH_PICO_DIR}/${pattern}")
    list(APPEND AXOLOTY_ZENOH_PICO_SOURCES ${_globbed})
endforeach()
list(APPEND AXOLOTY_ZENOH_PICO_SOURCES
    "${AXOLOTY_ZENOH_PICO_DIR}/src/link/link.c"
    "${AXOLOTY_ZENOH_PICO_DIR}/src/link/endpoint.c"
    "${AXOLOTY_ZENOH_PICO_DIR}/src/link/transport/tcp/address.c"
    "${AXOLOTY_ZENOH_PICO_DIR}/src/link/transport/udp/address.c"
    "${AXOLOTY_ZENOH_PICO_DIR}/src/link/transport/upper/serial_protocol.c"
    "${AXOLOTY_ZENOH_PICO_DIR}/src/link/transport/upper/tls_stream.c"
    # cmake/platforms/espidf.cmake
    "${AXOLOTY_ZENOH_PICO_DIR}/src/system/espidf/system.c"
    "${AXOLOTY_ZENOH_PICO_DIR}/src/system/socket/esp32.c"
    "${AXOLOTY_ZENOH_PICO_DIR}/src/link/transport/tcp/tcp_esp32.c"
    "${AXOLOTY_ZENOH_PICO_DIR}/src/link/transport/udp/udp_esp32.c"
    "${AXOLOTY_ZENOH_PICO_DIR}/src/link/transport/serial/uart_espidf.c"
)
list(REMOVE_DUPLICATES AXOLOTY_ZENOH_PICO_SOURCES)
foreach(source IN LISTS AXOLOTY_ZENOH_PICO_SOURCES)
    if(NOT EXISTS "${source}")
        message(FATAL_ERROR "zenoh-pico source listed but missing: ${source}")
    endif()
endforeach()

idf_component_register(
    SRCS ${AXOLOTY_ZENOH_PICO_SOURCES}
    INCLUDE_DIRS
        "${AXOLOTY_ZENOH_PICO_GENERATED_INCLUDE}"
        "${AXOLOTY_ZENOH_PICO_DIR}/include"
    PRIV_REQUIRES esp_driver_uart
)

target_compile_definitions(${COMPONENT_LIB} PRIVATE
    ZENOH_ESPIDF
    ZENOH_C_STANDARD=11
    Z_BUILD_LOG=0
)
