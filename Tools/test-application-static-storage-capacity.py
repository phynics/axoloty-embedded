# Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.
"""Check the optional app static-storage capacity contract."""

from __future__ import annotations

import importlib.util
import json
import os
from pathlib import Path
import struct
import subprocess
import sys
import tempfile


ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "Tools"))
SPEC = importlib.util.spec_from_file_location(
    "validate_composition", ROOT / "Tools" / "validate-composition.py"
)
assert SPEC is not None and SPEC.loader is not None
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)
POLICY_SPEC = importlib.util.spec_from_file_location(
    "static_storage_policy", ROOT / "Tools" / "EmbeddedApplicationMacros" / "static_storage_policy.py"
)
assert POLICY_SPEC is not None and POLICY_SPEC.loader is not None
POLICY = importlib.util.module_from_spec(POLICY_SPEC)
POLICY_SPEC.loader.exec_module(POLICY)


def synthetic_elf_and_map(map_member: str) -> tuple[bytes, str]:
    """Build a small ELF32/map pair accepted by the production storage auditor."""
    names = b"\0.shstrtab\0.strtab\0.symtab\0.data\0.bss\0"
    strings = b"\0state\0state_alias\0tail\0"
    names_offset = 52
    strings_offset = names_offset + len(names)
    symbols_offset = strings_offset + len(strings)
    data_offset = symbols_offset + 4 * 16
    bss_offset = data_offset + 8
    sections = [
        (0, 0, 0, 0, 0, 0, 0, 0, 0, 0),
        (names.index(b".shstrtab"), 3, 0, 0, names_offset, len(names), 0, 0, 1, 0),
        (names.index(b".strtab"), 3, 0, 0, strings_offset, len(strings), 0, 0, 1, 0),
        (names.index(b".symtab"), 2, 0, 0, symbols_offset, 64, 2, 1, 4, 16),
        (names.index(b".data"), 1, 3, 0x1000, data_offset, 8, 0, 0, 4, 0),
        (names.index(b".bss"), 8, 3, 0x2000, bss_offset, 16, 0, 0, 4, 0),
    ]
    elf = bytearray(b"\0" * 52)
    elf.extend(names)
    elf.extend(strings)
    elf.extend(b"\0" * 16)
    for name, address, size in ((1, 0x1000, 4), (7, 0x1000, 4), (19, 0x2000, 8)):
        elf.extend(struct.pack("<IIIBBH", name, address, size, 0x11, 0,
                               4 if address == 0x1000 else 5))
    elf.extend(b"12345678")
    sections_offset = len(elf)
    for section in sections:
        elf.extend(struct.pack("<IIIIIIIIII", *section))
    elf[0:16] = b"\x7fELF\x01\x01\x01" + b"\0" * 9
    elf[16:52] = struct.pack("<HHIIIIIHHHHHH", 2, 243, 1, 0, 0,
                             sections_offset, 0, 52, 32, 0, 40, 6, 1)
    linker_map = (
        ".data 0x1000 0x8\n"
        f" .data 0x1000 0x8 esp-idf/main/libmain.a({map_member})\n"
        ".bss 0x2000 0x10\n"
        f" .bss 0x2000 0x8 esp-idf/main/libmain.a({map_member})\n"
        " *fill* 0x2008 0x8\n"
    )
    return bytes(elf), linker_map


def manifest(static_capacity: object = ...) -> dict:
    capacities = {
        "maxTopicLength": 1,
        "maxPayloadSize": 1,
        "applicationStateBytes": 1,
    }
    if static_capacity is not ...:
        capacities["applicationStaticStorageBytes"] = static_capacity
    return {"requirements": {"platform": [], "carrier": []}, "capacities": capacities}


def main() -> int:
    completed_cases: set[str] = set()

    path = Path("minimal-app.json")
    # Existing minimal manifests remain valid without the new optional field.
    MODULE.app_requirements(manifest(), path)
    for value in (1, 73728, 0xFFFFFFFF):
        MODULE.app_requirements(manifest(value), path)
    for value in (True, False, 1.5, 0, -1, 0x100000000, "73728", None):
        try:
            MODULE.app_requirements(manifest(value), path)
        except MODULE.CompositionError as error:
            assert "applicationStaticStorageBytes must be a positive UInt32" in str(error)
        else:
            raise AssertionError(f"invalid static-storage capacity accepted: {value!r}")

    with tempfile.TemporaryDirectory() as temporary:
        temp = Path(temporary)
        app = temp / "app"
        app.mkdir()
        manifest_path = app / "app.json"
        inventory_path = app / "storage-inventory.json"
        build = temp / "build"
        build.mkdir()
        cache_path = build / "CMakeCache.txt"
        evidence = temp / "evidence"
        evidence.mkdir()
        manifest_path.write_text(json.dumps({"name": "fixture", "capacities": {}}), encoding="utf-8")
        inventory = {"schemaVersion": 1, "app": "fixture", "expectedMapMember": "DifferentName.swift.obj",
                     "entries": []}
        inventory_path.write_text(json.dumps(inventory), encoding="utf-8")

        def cache(mode: str, transport: str = "mqtt") -> None:
            transport_dir = f"/checkout/Transports/{'zenoh-pico' if transport == 'zenoh' else 'mqtt'}"
            cache_path.write_text(
                f"AXOLOTY_QUALIFICATION_CARRIER_SCENARIO:BOOL={mode}\n"
                f"AXOLOTY_TRANSPORT_DIR:PATH={transport_dir}\n", encoding="utf-8"
            )

        # The configured CMake mode is authoritative. An exported flag alone
        # cannot turn a normal Swift build into a skipped audit.
        cache("OFF")
        os.environ["AXOLOTY_QUALIFICATION_CARRIER_SCENARIO"] = "1"
        assert POLICY.classify(cache_path, manifest_path, inventory_path) == "swift-not-configured"
        del os.environ["AXOLOTY_QUALIFICATION_CARRIER_SCENARIO"]
        completed_cases.add("environment flag cannot bypass configured OFF cache")

        # Optional policy keeps minimal apps valid and yields an explicit
        # not-configured receipt without inventing a budget pass.
        (evidence / "linked-static-storage-budget.json").write_text("stale", encoding="utf-8")
        cache("OFF")
        gate_args = [str(ROOT / "Tools/EmbeddedApplicationMacros/static-storage-build-gate.sh"),
                     str(ROOT), str(app), "fixture", str(build), str(evidence),
                     "esp-idf/main/libmain.a"]
        subprocess.run(gate_args, check=True, capture_output=True, text=True)
        assert not (evidence / "linked-static-storage-budget.json").exists()
        assert json.loads((evidence / "static-storage-policy.json").read_text()) ["status"] == "not-configured"
        completed_cases.add("unconfigured policy receipt through production gate")

        # A C-only image is not applicable, clears stale reports, and does not
        # require Swift ELF/map artifacts. The unsupported MQTT selection fails.
        cache("ON", "zenoh")
        (evidence / "linked-static-storage-budget.json").write_text("stale", encoding="utf-8")
        subprocess.run(gate_args, check=True, capture_output=True, text=True)
        assert not (evidence / "linked-static-storage-budget.json").exists()
        assert json.loads((evidence / "static-storage-policy.json").read_text())["status"] == "not-applicable"
        completed_cases.add("Zenoh C-only not-applicable receipt through production gate")
        cache("ON", "mqtt")
        try:
            POLICY.classify(cache_path, manifest_path, inventory_path)
        except POLICY.PolicyError as error:
            assert "must select zenoh-pico" in str(error)
        else:
            raise AssertionError("C-only mode accepted for a non-Zenoh configured transport")
        completed_cases.add("C-only policy rejects MQTT transport")

        # Inventory member selection is SDK neutral and may vary per app.
        manifest_path.write_text(json.dumps({"name": "fixture", "capacities": {
            "applicationStaticStorageBytes": 73728}}), encoding="utf-8")
        cache("OFF")
        assert POLICY.classify(cache_path, manifest_path, inventory_path) == \
            "swift-configured:DifferentName.swift.obj"
        completed_cases.add("alternate app inventory member classification")
        for invalid in (None, True, 0, -1, 0x100000000, "73728"):
            manifest_path.write_text(json.dumps({"name": "fixture", "capacities": {
                "applicationStaticStorageBytes": invalid}}), encoding="utf-8")
            try:
                POLICY.classify(cache_path, manifest_path, inventory_path)
            except POLICY.PolicyError as error:
                assert "positive UInt32" in str(error)
            else:
                raise AssertionError(f"malformed configured policy bypassed build classification: {invalid!r}")
            completed_cases.add(f"malformed policy rejected: {type(invalid).__name__}")
        manifest_path.write_text(
            '{"name":"fixture","capacities":{"applicationStaticStorageBytes":null,'
            '"applicationStaticStorageBytes":73728}}', encoding="utf-8"
        )
        try:
            POLICY.classify(cache_path, manifest_path, inventory_path)
        except POLICY.PolicyError as error:
            assert "duplicate JSON key" in str(error)
        else:
            raise AssertionError("duplicate policy key bypassed build classification")
        completed_cases.add("duplicate policy key rejected")

    # Every post-link gate case uses fresh private files and the actual shell
    # gate, auditor CLI, and generated ELF/map fixture. No retained build is
    # needed or consulted.
    gate_path = ROOT / "Tools/EmbeddedApplicationMacros/static-storage-build-gate.sh"

    def gate_fixture(temp: Path, profile: str, ceiling: int, member: str) -> tuple[list[str], Path]:
        app = temp / "app"
        build = temp / "build"
        evidence = temp / "evidence"
        app.mkdir()
        build.mkdir()
        evidence.mkdir()
        (build / "CMakeCache.txt").write_text(
            "AXOLOTY_QUALIFICATION_CARRIER_SCENARIO:BOOL=OFF\n"
            f"AXOLOTY_TRANSPORT_DIR:PATH=/checkout/Transports/{profile}\n", encoding="utf-8"
        )
        (app / "app.json").write_text(json.dumps({"name": "fixture", "capacities": {
            "applicationStaticStorageBytes": ceiling}}), encoding="utf-8")
        (app / "storage-inventory.json").write_text(json.dumps({"schemaVersion": 1,
            "app": "fixture", "expectedMapMember": member, "entries": []}), encoding="utf-8")
        elf, linker_map = synthetic_elf_and_map(member)
        (build / "axoloty-swift.elf").write_bytes(elf)
        (build / "axoloty-swift.map").write_text(linker_map, encoding="utf-8")
        return ([str(gate_path), str(ROOT), str(app), f"fixture-{profile}", str(build),
                 str(evidence), "esp-idf/main/libmain.a"], evidence)

    # Exercise both configured transports. Each report must be repeatable and
    # must come from the production gate's invocation of the real auditor.
    for transport in ("mqtt", "zenoh-pico"):
        with tempfile.TemporaryDirectory() as temporary:
            gate, evidence = gate_fixture(Path(temporary), transport, 73728, "DifferentName.swift.obj")
            env = dict(os.environ, AXOLOTY_QUALIFICATION_CARRIER_SCENARIO="1")
            first = subprocess.run(gate, env=env, check=True, capture_output=True, text=True)
            report_path = evidence / "linked-static-storage-budget.json"
            first_report = report_path.read_bytes()
            report = json.loads(first_report)
            assert report["static_storage_budget"]["actual_bytes"] == 24
            assert report["static_storage_budget"]["passed"] is True
            assert json.loads((evidence / "static-storage-policy.json").read_text())["status"] == "enforced"
            second = subprocess.run(gate, env=env, check=True, capture_output=True, text=True)
            assert report_path.read_bytes() == first_report
            assert first.returncode == second.returncode == 0
            completed_cases.add(f"configured {transport} production gate and deterministic report")

    # A one-byte-low policy fails in the production gate and stops the exact
    # caller sequence that represents publication after post-link validation.
    with tempfile.TemporaryDirectory() as temporary:
        gate, evidence = gate_fixture(Path(temporary), "mqtt", 23, "DifferentName.swift.obj")
        sentinel = evidence / "published.bin"
        caller = 'set -e\n"$@"\ntouch "$SENTINEL"\n'
        env = dict(os.environ, SENTINEL=str(sentinel))
        result = subprocess.run(["sh", "-c", caller, "post-link-test", *gate],
                                env=env, capture_output=True, text=True)
        assert result.returncode == 2, result.stderr
        assert not sentinel.exists(), "over-budget image reached publication after the production gate"
        budget = json.loads((evidence / "linked-static-storage-budget.json").read_text())
        assert budget["static_storage_budget"]["actual_bytes"] == 24
        assert budget["static_storage_budget"]["passed"] is False
        completed_cases.add("one-byte-low production gate prevents publication sentinel")

    # Supplying a manifest alone must be rejected by the actual CLI parser.
    with tempfile.TemporaryDirectory() as temporary:
        manifest_path = Path(temporary) / "app.json"
        manifest_path.write_text("{}", encoding="utf-8")
        result = subprocess.run([sys.executable,
            str(ROOT / "Tools/EmbeddedApplicationMacros/linked_storage_audit.py"),
            "--app-manifest", str(manifest_path)], capture_output=True, text=True)
        assert result.returncode != 0
        assert "--app-manifest requires --enforce-static-storage-budget" in result.stderr
        completed_cases.add("auditor CLI rejects manifest-only mode")
    required_case_count = 14
    assert len(completed_cases) >= required_case_count, (
        f"only {len(completed_cases)} required cases ran: {sorted(completed_cases)}"
    )
    for case in sorted(completed_cases):
        print(f"PASS case: {case}")
    print(f"PASS required case count: {len(completed_cases)} >= {required_case_count}")
    print("PASS optional app static-storage capacity validation")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
