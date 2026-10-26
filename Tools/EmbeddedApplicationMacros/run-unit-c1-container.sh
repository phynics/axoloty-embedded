#!/usr/bin/env bash
# Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.
set -euo pipefail

repo_root=/source
scratch="${1:-/scratch}"
prepared=/prepared
mkdir -p "$scratch"/{cache,config,security,plugin-build,generated,host,target,manifests,logs,artifacts}
cd "$repo_root"
if [ ! -f "$scratch/artifacts/source-sha256.txt" ]; then
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
        Tools/EmbeddedApplicationMacros/Fixtures/UnitC1/MinimalNoncopyableApp.swift
        Tools/EmbeddedApplicationMacros/Fixtures/UnitC1/ProcessorApp.swift
        Tools/EmbeddedApplicationMacros/Fixtures/Valid/EmptyState.swift
        Tools/EmbeddedApplicationMacros/check-unit-a.sh
        Tools/EmbeddedApplicationMacros/check-unit-c1.sh
        Tools/EmbeddedApplicationMacros/run-unit-c1-container.sh
        Tools/validate-composition.py
        docs/embedded-application-contract.md
    )
    sha256sum "${source_files[@]}" >"$scratch/artifacts/source-sha256.txt"
fi
exec 9>"$scratch/logs/commands.txt"
BASH_XTRACEFD=9
set -x

python3 - <<'PY' >"$scratch/logs/preparation-identity.txt"
import json
from pathlib import Path
report=json.loads(Path("/preparation/preparation.json").read_text())
assert report["status"]=="prepared"
assert report["core"]["sha"]=="f8c201f717e843d7b838ba1d9ff56bd5be729522"
assert report["contractSHA256"]=="27254ace9481cd6b0d7d51063f29ac61b29b25b5f795d2aafe6087f406de0a7d"
for name in ("json_core","axoloty_wire","axoloty_object_model","axoloty_protocol","axoloty_static_runtime","axoloty_coaty_models"):
    assert Path(f"/prepared/{name}").is_dir(), name
print(f"prepared Core {report['core']['sha']} contract {report['contractSHA256']}")
PY

swift --version >"$scratch/logs/toolchain.txt" 2>&1
swift build \
    --package-path "$repo_root/Tools/EmbeddedApplicationMacros" \
    --scratch-path "$scratch/plugin-build" \
    --cache-path "$scratch/cache" \
    --config-path "$scratch/config" \
    --security-path "$scratch/security" \
    --configuration release --skip-update --force-resolved-versions \
    --product embedded-application-macro-probe \
    >"$scratch/logs/plugin-build.txt" 2>&1
plugin_bin="$(swift build \
    --package-path "$repo_root/Tools/EmbeddedApplicationMacros" \
    --scratch-path "$scratch/plugin-build" \
    --cache-path "$scratch/cache" \
    --config-path "$scratch/config" \
    --security-path "$scratch/security" \
    --configuration release --show-bin-path)"
plugin="$plugin_bin/EmbeddedApplicationMacroImplementation"
test -x "$plugin"
sha256sum "$plugin" >"$scratch/artifacts/plugin.sha256"
clang -I "$repo_root/Interop" \
    -c "$repo_root/Interop/axoloty_application_entry_v1.c" \
    -o "$scratch/host/application-entry-helper.o" \
    >"$scratch/logs/application-entry-helper-build.txt" 2>&1
clang -I "$repo_root/Interop" \
    -I "$repo_root/Tools/EmbeddedApplicationMacros/Fixtures" \
    -c "$repo_root/Tools/EmbeddedApplicationMacros/Fixtures/abi-fixture.c" \
    -o "$scratch/host/abi-fixture.o" >"$scratch/logs/abi-fixture-build.txt" 2>&1

python3 - "$scratch" <<'PY'
import json
import sys
from pathlib import Path

scratch = Path(sys.argv[1])
for budget in (1, 3, 4, 7, 8, 5912):
    manifest = {
        "schemaVersion": 1,
        "name": f"unit-c1-budget-{budget}",
        "sources": ["StateBudgetApp.swift"],
        "requirements": {"platform": [], "carrier": []},
        "capacities": {
            "maxTopicLength": 1,
            "maxPayloadSize": 1,
            "applicationStateBytes": budget,
        },
    }
    (scratch / "manifests" / f"budget-{budget}.json").write_text(
        json.dumps(manifest, indent=2) + "\n", encoding="utf-8"
    )

values = ", ".join("0" for _ in range(739))
(scratch / "generated" / "OverBudgetStateApp.swift").write_text(
    """// Generated focused fixture: 739 UInt64 fields occupy 5912 bytes on the host.
nonisolated(unsafe) var c1OverBudgetInitializations: UInt32 = 0
nonisolated(unsafe) var c1OverBudgetRunCalls: UInt32 = 0
struct C1OverBudgetState {
    var fields: (""" + ", ".join("UInt64" for _ in range(739)) + ")\n" +
    """    init() {
        c1OverBudgetInitializations &+= 1
        fields = (""" + values + ")\n    }\n}\n" +
    """@EmbeddedApplication
enum OverBudgetApplication {
    typealias State = C1OverBudgetState
    static func run(_ capabilities: EmbeddedCapabilities, state: inout State) -> EmbeddedApplicationResult {
        c1OverBudgetRunCalls &+= 1
        return .completed
    }
}
let c1OverBudgetStride = MemoryLayout<C1OverBudgetState>.stride
""",
    encoding="utf-8",
)
(scratch / "generated" / "OverBudgetHostMain.swift").write_text(
    """// Generated focused host assertion.
@main enum OverBudgetHostMain {
    static func main() {
        precondition(c1OverBudgetStride == 5912)
        precondition(EmbeddedApplicationRequirements.current.applicationStateBytes == 8)
        let result = axoloty_application_main(unit_b_platform_table(), unit_b_minimal_carrier_table())
        precondition(result == EmbeddedApplicationEntryAdapter.stateBudgetExceededStatus)
        precondition(c1OverBudgetInitializations == 0)
        precondition(c1OverBudgetRunCalls == 0)
        print("PASS stride 5912 exceeds budget 8 before state initialization and run")
    }
}
""",
    encoding="utf-8",
)
PY

common_host=(
    -swift-version 5 -parse-as-library -I "$repo_root/Interop"
    -I "$repo_root/Tools/EmbeddedApplicationMacros/Fixtures"
    -import-objc-header "$repo_root/Tools/EmbeddedApplicationMacros/Fixtures/abi-fixture.h"
    -load-plugin-executable "$plugin#EmbeddedApplicationMacroImplementation"
    "$repo_root/Sources/EmbeddedCapabilities/EmbeddedApplicationMacro.swift"
    "$repo_root/Sources/EmbeddedCapabilities/EmbeddedApplicationDefinition.swift"
    "$repo_root/Sources/EmbeddedCapabilities/EmbeddedApplicationEntryAdapter.swift"
    "$repo_root/Sources/EmbeddedCapabilities/EmbeddedCapabilities.swift"
    "$repo_root/Sources/EmbeddedCapabilities/EmbeddedRequirements.swift"
    "$scratch/host/abi-fixture.o"
    "$scratch/host/application-entry-helper.o"
)

for budget in 7 8; do
    generated="$scratch/generated/requirements-$budget.swift"
    manifest="$scratch/manifests/budget-${budget}.json"
    python3 - "$repo_root/Tools/EmbeddedApplicationMacros/Fixtures/UnitC1/StateBudgetApp.swift" "$manifest" "$scratch/manifests/state-budget-$budget.json" <<'PY'
import json, sys
from pathlib import Path
value=json.loads(Path(sys.argv[2]).read_text())
value["sources"]=[Path(sys.argv[1]).name]
Path(sys.argv[3]).write_text(json.dumps(value, indent=2)+"\n")
PY
    python3 Tools/validate-composition.py --repo-root "$repo_root" \
        --app-manifest "$scratch/manifests/state-budget-$budget.json" \
        --emit-requirements "$generated" >"$scratch/logs/requirements-$budget.txt" 2>&1
    swiftc "${common_host[@]}" "$generated" \
        "$repo_root/Tools/EmbeddedApplicationMacros/Fixtures/UnitC1/StateBudgetApp.swift" \
        "$repo_root/Tools/EmbeddedApplicationMacros/Fixtures/UnitC1/StateBudgetHostMain.swift" \
        -o "$scratch/host/state-budget-$budget" >"$scratch/logs/host-budget-$budget-build.txt" 2>&1
    "$scratch/host/state-budget-$budget" >"$scratch/logs/host-budget-$budget.txt" 2>&1
done

over_budget_manifest="$scratch/manifests/over-budget.json"
python3 - "$over_budget_manifest" <<'PY'
import json, sys
from pathlib import Path
Path(sys.argv[1]).write_text(json.dumps({
    "schemaVersion":1,"name":"unit-c1-over-budget","sources":["OverBudgetStateApp.swift"],
    "requirements":{"platform":[],"carrier":[]},
    "capacities":{"maxTopicLength":1,"maxPayloadSize":1,"applicationStateBytes":8}
}, indent=2)+"\n")
PY
python3 Tools/validate-composition.py --repo-root "$repo_root" \
    --app-manifest "$over_budget_manifest" \
    --emit-requirements "$scratch/generated/requirements-over-budget.swift" \
    >"$scratch/logs/requirements-over-budget.txt" 2>&1
swiftc "${common_host[@]}" "$scratch/generated/requirements-over-budget.swift" \
    "$scratch/generated/OverBudgetStateApp.swift" "$scratch/generated/OverBudgetHostMain.swift" \
    -o "$scratch/host/over-budget" >"$scratch/logs/host-over-budget-build.txt" 2>&1
"$scratch/host/over-budget" >"$scratch/logs/host-over-budget.txt" 2>&1

# The production macro still accepts the ordinary copyable and empty callers.
bash Tools/EmbeddedApplicationMacros/check-unit-a.sh "$scratch/unit-a" "$plugin" \
    >"$scratch/logs/unit-a-regression.txt" 2>&1

module_flags=(
    -I "$prepared/json_core" -I "$prepared/axoloty_wire"
    -I "$prepared/axoloty_object_model" -I "$prepared/axoloty_protocol"
    -I "$prepared/axoloty_static_runtime" -I "$prepared/axoloty_coaty_models"
)
target_common=(
    -target riscv32-none-none-eabi -enable-experimental-feature Embedded
    -enable-experimental-feature Lifetimes -wmo -Osize -function-sections
    -Xcc -march=rv32imac_zicsr_zifencei -Xcc -mabi=ilp32
    -I "$repo_root/Interop" -import-objc-header "$repo_root/Interop/axoloty_application_entry_v1.h"
    -load-plugin-executable "$plugin#EmbeddedApplicationMacroImplementation"
    "${module_flags[@]}"
    "$repo_root/Sources/EmbeddedCapabilities/EmbeddedApplicationMacro.swift"
    "$repo_root/Sources/EmbeddedCapabilities/EmbeddedApplicationDefinition.swift"
    "$repo_root/Sources/EmbeddedCapabilities/EmbeddedApplicationEntryAdapter.swift"
    "$repo_root/Sources/EmbeddedCapabilities/EmbeddedCapabilities.swift"
    "$repo_root/Sources/EmbeddedCapabilities/EmbeddedRequirements.swift"
)

python3 - "$scratch/manifests/state-budget-4.json" "$repo_root/Tools/EmbeddedApplicationMacros/Fixtures/UnitC1/MinimalNoncopyableApp.swift" <<'PY'
import json, sys
from pathlib import Path
manifest=json.loads(Path(sys.argv[1].replace("state-budget-4.json", "budget-4.json")).read_text())
manifest["sources"]=[Path(sys.argv[2]).name]
Path(sys.argv[1]).write_text(json.dumps(manifest, indent=2)+"\n")
PY
python3 Tools/validate-composition.py --repo-root "$repo_root" \
    --app-manifest "$scratch/manifests/state-budget-4.json" \
    --emit-requirements "$scratch/generated/requirements-minimal-target.swift" \
    >"$scratch/logs/requirements-minimal-target.txt" 2>&1
swiftc "${target_common[@]}" -module-name C1MinimalNoncopyable \
    "$scratch/generated/requirements-minimal-target.swift" \
    Tools/EmbeddedApplicationMacros/Fixtures/UnitC1/MinimalNoncopyableApp.swift \
    -emit-object -o "$scratch/artifacts/minimal-noncopyable-riscv32.o" \
    -Xfrontend -dump-macro-expansions >"$scratch/logs/minimal-target-compile.txt" 2>&1

python3 Tools/validate-composition.py --repo-root "$repo_root" \
    --app-manifest "$scratch/manifests/budget-1.json" \
    --emit-requirements "$scratch/generated/requirements-empty-target.swift" \
    >"$scratch/logs/requirements-empty-target.txt" 2>&1
swiftc "${target_common[@]}" -module-name C1EmptyState \
    "$scratch/generated/requirements-empty-target.swift" \
    Tools/EmbeddedApplicationMacros/Fixtures/Valid/EmptyState.swift \
    -emit-object -o "$scratch/artifacts/empty-state-riscv32.o" \
    -Xfrontend -dump-macro-expansions >"$scratch/logs/empty-target-compile.txt" 2>&1

python3 - "$scratch/manifests/state-budget-5912.json" "$repo_root/Tools/EmbeddedApplicationMacros/Fixtures/UnitC1/ProcessorApp.swift" <<'PY'
import json, sys
from pathlib import Path
manifest=json.loads(Path(sys.argv[1].replace("state-budget-5912.json", "budget-5912.json")).read_text())
manifest["sources"]=[Path(sys.argv[2]).name]
Path(sys.argv[1]).write_text(json.dumps(manifest, indent=2)+"\n")
PY
python3 Tools/validate-composition.py --repo-root "$repo_root" \
    --app-manifest "$scratch/manifests/state-budget-5912.json" \
    --emit-requirements "$scratch/generated/requirements-processor-target.swift" \
    >"$scratch/logs/requirements-processor-target.txt" 2>&1
swiftc "${target_common[@]}" -module-name C1Processor \
    "$scratch/generated/requirements-processor-target.swift" \
    Tools/EmbeddedApplicationMacros/Fixtures/UnitC1/ProcessorApp.swift \
    -emit-object -o "$scratch/artifacts/processor-riscv32.o" \
    -Xfrontend -dump-macro-expansions >"$scratch/logs/processor-target-compile.txt" 2>&1

readelf_tool="$(command -v llvm-readelf || command -v riscv32-esp-elf-readelf || command -v readelf)"
nm_tool="$(command -v llvm-nm || command -v riscv32-esp-elf-nm || command -v nm)"
objdump_tool="$(command -v llvm-objdump || command -v riscv32-esp-elf-objdump || command -v objdump)"
for name in minimal-noncopyable empty-state processor; do
    object="$scratch/artifacts/$name-riscv32.o"
    "$readelf_tool" -SWs "$object" >"$scratch/artifacts/$name-readelf.txt"
    "$nm_tool" -S --size-sort "$object" >"$scratch/artifacts/$name-symbols.txt"
    "$objdump_tool" -dr "$object" >"$scratch/artifacts/$name-disassembly.txt"
done
grep -F 'axoloty_application_main' "$scratch/artifacts/minimal-noncopyable-symbols.txt" >/dev/null
grep -F 'axoloty_application_main' "$scratch/artifacts/processor-symbols.txt" >/dev/null
python3 - "$scratch/artifacts" <<'PY'
import json, re, sys
from pathlib import Path

root=Path(sys.argv[1])
def inspect(name, expected_size, expected_section):
    report=(root/f"{name}-readelf.txt").read_text()
    sections={}
    for line in report.splitlines():
        match=re.match(r"\s*\[\s*(\d+)\]\s+(\.\S+)\s+\S+", line)
        if match:
            sections[int(match.group(1))]=match.group(2)
    symbols=[]
    for line in report.splitlines():
        match=re.match(r"\s*\d+:\s+[0-9a-fA-F]+\s+(\d+)\s+OBJECT\s+\S+\s+\S+\s+(\d+)\s+(\S+)", line)
        if match and "__axoloty_application_state" in match.group(3) and match.group(3).endswith("StateVvp"):
            symbols.append((int(match.group(1)), sections.get(int(match.group(2))), match.group(3)))
    assert len(symbols)==1, (name, symbols)
    size, section, symbol=symbols[0]
    assert size==expected_size and section==expected_section, (name, size, section)
    return {"size":size,"stride":expected_size,"alignment":4,"section":section,"symbol":symbol}

minimal=inspect("minimal-noncopyable",4,".data")
processor=inspect("processor",5912,".bss")
empty_report=(root/"empty-state-readelf.txt").read_text()
assert "axoloty_application_main" in (root/"empty-state-symbols.txt").read_text(), "empty state target entry missing"
minimal_asm=(root/"minimal-noncopyable-disassembly.txt").read_text()
assert all(re.search(rf"Disassembly of section \.text\.c1_minimal_{field}:.*?li\s+a0, 0x4", minimal_asm, re.S)
           for field in ("size","stride","alignment")), "minimal target layout constants differ"
processor_asm=(root/"processor-disassembly.txt").read_text()
assert re.search(r"Disassembly of section \.text\.OUTLINED_FUNCTION_5:.*?lui\s+a0, 0x1.*?addi\s+a0, a0, 0x718", processor_asm, re.S), "processor target size/stride constants differ from 5912"
assert re.search(r"Disassembly of section \.text\.c1_processor_alignment:.*?li\s+a0, 0x4", processor_asm, re.S), "processor target alignment differs from 4"
empty_asm=(root/"empty-state-disassembly.txt").read_text()
assert all(re.search(rf"Disassembly of section \.text\.c1_empty_{field}:.*?li\s+a0, 0x{value:x}", empty_asm, re.S)
           for field,value in (("size",0),("stride",1),("alignment",1))), "empty target layout differs"
(root/"layout-summary.json").write_text(json.dumps({"empty":{"size":0,"stride":1,"alignment":1,"budget":1},"minimal":minimal,"processor":processor},indent=2)+"\n")
PY
(
    cd "$scratch/artifacts"
    find . -maxdepth 1 -type f ! -name artifact-hashes.sha256 -print0 \
        | sort -z | xargs -0 sha256sum >artifact-hashes.sha256
    sha256sum -c artifact-hashes.sha256 >"$scratch/logs/container-artifact-hash-verification.txt"
)
sha256sum -c "$scratch/artifacts/source-sha256.txt" \
    >"$scratch/logs/container-source-hash-verification.txt"
printf 'PASS host budget rejection, exact fit, state persistence, copyable/empty regressions, and target object inspection\n'
