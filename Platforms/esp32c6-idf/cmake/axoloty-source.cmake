# Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.
#
# Read the Core-owned preparation report written by Tools/prepare-core.sh.
#
# Core checkout discovery, SwiftPM preparation, and contract validation belong
# to the Core tool. This file only translates the versioned report into the
# CMake variables used by the ESP-IDF components. It never searches a parent
# directory and never reads a Core build directory.

# A relative path escapes its root when its first segment is the parent
# directory.
#
# The prefix is a bracket expression, `[.][.]`, and not the `\.` of the pattern
# it replaces. `\.` is not a valid escape sequence in a CMake string, and CMake
# says so: the ESP-IDF requirements pass evaluates this file with policy CMP0010
# unset and reported "Invalid escape sequence \." against each of the four
# checks that used it, once per evaluation. In CMake 3.29 the pattern still
# happened to match what it should, but its interpretation is policy-governed
# and a policy change turns it into a hard error, in a check whose only job is
# to reject traversal. The bracket expression is two literal dots with no escape
# to interpret, so it carries no policy and no diagnostic, and it still does not
# match a directory whose name merely starts with dots, such as `...`.
#
# Defined before the include guard because the four checks live in whichever
# directory scope loaded this file first, and a variable set only inside the
# guard would be missing in the rest of the project.
set(AXOLOTY_PARENT_DIR_PREFIX "^[.][.]/")

if(AXOLOTY_PREPARATION_REPORT_LOADED)
    return()
endif()
set(AXOLOTY_PREPARATION_REPORT_LOADED TRUE)

if(NOT DEFINED AXOLOTY_PREPARATION_REPORT OR
   "${AXOLOTY_PREPARATION_REPORT}" STREQUAL "")
    if(DEFINED ENV{AXOLOTY_PREPARATION_REPORT})
        set(AXOLOTY_PREPARATION_REPORT "$ENV{AXOLOTY_PREPARATION_REPORT}")
    endif()
endif()

if(NOT DEFINED AXOLOTY_PREPARATION_REPORT OR
   "${AXOLOTY_PREPARATION_REPORT}" STREQUAL "")
    message(FATAL_ERROR
        "AXOLOTY_PREPARATION_REPORT is required; run Tools/prepare-core.sh first"
    )
endif()

if(NOT IS_ABSOLUTE "${AXOLOTY_PREPARATION_REPORT}" OR
   NOT EXISTS "${AXOLOTY_PREPARATION_REPORT}")
    message(FATAL_ERROR
        "AXOLOTY_PREPARATION_REPORT must be an existing absolute file: ${AXOLOTY_PREPARATION_REPORT}"
    )
endif()
file(REAL_PATH "${AXOLOTY_PREPARATION_REPORT}" AXOLOTY_PREPARATION_REPORT_REAL)
if(NOT "${AXOLOTY_PREPARATION_REPORT}" STREQUAL "${AXOLOTY_PREPARATION_REPORT_REAL}")
    message(FATAL_ERROR "AXOLOTY_PREPARATION_REPORT must be canonical")
endif()
file(READ "${AXOLOTY_PREPARATION_REPORT}" AXOLOTY_PREPARATION_JSON)

string(JSON AXOLOTY_PREPARATION_SCHEMA GET "${AXOLOTY_PREPARATION_JSON}" schemaVersion)
if(NOT AXOLOTY_PREPARATION_SCHEMA EQUAL 1)
    message(FATAL_ERROR "unsupported Core preparation schema: ${AXOLOTY_PREPARATION_SCHEMA}")
endif()
string(JSON AXOLOTY_PREPARATION_STATUS GET "${AXOLOTY_PREPARATION_JSON}" status)
if(NOT AXOLOTY_PREPARATION_STATUS STREQUAL "prepared")
    message(FATAL_ERROR "Core preparation did not pass: ${AXOLOTY_PREPARATION_STATUS}")
endif()

string(JSON AXOLOTY_SOURCE_DIR GET "${AXOLOTY_PREPARATION_JSON}" core sourceDir)
string(JSON AXOLOTY_CORE_SHA GET "${AXOLOTY_PREPARATION_JSON}" core sha)
string(JSON AXOLOTY_CORE_DIRTY_VALUE GET "${AXOLOTY_PREPARATION_JSON}" core dirty)
if(NOT IS_ABSOLUTE "${AXOLOTY_SOURCE_DIR}" OR NOT IS_DIRECTORY "${AXOLOTY_SOURCE_DIR}")
    message(FATAL_ERROR "Core sourceDir in the preparation report is not a directory")
endif()
file(REAL_PATH "${AXOLOTY_SOURCE_DIR}" AXOLOTY_SOURCE_DIR_REAL)
if(NOT "${AXOLOTY_SOURCE_DIR}" STREQUAL "${AXOLOTY_SOURCE_DIR_REAL}")
    message(FATAL_ERROR "Core sourceDir in the preparation report must be canonical")
endif()
string(LENGTH "${AXOLOTY_CORE_SHA}" AXOLOTY_CORE_SHA_LENGTH)
if(NOT AXOLOTY_CORE_SHA_LENGTH EQUAL 40 OR
   NOT AXOLOTY_CORE_SHA MATCHES "^[0-9a-fA-F]+$")
    message(FATAL_ERROR "Core sha in the preparation report is invalid")
endif()
if(AXOLOTY_CORE_DIRTY_VALUE STREQUAL "true" OR
   AXOLOTY_CORE_DIRTY_VALUE STREQUAL "ON" OR
   AXOLOTY_CORE_DIRTY_VALUE STREQUAL "1")
    set(AXOLOTY_CORE_DIRTY 1)
else()
    set(AXOLOTY_CORE_DIRTY 0)
endif()

# A caller may select the Core checkout in the environment. The report remains
# authoritative, but this check catches a stale or mismatched environment
# before CMake starts compiling firmware.
if(DEFINED ENV{AXOLOTY_SOURCE_DIR} AND NOT "$ENV{AXOLOTY_SOURCE_DIR}" STREQUAL "")
    file(REAL_PATH "$ENV{AXOLOTY_SOURCE_DIR}" AXOLOTY_SELECTED_SOURCE_DIR)
    if(NOT "${AXOLOTY_SELECTED_SOURCE_DIR}" STREQUAL "${AXOLOTY_SOURCE_DIR}")
        message(FATAL_ERROR "AXOLOTY_SOURCE_DIR disagrees with the preparation report")
    endif()
endif()

string(JSON AXOLOTY_PACKAGE_COUNT LENGTH "${AXOLOTY_PREPARATION_JSON}" portablePackages)
math(EXPR AXOLOTY_PACKAGE_LAST "${AXOLOTY_PACKAGE_COUNT} - 1")
foreach(AXOLOTY_PACKAGE_INDEX RANGE ${AXOLOTY_PACKAGE_LAST})
    string(JSON AXOLOTY_PACKAGE_NAME GET
        "${AXOLOTY_PREPARATION_JSON}" portablePackages ${AXOLOTY_PACKAGE_INDEX} name
    )
    string(JSON AXOLOTY_PACKAGE_SOURCE GET
        "${AXOLOTY_PREPARATION_JSON}" portablePackages ${AXOLOTY_PACKAGE_INDEX} sourcePath
    )
    if(AXOLOTY_PACKAGE_NAME STREQUAL "AxolotyWire")
        set(AXOLOTY_WIRE_SOURCE_DIR "${AXOLOTY_PACKAGE_SOURCE}")
    elseif(AXOLOTY_PACKAGE_NAME STREQUAL "AxolotyObjectModel")
        set(AXOLOTY_OBJECT_MODEL_SOURCE_DIR "${AXOLOTY_PACKAGE_SOURCE}")
    elseif(AXOLOTY_PACKAGE_NAME STREQUAL "AxolotyProtocol")
        set(AXOLOTY_PROTOCOL_SOURCE_DIR "${AXOLOTY_PACKAGE_SOURCE}")
    elseif(AXOLOTY_PACKAGE_NAME STREQUAL "AxolotyCoatyModels")
        set(AXOLOTY_COATY_MODELS_SOURCE_DIR "${AXOLOTY_PACKAGE_SOURCE}")
    elseif(AXOLOTY_PACKAGE_NAME STREQUAL "AxolotyStaticRuntime")
        set(AXOLOTY_STATIC_RUNTIME_SOURCE_DIR "${AXOLOTY_PACKAGE_SOURCE}")
    endif()
endforeach()

foreach(AXOLOTY_PACKAGE_SOURCE_DIR IN ITEMS
    AXOLOTY_WIRE_SOURCE_DIR
    AXOLOTY_OBJECT_MODEL_SOURCE_DIR
    AXOLOTY_PROTOCOL_SOURCE_DIR
    AXOLOTY_COATY_MODELS_SOURCE_DIR
    AXOLOTY_STATIC_RUNTIME_SOURCE_DIR
)
    if(NOT DEFINED ${AXOLOTY_PACKAGE_SOURCE_DIR} OR
       NOT IS_DIRECTORY "${${AXOLOTY_PACKAGE_SOURCE_DIR}}")
        message(FATAL_ERROR "preparation report is missing ${AXOLOTY_PACKAGE_SOURCE_DIR}")
    endif()
    file(REAL_PATH "${${AXOLOTY_PACKAGE_SOURCE_DIR}}" AXOLOTY_RESOLVED_PACKAGE_SOURCE)
    if(NOT "${${AXOLOTY_PACKAGE_SOURCE_DIR}}" STREQUAL "${AXOLOTY_RESOLVED_PACKAGE_SOURCE}")
        message(FATAL_ERROR "${AXOLOTY_PACKAGE_SOURCE_DIR} must be canonical")
    endif()
    file(RELATIVE_PATH AXOLOTY_PACKAGE_RELATIVE
        "${AXOLOTY_SOURCE_DIR}" "${AXOLOTY_RESOLVED_PACKAGE_SOURCE}"
    )
    if(IS_ABSOLUTE "${AXOLOTY_PACKAGE_RELATIVE}" OR
       "${AXOLOTY_PACKAGE_RELATIVE}" STREQUAL ".." OR
       "${AXOLOTY_PACKAGE_RELATIVE}" MATCHES "${AXOLOTY_PARENT_DIR_PREFIX}")
        message(FATAL_ERROR "${AXOLOTY_PACKAGE_SOURCE_DIR} escapes the Core checkout")
    endif()
endforeach()

# The Axoloty Zenoh consumer artifacts are a Core-owned contract: the C facade
# ABI the `zenoh-pico` backend implements, the portable `AxolotyZenohCore` Swift
# module that imports it, and the generated module map that binds the two. Core
# publishes all of it in the preparation report under `zenohCore`
# (phynics/axoloty#956, phynics/axoloty#974), with a SHA-256 for the header.
#
# The report is the only channel. This resolver never guesses a Core-relative
# path: a firmware file that hardcoded one would couple to Core's private
# package layout, which is exactly what the repository split had to disprove.
# A report without `zenohCore` therefore yields no Zenoh variables at all, and
# only a profile that selected the Zenoh transport fails -- because an ESP-IDF
# requirements pass walks this file for every profile and a transport's contract
# must not become the build's contract (see docs/container-builds.md).
foreach(AXOLOTY_ZENOH_VARIABLE IN ITEMS
    AXOLOTY_ZENOH_MODULE
    AXOLOTY_ZENOH_CORE_SOURCE_DIR
    AXOLOTY_ZENOH_FACADE_MODULE
    AXOLOTY_ZENOH_FACADE_HEADER
    AXOLOTY_ZENOH_FACADE_HEADER_SHA256
    AXOLOTY_ZENOH_FACADE_INCLUDE_DIR
    AXOLOTY_ZENOH_FACADE_MODULE_MAP
)
    unset(${AXOLOTY_ZENOH_VARIABLE})
endforeach()

string(JSON AXOLOTY_ZENOH_REPORTED_MODULE ERROR_VARIABLE AXOLOTY_ZENOH_ABSENT
    GET "${AXOLOTY_PREPARATION_JSON}" zenohCore module
)
if(NOT AXOLOTY_ZENOH_ABSENT)
    set(AXOLOTY_ZENOH_MODULE "${AXOLOTY_ZENOH_REPORTED_MODULE}")
    string(JSON AXOLOTY_ZENOH_CORE_SOURCE_DIR GET
        "${AXOLOTY_PREPARATION_JSON}" zenohCore sourceDir
    )
    string(JSON AXOLOTY_ZENOH_FACADE_MODULE GET
        "${AXOLOTY_PREPARATION_JSON}" zenohCore facadeModule
    )
    string(JSON AXOLOTY_ZENOH_FACADE_HEADER GET
        "${AXOLOTY_PREPARATION_JSON}" zenohCore facadeHeader
    )
    string(JSON AXOLOTY_ZENOH_FACADE_HEADER_SHA256 GET
        "${AXOLOTY_PREPARATION_JSON}" zenohCore facadeHeaderSHA256
    )
    string(JSON AXOLOTY_ZENOH_FACADE_MODULE_MAP GET
        "${AXOLOTY_PREPARATION_JSON}" zenohCore moduleMap
    )

    # Both Core-side paths must be absolute, canonical, present, and inside the
    # Core checkout the report names. The generated module map must be
    # canonical and inside caller-owned scratch. A report that says otherwise
    # is rejected, not repaired.
    foreach(AXOLOTY_ZENOH_REPORT_PATH IN ITEMS
        "${AXOLOTY_ZENOH_CORE_SOURCE_DIR}"
        "${AXOLOTY_ZENOH_FACADE_HEADER}"
    )
        if(NOT IS_ABSOLUTE "${AXOLOTY_ZENOH_REPORT_PATH}")
            message(FATAL_ERROR
                "the Core preparation report names a non-absolute Zenoh path: ${AXOLOTY_ZENOH_REPORT_PATH}"
            )
        endif()
        if(NOT EXISTS "${AXOLOTY_ZENOH_REPORT_PATH}")
            message(FATAL_ERROR
                "the Core preparation report names a Zenoh path that does not exist: ${AXOLOTY_ZENOH_REPORT_PATH}"
            )
        endif()
        file(REAL_PATH "${AXOLOTY_ZENOH_REPORT_PATH}" AXOLOTY_ZENOH_REPORT_PATH_REAL)
        if(NOT "${AXOLOTY_ZENOH_REPORT_PATH}" STREQUAL "${AXOLOTY_ZENOH_REPORT_PATH_REAL}")
            message(FATAL_ERROR
                "the Core preparation report names a non-canonical Zenoh path: ${AXOLOTY_ZENOH_REPORT_PATH}"
            )
        endif()
        file(RELATIVE_PATH AXOLOTY_ZENOH_REPORT_RELATIVE
            "${AXOLOTY_SOURCE_DIR}" "${AXOLOTY_ZENOH_REPORT_PATH}"
        )
        if(IS_ABSOLUTE "${AXOLOTY_ZENOH_REPORT_RELATIVE}" OR
           "${AXOLOTY_ZENOH_REPORT_RELATIVE}" STREQUAL ".." OR
           "${AXOLOTY_ZENOH_REPORT_RELATIVE}" MATCHES "${AXOLOTY_PARENT_DIR_PREFIX}")
            message(FATAL_ERROR
                "the Core preparation report names a Zenoh path outside the Core checkout: ${AXOLOTY_ZENOH_REPORT_PATH}"
            )
        endif()
    endforeach()
    if(NOT IS_DIRECTORY "${AXOLOTY_ZENOH_CORE_SOURCE_DIR}")
        message(FATAL_ERROR "the reported AxolotyZenohCore sourceDir is not a directory")
    endif()
    if(IS_DIRECTORY "${AXOLOTY_ZENOH_FACADE_HEADER}")
        message(FATAL_ERROR "the reported Axoloty Zenoh facade header is not a file")
    endif()

    if(NOT IS_ABSOLUTE "${AXOLOTY_ZENOH_FACADE_MODULE_MAP}" OR
       NOT EXISTS "${AXOLOTY_ZENOH_FACADE_MODULE_MAP}")
        message(FATAL_ERROR
            "the Core preparation report does not name a generated Zenoh module map"
        )
    endif()
    if(IS_DIRECTORY "${AXOLOTY_ZENOH_FACADE_MODULE_MAP}")
        message(FATAL_ERROR "the reported Zenoh module map is a directory, not a file")
    endif()
    # Canonicality is checked against the value the report named. Resolving into
    # the same variable would compare the resolved path with itself and accept
    # anything, which is the one thing this check exists to catch.
    file(REAL_PATH "${AXOLOTY_ZENOH_FACADE_MODULE_MAP}" AXOLOTY_ZENOH_FACADE_MODULE_MAP_REAL)
    if(NOT "${AXOLOTY_ZENOH_FACADE_MODULE_MAP}" STREQUAL "${AXOLOTY_ZENOH_FACADE_MODULE_MAP_REAL}")
        message(FATAL_ERROR "the reported Zenoh module map must be canonical")
    endif()
    string(JSON AXOLOTY_ZENOH_SCRATCH_DIR GET
        "${AXOLOTY_PREPARATION_JSON}" staticRuntimeMacro scratchDir
    )
    if(NOT IS_ABSOLUTE "${AXOLOTY_ZENOH_SCRATCH_DIR}" OR
       NOT IS_DIRECTORY "${AXOLOTY_ZENOH_SCRATCH_DIR}")
        message(FATAL_ERROR "the Core preparation report scratchDir is not a directory")
    endif()
    file(REAL_PATH "${AXOLOTY_ZENOH_SCRATCH_DIR}" AXOLOTY_ZENOH_SCRATCH_DIR_REAL)
    if(NOT "${AXOLOTY_ZENOH_SCRATCH_DIR}" STREQUAL "${AXOLOTY_ZENOH_SCRATCH_DIR_REAL}")
        message(FATAL_ERROR "the Core preparation report scratchDir must be canonical")
    endif()
    file(RELATIVE_PATH AXOLOTY_ZENOH_MODULE_MAP_RELATIVE
        "${AXOLOTY_ZENOH_SCRATCH_DIR}" "${AXOLOTY_ZENOH_FACADE_MODULE_MAP}"
    )
    if(IS_ABSOLUTE "${AXOLOTY_ZENOH_MODULE_MAP_RELATIVE}" OR
       "${AXOLOTY_ZENOH_MODULE_MAP_RELATIVE}" STREQUAL ".." OR
       "${AXOLOTY_ZENOH_MODULE_MAP_RELATIVE}" MATCHES "${AXOLOTY_PARENT_DIR_PREFIX}")
        message(FATAL_ERROR "the reported Zenoh module map escapes caller-owned scratch")
    endif()

    # The header digest identifies the exact C declarations this build compiles
    # against. It is checked, not trusted.
    string(LENGTH "${AXOLOTY_ZENOH_FACADE_HEADER_SHA256}" AXOLOTY_ZENOH_FACADE_HEADER_SHA256_LENGTH)
    if(NOT AXOLOTY_ZENOH_FACADE_HEADER_SHA256_LENGTH EQUAL 64 OR
       NOT AXOLOTY_ZENOH_FACADE_HEADER_SHA256 MATCHES "^[0-9a-f]+$")
        message(FATAL_ERROR
            "the reported Axoloty Zenoh facade header SHA-256 is not 64 lowercase hexadecimal characters"
        )
    endif()
    file(SHA256 "${AXOLOTY_ZENOH_FACADE_HEADER}" AXOLOTY_ZENOH_FACADE_HEADER_ACTUAL_SHA256)
    if(NOT AXOLOTY_ZENOH_FACADE_HEADER_ACTUAL_SHA256 STREQUAL "${AXOLOTY_ZENOH_FACADE_HEADER_SHA256}")
        message(FATAL_ERROR
            "the Axoloty Zenoh facade header does not match the SHA-256 the preparation report names"
        )
    endif()

    get_filename_component(AXOLOTY_ZENOH_FACADE_INCLUDE_DIR
        "${AXOLOTY_ZENOH_FACADE_HEADER}" DIRECTORY
    )
endif()

string(JSON AXOLOTY_JSON_CORE_SOURCE_DIR GET
    "${AXOLOTY_PREPARATION_JSON}" jsonCore sourceDir
)
string(JSON AXOLOTY_STATIC_RUNTIME_MACRO_TOOL GET
    "${AXOLOTY_PREPARATION_JSON}" staticRuntimeMacro executable
)
string(JSON AXOLOTY_STATIC_RUNTIME_MACRO_SCRATCH_DIR GET
    "${AXOLOTY_PREPARATION_JSON}" staticRuntimeMacro scratchDir
)
foreach(AXOLOTY_SCRATCH_VALUE IN ITEMS
    AXOLOTY_JSON_CORE_SOURCE_DIR
    AXOLOTY_STATIC_RUNTIME_MACRO_SCRATCH_DIR
)
    if(NOT IS_ABSOLUTE "${${AXOLOTY_SCRATCH_VALUE}}" OR
       NOT IS_DIRECTORY "${${AXOLOTY_SCRATCH_VALUE}}")
        message(FATAL_ERROR "${AXOLOTY_SCRATCH_VALUE} from the preparation report is not a directory")
    endif()
    file(REAL_PATH "${${AXOLOTY_SCRATCH_VALUE}}" AXOLOTY_SCRATCH_REAL)
    if(NOT "${${AXOLOTY_SCRATCH_VALUE}}" STREQUAL "${AXOLOTY_SCRATCH_REAL}")
        message(FATAL_ERROR "${AXOLOTY_SCRATCH_VALUE} must be canonical")
    endif()
endforeach()
if(NOT IS_ABSOLUTE "${AXOLOTY_STATIC_RUNTIME_MACRO_TOOL}" OR
   NOT EXISTS "${AXOLOTY_STATIC_RUNTIME_MACRO_TOOL}" OR
   IS_DIRECTORY "${AXOLOTY_STATIC_RUNTIME_MACRO_TOOL}")
    message(FATAL_ERROR "static-runtime macro executable is missing")
endif()
# Executability is a second test because `IS_EXECUTABLE` is not an `if()`
# operator before CMake 3.29, and CMake treats an unknown operator as a hard
# error rather than as a false condition:
#
#   CMake Error at axoloty-source.cmake:316 (if):
#     if given arguments:
#       "NOT" "IS_ABSOLUTE" "..." "OR" "NOT" "EXISTS" "..." "OR"
#       "NOT" "IS_EXECUTABLE" "..."
#     Unknown arguments specified
#
# ESP-IDF accepts CMake 3.16 and CI provides 3.22, so that error was reached on
# every configure there, not only in the check that found it. `if()` reads its
# condition when it runs, so guarding the call is enough: the operator is never
# evaluated on a CMake that would refuse it.
#
# A CMake older than 3.29 therefore checks that the tool exists, is absolute,
# is canonical and is contained, and does not check that it is executable. That
# weaker state is stated rather than hidden: the variable below is FALSE on
# those versions, so a caller can report it, and it is a fact the
# path-escape check prints on every run.
set(AXOLOTY_STATIC_RUNTIME_MACRO_EXECUTABILITY_CHECKED FALSE)
if(NOT CMAKE_VERSION VERSION_LESS 3.29)
    if(NOT IS_EXECUTABLE "${AXOLOTY_STATIC_RUNTIME_MACRO_TOOL}")
        message(FATAL_ERROR "static-runtime macro executable is not executable")
    endif()
    set(AXOLOTY_STATIC_RUNTIME_MACRO_EXECUTABILITY_CHECKED TRUE)
endif()
file(REAL_PATH "${AXOLOTY_STATIC_RUNTIME_MACRO_TOOL}" AXOLOTY_MACRO_REAL)
if(NOT "${AXOLOTY_STATIC_RUNTIME_MACRO_TOOL}" STREQUAL "${AXOLOTY_MACRO_REAL}")
    message(FATAL_ERROR "static-runtime macro executable must be canonical")
endif()
file(RELATIVE_PATH AXOLOTY_MACRO_RELATIVE
    "${AXOLOTY_STATIC_RUNTIME_MACRO_SCRATCH_DIR}"
    "${AXOLOTY_STATIC_RUNTIME_MACRO_TOOL}"
)
if(IS_ABSOLUTE "${AXOLOTY_MACRO_RELATIVE}" OR
   "${AXOLOTY_MACRO_RELATIVE}" STREQUAL ".." OR
   "${AXOLOTY_MACRO_RELATIVE}" MATCHES "${AXOLOTY_PARENT_DIR_PREFIX}")
    message(FATAL_ERROR "static-runtime macro executable escapes caller scratch")
endif()
