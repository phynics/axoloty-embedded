#!/usr/bin/env bash
# Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/../.." && pwd)"
scratch="${1:-/tmp/axoloty-batch2-382c4846/unit-c2-scratch}"
preparation_report="/tmp/axoloty-batch2-382c4846/unit-b1-buildscratch/firmware/evidence/preparation.json"
prepared_build="/tmp/axoloty-batch2-382c4846/unit-b1-buildscratch/firmware/build/esp-idf"
lock="/tmp/axoloty-batch2-382c4846/verification.lock"
image="axoloty-embedded-dev"

test -f "$preparation_report"
test -d "$prepared_build/axoloty_protocol"
mkdir -p "$scratch"

source_files=(
    Interop/axoloty_application_entry_v1.h
    Interop/axoloty_application_entry_v1.c
    Sources/EmbeddedCapabilities/EmbeddedApplicationEntryAdapter.swift
    Sources/EmbeddedCapabilities/EmbeddedApplicationMacro.swift
    Sources/EmbeddedCapabilities/EmbeddedApplicationDefinition.swift
    Sources/EmbeddedCapabilities/EmbeddedCapabilities.swift
    Sources/EmbeddedCapabilities/EmbeddedRequirements.swift
    Interop/axoloty_abi_status_v1.h
    Interop/axoloty_platform_v1.h
    Interop/axoloty_carrier_v1.h
    Tools/EmbeddedApplicationMacros/Fixtures/abi-fixture.c
    Tools/EmbeddedApplicationMacros/Fixtures/UnitC1/StateBudgetApp.swift
    Tools/EmbeddedApplicationMacros/Fixtures/UnitC1/MinimalNoncopyableApp.swift
    Tools/EmbeddedApplicationMacros/Fixtures/UnitC1/ProcessorApp.swift
    Tools/EmbeddedApplicationMacros/Fixtures/Valid/EmptyState.swift
    Tools/EmbeddedApplicationMacros/Fixtures/Valid/NamespaceEnum.swift
    Tools/EmbeddedApplicationMacros/Fixtures/Valid/NamespaceStructExternalState.swift
    Tools/EmbeddedApplicationMacros/Fixtures/ProductionHeaderApp.swift
    Tools/capability_catalog.py
    Tools/validate-composition.py
    Tools/EmbeddedApplicationMacros/Sources/EmbeddedApplicationMacroImplementation/EmbeddedApplicationMacro.swift
    Tools/EmbeddedApplicationMacros/Fixtures/abi-fixture.h
    Tools/EmbeddedApplicationMacros/Fixtures/OutcomeStatusCheck.swift
    Tools/EmbeddedApplicationMacros/Fixtures/UnitC1/StateBudgetHostMain.swift
    Tools/EmbeddedApplicationMacros/Fixtures/UnitC2/EntryExclusionApp.swift
    Tools/EmbeddedApplicationMacros/Fixtures/UnitC2/EntryExclusionHostMain.swift
    Tools/EmbeddedApplicationMacros/Fixtures/UnitC2/race-fixture.c
    Tools/EmbeddedApplicationMacros/check-unit-a.sh
    Tools/EmbeddedApplicationMacros/check-unit-b.sh
    Tools/EmbeddedApplicationMacros/check-unit-c1.sh
    Tools/EmbeddedApplicationMacros/check-unit-c2.sh
    Tools/EmbeddedApplicationMacros/run-unit-c1-container.sh
    Tools/EmbeddedApplicationMacros/run-unit-c2-container.sh
    Platforms/esp32c6-idf/main/CMakeLists.txt
    docs/embedded-application-contract.md
)
(cd "$repo_root" && sha256sum "${source_files[@]}") >"$scratch/source-sha256.txt"

flock -x "$lock" bash -c '
set -euo pipefail
repo_root="$1"
scratch="$2"
image="$3"
preparation_report="$4"
prepared_build="$5"
docker run --rm --user 0:0 \
    -v "$repo_root:/source" \
    -v "$scratch:/scratch" \
    -v "$preparation_report:/preparation/preparation.json:ro" \
    -v "$prepared_build/json_core:/prepared/json_core:ro" \
    -v "$prepared_build/axoloty_wire:/prepared/axoloty_wire:ro" \
    -v "$prepared_build/axoloty_object_model:/prepared/axoloty_object_model:ro" \
    -v "$prepared_build/axoloty_protocol:/prepared/axoloty_protocol:ro" \
    -v "$prepared_build/axoloty_static_runtime:/prepared/axoloty_static_runtime:ro" \
    -v "$prepared_build/axoloty_coaty_models:/prepared/axoloty_coaty_models:ro" \
    -w /source -e AXOLOTY_DEVCONTAINER=1 "$image" \
    bash Tools/EmbeddedApplicationMacros/run-unit-c2-container.sh
if (cd "$repo_root" && sha256sum -c "$scratch/source-sha256.txt") \
    >"$scratch/logs/source-hash-verification.txt" 2>&1; then
    source_status=0
else
    source_status=$?
fi
if (cd "$scratch" && sha256sum -c artifacts/artifact-hashes.sha256) \
    >"$scratch/logs/artifact-hash-verification.txt" 2>&1; then
    artifact_status=0
else
    artifact_status=$?
fi
printf "source_manifest_status=%s\nartifact_manifest_status=%s\n" \
    "$source_status" "$artifact_status" >"$scratch/logs/final-hash-verification.exit"
if [ "$source_status" -ne 0 ] || [ "$artifact_status" -ne 0 ]; then
    cat "$scratch/logs/source-hash-verification.txt" \
        "$scratch/logs/artifact-hash-verification.txt" >&2
    exit 1
fi
if Tools/verify.sh --tier repo >"$scratch/logs/verify-repo.txt" 2>&1; then
    repo_status=0
else
    repo_status=$?
fi
printf "%s\n" "$repo_status" >"$scratch/logs/verify-repo.exit"
cat "$scratch/logs/verify-repo.txt"
exit "$repo_status"
' _ "$repo_root" "$scratch" "$image" "$preparation_report" "$prepared_build"
