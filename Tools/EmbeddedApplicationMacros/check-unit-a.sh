#!/usr/bin/env bash
# Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.
# Compile the real macro against caller fixtures and the production C headers.
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/../.." && pwd)"
scratch="${1:?pass private scratch directory}"
plugin="${2:?pass the built macro plugin path}"
mkdir -p "$scratch/host-fixtures" "$scratch/diagnostics" "$scratch/target" "$scratch/generated"
cd "$repo_root"
clang -I Interop -c Interop/axoloty_application_entry_v1.c \
    -o "$scratch/host-fixtures/application-entry-helper.o"

python3 Tools/validate-composition.py \
    --repo-root "$repo_root" \
    --profile Profiles/esp32c6-mqtt/profile.json \
    --emit-requirements "$scratch/generated/ManifestRequirements.swift" \
    >"$scratch/requirements.log" 2>&1

swift_sources=(
    Sources/EmbeddedCapabilities/EmbeddedApplicationMacro.swift
    Sources/EmbeddedCapabilities/EmbeddedApplicationDefinition.swift
    Sources/EmbeddedCapabilities/EmbeddedApplicationEntryAdapter.swift
    Sources/EmbeddedCapabilities/EmbeddedCapabilities.swift
    Sources/EmbeddedCapabilities/EmbeddedRequirements.swift
    "$scratch/generated/ManifestRequirements.swift"
)
common_flags=(
    -I Interop
    -import-objc-header Interop/axoloty_application_entry_v1.h
    -load-plugin-executable "$plugin#EmbeddedApplicationMacroImplementation"
)

for fixture in \
    Tools/EmbeddedApplicationMacros/Fixtures/Valid/NamespaceEnum.swift \
    Tools/EmbeddedApplicationMacros/Fixtures/Valid/NamespaceStructExternalState.swift \
    Tools/EmbeddedApplicationMacros/Fixtures/Valid/EmptyState.swift; do
    module="$(basename "$fixture" .swift)"
    swiftc -typecheck -parse-as-library -module-name "$module" \
        "${common_flags[@]}" "${swift_sources[@]}" "$fixture" \
        >"$scratch/host-fixtures/$module.log" 2>&1
    printf 'PASS valid fixture: %s\n' "$fixture"
done

invalid_fixture() {
    local fixture="$1" expected="$2" module
    module="$(basename "$fixture" .swift)"
    if swiftc -typecheck -parse-as-library -module-name "$module" \
        "${common_flags[@]}" "${swift_sources[@]}" "$fixture" \
        >"$scratch/diagnostics/$module.log" 2>&1; then
        printf 'FAIL invalid fixture compiled: %s\n' "$fixture" >&2
        return 1
    fi
    if ! grep -F "$expected" "$scratch/diagnostics/$module.log" >/dev/null; then
        printf 'FAIL expected diagnostic missing for %s: %s\n' "$fixture" "$expected" >&2
        cat "$scratch/diagnostics/$module.log" >&2
        return 1
    fi
    printf 'PASS rejected fixture: %s (%s)\n' "$fixture" "$expected"
}

invalid_fixture Tools/EmbeddedApplicationMacros/Fixtures/Invalid/InstanceRun.swift \
    'application run must be static'
invalid_fixture Tools/EmbeddedApplicationMacros/Fixtures/Invalid/WrongParameters.swift \
    "extra argument 'state'"
invalid_fixture Tools/EmbeddedApplicationMacros/Fixtures/Invalid/WrongReturn.swift \
    "cannot convert value of type 'Int32' to expected argument type 'EmbeddedApplicationResult'"
invalid_fixture Tools/EmbeddedApplicationMacros/Fixtures/Invalid/AsyncRun.swift \
    'application run must be synchronous'
invalid_fixture Tools/EmbeddedApplicationMacros/Fixtures/Invalid/MissingState.swift \
    'application must declare State'
invalid_fixture Tools/EmbeddedApplicationMacros/Fixtures/Invalid/MissingRun.swift \
    'application must declare static run'

swiftc -parse-as-library -module-name OutcomeStatusCheck \
    -I Interop -import-objc-header Interop/axoloty_application_entry_v1.h \
    Sources/EmbeddedCapabilities/EmbeddedApplicationDefinition.swift \
    Sources/EmbeddedCapabilities/EmbeddedApplicationEntryAdapter.swift \
    Sources/EmbeddedCapabilities/EmbeddedCapabilities.swift \
    Sources/EmbeddedCapabilities/EmbeddedRequirements.swift \
    "$scratch/generated/ManifestRequirements.swift" \
    Tools/EmbeddedApplicationMacros/Fixtures/OutcomeStatusCheck.swift \
    "$scratch/host-fixtures/application-entry-helper.o" \
    -o "$scratch/host-fixtures/outcome-status-check"
"$scratch/host-fixtures/outcome-status-check"
printf 'PASS all app outcome and bootstrap status mappings\n'

swiftc -target riscv32-none-none-eabi \
    -enable-experimental-feature Embedded -wmo -parse-as-library \
    -module-name ProductionHeaderApplication \
    "${common_flags[@]}" "${swift_sources[@]}" \
    Tools/EmbeddedApplicationMacros/Fixtures/ProductionHeaderApp.swift \
    -emit-object -o "$scratch/target/production-header-entry.o" \
    >"$scratch/target/compile.log" 2>&1
symbol_tool="$(command -v llvm-nm || command -v riscv32-esp-elf-nm || command -v nm || true)"
if [ -z "$symbol_tool" ]; then
    echo 'FAIL no symbol inspection tool is available in the pinned image' >&2
    exit 1
fi
"$symbol_tool" -g --defined-only "$scratch/target/production-header-entry.o" \
    >"$scratch/target/symbols.txt"
if ! grep -F 'axoloty_application_main' "$scratch/target/symbols.txt" >/dev/null; then
    echo 'FAIL target object does not define axoloty_application_main' >&2
    cat "$scratch/target/symbols.txt" >&2
    exit 1
fi
printf 'PASS production C-imported Embedded Swift entry: %s\n' "$scratch/target/production-header-entry.o"
printf 'PASS target object exports neutral entry symbol\n'
