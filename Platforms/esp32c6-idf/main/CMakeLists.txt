# Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.
#
# Main component for the ESP32-C6 platform.
#
# One application, one transport, and this platform compile into a single
# Embedded Swift module. The application receives its outside operations
# through the seam this platform builds; the transport supplies the bounded
# carrier mechanics. Portable Core modules compile in place from the locked
# checkout as separate components.

include("${CMAKE_CURRENT_LIST_DIR}/../cmake/axoloty-source.cmake")

option(AXOLOTY_SWIFT_UNICODE_LINKER_PROBE
    "Compile a String-normalization probe to verify the Unicode linker setup"
    OFF
)

# The qualification build selects a carrier-scenario entry point instead of
# the shared smoke application entry point. It is off by default, so the shared
# smoke image keeps its own entry point. ESP-IDF re-expands component
# requirements in a sub-invocation that does not inherit -D cache variables,
# so read the environment as axoloty-source.cmake does, then normalize to a
# CMake boolean.
if(NOT DEFINED AXOLOTY_QUALIFICATION_CARRIER_SCENARIO OR
   "${AXOLOTY_QUALIFICATION_CARRIER_SCENARIO}" STREQUAL "")
    if(DEFINED ENV{AXOLOTY_QUALIFICATION_CARRIER_SCENARIO})
        set(AXOLOTY_QUALIFICATION_CARRIER_SCENARIO
            "$ENV{AXOLOTY_QUALIFICATION_CARRIER_SCENARIO}")
    endif()
endif()
if(AXOLOTY_QUALIFICATION_CARRIER_SCENARIO)
    set(AXOLOTY_QUALIFICATION_CARRIER_SCENARIO ON)
else()
    set(AXOLOTY_QUALIFICATION_CARRIER_SCENARIO OFF)
endif()

# ESP-IDF expands component requirements in a separate CMake sub-invocation
# that does not inherit -D cache variables, and this file is included during
# that pass. Fall back to the environment, exactly as axoloty-source.cmake
# does for the preparation report. Without this the axis paths are empty,
# which surfaces much later as a corpus generator failure rather than as a
# missing selection.
foreach(AXOLOTY_AXIS_VARIABLE AXOLOTY_APPLICATION_DIR AXOLOTY_TRANSPORT_DIR)
    if(NOT DEFINED ${AXOLOTY_AXIS_VARIABLE} OR "${${AXOLOTY_AXIS_VARIABLE}}" STREQUAL "")
        if(DEFINED ENV{${AXOLOTY_AXIS_VARIABLE}} AND NOT "$ENV{${AXOLOTY_AXIS_VARIABLE}}" STREQUAL "")
            set(${AXOLOTY_AXIS_VARIABLE} "$ENV{${AXOLOTY_AXIS_VARIABLE}}")
        endif()
    endif()
    if(NOT DEFINED ${AXOLOTY_AXIS_VARIABLE} OR "${${AXOLOTY_AXIS_VARIABLE}}" STREQUAL "")
        message(FATAL_ERROR
            "${AXOLOTY_AXIS_VARIABLE} is required; the profile selects it. Pass it with -D and export it, or run the build through Profiles/<name>/build.sh"
        )
    endif()
    if(NOT IS_DIRECTORY "${${AXOLOTY_AXIS_VARIABLE}}")
        message(FATAL_ERROR "${AXOLOTY_AXIS_VARIABLE} is not a directory: ${${AXOLOTY_AXIS_VARIABLE}}")
    endif()
endforeach()

set(AXOLOTY_APPLICATION_MAIN_DIR "${AXOLOTY_APPLICATION_DIR}/main")
set(AXOLOTY_TRANSPORT_MAIN_DIR "${AXOLOTY_TRANSPORT_DIR}/main")
get_filename_component(AXOLOTY_SELECTED_TRANSPORT_NAME "${AXOLOTY_TRANSPORT_DIR}" NAME)
if(NOT DEFINED AXOLOTY_REPOSITORY_ROOT OR "${AXOLOTY_REPOSITORY_ROOT}" STREQUAL "")
    if(DEFINED ENV{AXOLOTY_REPOSITORY_ROOT})
        set(AXOLOTY_REPOSITORY_ROOT "$ENV{AXOLOTY_REPOSITORY_ROOT}")
    endif()
endif()
if(NOT AXOLOTY_REPOSITORY_ROOT OR NOT IS_DIRECTORY "${AXOLOTY_REPOSITORY_ROOT}")
    message(FATAL_ERROR "AXOLOTY_REPOSITORY_ROOT must name the firmware repository root")
endif()
file(REAL_PATH "${AXOLOTY_REPOSITORY_ROOT}" AXOLOTY_REPOSITORY_ROOT_REAL)
if(NOT "${AXOLOTY_REPOSITORY_ROOT}" STREQUAL "${AXOLOTY_REPOSITORY_ROOT_REAL}")
    message(FATAL_ERROR "AXOLOTY_REPOSITORY_ROOT must be canonical")
endif()
if(NOT DEFINED AXOLOTY_PROFILE_DIR OR "${AXOLOTY_PROFILE_DIR}" STREQUAL "")
    if(DEFINED ENV{AXOLOTY_PROFILE_DIR})
        set(AXOLOTY_PROFILE_DIR "$ENV{AXOLOTY_PROFILE_DIR}")
    endif()
endif()
if(NOT AXOLOTY_PROFILE_DIR OR NOT IS_DIRECTORY "${AXOLOTY_PROFILE_DIR}")
    message(FATAL_ERROR "AXOLOTY_PROFILE_DIR must name the selected profile directory")
endif()
file(REAL_PATH "${AXOLOTY_PROFILE_DIR}" AXOLOTY_PROFILE_DIR_REAL)
if(NOT "${AXOLOTY_PROFILE_DIR}" STREQUAL "${AXOLOTY_PROFILE_DIR_REAL}")
    message(FATAL_ERROR "AXOLOTY_PROFILE_DIR must be canonical")
endif()
file(READ "${AXOLOTY_PROFILE_DIR}/profile.json" AXOLOTY_PROFILE_JSON)
string(JSON AXOLOTY_PROFILE_PLATFORM GET "${AXOLOTY_PROFILE_JSON}" platform)
set(AXOLOTY_PLATFORM_DIR "${AXOLOTY_REPOSITORY_ROOT}/Platforms/${AXOLOTY_PROFILE_PLATFORM}")
if(NOT IS_DIRECTORY "${AXOLOTY_PLATFORM_DIR}")
    message(FATAL_ERROR "selected platform directory is missing: ${AXOLOTY_PLATFORM_DIR}")
endif()
set(AXOLOTY_INTEROP_DIR "${AXOLOTY_REPOSITORY_ROOT}/Interop")

find_package(Python3 COMPONENTS Interpreter REQUIRED)
set(AXOLOTY_REQUIREMENTS_SWIFT "${CMAKE_CURRENT_BINARY_DIR}/ManifestRequirements.swift")
set(AXOLOTY_COMPOSITION_INPUTS
    "${AXOLOTY_PROFILE_DIR}/profile.json"
    "${AXOLOTY_APPLICATION_DIR}/app.json"
    "${AXOLOTY_PLATFORM_DIR}/platform.json"
    "${AXOLOTY_TRANSPORT_DIR}/transport.json"
    "${AXOLOTY_REPOSITORY_ROOT}/axoloty-core.lock.json"
    "${AXOLOTY_REPOSITORY_ROOT}/Tools/validate-composition.py"
    "${AXOLOTY_REPOSITORY_ROOT}/Tools/capability_catalog.py"
    "${AXOLOTY_REPOSITORY_ROOT}/Interop/axoloty_platform_v1.h"
    "${AXOLOTY_REPOSITORY_ROOT}/Interop/axoloty_carrier_v1.h"
)
foreach(AXOLOTY_COMPOSITION_INPUT IN LISTS AXOLOTY_COMPOSITION_INPUTS)
    if(NOT EXISTS "${AXOLOTY_COMPOSITION_INPUT}")
        message(FATAL_ERROR "composition input is missing: ${AXOLOTY_COMPOSITION_INPUT}")
    endif()
    set_property(DIRECTORY APPEND PROPERTY CMAKE_CONFIGURE_DEPENDS "${AXOLOTY_COMPOSITION_INPUT}")
endforeach()
execute_process(
    COMMAND "${Python3_EXECUTABLE}" "${AXOLOTY_REPOSITORY_ROOT}/Tools/validate-composition.py"
        --repo-root "${AXOLOTY_REPOSITORY_ROOT}"
        --profile "${AXOLOTY_PROFILE_DIR}/profile.json"
        --emit-requirements "${AXOLOTY_REQUIREMENTS_SWIFT}"
    RESULT_VARIABLE AXOLOTY_COMPOSITION_STATUS
    OUTPUT_VARIABLE AXOLOTY_COMPOSITION_OUTPUT
    ERROR_VARIABLE AXOLOTY_COMPOSITION_ERROR
)
if(NOT AXOLOTY_COMPOSITION_STATUS EQUAL 0)
    message(FATAL_ERROR "manifest composition validation/generation failed: ${AXOLOTY_COMPOSITION_ERROR}")
endif()
message(STATUS "${AXOLOTY_COMPOSITION_OUTPUT}Generated manifest requirements: ${AXOLOTY_REQUIREMENTS_SWIFT}")

set(AXOLOTY_APPLICATION_MANIFEST "${AXOLOTY_APPLICATION_DIR}/app.json")
if(NOT EXISTS "${AXOLOTY_APPLICATION_MANIFEST}")
    message(FATAL_ERROR "selected application has no app.json: ${AXOLOTY_APPLICATION_MANIFEST}")
endif()
file(READ "${AXOLOTY_APPLICATION_MANIFEST}" AXOLOTY_APPLICATION_JSON)
string(JSON AXOLOTY_APPLICATION_SOURCE_COUNT LENGTH "${AXOLOTY_APPLICATION_JSON}" sources)
if(AXOLOTY_APPLICATION_SOURCE_COUNT LESS 1)
    message(FATAL_ERROR "app.json must list at least one Swift source")
endif()
math(EXPR AXOLOTY_APPLICATION_SOURCE_LAST "${AXOLOTY_APPLICATION_SOURCE_COUNT} - 1")
set(AXOLOTY_APPLICATION_SWIFT_SOURCES)
foreach(AXOLOTY_SOURCE_INDEX RANGE ${AXOLOTY_APPLICATION_SOURCE_LAST})
    string(JSON AXOLOTY_APPLICATION_SOURCE GET
        "${AXOLOTY_APPLICATION_JSON}" sources ${AXOLOTY_SOURCE_INDEX})
    if(NOT AXOLOTY_APPLICATION_SOURCE MATCHES "[.]swift$")
        message(FATAL_ERROR "application manifest source is not Swift: ${AXOLOTY_APPLICATION_SOURCE}")
    endif()
    set(AXOLOTY_APPLICATION_SOURCE_PATH "${AXOLOTY_APPLICATION_DIR}/${AXOLOTY_APPLICATION_SOURCE}")
    if(NOT EXISTS "${AXOLOTY_APPLICATION_SOURCE_PATH}")
        message(FATAL_ERROR "application manifest source is missing: ${AXOLOTY_APPLICATION_SOURCE_PATH}")
    endif()
    list(APPEND AXOLOTY_APPLICATION_SWIFT_SOURCES "${AXOLOTY_APPLICATION_SOURCE_PATH}")
endforeach()

if(NOT DEFINED AXOLOTY_EMBEDDED_MACRO_PLUGIN OR "${AXOLOTY_EMBEDDED_MACRO_PLUGIN}" STREQUAL "")
    if(DEFINED ENV{AXOLOTY_EMBEDDED_MACRO_PLUGIN})
        set(AXOLOTY_EMBEDDED_MACRO_PLUGIN "$ENV{AXOLOTY_EMBEDDED_MACRO_PLUGIN}")
    endif()
endif()
if(NOT EXISTS "${AXOLOTY_EMBEDDED_MACRO_PLUGIN}")
    message(FATAL_ERROR "AXOLOTY_EMBEDDED_MACRO_PLUGIN is required; run Tools/build-embedded-macro.sh first")
endif()
if(IS_DIRECTORY "${AXOLOTY_EMBEDDED_MACRO_PLUGIN}")
    message(FATAL_ERROR "AXOLOTY_EMBEDDED_MACRO_PLUGIN must name the host executable")
endif()

# Only the Zenoh transport supplies a carrier-scenario device entry point. Fail
# closed when a profile asks for the qualification build and selects another
# transport, instead of building an image with no `app_main`.
if(AXOLOTY_QUALIFICATION_CARRIER_SCENARIO AND NOT AXOLOTY_SELECTED_TRANSPORT_NAME STREQUAL "zenoh-pico")
    message(FATAL_ERROR
        "AXOLOTY_QUALIFICATION_CARRIER_SCENARIO is set, but the selected transport is "
        "'${AXOLOTY_SELECTED_TRANSPORT_NAME}'; the carrier scenario is a zenoh-pico qualification build"
    )
endif()

# The transport axis supplies its carrier sources declaratively. The platform
# compiles exactly what the selected transport lists, so the profile's
# transport selection reaches the build without the platform naming a carrier.
set(AXOLOTY_TRANSPORT_SOURCES_FILE "${AXOLOTY_TRANSPORT_MAIN_DIR}/idf_sources.cmake")
if(NOT EXISTS "${AXOLOTY_TRANSPORT_SOURCES_FILE}")
    message(FATAL_ERROR
        "transport ${AXOLOTY_TRANSPORT_DIR} declares no main/idf_sources.cmake; "
        "it cannot be composed into the platform"
    )
endif()
include("${AXOLOTY_TRANSPORT_SOURCES_FILE}")

# A transport may contribute include directories from its own manifest, for a
# C seam it does not own, so this list is appended to rather than reset. The
# optional transport include directory is the same mechanism.
if(IS_DIRECTORY "${AXOLOTY_TRANSPORT_DIR}/include")
    list(APPEND AXOLOTY_TRANSPORT_INCLUDE_DIRS "${AXOLOTY_TRANSPORT_DIR}/include")
endif()

set(AXOLOTY_SWIFT_SOURCES
    ${AXOLOTY_APPLICATION_SWIFT_SOURCES}
    ${AXOLOTY_REQUIREMENTS_SWIFT}
    ${AXOLOTY_REPOSITORY_ROOT}/Sources/EmbeddedCapabilities/EmbeddedCapabilities.swift
    ${AXOLOTY_REPOSITORY_ROOT}/Sources/EmbeddedCapabilities/EmbeddedApplicationMacro.swift
    ${AXOLOTY_REPOSITORY_ROOT}/Sources/EmbeddedCapabilities/EmbeddedApplicationDefinition.swift
    ${AXOLOTY_REPOSITORY_ROOT}/Sources/EmbeddedCapabilities/EmbeddedApplicationEntryAdapter.swift
    ${AXOLOTY_REPOSITORY_ROOT}/Sources/EmbeddedCapabilities/EmbeddedRequirements.swift
    ${AXOLOTY_TRANSPORT_SWIFT_SOURCES}
)

# The qualification build supplies its own C entry point and must not also
# link the shared smoke entry point. The flag is read above and defaults off,
# so the normal image keeps `Esp32c6AppMain.c`.
set(AXOLOTY_PLATFORM_C_SOURCES
    "${CMAKE_CURRENT_LIST_DIR}/axoloty_platform_v1.c"
    "${CMAKE_CURRENT_LIST_DIR}/heap_trace_platform_adapter.c"
    "${AXOLOTY_INTEROP_DIR}/axoloty_application_entry_v1.c"
)
if(NOT AXOLOTY_QUALIFICATION_CARRIER_SCENARIO)
    list(APPEND AXOLOTY_PLATFORM_C_SOURCES
        "${CMAKE_CURRENT_LIST_DIR}/Esp32c6AppMain.c"
    )
endif()

set(AXOLOTY_CORPUS_SOURCE "${CMAKE_CURRENT_BINARY_DIR}/GeneratedCorpus.swift")
set(AXOLOTY_CORPUS_FIXTURE_DIR "${AXOLOTY_APPLICATION_DIR}/fixtures")
set(AXOLOTY_CORPUS_GENERATOR "${AXOLOTY_CORPUS_FIXTURE_DIR}/generate-embedded-corpus.mjs")
set(AXOLOTY_CORPUS_MANIFEST "${AXOLOTY_CORPUS_FIXTURE_DIR}/manifest.json")
set_property(DIRECTORY APPEND PROPERTY CMAKE_CONFIGURE_DEPENDS
    ${AXOLOTY_CORPUS_GENERATOR}
    ${AXOLOTY_CORPUS_MANIFEST}
    ${AXOLOTY_CORPUS_FIXTURE_DIR}/payloads/*.json
)
execute_process(
    COMMAND node
        ${AXOLOTY_CORPUS_GENERATOR}
        ${AXOLOTY_CORPUS_MANIFEST}
        ${AXOLOTY_CORPUS_SOURCE}
    RESULT_VARIABLE AXOLOTY_CORPUS_GENERATION_RESULT
)
if(NOT AXOLOTY_CORPUS_GENERATION_RESULT EQUAL 0)
    message(FATAL_ERROR "Failed to generate Embedded Swift corpus vectors")
endif()
list(APPEND AXOLOTY_SWIFT_SOURCES ${AXOLOTY_CORPUS_SOURCE})
if(AXOLOTY_SWIFT_UNICODE_LINKER_PROBE)
    list(APPEND AXOLOTY_SWIFT_SOURCES
        ${CMAKE_CURRENT_LIST_DIR}/UnicodeLinkerProbe.swift
    )
endif()

idf_component_register(
    SRCS
        "log_helper.c"
        "network_bootstrap.c"
        "runtime_identity.c"
        ${AXOLOTY_PLATFORM_C_SOURCES}
        ${AXOLOTY_TRANSPORT_C_SOURCES}
    PRIV_INCLUDE_DIRS "." "${CMAKE_CURRENT_BINARY_DIR}" "${AXOLOTY_INTEROP_DIR}"
        "${AXOLOTY_TRANSPORT_MAIN_DIR}"
        ${AXOLOTY_TRANSPORT_INCLUDE_DIRS}
    PRIV_REQUIRES
        idf_swift
        axoloty_wire
        axoloty_protocol
        axoloty_static_runtime
        axoloty_object_model
        axoloty_coaty_models
        esp_system
        esp_timer
        heap
        esp_rom
        freertos
        log
        esp_wifi
        esp_event
        esp_netif
        nvs_flash
        ${AXOLOTY_TRANSPORT_IDF_REQUIRES}
    LDFRAGMENTS "linker.lf"
)

# The config header is staged before CMake configures this copied project.
# These consumers use __has_include, so an object built while the header was
# absent cannot learn about it from its depfile. Make the staged header an
# explicit input to every selected translation unit that reads it. The staging
# helper refreshes only the header timestamp, so no tracked source is touched.
set(AXOLOTY_NETWORK_CONFIG_HEADER
    "${CMAKE_CURRENT_LIST_DIR}/axoloty_network_config.h"
)
set(AXOLOTY_NETWORK_CONFIG_CONSUMERS
    "${CMAKE_CURRENT_LIST_DIR}/network_bootstrap.c"
)
if(AXOLOTY_SELECTED_TRANSPORT_NAME STREQUAL "mqtt-espidf")
    list(APPEND AXOLOTY_NETWORK_CONFIG_CONSUMERS
        "${AXOLOTY_TRANSPORT_MAIN_DIR}/mqtt_carrier_espidf.c"
    )
elseif(AXOLOTY_SELECTED_TRANSPORT_NAME STREQUAL "zenoh-pico")
    list(APPEND AXOLOTY_NETWORK_CONFIG_CONSUMERS
        "${AXOLOTY_TRANSPORT_MAIN_DIR}/zenoh_endpoint.c"
    )
endif()
set_source_files_properties(${AXOLOTY_NETWORK_CONFIG_CONSUMERS}
    PROPERTIES OBJECT_DEPENDS "${AXOLOTY_NETWORK_CONFIG_HEADER}"
)

# The Zenoh transport's carrier is written against the prepared
# AxolotyZenohCore module. Order its publication and the Core-generated
# facade module map before the main Swift compile, but only for the profile
# that selected it: the component registers empty for every other profile.
# AXOLOTY_SELECTED_TRANSPORT_NAME is computed above, before the transport
# manifest is included.
set(AXOLOTY_MAIN_BRIDGING_HEADER "${CMAKE_CURRENT_LIST_DIR}/BridgingHeader.h")
if(AXOLOTY_SELECTED_TRANSPORT_NAME STREQUAL "zenoh-pico")
    add_dependencies(${COMPONENT_LIB} axoloty_zenoh_core_module_alias)
    get_filename_component(AXOLOTY_ZENOH_FACADE_MODULE_DIR
        "${AXOLOTY_ZENOH_FACADE_MODULE_MAP}" DIRECTORY
    )
    target_include_directories(${COMPONENT_LIB} PRIVATE
        "${AXOLOTY_ZENOH_FACADE_MODULE_DIR}"
    )
endif()

# Register the main Swift sources with the platform bridge. For Zenoh, the
# selected Core-generated facade module map is also a Clang input to the
# bridge's PCH and the subsequent Swift module imports.
idf_component_register_swift(
    ${COMPONENT_LIB}
    BRIDGING_HEADER ${AXOLOTY_MAIN_BRIDGING_HEADER}
    SRCS ${AXOLOTY_SWIFT_SOURCES}
)

target_compile_options(${COMPONENT_LIB} PRIVATE
    "$<$<COMPILE_LANGUAGE:Swift>:-load-plugin-executable>"
    "$<$<COMPILE_LANGUAGE:Swift>:${AXOLOTY_EMBEDDED_MACRO_PLUGIN}#EmbeddedApplicationMacroImplementation>"
)

# The carrier-scenario device source is guarded by this macro. It is defined
# for every build so the source compiles to nothing when the qualification
# entry point is not selected.
if(AXOLOTY_QUALIFICATION_CARRIER_SCENARIO)
    target_compile_definitions(${COMPONENT_LIB} PRIVATE
        AXOLOTY_QUALIFICATION_CARRIER_SCENARIO=1
    )
else()
    target_compile_definitions(${COMPONENT_LIB} PRIVATE
        AXOLOTY_QUALIFICATION_CARRIER_SCENARIO=0
    )
endif()

# `idf_component_register_swift` resets COMPILE_OPTIONS to its Embedded
# target defaults. Add the report-generated facade map afterwards so both the
# bridging-header PCH and the Swift frontend can resolve CAxolotyZenoh.
if(AXOLOTY_SELECTED_TRANSPORT_NAME STREQUAL "zenoh-pico")
    target_compile_options(${COMPONENT_LIB} PRIVATE
        "$<$<COMPILE_LANGUAGE:Swift>:-Xcc>"
        "$<$<COMPILE_LANGUAGE:Swift>:-fmodule-map-file=${AXOLOTY_ZENOH_FACADE_MODULE_MAP}>"
    )
endif()

# The application and the static model consumers import Core modules. Require
# each explicit module output before compiling any main Swift source so clean
# parallel builds cannot race module publication.
add_dependencies(${COMPONENT_LIB} axoloty_object_model_module_alias)
add_dependencies(${COMPONENT_LIB} axoloty_coaty_models_module_alias)
add_dependencies(${COMPONENT_LIB} axoloty_protocol_module_alias)
add_dependencies(${COMPONENT_LIB} axoloty_static_runtime_module_alias)

# StaticDeviceAgent consumes the noncopyable processor from the protocol
# component. Explicitly enable the same lifetime feature for the application
# consumer; otherwise the standalone protocol check would not prove the actual
# ESP-IDF consumer build.
target_compile_options(${COMPONENT_LIB} PRIVATE
    "$<$<COMPILE_LANGUAGE:Swift>:-enable-experimental-feature>"
    "$<$<COMPILE_LANGUAGE:Swift>:Lifetimes>"
)

# String-backed validation paths use normalization data shipped as a separate
# Embedded Swift archive. linker.lf maps its GOT/PLT input sections into
# ESP-IDF's dram0_data output before the generic /DISCARD/ rule.
target_link_libraries(${COMPONENT_LIB} PUBLIC
    /usr/lib/swift/embedded/riscv32-none-none-eabi/libswiftUnicodeDataTables.a
)
if(AXOLOTY_SWIFT_UNICODE_LINKER_PROBE)
    target_link_options(${COMPONENT_LIB} PUBLIC
        -u axoloty_unicode_linker_probe
    )
endif()
