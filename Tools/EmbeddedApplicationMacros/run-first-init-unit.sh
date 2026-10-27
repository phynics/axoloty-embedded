#!/usr/bin/env bash
# Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/../.." && pwd)"
scratch="${1:?pass private scratch directory}"
plugin="${2:?pass the built macro plugin path}"
target_mode="${3:-host}"
if [[ "$target_mode" != host && "$target_mode" != --embedded-target ]]; then
    echo "usage: $0 <scratch> <macro-plugin> [--embedded-target]" >&2
    exit 3
fi
mkdir -p "$scratch"/{generated,objects,logs,bin}
cd "$repo_root"

python3 - "$scratch" <<'PY'
import json, sys
from pathlib import Path
root=Path(sys.argv[1])
base={"schemaVersion":1,"name":"first-init","sources":["FirstInitializationApp.swift"],
      "requirements":{"platform":["diagnostics.heap"],"carrier":[]},
      "capacities":{"maxTopicLength":1,"maxPayloadSize":1,"applicationStateBytes":8}}
(root/"trace-app.json").write_text(json.dumps(base,indent=2)+"\n")
base["name"]="first-init-missing-trace"
base["requirements"]["platform"]=[]
(root/"missing-trace-app.json").write_text(json.dumps(base,indent=2)+"\n")
base["name"]="first-init-overbudget"
base["requirements"]["platform"]=["diagnostics.heap"]
base["capacities"]["applicationStateBytes"]=1
(root/"overbudget-app.json").write_text(json.dumps(base,indent=2)+"\n")
base["name"]="disabled-heap-diagnostics"
base["sources"]=["DisabledHeapDiagnosticsApp.swift"]
(root/"disabled-heap-app.json").write_text(json.dumps(base,indent=2)+"\n")
base["name"]="disabled-console"
base["requirements"]["platform"]=["console.write"]
base["sources"]=["ConsoleOnly.swift"]
(root/"disabled-console-app.json").write_text(json.dumps(base,indent=2)+"\n")
PY

emit_requirements() {
    local manifest="$1" output="$2"
    python3 Tools/validate-composition.py --repo-root "$repo_root" \
        --app-manifest "$manifest" --emit-requirements "$output"
}
emit_requirements "$scratch/trace-app.json" "$scratch/generated/TraceRequirements.swift" >"$scratch/logs/trace-requirements.log"
emit_requirements "$scratch/missing-trace-app.json" "$scratch/generated/MissingTraceRequirements.swift" >"$scratch/logs/missing-trace-requirements.log"
emit_requirements "$scratch/overbudget-app.json" "$scratch/generated/OverbudgetRequirements.swift" >"$scratch/logs/overbudget-requirements.log"
emit_requirements "$scratch/disabled-heap-app.json" "$scratch/generated/DisabledHeapRequirements.swift" >"$scratch/logs/disabled-heap-requirements.log"
emit_requirements "$scratch/disabled-console-app.json" "$scratch/generated/DisabledConsoleRequirements.swift" >"$scratch/logs/disabled-console-requirements.log"

# Model a malformed runtime requirement record while retaining the compile-time
# witness. Normal composition emits both trace bits together from diagnostics.heap.
python3 - "$scratch/generated/TraceRequirements.swift" "$scratch/generated/RuntimeMismatchRequirements.swift" <<'PY'
import sys
from pathlib import Path
source = Path(sys.argv[1]).read_text()
assert source.count("platformFunctions: 48,") == 1
Path(sys.argv[2]).write_text(source.replace("platformFunctions: 48,", "platformFunctions: 16,"))
PY

common=(
    -swift-version 5 -parse-as-library -I Interop
    -import-objc-header Interop/axoloty_application_entry_v1.h
    -load-plugin-executable "$plugin#EmbeddedApplicationMacroImplementation"
    Sources/EmbeddedCapabilities/EmbeddedApplicationMacro.swift
    Sources/EmbeddedCapabilities/EmbeddedApplicationDefinition.swift
    Sources/EmbeddedCapabilities/EmbeddedApplicationEntryAdapter.swift
    Sources/EmbeddedCapabilities/EmbeddedCapabilities.swift
    Sources/EmbeddedCapabilities/EmbeddedRequirements.swift
)

clang -I Interop -c Interop/axoloty_application_entry_v1.c -o "$scratch/objects/entry.o"
clang -I Interop -c Tools/EmbeddedApplicationMacros/Fixtures/UnitFirstInitialization/trace-fixture.c \
    -o "$scratch/objects/trace-fixture.o"

swiftc "${common[@]}" -module-name FirstInitialization \
    "$scratch/generated/TraceRequirements.swift" \
    Tools/EmbeddedApplicationMacros/Fixtures/UnitFirstInitialization/FirstInitializationApp.swift \
    Tools/EmbeddedApplicationMacros/Fixtures/UnitFirstInitialization/EntryOrderingHostMain.swift \
    "$scratch/objects/trace-fixture.o" "$scratch/objects/entry.o" \
    -Xfrontend -dump-macro-expansions -o "$scratch/bin/entry-ordering" \
    >"$scratch/logs/entry-ordering-expansion.log" 2>&1
for scenario in success begin stop overflow nonzero repeat repeat-failure; do
    "$scratch/bin/entry-ordering" "$scenario" >"$scratch/logs/$scenario.log" 2>&1
done

swiftc "${common[@]}" -module-name FirstInitializationRuntimeMismatch \
    "$scratch/generated/RuntimeMismatchRequirements.swift" \
    Tools/EmbeddedApplicationMacros/Fixtures/UnitFirstInitialization/FirstInitializationApp.swift \
    Tools/EmbeddedApplicationMacros/Fixtures/UnitFirstInitialization/EntryOrderingHostMain.swift \
    "$scratch/objects/trace-fixture.o" "$scratch/objects/entry.o" \
    -o "$scratch/bin/entry-runtime-mismatch" >"$scratch/logs/runtime-mismatch-build.log" 2>&1
"$scratch/bin/entry-runtime-mismatch" requirements >"$scratch/logs/runtime-mismatch.log" 2>&1

swiftc "${common[@]}" -module-name FirstInitializationOverbudget \
    "$scratch/generated/OverbudgetRequirements.swift" \
    Tools/EmbeddedApplicationMacros/Fixtures/UnitFirstInitialization/FirstInitializationApp.swift \
    Tools/EmbeddedApplicationMacros/Fixtures/UnitFirstInitialization/EntryOrderingHostMain.swift \
    "$scratch/objects/trace-fixture.o" "$scratch/objects/entry.o" \
    -o "$scratch/bin/entry-overbudget" >"$scratch/logs/overbudget-build.log" 2>&1
"$scratch/bin/entry-overbudget" overbudget >"$scratch/logs/overbudget.log" 2>&1

swiftc "${common[@]}" -module-name DisabledHeapDiagnostics \
    "$scratch/generated/DisabledHeapRequirements.swift" \
    Tools/EmbeddedApplicationMacros/Fixtures/UnitFirstInitialization/DisabledHeapDiagnosticsApp.swift \
    Tools/EmbeddedApplicationMacros/Fixtures/UnitFirstInitialization/DisabledHeapDiagnosticsMain.swift \
    "$scratch/objects/trace-fixture.o" "$scratch/objects/entry.o" \
    -o "$scratch/bin/disabled-heap" >"$scratch/logs/disabled-heap-build.log" 2>&1
"$scratch/bin/disabled-heap" >"$scratch/logs/disabled-heap.log" 2>&1

if swiftc "${common[@]}" -module-name MissingTraceWitness \
    "$scratch/generated/MissingTraceRequirements.swift" \
    Tools/EmbeddedApplicationMacros/Fixtures/UnitFirstInitialization/FirstInitializationApp.swift \
    -typecheck >"$scratch/logs/missing-trace-witness.log" 2>&1; then
    echo "FAIL opted-in app compiled without generated heap trace witness" >&2
    exit 1
fi
grep -F EmbeddedHeapTraceInitializationRequirements "$scratch/logs/missing-trace-witness.log" >/dev/null

for fixture_and_message in \
    "UnknownArgument.swift|extra argument 'unknown' in macro expansion" \
    "InvalidDuplicateArgument.swift|extra argument" \
    "InvalidNonliteralArgument.swift|must be a literal true or false" \
    "InvalidHookShape.swift|must be static, synchronous, nonthrowing, parameterless, and return Void" \
    "InstanceHook.swift|must be static, synchronous, nonthrowing, parameterless, and return Void" \
    "AsyncHook.swift|must be static, synchronous, nonthrowing, parameterless, and return Void" \
    "ThrowingHook.swift|must be static, synchronous, nonthrowing, parameterless, and return Void" \
    "WrongReturnHook.swift|must be static, synchronous, nonthrowing, parameterless, and return Void" \
    "MissingHook.swift|requires exactly one static initializeStaticState() hook"; do
    fixture="${fixture_and_message%%|*}"
    expected="${fixture_and_message#*|}"
    if swiftc "${common[@]}" -module-name InvalidFirstInit \
        "$scratch/generated/TraceRequirements.swift" \
        "Tools/EmbeddedApplicationMacros/Fixtures/UnitFirstInitialization/$fixture" \
        -typecheck >"$scratch/logs/$fixture.log" 2>&1; then
        echo "FAIL invalid first-init fixture compiled: $fixture" >&2
        exit 1
    fi
    grep -F "$expected" "$scratch/logs/$fixture.log" >/dev/null
done

swiftc "${common[@]}" -module-name MinimalConsole \
    "$scratch/generated/DisabledConsoleRequirements.swift" \
    Tools/EmbeddedApplicationMacros/Fixtures/MinimalConsole/ConsoleOnly.swift \
    -typecheck -Xfrontend -dump-macro-expansions \
    >"$scratch/logs/disabled-console-expansion.log" 2>&1
if grep -E 'beginHeapTrace|endHeapTrace|initializeStaticState\(' \
    "$scratch/logs/disabled-console-expansion.log" >/dev/null; then
    echo "FAIL disabled minimal console entry mentions the trace or hook" >&2
    exit 1
fi

python3 - "$scratch/logs/entry-ordering-expansion.log" <<'PY'
import re, sys
from pathlib import Path
text=Path(sys.argv[1]).read_text()
headers=list(re.finditer(r"(?m)^@__swiftmacro_[^\n]+\.swift\n-+\n", text))
blocks=[]
for header in headers:
    end=text.find("\n------------------------------", header.end())
    if end < 0:
        continue
    block=text[header.end():end]
    if "axoloty_application_main" in block and "beginHeapTrace()" in block:
        blocks.append(block)
assert blocks, "generated entry expansion not found"
markers=["MemoryLayout<FirstInitializationApp.State>.stride", "EmbeddedApplicationEntryAdapter.capabilities(", "EmbeddedApplicationEntryAdapter.claimEntry()", "hasHeapTraceRequirements(", "capabilities.platform.beginHeapTrace()", "FirstInitializationApp.initializeStaticState()", "withUnsafeMutablePointer(to: &__axoloty_application_state)", "capabilities.platform.endHeapTrace()", "FirstInitializationApp.run(capabilities"]
for block in blocks:
    positions=[block.find(marker) for marker in markers]
    assert all(position >= 0 for position in positions), (markers, positions)
    assert positions == sorted(positions), (markers, positions)
    state_addresses=[match.start() for match in re.finditer(r"&__axoloty_application_state", block)]
    assert len(state_addresses) == 1 and state_addresses[0] > positions[4], state_addresses
print("PASS macro expansion order: " + " < ".join(markers))
PY

if [[ "$target_mode" == --embedded-target ]]; then
    # This is a separate target proof. The build-tier host fixture never needs
    # the RISC-V target or Embedded Swift frontend support.
    swiftc -target riscv32-none-none-eabi -enable-experimental-feature Embedded \
        -wmo -Osize -parse-as-library -I Interop \
        -import-objc-header Interop/axoloty_application_entry_v1.h \
        -load-plugin-executable "$plugin#EmbeddedApplicationMacroImplementation" \
        -module-name FirstInitializationTarget \
        Sources/EmbeddedCapabilities/EmbeddedApplicationMacro.swift \
        Sources/EmbeddedCapabilities/EmbeddedApplicationDefinition.swift \
        Sources/EmbeddedCapabilities/EmbeddedApplicationEntryAdapter.swift \
        Sources/EmbeddedCapabilities/EmbeddedCapabilities.swift \
        Sources/EmbeddedCapabilities/EmbeddedRequirements.swift \
        "$scratch/generated/TraceRequirements.swift" \
        Tools/EmbeddedApplicationMacros/Fixtures/UnitFirstInitialization/FirstInitializationApp.swift \
        -emit-object -o "$scratch/objects/entry-riscv32.o" \
        >"$scratch/logs/embedded-target-compile.log" 2>&1
    echo "PASS first-init ordering/status fixtures and Embedded Swift object compile"
else
    echo "PASS first-init ordering/status host fixtures"
fi
