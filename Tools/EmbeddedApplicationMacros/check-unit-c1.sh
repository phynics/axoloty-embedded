#!/usr/bin/env bash
# Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/../.." && pwd)"
scratch="${1:-/tmp/axoloty-batch2-382c4846/unit-c1-scratch}"
preparation_report="/tmp/axoloty-batch2-382c4846/unit-b1-buildscratch/firmware/evidence/preparation.json"
prepared_build="/tmp/axoloty-batch2-382c4846/unit-b1-buildscratch/firmware/build/esp-idf"
lock="/tmp/axoloty-batch2-382c4846/verification.lock"
image="axoloty-embedded-dev"

test -f "$preparation_report"
test -d "$prepared_build/axoloty_protocol"
mkdir -p "$scratch"
mkdir -p "$scratch/artifacts" "$scratch/logs"

source_files=(
    Interop/axoloty_application_entry_v1.h
    Interop/axoloty_application_entry_v1.c
    Interop/axoloty_carrier_v1.h
    Interop/axoloty_platform_v1.h
    Sources/EmbeddedCapabilities/EmbeddedApplicationDefinition.swift
    Sources/EmbeddedCapabilities/EmbeddedApplicationEntryAdapter.swift
    Sources/EmbeddedCapabilities/EmbeddedCapabilities.swift
    Sources/EmbeddedCapabilities/EmbeddedRequirements.swift
    Tools/EmbeddedApplicationMacros/Sources/EmbeddedApplicationMacroImplementation/EmbeddedApplicationMacro.swift
    Tools/EmbeddedApplicationMacros/Fixtures/OutcomeStatusCheck.swift
    Tools/EmbeddedApplicationMacros/Fixtures/UnitC1/StateBudgetApp.swift
    Tools/EmbeddedApplicationMacros/Fixtures/UnitC1/StateBudgetHostMain.swift
    Tools/EmbeddedApplicationMacros/Fixtures/abi-fixture.h
    Tools/EmbeddedApplicationMacros/Fixtures/UnitC1/MinimalNoncopyableApp.swift
    Tools/EmbeddedApplicationMacros/Fixtures/UnitC1/ProcessorApp.swift
    Tools/EmbeddedApplicationMacros/Fixtures/Valid/EmptyState.swift
    Tools/EmbeddedApplicationMacros/check-unit-a.sh
    Tools/EmbeddedApplicationMacros/check-unit-c1.sh
    Tools/EmbeddedApplicationMacros/run-unit-c1-container.sh
    Tools/validate-composition.py
    docs/embedded-application-contract.md
)
(cd "$repo_root" && sha256sum "${source_files[@]}") >"$scratch/artifacts/source-sha256.txt"

flock -x "$lock" bash -c '
    set -euo pipefail
    repo_root="$1"
    scratch="$2"
    preparation_report="$3"
    prepared_build="$4"
    image="$5"
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
        bash Tools/EmbeddedApplicationMacros/run-unit-c1-container.sh
    if (cd "$scratch/artifacts" && sha256sum -c artifact-hashes.sha256) \
        >"$scratch/logs/final-artifact-hash-verification.txt" 2>&1; then
        artifact_status=0
    else
        artifact_status=$?
    fi
    if (cd "$repo_root" && sha256sum -c "$scratch/artifacts/source-sha256.txt") \
        >"$scratch/logs/final-source-hash-verification.txt" 2>&1; then
        source_status=0
    else
        source_status=$?
    fi
    printf "artifact_manifest_status=%s
source_manifest_status=%s
" "$artifact_status" "$source_status" >"$scratch/logs/final-hash-verification.exit"
    if [ "$artifact_status" -ne 0 ] || [ "$source_status" -ne 0 ]; then
        cat "$scratch/logs/final-artifact-hash-verification.txt" \
            "$scratch/logs/final-source-hash-verification.txt" >&2
        exit 1
    fi
    if Tools/verify.sh --tier repo >"$scratch/logs/verify-repo.txt" 2>&1; then
        verify_status=0
    else
        verify_status=$?
    fi
    printf "%s\n" "$verify_status" >"$scratch/logs/verify-repo.exit"
    exit "$verify_status"
' _ "$repo_root" "$scratch" "$preparation_report" "$prepared_build" "$image"
