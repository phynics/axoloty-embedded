#!/usr/bin/env bash
# Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.
set -eu

for tool in cmake python3 make git node; do
    command -v "$tool" >/dev/null 2>&1 || {
        echo "check-core-cmake-helper: $tool is required" >&2
        exit 69
    }
done
compiler=${CC:-}
if [ -z "$compiler" ]; then
    for candidate in cc clang gcc; do
        if command -v "$candidate" >/dev/null 2>&1; then
            compiler=$candidate
            break
        fi
    done
fi
if [ -z "$compiler" ] || ! command -v "$compiler" >/dev/null 2>&1; then
    echo "check-core-cmake-helper: a host C compiler is required" >&2
    exit 69
fi

repo_root=$(CDPATH='' cd -- "$(dirname -- "$0")/../.." && pwd)
work=$(mktemp -d "${TMPDIR:-/tmp}/axoloty-core-cmake-helper.XXXXXX")
trap 'rm -rf "$work"' EXIT

python3 - "$work" "$repo_root/Platforms/common/axoloty-core.cmake" <<'PY'
import hashlib
import json
import os
import pathlib
import sys

work = pathlib.Path(sys.argv[1]).resolve()
helper = pathlib.Path(sys.argv[2]).resolve()
core = work / "core"
scratch = work / "scratch"
for directory in (core, scratch):
    directory.mkdir(parents=True)
packages = {}
for name in ("AxolotyWire", "AxolotyObjectModel", "AxolotyProtocol", "AxolotyCoatyModels", "AxolotyStaticRuntime"):
    source = core / "Sources" / name
    source.mkdir(parents=True)
    (source / "Fixture.swift").write_text("// synthetic fixture\n")
    packages[name] = str(source)
json_core = core / "Sources" / "JSONCore"
json_core.mkdir(parents=True)
macro = scratch / "macro-tool"
macro.write_text("#!/bin/sh\nexit 0\n")
macro.chmod(0o755)
zenoh = core / "Sources" / "AxolotyZenohCore"
zenoh.mkdir(parents=True)
(zenoh / "Fixture.swift").write_text("// synthetic fixture\n")
header = core / "include" / "axoloty_zenoh.h"
header.parent.mkdir()
header.write_text("/* fixture */\n")
module_map = scratch / "module.modulemap"
module_map.write_text("module Fixture { header \\\"axoloty_zenoh.h\\\" }\n")

def report(include_zenoh=True):
    value = {
        "schemaVersion": 1,
        "status": "prepared",
        "core": {"sourceDir": str(core), "sha": "0123456789abcdef0123456789abcdef01234567", "dirty": False},
        "portablePackages": [{"name": n, "sourcePath": p} for n, p in packages.items()],
        "jsonCore": {"sourceDir": str(json_core)},
        "staticRuntimeMacro": {"executable": str(macro), "scratchDir": str(scratch)},
    }
    if include_zenoh:
        value["zenohCore"] = {
            "module": "AxolotyZenohCore", "sourceDir": str(zenoh),
            "facadeModule": "CAxolotyZenoh", "facadeHeader": str(header),
            "facadeHeaderSHA256": hashlib.sha256(header.read_bytes()).hexdigest(),
            "moduleMap": str(module_map),
        }
    return value

(work / "report.json").write_text(json.dumps(report(), indent=2))
(work / "report-no-zenoh.json").write_text(json.dumps(report(False), indent=2))
mutations = {
    "malformed": "{not-json",
    "missing-package": report(),
    "noncanonical-root": report(),
    "escaping-package": report(),
    "escaping-zenoh-map": report(),
    "bad-zenoh-digest": report(),
}
mutations["missing-package"]["portablePackages"] = [p for p in mutations["missing-package"]["portablePackages"] if p["name"] != "AxolotyProtocol"]
mutations["noncanonical-root"]["core"]["sourceDir"] = str(core / "Sources" / "..")
(work / "outside").mkdir()
mutations["escaping-package"]["portablePackages"][0]["sourcePath"] = str(work / "outside")
(work / "module.modulemap").write_text("module Outside {}\n")
mutations["escaping-zenoh-map"]["zenohCore"]["moduleMap"] = str(work / "module.modulemap")
mutations["bad-zenoh-digest"]["zenohCore"]["facadeHeaderSHA256"] = "0" * 64
for name, value in mutations.items():
    (work / f"{name}.json").write_text(value if isinstance(value, str) else json.dumps(value, indent=2))

project = work / "project"
project.mkdir()
(project / "dependency_probe.c").write_text("int dependency_probe(void) { return 0; }\n")
(project / "CMakeLists.txt").write_text(f'''cmake_minimum_required(VERSION 3.20)
project(core_helper_fixture C)
if(DEFINED FIXTURE_HELPER_INCLUDE)
  include("${{FIXTURE_HELPER_INCLUDE}}")
else()
  include("{helper.as_posix()}")
endif()
axoloty_collect_swift_sources(FIXTURE_SOURCES "${{AXOLOTY_WIRE_SOURCE_DIR}}" fixture_wire)
if(NOT FIXTURE_SOURCES STREQUAL "${{AXOLOTY_WIRE_SOURCE_DIR}}/Fixture.swift")
  message(FATAL_ERROR "source collection returned unexpected sources: ${{FIXTURE_SOURCES}}")
endif()
set(fixture_source "${{CMAKE_CURRENT_SOURCE_DIR}}/dependency_probe.c")
set(wire_module "${{CMAKE_CURRENT_BINARY_DIR}}/AxolotyWire.swiftmodule")
set(model_module "${{CMAKE_CURRENT_BINARY_DIR}}/AxolotyObjectModel.swiftmodule")
axoloty_append_swift_module_dependency("${{fixture_source}}" "${{wire_module}}")
axoloty_append_swift_module_dependency("${{fixture_source}}" "${{model_module}}")
get_source_file_property(retained_dependencies "${{fixture_source}}" OBJECT_DEPENDS)
if(NOT retained_dependencies STREQUAL "${{wire_module}};${{model_module}}")
  message(FATAL_ERROR "module dependencies were not retained: ${{retained_dependencies}}")
endif()
add_custom_command(OUTPUT "${{wire_module}}" "${{model_module}}"
  COMMAND ${{CMAKE_COMMAND}} -E touch "${{wire_module}}" "${{model_module}}" VERBATIM)
add_custom_target(module_aliases DEPENDS "${{wire_module}}" "${{model_module}}")
add_library(dependency_probe STATIC dependency_probe.c)
''')

empty_project = work / "empty-project"
empty_project.mkdir()
(empty_project / "CMakeLists.txt").write_text(f'''cmake_minimum_required(VERSION 3.20)
project(core_helper_empty_fixture NONE)
include("{helper.as_posix()}")
axoloty_collect_swift_sources(EMPTY_SOURCES "${{EMPTY_SOURCE_DIR}}" missing_module)
''')
empty = work / "empty-module"
empty.mkdir()
(pathlib.Path(work / "paths.json")).write_text(json.dumps({"core": str(core), "scratch": str(scratch), "empty": str(empty)}))
PY

configure() {
    name=$1
    report=$2
    shift 2
    CC="$compiler" cmake -S "$work/project" -B "$work/build-$name" -G "Unix Makefiles" -DAXOLOTY_PREPARATION_REPORT="$report" "$@" >"$work/$name.log" 2>&1
}
expect_rejected() {
    name=$1
    report=$2
    if configure "$name" "$report"; then
        echo "check-core-cmake-helper: accepted invalid $name report" >&2
        exit 1
    fi
    echo "ok   rejected $name report"
}
if ! configure valid "$work/report.json"; then cat "$work/valid.log" >&2; exit 1; fi
echo "ok   configured full synthetic prepared report without ESP-IDF"
if ! configure no-zenoh "$work/report-no-zenoh.json"; then cat "$work/no-zenoh.log" >&2; exit 1; fi
echo "ok   accepted prepared report without optional Zenoh contract"
mkdir -p "$work/staged/platform/cmake"
cp "$repo_root/Platforms/esp32c6-idf/cmake/axoloty-source.cmake" \
    "$work/staged/platform/cmake/axoloty-source.cmake"
staged_wrapper="$work/staged/platform/cmake/axoloty-source.cmake"
if ! configure staged "$work/report.json" \
    -DFIXTURE_HELPER_INCLUDE="$staged_wrapper" \
    -DAXOLOTY_REPOSITORY_ROOT="$repo_root"; then
    cat "$work/staged.log" >&2
    exit 1
fi
echo "ok   staged SDK wrapper resolves common helper through repository input"
if ! env AXOLOTY_REPOSITORY_ROOT="$repo_root" CC="$compiler" cmake \
    -S "$work/project" -B "$work/build-staged-env" -G "Unix Makefiles" \
    -DFIXTURE_HELPER_INCLUDE="$staged_wrapper" \
    -DAXOLOTY_PREPARATION_REPORT="$work/report.json" >"$work/staged-env.log" 2>&1; then
    cat "$work/staged-env.log" >&2
    exit 1
fi
echo "ok   staged SDK wrapper resolves environment-only repository input"
expect_rejected malformed "$work/malformed.json"
expect_rejected missing-package "$work/missing-package.json"
expect_rejected noncanonical-root "$work/noncanonical-root.json"
expect_rejected escaping-package "$work/escaping-package.json"
expect_rejected escaping-zenoh-map "$work/escaping-zenoh-map.json"
expect_rejected bad-zenoh-digest "$work/bad-zenoh-digest.json"

if cmake -S "$work/empty-project" -B "$work/build-empty" -G "Unix Makefiles" \
    -DAXOLOTY_PREPARATION_REPORT="$work/report-no-zenoh.json" \
    -DEMPTY_SOURCE_DIR="$work/empty-module" >"$work/missing-module.log" 2>&1; then
    echo "check-core-cmake-helper: accepted a package with no Swift modules" >&2
    exit 1
fi
if ! grep -Fq 'No missing_module sources found' "$work/missing-module.log"; then
    cat "$work/missing-module.log" >&2
    echo "check-core-cmake-helper: missing-module failure did not name the module" >&2
    exit 1
fi
echo "ok   rejected missing module sources"

sed -n '/^CMakeFiles\/dependency_probe.dir\/dependency_probe.c.o:/,/^$/p' \
    "$work/build-valid/CMakeFiles/dependency_probe.dir/build.make" >"$work/object-graph.txt"
for module in AxolotyWire.swiftmodule AxolotyObjectModel.swiftmodule; do
    if ! grep -Fq "$module" "$work/object-graph.txt"; then
        cat "$work/object-graph.txt" >&2
        echo "check-core-cmake-helper: generated object graph lost $module" >&2
        exit 1
    fi
done
echo "ok   generated object graph retains both module prerequisites"

# Drive the production invariant over a private copy. Keeping the expected
# source variable in a comment must not hide a collector bound to another module.
python3 - "$repo_root" "$work" <<'PY'
from pathlib import Path
import shutil
import subprocess
import sys

repo, work = map(Path, sys.argv[1:])
fixture = work / "binding-repo"
fixture.mkdir()
paths = subprocess.check_output(
    ["git", "ls-files", "-z", "--cached", "--others", "--exclude-standard"], cwd=repo
).decode().split("\0")
for relative in paths:
    source = repo / relative
    if not relative or not source.is_file():
        continue
    target = fixture / relative
    target.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(source, target)
subprocess.run(["git", "init", "-q", str(fixture)], check=True)
subprocess.run(["git", "add", "."], cwd=fixture, check=True)
command = ["bash", "Tools/check-invariants.sh"]
positive = subprocess.run(command, cwd=fixture, capture_output=True, text=True)
if positive.returncode:
    sys.stderr.write(positive.stdout + positive.stderr)
    raise SystemExit("valid collector binding fixture failed")
component = fixture / "Platforms/esp32c6-idf/components/axoloty_wire/CMakeLists.txt"
text = component.read_text()
assert '"${AXOLOTY_WIRE_SOURCE_DIR}"' in text
component.write_text(text.replace('"${AXOLOTY_WIRE_SOURCE_DIR}"',
                                  '"${AXOLOTY_PROTOCOL_SOURCE_DIR}"', 1)
                     + "\n# expected AXOLOTY_WIRE_SOURCE_DIR\n")
negative = subprocess.run(command, cwd=fixture, capture_output=True, text=True)
diagnostic = "wire component collector is not bound to AXOLOTY_WIRE_SOURCE_DIR"
if negative.returncode == 0 or diagnostic not in negative.stdout + negative.stderr:
    sys.stderr.write(negative.stdout + negative.stderr)
    raise SystemExit("wrong collector binding was not rejected")
print("ok   production invariant rejects another module's source root despite comment")
PY
