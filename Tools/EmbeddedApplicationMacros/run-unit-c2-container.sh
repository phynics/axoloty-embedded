#!/usr/bin/env bash
# Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.
set -euo pipefail

repo_root=/source
scratch=/scratch
prepared=/prepared
mkdir -p "$scratch"/{cache,config,security,plugin-build,generated,host,target,manifests,logs,artifacts}
cd "$repo_root"
exec 9>"$scratch/logs/commands.txt"
BASH_XTRACEFD=9
set -x

python3 - <<'PY' >"$scratch/logs/preparation-identity.txt"
import json
from pathlib import Path
report=json.loads(Path("/preparation/preparation.json").read_text())
assert report["status"] == "prepared"
assert report["core"]["sha"] == "f8c201f717e843d7b838ba1d9ff56bd5be729522"
assert report["contractSHA256"] == "27254ace9481cd6b0d7d51063f29ac61b29b25b5f795d2aafe6087f406de0a7d"
for name in ("json_core", "axoloty_wire", "axoloty_object_model", "axoloty_protocol", "axoloty_static_runtime", "axoloty_coaty_models"):
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

bash Tools/EmbeddedApplicationMacros/run-first-init-unit.sh \
    "$scratch/first-init" "$plugin" --embedded-target \
    >"$scratch/logs/first-init-unit.log" 2>&1

clang -I Interop -c Interop/axoloty_application_entry_v1.c \
    -o "$scratch/host/application-entry-helper.o" \
    >"$scratch/logs/host-helper-compile.txt" 2>&1
clang -I Interop -I Tools/EmbeddedApplicationMacros/Fixtures \
    -c Tools/EmbeddedApplicationMacros/Fixtures/abi-fixture.c \
    -o "$scratch/host/abi-fixture.o" >"$scratch/logs/host-abi-fixture-compile.txt" 2>&1
clang -pthread -I Interop -I Tools/EmbeddedApplicationMacros/Fixtures \
    -c Tools/EmbeddedApplicationMacros/Fixtures/UnitC2/race-fixture.c \
    -o "$scratch/host/race-fixture.o" >"$scratch/logs/host-race-fixture-compile.txt" 2>&1

python3 - "$scratch" <<'PY'
import json, sys
from pathlib import Path
scratch=Path(sys.argv[1])
manifest={"schemaVersion":1,"name":"unit-c2-entry-exclusion","sources":["EntryExclusionApp.swift"],"requirements":{"platform":[],"carrier":[]},"capacities":{"maxTopicLength":1,"maxPayloadSize":1,"applicationStateBytes":4}}
(scratch/"manifests/app.json").write_text(json.dumps(manifest, indent=2)+"\n")
PY
python3 Tools/validate-composition.py --repo-root "$repo_root" \
    --app-manifest "$scratch/manifests/app.json" \
    --emit-requirements "$scratch/generated/ManifestRequirements.swift" \
    >"$scratch/logs/requirements.txt" 2>&1

common_host=(
    -swift-version 5 -parse-as-library -I Interop
    -I Tools/EmbeddedApplicationMacros/Fixtures
    -import-objc-header Tools/EmbeddedApplicationMacros/Fixtures/abi-fixture.h
    -load-plugin-executable "$plugin#EmbeddedApplicationMacroImplementation"
    Sources/EmbeddedCapabilities/EmbeddedApplicationMacro.swift
    Sources/EmbeddedCapabilities/EmbeddedApplicationDefinition.swift
    Sources/EmbeddedCapabilities/EmbeddedApplicationEntryAdapter.swift
    Sources/EmbeddedCapabilities/EmbeddedCapabilities.swift
    Sources/EmbeddedCapabilities/EmbeddedRequirements.swift
    "$scratch/generated/ManifestRequirements.swift"
    Tools/EmbeddedApplicationMacros/Fixtures/UnitC2/EntryExclusionApp.swift
    Tools/EmbeddedApplicationMacros/Fixtures/UnitC2/EntryExclusionHostMain.swift
    "$scratch/host/abi-fixture.o"
    "$scratch/host/application-entry-helper.o"
    "$scratch/host/race-fixture.o"
    -lpthread
)
for scenario in repeat invalid-abi recursive failed race; do
    swiftc "${common_host[@]}" -o "$scratch/host/$scenario" \
        >"$scratch/logs/$scenario-build.txt" 2>&1
    timeout --signal=TERM --kill-after=5s 30s "$scratch/host/$scenario" "$scenario" >"$scratch/logs/$scenario.txt" 2>&1
done

# A/B1 regression uses the real macro, production headers and the shared C helper.
bash Tools/EmbeddedApplicationMacros/check-unit-a.sh "$scratch/unit-a" "$plugin" \
    >"$scratch/logs/unit-a-regression.txt" 2>&1

# C1 regression retains the corrected budget rejection and single-use repeat assertion.
mkdir -p "$scratch/unit-c1-regression/artifacts"
cp "$scratch/source-sha256.txt" "$scratch/unit-c1-regression/artifacts/source-sha256.txt"
bash Tools/EmbeddedApplicationMacros/run-unit-c1-container.sh "$scratch/unit-c1-regression" \
    >"$scratch/logs/unit-c1-regression.txt" 2>&1

# B regression exercises capability boundaries and a minimal real macro entry.
AXOLOTY_SCRATCH="$scratch/unit-b-build" \
    bash Tools/EmbeddedApplicationMacros/check-unit-b.sh "$scratch/unit-b-regression" \
    >"$scratch/logs/unit-b-regression.txt" 2>&1

# Compile the helper with the ESP32-C6 RISC-V compiler at firmware optimization.
# The image installs the toolchain under /opt/esp but adds it to PATH only when
# the IDF environment is exported.
if ! command -v riscv32-esp-elf-gcc >/dev/null 2>&1 && [ -f /opt/esp/idf/export.sh ]; then
    . /opt/esp/idf/export.sh >/dev/null 2>&1
fi
target_cc="$(command -v riscv32-esp-elf-gcc)" || {
    echo "missing riscv32-esp-elf-gcc; cannot compile the C2 target objects" >&2
    exit 1
}
target_objdump="$(command -v riscv32-esp-elf-objdump)" || {
    echo "missing riscv32-esp-elf-objdump; cannot disassemble the C2 target objects" >&2
    exit 1
}
target_nm="$(command -v riscv32-esp-elf-nm)" || {
    echo "missing riscv32-esp-elf-nm; cannot inspect the C2 target objects" >&2
    exit 1
}
"$target_cc" -march=rv32imac_zicsr_zifencei -mabi=ilp32 -O2 \
    -ffreestanding -fno-builtin -Wall -Wextra -Werror \
    -I Interop -c Interop/axoloty_application_entry_v1.c \
    -o "$scratch/artifacts/application-entry-riscv32.o" \
    >"$scratch/logs/target-helper-compile.txt" 2>&1
"$target_objdump" -dr "$scratch/artifacts/application-entry-riscv32.o" \
    >"$scratch/artifacts/application-entry-riscv32-disassembly.txt"
"$target_nm" -u "$scratch/artifacts/application-entry-riscv32.o" \
    >"$scratch/artifacts/application-entry-riscv32-undefined.txt"
"$target_nm" -S --size-sort "$scratch/artifacts/application-entry-riscv32.o" \
    >"$scratch/artifacts/application-entry-riscv32-symbols.txt"
grep -E 'lr\.w|sc\.w|amoswap\.w|amocas\.w' \
    "$scratch/artifacts/application-entry-riscv32-disassembly.txt" >/dev/null
test ! -s "$scratch/artifacts/application-entry-riscv32-undefined.txt"
if grep -E 'atomic|malloc|calloc|realloc|free' "$scratch/artifacts/application-entry-riscv32-undefined.txt"; then
    echo "helper has a forbidden undefined atomic or allocator symbol" >&2
    exit 1
fi

# Compile the actual macro entry with the production C imports and noncopyable Core processor state.
module_flags=(
    -I "$prepared/json_core" -I "$prepared/axoloty_wire"
    -I "$prepared/axoloty_object_model" -I "$prepared/axoloty_protocol"
    -I "$prepared/axoloty_static_runtime" -I "$prepared/axoloty_coaty_models"
)
target_common=(
    -target riscv32-none-none-eabi -enable-experimental-feature Embedded
    -enable-experimental-feature Lifetimes -wmo -Osize -function-sections
    -Xcc -march=rv32imac_zicsr_zifencei -Xcc -mabi=ilp32
    -I Interop -import-objc-header Interop/axoloty_application_entry_v1.h
    -load-plugin-executable "$plugin#EmbeddedApplicationMacroImplementation"
    "${module_flags[@]}"
    Sources/EmbeddedCapabilities/EmbeddedApplicationMacro.swift
    Sources/EmbeddedCapabilities/EmbeddedApplicationDefinition.swift
    Sources/EmbeddedCapabilities/EmbeddedApplicationEntryAdapter.swift
    Sources/EmbeddedCapabilities/EmbeddedCapabilities.swift
    Sources/EmbeddedCapabilities/EmbeddedRequirements.swift
)
python3 - "$scratch/manifests/processor-app.json" <<'PY'
import json, sys
from pathlib import Path
value=json.loads(Path(sys.argv[1].replace("processor-app.json", "app.json")).read_text())
value["name"]="unit-c2-processor"
value["sources"]=["ProcessorApp.swift"]
value["capacities"]["applicationStateBytes"]=5912
Path(sys.argv[1]).write_text(json.dumps(value, indent=2)+"\n")
PY
python3 Tools/validate-composition.py --repo-root "$repo_root" \
    --app-manifest "$scratch/manifests/processor-app.json" \
    --emit-requirements "$scratch/generated/ProcessorRequirements.swift" \
    >"$scratch/logs/processor-requirements.txt" 2>&1
swiftc "${target_common[@]}" -module-name C2Processor \
    "$scratch/generated/ProcessorRequirements.swift" \
    Tools/EmbeddedApplicationMacros/Fixtures/UnitC1/ProcessorApp.swift \
    -emit-object -o "$scratch/artifacts/processor-entry-riscv32.o" \
    -Xfrontend -dump-macro-expansions \
    >"$scratch/logs/processor-entry-compile.txt" 2>&1
"$target_objdump" -dr "$scratch/artifacts/processor-entry-riscv32.o" \
    >"$scratch/artifacts/processor-entry-riscv32-disassembly.txt"
"$target_nm" -u "$scratch/artifacts/processor-entry-riscv32.o" \
    >"$scratch/artifacts/processor-entry-riscv32-undefined.txt"
"$target_nm" -g --defined-only "$scratch/artifacts/processor-entry-riscv32.o" \
    >"$scratch/artifacts/processor-entry-riscv32-defined.txt"
grep -F 'axoloty_application_main' "$scratch/artifacts/processor-entry-riscv32-defined.txt" >/dev/null
grep -F 'axoloty_application_entry_claim_v1' "$scratch/artifacts/processor-entry-riscv32-undefined.txt" >/dev/null
"$(command -v riscv32-esp-elf-ld)" -r \
    "$scratch/artifacts/processor-entry-riscv32.o" \
    "$scratch/artifacts/application-entry-riscv32.o" \
    -o "$scratch/artifacts/processor-entry-with-helper-riscv32.o" \
    >"$scratch/logs/partial-link.txt" 2>&1
"$target_nm" -u "$scratch/artifacts/processor-entry-with-helper-riscv32.o" \
    >"$scratch/artifacts/processor-entry-with-helper-undefined.txt"
if grep -F 'axoloty_application_entry_claim_v1' \
    "$scratch/artifacts/processor-entry-with-helper-undefined.txt"; then
    echo "partial link did not resolve the shared entry helper" >&2
    exit 1
fi

(
    cd "$scratch"
    find artifacts -type f ! -name artifact-hashes.sha256 -print0 \
        | sort -z | xargs -0 sha256sum >artifacts/artifact-hashes.sha256
)
