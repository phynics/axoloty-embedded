#!/usr/bin/env bash
# Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.
# Verify manifest-driven requirements and ABI boundaries for Unit B.
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/../.." && pwd)"
scratch="${1:?pass private scratch directory}"
mkdir -p "$scratch"/{generated,logs,host,target,plugin-build}
cd "$repo_root"
swift --version >"$scratch/logs/toolchain.log" 2>&1
sha256sum \
    Tools/capability_catalog.py Tools/validate-composition.py Tools/build-embedded-macro.sh \
    Sources/EmbeddedCapabilities/EmbeddedRequirements.swift \
    Sources/EmbeddedCapabilities/EmbeddedCapabilities.swift \
    Sources/EmbeddedCapabilities/EmbeddedApplicationEntryAdapter.swift \
    Tools/EmbeddedApplicationMacros/Sources/EmbeddedApplicationMacroImplementation/EmbeddedApplicationMacro.swift \
    Interop/axoloty_platform_v1.h Interop/axoloty_carrier_v1.h Interop/axoloty_application_entry_v1.h \
    Interop/axoloty_application_entry_v1.c \
    Tools/EmbeddedApplicationMacros/Fixtures/ABIPrefixCheck.c \
    Tools/EmbeddedApplicationMacros/Fixtures/abi-fixture.c \
    Tools/EmbeddedApplicationMacros/Fixtures/CapabilityBoundaryCheck.swift \
    Tools/EmbeddedApplicationMacros/Fixtures/MinimalConsole/app.json \
    Applications/device-smoke-agent/app.json >"$scratch/logs/source-hashes.txt"

plugin="$(AXOLOTY_SCRATCH="${AXOLOTY_SCRATCH:-$scratch/plugin-build}" bash Tools/build-embedded-macro.sh)"
test -x "$plugin"
printf 'PASS normal bootstrap produced plugin: %s\n' "$plugin"

python3 Tools/validate-composition.py \
    --repo-root "$repo_root" --profile Profiles/esp32c6-mqtt/profile.json \
    --emit-requirements "$scratch/generated/smoke.swift" >"$scratch/logs/smoke-generator.log" 2>&1
python3 Tools/validate-composition.py \
    --repo-root "$repo_root" --profile Profiles/esp32c6-mqtt/profile.json \
    --emit-requirements "$scratch/generated/smoke-repeat.swift" >"$scratch/logs/smoke-repeat.log" 2>&1
cmp "$scratch/generated/smoke.swift" "$scratch/generated/smoke-repeat.swift"
printf 'PASS smoke requirements generation is byte-stable\n'

python3 Tools/validate-composition.py \
    --repo-root "$repo_root" \
    --app-manifest Tools/EmbeddedApplicationMacros/Fixtures/MinimalConsole/app.json \
    --emit-requirements "$scratch/generated/minimal-console.swift" >"$scratch/logs/minimal-generator.log" 2>&1
grep -F 'platformCapabilities: 8' "$scratch/generated/minimal-console.swift" >/dev/null
grep -F 'carrierCapabilities: 0' "$scratch/generated/minimal-console.swift" >/dev/null
printf 'PASS console-only app generates just console.write and zero carrier requirements\n'

python3 - "$repo_root" "$scratch" <<'PY'
import copy
import json
import subprocess
import sys
from pathlib import Path

root, scratch = Path(sys.argv[1]), Path(sys.argv[2])
base = json.loads((root / "Tools/EmbeddedApplicationMacros/Fixtures/MinimalConsole/app.json").read_text())
cases = [
    ("unknown", lambda x: x["requirements"]["platform"].append("platform.magic"), "unknown platform capability name: platform.magic"),
    ("duplicate", lambda x: x["requirements"]["platform"].append("console.write"), "contains a duplicate capability"),
    ("missing", lambda x: x.pop("requirements"), "requirements must declare platform and carrier arrays"),
    ("malformed-capacity", lambda x: x["capacities"].update(maxTopicLength=True), "capacities.maxTopicLength must be a positive UInt32"),
    ("overflow-capacity", lambda x: x["capacities"].update(maxPayloadSize=4294967296), "capacities.maxPayloadSize must be a positive UInt32"),
]
for name, mutate, expected in cases:
    value = copy.deepcopy(base)
    mutate(value)
    path = scratch / f"{name}.json"
    path.write_text(json.dumps(value), encoding="utf-8")
    result = subprocess.run([
        sys.executable, str(root / "Tools/validate-composition.py"),
        "--repo-root", str(root), "--app-manifest", str(path),
        "--emit-requirements", str(scratch / f"{name}.swift"),
    ], text=True, capture_output=True)
    (scratch / "logs" / f"{name}.log").write_text(
        f"command exit={result.returncode}\nstdout:\n{result.stdout}stderr:\n{result.stderr}", encoding="utf-8"
    )
    assert result.returncode != 0, f"{name} unexpectedly succeeded"
    assert expected in result.stderr, f"{name} missing diagnostic: {expected}\n{result.stderr}"
    print(f"PASS {name} rejected (exit {result.returncode}): {expected}")
PY

clang -fsanitize=address -g -I Interop \
    Tools/EmbeddedApplicationMacros/Fixtures/ABIPrefixCheck.c \
    -o "$scratch/host/abi-prefix-check" >"$scratch/logs/abi-prefix-build.log" 2>&1
ASAN_OPTIONS=detect_leaks=1 "$scratch/host/abi-prefix-check" \
    >"$scratch/logs/abi-prefix.log" 2>&1
cat "$scratch/logs/abi-prefix.log"

clang -I Interop -I Tools/EmbeddedApplicationMacros/Fixtures \
    -c Tools/EmbeddedApplicationMacros/Fixtures/abi-fixture.c \
    -o "$scratch/host/abi-fixture.o"
clang -I Interop -c Interop/axoloty_application_entry_v1.c \
    -o "$scratch/host/application-entry-helper.o"
python3 Tools/validate-composition.py \
    --repo-root "$repo_root" \
    --app-manifest Tools/EmbeddedApplicationMacros/Fixtures/BoundedCarrier/app.json \
    --emit-requirements "$scratch/generated/bounded-carrier.swift" >"$scratch/logs/bounded-generator.log" 2>&1
swiftc -parse-as-library -module-name CapabilityBoundaryCheck \
    -I Interop -I Tools/EmbeddedApplicationMacros/Fixtures \
    -import-objc-header Tools/EmbeddedApplicationMacros/Fixtures/abi-fixture.h \
    Sources/EmbeddedCapabilities/EmbeddedCapabilities.swift \
    Sources/EmbeddedCapabilities/EmbeddedRequirements.swift \
    "$scratch/generated/bounded-carrier.swift" \
    Tools/EmbeddedApplicationMacros/Fixtures/CapabilityBoundaryCheck.swift \
    "$scratch/host/abi-fixture.o" -o "$scratch/host/capability-boundary-check" \
    >"$scratch/logs/capability-compile.log" 2>&1
"$scratch/host/capability-boundary-check"
printf 'PASS required call, undeclared operation, wrapper bounds and invalid output length\n'

swiftc -parse-as-library -module-name MinimalConsoleEntryCheck \
    -I Interop -I Tools/EmbeddedApplicationMacros/Fixtures \
    -import-objc-header Tools/EmbeddedApplicationMacros/Fixtures/abi-fixture.h \
    -load-plugin-executable "$plugin#EmbeddedApplicationMacroImplementation" \
    Sources/EmbeddedCapabilities/EmbeddedApplicationMacro.swift \
    Sources/EmbeddedCapabilities/EmbeddedApplicationDefinition.swift \
    Sources/EmbeddedCapabilities/EmbeddedApplicationEntryAdapter.swift \
    Sources/EmbeddedCapabilities/EmbeddedCapabilities.swift \
    Sources/EmbeddedCapabilities/EmbeddedRequirements.swift \
    "$scratch/generated/minimal-console.swift" \
    Tools/EmbeddedApplicationMacros/Fixtures/MinimalConsole/ConsoleOnly.swift \
    Tools/EmbeddedApplicationMacros/Fixtures/MinimalConsole/EntryCheckMain.swift \
    "$scratch/host/abi-fixture.o" "$scratch/host/application-entry-helper.o" \
    -o "$scratch/host/minimal-console-entry-check" \
    >"$scratch/logs/minimal-entry-compile.log" 2>&1
"$scratch/host/minimal-console-entry-check"
printf 'PASS console-only entry starts with a null-function carrier table and console.write only\n'

bash Tools/EmbeddedApplicationMacros/check-unit-a.sh "$scratch/unit-a" "$plugin" \
    >"$scratch/logs/unit-a.log" 2>&1
cat "$scratch/logs/unit-a.log"

python3 Tools/validate-composition.py \
    --repo-root "$repo_root" \
    --app-manifest Tools/EmbeddedApplicationMacros/Fixtures/MinimalConsole/app.json \
    --emit-requirements "$scratch/generated/ManifestRequirements.swift" \
    >"$scratch/logs/minimal-target-generator.log" 2>&1
swiftc -target riscv32-none-none-eabi -enable-experimental-feature Embedded -wmo \
    -parse-as-library -module-name MinimalConsoleApplication \
    -I Interop -import-objc-header Interop/axoloty_application_entry_v1.h \
    -load-plugin-executable "$plugin#EmbeddedApplicationMacroImplementation" \
    Sources/EmbeddedCapabilities/EmbeddedApplicationMacro.swift \
    Sources/EmbeddedCapabilities/EmbeddedApplicationDefinition.swift \
    Sources/EmbeddedCapabilities/EmbeddedApplicationEntryAdapter.swift \
    Sources/EmbeddedCapabilities/EmbeddedCapabilities.swift \
    Sources/EmbeddedCapabilities/EmbeddedRequirements.swift \
    "$scratch/generated/ManifestRequirements.swift" \
    Tools/EmbeddedApplicationMacros/Fixtures/MinimalConsole/ConsoleOnly.swift \
    -emit-object -o "$scratch/target/minimal-console-entry.o" \
    >"$scratch/logs/minimal-target-compile.log" 2>&1
symbol_tool="$(command -v llvm-nm || command -v riscv32-esp-elf-nm || command -v nm)"
"$symbol_tool" -g --defined-only "$scratch/target/minimal-console-entry.o" \
    >"$scratch/logs/minimal-target-symbols.txt"
grep -F axoloty_application_main "$scratch/logs/minimal-target-symbols.txt" >/dev/null
printf 'PASS minimal console app compiles with production macro and imported ABI headers\n'

printf 'Unit B focused checks complete. Scratch: %s\n' "$scratch"

