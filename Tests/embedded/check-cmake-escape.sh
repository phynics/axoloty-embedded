#!/bin/sh
# Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

# Proves the parent-directory escape checks in
# Platforms/esp32c6-idf/cmake/axoloty-source.cmake actually fire.
#
# Those checks compared a relative path against "^\\.\\./". `\.` is not a valid
# escape sequence in a CMake string: in the ESP-IDF requirements pass, where the
# policy is unset, CMake reported "Invalid escape sequence \." and "Policy
# CMP0010 is not set" against each of the four sites, once per evaluation. In
# CMake 3.29 the pattern still matched what it should, so this is a diagnostic
# and a policy dependency rather than a proven traversal hole -- but a check that
# rejects paths on a policy-governed pattern is one policy change away from being
# a hard configure error.
#
# So this file loads the real resolver with real CMake, in script mode like the
# requirements pass, and observes three things: that no escape or policy
# diagnostic is emitted, that a real traversal is rejected, and that a directory
# whose name merely starts with dots is not.
#
# The pattern under test is the one the resolver defines. Nothing here
# reimplements the rule, and the escapes are produced by file(RELATIVE_PATH)
# exactly as in the build.
#
# Cases, all against a real prepared report with one field moved:
#
#   valid              every reported path where the report names it: accepted
#   dots-directory     a module map under a `...` directory inside caller
#                      scratch: accepted, because `[.][.]` is two literal dots
#                      and a longer run of dots is not an escape
#   parent-traversal   a module map one level above caller scratch: rejected
#   sibling-prefix     a module map under a directory whose name starts with the
#                      scratch path: rejected, because containment is not a
#                      prefix test
#   no-cmp0010         none of the runs emits an escape or policy warning
#
# Exit status: 0 passed, 1 failed, 69 cmake, python3, or the Core report is absent.

set -eu

script_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
repo_root=$(CDPATH='' cd -- "$script_dir/../.." && pwd)
resolver="$repo_root/Platforms/esp32c6-idf/cmake/axoloty-source.cmake"

for tool in cmake python3; do
    command -v "$tool" >/dev/null 2>&1 || {
        echo "check-cmake-escape: $tool is required" >&2
        exit 69
    }
done

scratch=${AXOLOTY_SCRATCH:-"$repo_root/.axoloty"}
report=${AXOLOTY_PREPARATION_REPORT:-"$scratch/core-preparation.json"}
if [ ! -f "$report" ]; then
    if ! "$repo_root/Tools/prepare-core.sh" >/dev/null 2>&1; then
        echo "check-cmake-escape: Core preparation did not produce $report" >&2
        exit 69
    fi
fi
[ -f "$report" ] || {
    echo "check-cmake-escape: Core preparation report is missing: $report" >&2
    exit 69
}

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# The probe loads the real resolver and reports the outcome. cmake -P runs the
# file in script mode, which is the same mode the ESP-IDF requirements pass uses,
# so a pattern that does not parse here does not parse there either.
cat > "$work/probe.cmake" <<'PROBE'
include("${RESOLVER}")
message(STATUS "ACCEPTED module map: ${AXOLOTY_ZENOH_FACADE_MODULE_MAP}")
PROBE

json_field() {
    python3 - "$1" "$2" <<'PY'
import json, sys
with open(sys.argv[1]) as handle:
    document = json.load(handle)
value = document
for key in sys.argv[2].split("."):
    value = value[key]
sys.stdout.write(value)
PY
}

core_source_dir=$(json_field "$report" core.sourceDir)
scratch_dir=$(json_field "$report" staticRuntimeMacro.scratchDir)
real_module_map=$(json_field "$report" zenohCore.moduleMap)

# Each case copies the real report and moves one field, so everything else in the
# contract still validates and only the property under test can decide the run.
build_case() {
    name="$1"
    module_map="$2"
    python3 - "$report" "$work/$name.json" "$module_map" <<'PY'
import json, os, sys
with open(sys.argv[1]) as handle:
    document = json.load(handle)
document["zenohCore"]["moduleMap"] = sys.argv[3]
with open(sys.argv[2], "w") as handle:
    json.dump(document, handle, indent=2, sort_keys=True)
PY
}

failures=0
run_case() {
    name="$1"
    description="$2"
    expect="$3"
    set +e
    # The resolver's own variable name, or the run stops at the preparation
    # report guard and never reaches a path check.
    cmake -DRESOLVER="$resolver" \
        -DAXOLOTY_PREPARATION_REPORT="$work/$name.json" \
        -P "$work/probe.cmake" >"$work/$name.log" 2>&1
    status=$?
    set -e
    if grep -qE 'Invalid escape sequence|CMP0010' "$work/$name.log"; then
        echo "check-cmake-escape: FAILED: $name emitted a CMake escape or policy warning" >&2
        grep -E 'Invalid escape sequence|CMP0010' -B6 "$work/$name.log" >&2
        failures=$((failures + 1))
        return
    fi
    case "$expect" in
        accept)
            if [ "$status" -ne 0 ]; then
                echo "check-cmake-escape: FAILED: $description was rejected" >&2
                sed -n '1,12p' "$work/$name.log" >&2
                failures=$((failures + 1))
                return
            fi
            ;;
        reject)
            if [ "$status" -eq 0 ]; then
                echo "check-cmake-escape: FAILED: $description was accepted" >&2
                failures=$((failures + 1))
                return
            fi
            if ! grep -q 'escapes caller-owned scratch' "$work/$name.log"; then
                echo "check-cmake-escape: FAILED: $description failed for an unrelated reason" >&2
                echo "check-cmake-escape: expected the containment rejection, not another error" >&2
                sed -n '1,12p' "$work/$name.log" >&2
                failures=$((failures + 1))
                return
            fi
            ;;
    esac
    echo "ok   $description"
}

echo "== the report as Core wrote it"
# Copied verbatim, so the case measures the report and not a mutation of it.
cp "$report" "$work/valid.json"
run_case valid "the reported paths where the report names them" accept

echo "== a directory whose name only starts with dots"
# `...` is three dots, not two, so it is inside caller scratch and must be
# accepted. A pattern written as a bare `..` would reject it.
dots_dir="$scratch_dir/.../probe"
mkdir -p "$dots_dir"
dots_map="$dots_dir/module.modulemap"
cp "$real_module_map" "$dots_map"
build_case dots "$dots_map"
run_case dots "a module map under a ... directory inside caller scratch" accept

echo "== a real traversal"
parent_dir="$(dirname "$scratch_dir")/escape-check"
mkdir -p "$parent_dir"
parent_map="$parent_dir/module.modulemap"
cp "$real_module_map" "$parent_map"
build_case parent "$parent_map"
run_case parent "a module map one level above caller scratch" reject

echo "== a sibling whose name starts with the scratch path"
sibling_dir="$scratch_dir-sibling"
mkdir -p "$sibling_dir"
sibling_map="$sibling_dir/module.modulemap"
cp "$real_module_map" "$sibling_map"
build_case sibling "$sibling_map"
run_case sibling "a module map under a sibling of caller scratch" reject

# The Core checkout is not written to, but the roots are reported so a failure
# above names the paths it was reasoning about.
echo "check-cmake-escape: core.sourceDir $core_source_dir"
echo "check-cmake-escape: scratchDir $scratch_dir"

if [ "$failures" -ne 0 ]; then
    echo "check-cmake-escape: $failures case(s) failed" >&2
    exit 1
fi
echo "check-cmake-escape: passed"
