# Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.
#
# Top-level ESP-IDF project for the ESP32-C6 platform.
#
# The profile does not build this file directly: `Profiles/<name>/build.sh`
# selects one application, one transport, and this platform from `profile.json`
# and passes the three directories plus the Core preparation report. The build
# reaches Core only through that report, never by searching a parent directory.

cmake_minimum_required(VERSION 3.29)

foreach(required_variable IN ITEMS
    AXOLOTY_APPLICATION_DIR
    AXOLOTY_TRANSPORT_DIR
    AXOLOTY_PREPARATION_REPORT
)
    if(NOT DEFINED ${required_variable} OR "${${required_variable}}" STREQUAL "")
        message(FATAL_ERROR
            "${required_variable} is required; build through Profiles/<name>/build.sh"
        )
    endif()
    if(NOT IS_ABSOLUTE "${${required_variable}}")
        message(FATAL_ERROR "${required_variable} must be an absolute path")
    endif()
endforeach()

foreach(required_directory IN ITEMS
    AXOLOTY_APPLICATION_DIR
    AXOLOTY_TRANSPORT_DIR
)
    if(NOT IS_DIRECTORY "${${required_directory}}")
        message(FATAL_ERROR "${required_directory} is not a directory: ${${required_directory}}")
    endif()
endforeach()

if(NOT EXISTS "${AXOLOTY_PREPARATION_REPORT}")
    message(FATAL_ERROR "Core preparation report is missing: ${AXOLOTY_PREPARATION_REPORT}")
endif()

include($ENV{IDF_PATH}/tools/cmake/project.cmake)
project(axoloty-swift)

# ESP-IDF v5.4 discards .got/.got.plt in its generated sections.ld (the rule
# is explicitly marked TODO: GCC-382). Swift's prebuilt Unicode archive uses
# R_RISCV_CALL_PLT relocations, so GNU ld synthesizes .got.plt after ldgen's
# archive selectors have been applied. Patch only the generated build copy,
# immediately before the ELF link, and fail closed if the pinned template no
# longer matches.
idf_build_get_property(project_elf EXECUTABLE)
add_custom_command(TARGET ${project_elf} PRE_LINK
    COMMAND ${CMAKE_COMMAND}
        -DLINKER_SCRIPT=${CMAKE_BINARY_DIR}/esp-idf/esp_system/ld/sections.ld
        -P ${CMAKE_CURRENT_LIST_DIR}/main/patch-swift-got.cmake
    VERBATIM
)
