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

set(AXOLOTY_APPLICATION_MAIN_DIR "${AXOLOTY_APPLICATION_DIR}/main")
set(AXOLOTY_TRANSPORT_MAIN_DIR "${AXOLOTY_TRANSPORT_DIR}/main")

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

set(AXOLOTY_SWIFT_SOURCES
    ${AXOLOTY_APPLICATION_MAIN_DIR}/Main.swift
    ${AXOLOTY_APPLICATION_MAIN_DIR}/StaticDeviceAgent.swift
    ${AXOLOTY_APPLICATION_MAIN_DIR}/DeviceSmokeSeam.swift
    ${AXOLOTY_APPLICATION_MAIN_DIR}/ProtocolModuleConsumer.swift
    ${AXOLOTY_APPLICATION_MAIN_DIR}/ObjectModelModuleConsumer.swift
    ${AXOLOTY_APPLICATION_MAIN_DIR}/CoatyModelsModuleConsumer.swift
    ${AXOLOTY_TRANSPORT_SWIFT_SOURCES}
    ${CMAKE_CURRENT_LIST_DIR}/Esp32c6SmokeSeam.swift
    ${CMAKE_CURRENT_LIST_DIR}/Esp32c6AppMain.swift
)

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
        ${AXOLOTY_TRANSPORT_C_SOURCES}
    PRIV_INCLUDE_DIRS "." "${CMAKE_CURRENT_BINARY_DIR}" "${AXOLOTY_TRANSPORT_MAIN_DIR}"
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
        mqtt
        ${AXOLOTY_TRANSPORT_IDF_REQUIRES}
    LDFRAGMENTS "linker.lf"
)

idf_component_register_swift(
    ${COMPONENT_LIB}
    BRIDGING_HEADER ${CMAKE_CURRENT_LIST_DIR}/BridgingHeader.h
    SRCS ${AXOLOTY_SWIFT_SOURCES}
)

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
