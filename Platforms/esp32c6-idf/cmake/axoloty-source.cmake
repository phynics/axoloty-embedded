# Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.
#
# Keep the historical ESP-IDF include path available to existing components.
# The report decoder is SDK-neutral and lives under Platforms/common so other
# SDK adapters can consume the same prepared report without an IDF include.
# Firmware builds copy this SDK subtree into caller scratch. The repository
# input survives ESP-IDF's separate requirements pass through the environment.
if(DEFINED AXOLOTY_REPOSITORY_ROOT AND NOT AXOLOTY_REPOSITORY_ROOT STREQUAL "")
    set(AXOLOTY_COMMON_CORE_HELPER
        "${AXOLOTY_REPOSITORY_ROOT}/Platforms/common/axoloty-core.cmake")
elseif(DEFINED ENV{AXOLOTY_REPOSITORY_ROOT} AND
       NOT "$ENV{AXOLOTY_REPOSITORY_ROOT}" STREQUAL "")
    set(AXOLOTY_COMMON_CORE_HELPER
        "$ENV{AXOLOTY_REPOSITORY_ROOT}/Platforms/common/axoloty-core.cmake")
else()
    # Keep direct includes from the source tree compatible with existing users.
    set(AXOLOTY_COMMON_CORE_HELPER
        "${CMAKE_CURRENT_LIST_DIR}/../../common/axoloty-core.cmake")
endif()
if(NOT EXISTS "${AXOLOTY_COMMON_CORE_HELPER}")
    message(FATAL_ERROR
        "Core helper is missing; set AXOLOTY_REPOSITORY_ROOT to the firmware repository")
endif()
include("${AXOLOTY_COMMON_CORE_HELPER}")
unset(AXOLOTY_COMMON_CORE_HELPER)
