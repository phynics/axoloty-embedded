#!/usr/bin/env python3
# Copyright (c) 2026 Axoloty contributors. Licensed under the MIT License.
"""Bind first-init diagnostics and existing storage/allocator evidence to exact artifacts.

Runs the pinned disassembler on the supplied ELF and vendor ROM, then proves
the synchronous initialization interval with initialization_interval. The
separate first_init_stack diagnostic retains its original null-bound contract.
"""

from __future__ import annotations

import argparse
import csv
import contextlib
import hashlib
import json
import os
import re
import struct
import subprocess
import sys
import tempfile
from pathlib import Path


IMAGE = "sha256:9006ed8fa42927aa468ff206a8f4ad3149a2994cb327307ee7752e96ac2bbda2"
OBJDUMP = "/opt/esp/tools/tools/riscv32-esp-elf/esp-14.2.0_20241119/riscv32-esp-elf/bin/riscv32-esp-elf-objdump"
NM = "/opt/esp/tools/tools/riscv32-esp-elf/esp-14.2.0_20241119/riscv32-esp-elf/bin/riscv32-esp-elf-nm"
OBJDUMP_SHA256 = "0e390b782ff62cffb32649ef7cd7ea050b00b9e5f0ba05935adfc4bb8876d06a"
NM_SHA256 = "96cedcf972b2d11194100880b6577b8cc7d268608e62a73b1b682c7cd23701a2"
ROM_SHA256 = "788e1d38724aeb8fd974fa10c4a7b089c02627d35342ce84b9e0b12b239f3551"
STORAGE_LIMIT = 73728
CASES = {
    "zero": (0, 0, 0, 0),
    "malloc_free": (1, 1, 0, 0),
    "malloc_multiple": (2, 2, 0, 0),
    "heap_caps_internal": (1, 1, 0, 0),
    "calloc": (1, 1, 0, 0),
    "overflow": (0xFFFFFFFF, 0, 1, -3),
}


class ProofInputError(Exception):
    pass


def digest(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            h.update(block)
    return h.hexdigest()


def read_json(path: Path) -> dict:
    value = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(value, dict):
        raise ProofInputError(f"expected JSON object: {path}")
    return value


def object_field(value: dict, key: str, label: str) -> dict:
    member = value.get(key)
    if not isinstance(member, dict):
        raise ProofInputError(f"{label} must be a JSON object")
    return member


def one_symbol(symbols: str, predicate, label: str) -> str:
    names = []
    for line in symbols.splitlines():
        fields = line.split(maxsplit=3)
        if len(fields) == 4 and predicate(fields[3]):
            names.append(fields[3])
    names = sorted(set(names))
    if len(names) != 1:
        raise ProofInputError(f"expected one {label} symbol, found {len(names)}")
    return names[0]


def parse_calibration(path: Path) -> dict:
    rows: dict[str, dict[str, str]] = {}
    with path.open(encoding="utf-8", newline="") as stream:
        for row in csv.reader(stream):
            if not row or row[0] != "AXOLOTY_HEAP_CAL_V1":
                continue
            values: dict[str, str] = {}
            for item in row[1:]:
                if "=" not in item:
                    raise ProofInputError("malformed calibration row")
                key, value = item.split("=", 1)
                if key in values:
                    raise ProofInputError(f"duplicate calibration field: {key}")
                values[key] = value
            case = values.get("case", "")
            if case in rows:
                raise ProofInputError(f"duplicate calibration case: {case}")
            rows[case] = values
    if set(rows) != set(CASES):
        raise ProofInputError(f"calibration cases mismatch: {sorted(rows)}")
    for case, expected in CASES.items():
        row = rows[case]
        if row.get("result") != "PASS" or row.get("coverage_complete") != "0":
            raise ProofInputError(f"unexpected result or coverage for {case}")
        fields = tuple(int(row[name], 0) for name in ("alloc", "frees", "overflow", "end"))
        if fields != expected:
            raise ProofInputError(f"calibration control does not match expected behavior: {case}")
        if row.get("begin") != "0" or row.get("end_called") != "1" or row.get("summary") != "1" or row.get("mode_ok") != "1":
            raise ProofInputError(f"incomplete observer result for {case}")
    return {name: rows[name] for name in sorted(rows)}


def validate_storage(storage: dict, policy: dict, profile: str, elf_hash: str, map_hash: str) -> dict:
    identity = object_field(storage, "input", "linked-storage input identity")
    if storage.get("schema") != "axoloty.linked-storage-measurement.v1":
        raise ProofInputError("unsupported linked-storage measurement schema")
    if identity.get("elf_sha256") != elf_hash or identity.get("map_sha256") != map_hash:
        raise ProofInputError("linked-storage report is not bound to the selected ELF and map")
    budget = object_field(storage, "static_storage_budget", "linked-storage budget")
    if policy.get("schema") != "axoloty.app-static-storage-policy.v1" or policy.get("profile") != profile or policy.get("status") != "enforced":
        raise ProofInputError("static-storage policy is not enforced for the selected profile")
    if budget.get("ceiling_bytes") != STORAGE_LIMIT or budget.get("passed") is not True or budget.get("actual_bytes") != storage.get("aggregate_charged_static_bytes"):
        raise ProofInputError("linked static-storage accounting does not pass the approved 73,728-byte ceiling")
    inventory = object_field(storage, "inventory_join", "inventory join")
    attribution = object_field(storage, "attribution", "storage attribution")
    if inventory.get("join_status") != "matched" or attribution.get("complete") is not False:
        raise ProofInputError("unexpected app-inventory join or source-ownership claim")
    if type(budget.get("actual_bytes")) is not int or type(budget.get("headroom_bytes")) is not int or budget["headroom_bytes"] != STORAGE_LIMIT - budget["actual_bytes"]:
        raise ProofInputError("linked-storage byte accounting is internally inconsistent")
    return budget


def validate_image_receipt(receipt: dict, profile: str, bin_hash: str) -> None:
    selected = profile.removeprefix("esp32c6-")
    build_rows = receipt.get("profileBuilds")
    device_rows = receipt.get("devices")
    if not isinstance(build_rows, list) or not all(isinstance(row, dict) for row in build_rows):
        raise ProofInputError("profile build receipt rows must be JSON objects")
    if not isinstance(device_rows, list) or not all(isinstance(row, dict) for row in device_rows):
        raise ProofInputError("device receipt rows must be JSON objects")
    builds = [row for row in build_rows if row.get("profile") == selected and row.get("calibration") == "ON"]
    devices = [row for row in device_rows if row.get("profile") == selected]
    if len(builds) != 1 or len(devices) != 1 or builds[0].get("imageSha256") != bin_hash or devices[0].get("imageSha256") != bin_hash:
        raise ProofInputError("calibration/device receipt does not match selected firmware binary")
    if receipt.get("coverageComplete") is not False:
        raise ProofInputError("calibration receipt unexpectedly claims complete allocator coverage")


def validate_output_directory(output_dir: Path, protected_directories: tuple[Path, ...], protected_files: tuple[Path, ...]) -> None:
    output = output_dir.resolve()
    for protected in protected_directories:
        path = protected.resolve()
        if output == path or output in path.parents or path in output.parents:
            raise ProofInputError(f"output directory overlaps an input directory: {path}")
    output_names = OUTPUT_NAMES
    protected = {path.resolve() for path in protected_files}
    for name in output_names:
        candidate = (output / name).resolve()
        if candidate in protected or any(candidate.exists() and path.exists() and os.path.samefile(candidate, path) for path in protected_files):
            raise ProofInputError(f"output file aliases an input: {candidate}")


OUTPUT_NAMES = (
        "first-init-proof.json", "diagnostic-candidate.json", "diagnostic-command.json",
        "diagnostic.stdout.txt", "diagnostic.stderr.txt", "firmware.disassembly.txt",
        "rom.disassembly.txt", "firmware.symbols.txt", "objdump-version.txt",
        "objdump.sha256", "nm.sha256", "disassembler-command.json",
        "disassembler.stdout.txt", "disassembler.stderr.txt", "build-config.json",
        "callbacks.json", "calibration-extracted-from-raw.csv",
        "calibration-extract-command.json", "calibration-extract.stdout.txt",
        "calibration-extract.stderr.txt", "calibration-validate-command.json",
        "calibration-validate.stdout.txt", "calibration-validate.stderr.txt",
        "artifact-sha256.json", "initialization-cfg.json", "first-epoch.log",
        "smoke-result.json", "smoke-command.json", "smoke.stdout.txt", "smoke.stderr.txt",
    )

def run_disassembler(elf: Path, rom: Path, out_dir: Path, tool_dir: Path | None = None) -> tuple[str, str]:
    out_dir.mkdir(parents=True, exist_ok=True)
    elf_mount = elf.resolve()
    rom_mount = rom.resolve()
    output_mount = out_dir.resolve()
    if not elf_mount.is_file() or not rom_mount.is_file():
        raise ProofInputError("ELF and ROM inputs must be regular files")
    command = [
        "docker", "run", "--pull=never", "--network=none", "--cpus=4", "--rm",
        "--mount", f"type=bind,src={elf_mount},dst=/input/firmware.elf,readonly",
        "--mount", f"type=bind,src={rom_mount},dst=/input/rom.elf,readonly",
        "--mount", f"type=bind,src={output_mount},dst=/output",
        IMAGE, "bash", "-lc",
        "set -euo pipefail; "
        f"test \"$(sha256sum {OBJDUMP} | cut -d' ' -f1)\" = {OBJDUMP_SHA256}; "
        f"test \"$(sha256sum {NM} | cut -d' ' -f1)\" = {NM_SHA256}; "
        f"{OBJDUMP} --version > /output/objdump-version.txt; "
        f"{OBJDUMP} -d -z -M no-aliases,numeric /input/firmware.elf > /output/firmware.disassembly.txt; "
        f"{OBJDUMP} -d -z -M no-aliases,numeric /input/rom.elf > /output/rom.disassembly.txt; "
        f"{NM} -n -S /input/firmware.elf > /output/firmware.symbols.txt; "
        f"sha256sum {OBJDUMP} > /output/objdump.sha256; "
        f"sha256sum {NM} > /output/nm.sha256; "
        "printf '%s\\n' 'pinned disassembly completed'",
    ]
    if tool_dir is not None:
        objdump, nm = (tool_dir / Path(path).name for path in (OBJDUMP,NM))
        if digest(objdump) != OBJDUMP_SHA256 or digest(nm) != NM_SHA256:
            raise ProofInputError("native disassembler executable does not match the pinned tool")
        commands = [([str(objdump),"--version"],"objdump-version.txt"),
                    ([str(objdump),"-d","-z","-M","no-aliases,numeric",str(elf.resolve())],"firmware.disassembly.txt"),
                    ([str(objdump),"-d","-z","-M","no-aliases,numeric",str(rom.resolve())],"rom.disassembly.txt"),
                    ([str(nm),"-n","-S",str(elf.resolve())],"firmware.symbols.txt")]
        for cmd,name in commands:
            run_command(cmd,out_dir,"disassembler-"+name,stdout_file=name,record=False)
        (out_dir / "objdump.sha256").write_text(f"{OBJDUMP_SHA256}  {OBJDUMP}\n")
        (out_dir / "nm.sha256").write_text(f"{NM_SHA256}  {NM}\n")
        write_json(out_dir / "disassembler-command.json",[[str(arg).replace(str(out_dir.resolve()),"<output-dir>") for arg in cmd] for cmd,_name in commands])
    else:
        run_command(command,out_dir,"disassembler")
    for name in ("firmware.disassembly.txt", "rom.disassembly.txt", "firmware.symbols.txt", "objdump-version.txt", "objdump.sha256"):
        if not (out_dir / name).is_file():
            raise ProofInputError(f"disassembler did not produce {name}")
    return digest(out_dir / "firmware.disassembly.txt"), digest(out_dir / "rom.disassembly.txt")


def run_self_test() -> None:
    lines = ["AXOLOTY_HEAP_CAL_V1,case=zero,result=PASS,path=none,coverage_complete=0,begin=0,end=0,end_called=1,alloc=0,frees=0,overflow=0,mode=0,mode_ok=1,summary=1,expected=0,matched=0,records=0"]
    expected_values = {
        "malloc_free": (1, 1, 0, 0), "malloc_multiple": (2, 2, 0, 0),
        "heap_caps_internal": (1, 1, 0, 0), "calloc": (1, 1, 0, 0),
        "overflow": (0xFFFFFFFF, 0, 1, -3),
    }
    for case, (alloc, frees, overflow, end) in expected_values.items():
        lines.append(f"AXOLOTY_HEAP_CAL_V1,case={case},result=PASS,path=fixture,coverage_complete=0,begin=0,end={end},end_called=1,alloc={alloc},frees={frees},overflow={overflow},mode=0,mode_ok=1,summary=1,expected=1,matched=1,records=1")
    with tempfile.TemporaryDirectory(prefix="final-init-proof-test-") as directory:
        root = Path(directory)
        fixture = root / "controls.csv"
        fixture.write_text("\n".join(lines) + "\n", encoding="utf-8")
        assert set(parse_calibration(fixture)) == set(CASES)
        validate_output_directory(root / "proof", (root / "inputs",), (fixture,))
        for unsafe in (root / "inputs", root):
            try:
                validate_output_directory(unsafe, (root / "inputs",), (fixture,))
            except ProofInputError:
                pass
            else:
                raise AssertionError("overlapping output directory was accepted")
        alias_dir = root / "alias"
        alias_dir.mkdir()
        (alias_dir / "first-init-proof.json").symlink_to(fixture)
        try:
            validate_output_directory(alias_dir, (), (fixture,))
        except ProofInputError:
            pass
        else:
            raise AssertionError("output symlink to an input was accepted")
        hardlink_dir = root / "hardlink"
        hardlink_dir.mkdir()
        os.link(fixture, hardlink_dir / "first-init-proof.json")
        try:
            validate_output_directory(hardlink_dir, (), (fixture,))
        except ProofInputError:
            pass
        else:
            raise AssertionError("output hardlink to an input was accepted")
        for mutated in (
            "\n".join(lines[:-1]) + "\n",
            "\n".join(lines).replace("coverage_complete=0", "coverage_complete=1") + "\n",
            "\n".join(lines).replace("case=malloc_free,result=PASS", "case=malloc_free,result=FAIL") + "\n",
            "\n".join(lines).replace("case=overflow,result=PASS", "case=overflow,result=PASS", 1) + "\n" + lines[-1] + "\n",
        ):
            fixture.write_text(mutated, encoding="utf-8")
            try:
                parse_calibration(fixture)
            except ProofInputError:
                pass
            else:
                raise AssertionError("invalid calibration evidence was accepted")
    valid_storage = {
        "schema": "axoloty.linked-storage-measurement.v1",
        "input": {"elf_sha256": "elf", "map_sha256": "map"},
        "static_storage_budget": {"ceiling_bytes": STORAGE_LIMIT, "passed": True, "actual_bytes": 100, "headroom_bytes": STORAGE_LIMIT - 100},
        "aggregate_charged_static_bytes": 100,
        "inventory_join": {"join_status": "matched"},
        "attribution": {"complete": False},
    }
    valid_policy = {"schema": "axoloty.app-static-storage-policy.v1", "profile": "esp32c6-mqtt", "status": "enforced"}
    assert validate_storage(valid_storage, valid_policy, "esp32c6-mqtt", "elf", "map")["actual_bytes"] == 100
    bad_storage = {**valid_storage, "input": {"elf_sha256": "stale", "map_sha256": "map"}}
    try:
        validate_storage(bad_storage, valid_policy, "esp32c6-mqtt", "elf", "map")
    except ProofInputError:
        pass
    else:
        raise AssertionError("stale ELF-bound storage report was accepted")
    bad_policy = {**valid_policy, "status": "not-configured"}
    try:
        validate_storage(valid_storage, bad_policy, "esp32c6-mqtt", "elf", "map")
    except ProofInputError:
        pass
    else:
        raise AssertionError("unconfigured storage policy was accepted")
    malformed_storage = {**valid_storage, "inventory_join": []}
    try:
        validate_storage(malformed_storage, valid_policy, "esp32c6-mqtt", "elf", "map")
    except ProofInputError:
        pass
    else:
        raise AssertionError("malformed nested storage evidence was accepted")
    fake_receipt = {"profileBuilds": [{"profile": "mqtt", "calibration": "ON", "imageSha256": "bin"}], "devices": [{"profile": "mqtt", "imageSha256": "bin"}], "coverageComplete": False}
    validate_image_receipt(fake_receipt, "esp32c6-mqtt", "bin")
    try:
        validate_image_receipt(fake_receipt, "esp32c6-mqtt", "other-bin")
    except ProofInputError:
        pass
    else:
        raise AssertionError("calibration receipt for a different binary was accepted")
    try:
        validate_image_receipt({**fake_receipt, "profileBuilds": [{}]}, "esp32c6-mqtt", "bin")
    except ProofInputError:
        pass
    else:
        raise AssertionError("malformed build provenance rows were accepted")
    print("final_init_proof self-test: calibration controls and fail-closed mutations passed")


def write_json(path, value):
    path.write_text(json.dumps(value,indent=2,sort_keys=True)+'\n')


def run_command(command, out, label, stdout_file=None, record=True, env=None):
    """Run once; retain status and raw diagnostics. Paths in receipts are stable."""
    normalize = lambda value:value.replace(str(out.resolve()),'<output-dir>')
    if record:
        write_json(out / (label+'-command.json'),[normalize(str(arg)) for arg in command])
    result = subprocess.run(command,capture_output=True,text=True,check=False,env=env)
    if stdout_file:
        (out/stdout_file).write_text(normalize(result.stdout))
    if record:
        (out/(label+'.stdout.txt')).write_text(normalize(result.stdout))
        (out/(label+'.stderr.txt')).write_text(normalize(result.stderr))
    if result.returncode:
        raise ProofInputError(f'{label} failed with exit {result.returncode}: {result.stderr[-1000:]}')
    return result


def first_epoch(raw):
    """Select epoch one, including every byte up to the next reset or EOF.

    A later PASS cannot repair an incomplete first boot. Completion selects
    no rows: all calibration-prefix lines in the chosen epoch are retained.
    """
    offset = 0
    preamble = (b'Executing action: monitor', b'Running idf_monitor in directory ', b'Executing \"', b'--- esp-idf-monitor ', b'--- Quit: ')
    rom_seen = False
    activity = False
    completion = None
    end = len(raw)
    for line in raw.splitlines(keepends=True):
        if b'ESP-ROM:' in line:
            if rom_seen or activity:
                end = offset
                break
            rom_seen = True
        elif b'rst:0x' in line and activity:
            end = offset
            break
        if not rom_seen and line.strip() and not line.strip().startswith(preamble):
            raise ProofInputError('first epoch is incomplete: initial ROM boundary is absent')
        if b'AXOLOTY_HEAP_CAL_V1' in line:
            activity = True
        start = line.find(b'{')
        if start >= 0:
            try:
                row = json.loads(line[start:].strip())
            except (ValueError,UnicodeError):
                row = {}
            if row.get('runId') == 'embedded-swift-smoke-v2':
                if row.get('caseId') == 'boot' and activity and completion is not None:
                    end = offset
                    break
                activity = True
                if row.get('caseId') == 'completion' and row.get('status') == 'completed':
                    if completion is not None:
                        raise ProofInputError('duplicate completion in first epoch')
                    completion = offset + len(line)
        offset += len(line)
    if not rom_seen or completion is None or completion > end:
        raise ProofInputError('first epoch is incomplete; later epochs are ineligible')
    return raw[:end], {'startByte':0,'endByteExclusive':end,'completionEndByte':completion,
                       'trailingBytesExcluded':len(raw)-end}


def validate_provenance(provenance, bin_hash, core_lock):
    firmware = object_field(provenance,'firmware','firmware provenance')
    core = object_field(provenance,'core','Core provenance')
    artifact = object_field(provenance,'artifact','artifact provenance')
    if (provenance.get('status') != 'passed' or firmware.get('dirty') is not False
            or firmware.get('sourceCopied') is not False or core.get('dirty') is not False
            or not re.fullmatch('[0-9a-f]{40}',firmware.get('revision',''))
            or core.get('sha') != core_lock['core']['revision']
            or artifact.get('sha256') != bin_hash):
        raise ProofInputError('build provenance does not bind clean source, locked Core, and binary')
    return firmware,core


def verify_binary_elf(binary, elf_hash):
    # ESP image header + first segment header + esp_app_desc_t ELF digest.
    # This fixed layout belongs to the pinned ESP-IDF/ESP32-C6 profile.
    data = binary.read_bytes()
    if (len(data) < 208 or data[0] != 0xe9 or data[1] < 1
            or struct.unpack_from('<I',data,32)[0] != 0xabcd5432
            or data[176:208] != bytes.fromhex(elf_hash)):
        raise ProofInputError('ESP image app descriptor does not bind the selected ELF')


def source_identity(repo, revision):
    # The firmware producer is distinct from this tooling revision. Verify the
    # product inputs in this checkout, including generators and the ABI, against
    # that producer. The parent may commit these host tools independently.
    paths = ('Applications','Platforms','Profiles','Transports','Sources','Interop','axoloty-core.lock.json','Package.resolved','Package.swift','Tools/EmbeddedApplicationMacros/Sources')
    listed = subprocess.run(['git','ls-files','-z','--',*paths],cwd=repo,capture_output=True,check=True).stdout
    hashes = {}
    for name in listed.decode().split('\0'):
        if not name:
            continue
        original = subprocess.run(['git','show',f'{revision}:{name}'],cwd=repo,capture_output=True,check=True).stdout
        actual = (repo/name).read_bytes()
        if actual != original:
            raise ProofInputError(f'product source differs from artifact producer: {name}')
        hashes[name] = hashlib.sha256(actual).hexdigest()
    return hashlib.sha256(json.dumps(hashes,sort_keys=True).encode()).hexdigest()


def validate_device(directory, receipt, profile, bin_hash, firmware, core):
    manifest = read_json(directory/'device-manifest.json')
    producer = read_json(directory/'build-provenance.json')
    if (producer.get('artifact',{}).get('sha256') != bin_hash
            or producer.get('firmware',{}).get('revision') != firmware['revision']
            or producer.get('core',{}).get('sha') != core['sha']):
        raise ProofInputError('device producer differs from selected build')
    row = [r for r in receipt['devices'] if r.get('profile') == profile.removeprefix('esp32c6-')][0]
    mac = manifest.get('mac','').lower().replace(':ff:fe:',':')
    if (manifest.get('chip') != 'esp32c6' or 'revision v0.0' not in manifest.get('chipDescription','')
            or manifest.get('queried') is not True or not mac
            or mac != row.get('boardBaseMac','').lower()
            or row.get('source') != firmware['revision'] or receipt.get('coreRevision') != core['sha']
            or row.get('smokePassed') != 312 or row.get('failed') != 0
            or row.get('calibrationControlsPassed') != 6):
        raise ProofInputError('board/source/Core or calibration/smoke receipt mismatch')
    return {'chip':'esp32c6','revision':'v0.0','baseMac':mac,
            'manifestSha256':digest(directory/'device-manifest.json'),
            'buildProvenanceSha256':digest(directory/'build-provenance.json')}


def preflight(argv):
    tolerant = argparse.ArgumentParser(add_help=False,allow_abbrev=False)
    directories = ('--artifacts','--profile-evidence','--device-evidence','--tool-dir')
    files = ('--rom-elf','--calibration-csv','--calibration-raw-log','--calibration-device-receipt','--device-run-receipt','--sdkconfig')
    for flag in (*directories,*files,'--output-dir'):
        tolerant.add_argument(flag,action='append',nargs='?',type=Path,default=[])
    args,_ = tolerant.parse_known_args(argv)
    output = args.output_dir[-1] if args.output_dir else None
    if output is None:
        return
    dirs = tuple(p for flag in directories for p in getattr(args,flag[2:].replace('-','_')) if p is not None)
    protected = tuple(p for flag in files for p in getattr(args,flag[2:].replace('-','_')) if p is not None)
    protected += tuple(directory/name for directory in dirs for name in OUTPUT_NAMES)
    validate_output_directory(output,dirs,protected)
    if output.exists():
        for name in OUTPUT_NAMES:
            path = output/name
            if path.is_file() or path.is_symlink():
                path.unlink()
            elif path.exists():
                raise ProofInputError(f'managed output is a directory: {path}')


@contextlib.contextmanager
def evidence_workspace(output):
    """Keep failure logs without publishing a receipt or success manifest."""
    with tempfile.TemporaryDirectory(prefix='.first-init-',dir=output) as scratch:
        workspace = Path(scratch)
        try:
            yield workspace
        except BaseException:
            for name in OUTPUT_NAMES:
                if name not in ('first-init-proof.json','artifact-sha256.json','initialization-cfg.json') and (workspace/name).is_file():
                    os.replace(workspace/name,output/name)
            raise


def main(argv=None):
    argv = sys.argv[1:] if argv is None else argv
    parser = argparse.ArgumentParser(description=__doc__,allow_abbrev=False)
    parser.add_argument('--self-test',action='store_true')
    parser.add_argument('--profile',choices=('esp32c6-mqtt','esp32c6-zenoh'))
    for flag in ('artifacts','profile-evidence','rom-elf','calibration-csv','calibration-raw-log',
                 'calibration-device-receipt','device-run-receipt','device-evidence','sdkconfig','output-dir','tool-dir'):
        parser.add_argument('--'+flag,type=Path)
    try:
        try:
            args = parser.parse_args(argv)
        except SystemExit as error:
            if error.code:
                preflight(argv)
            raise
        if args.self_test:
            run_self_test()
            from initialization_interval_tests import run_tests
            run_tests()
            return 0
        preflight(argv)
        required = ('profile','artifacts','profile_evidence','rom_elf','calibration_csv',
                    'calibration_raw_log','calibration_device_receipt','device_run_receipt','sdkconfig','output_dir')
        if any(getattr(args,key) is None for key in required):
            raise ProofInputError('required inputs: '+', '.join('--'+key.replace('_','-') for key in required))
        repo = Path(__file__).resolve().parents[2]
        elf,map_file,binary = (args.artifacts/name for name in ('axoloty-swift.elf','axoloty-swift.map','axoloty-swift.bin'))
        elf_hash,map_hash,bin_hash = (digest(p) for p in (elf,map_file,binary))
        verify_binary_elf(binary,elf_hash)
        if digest(args.rom_elf) != ROM_SHA256:
            raise ProofInputError('wrong vendor ROM digest')
        lock = read_json(repo/'axoloty-core.lock.json')
        provenance = read_json(args.profile_evidence/'build-provenance.json')
        firmware,core = validate_provenance(provenance,bin_hash,lock)
        source_hash = source_identity(repo,firmware['revision'])
        calibration_config = read_json(args.profile_evidence/'allocator-calibration-config.json')
        if type(calibration_config.get('schema')) is not int or calibration_config.get('schema') != 1 or calibration_config.get('heapTraceCalibration') is not True:
            raise ProofInputError('selected build did not enable named observer calibration')
        budget = validate_storage(read_json(args.profile_evidence/'linked-static-storage-budget.json'),
                                  read_json(args.profile_evidence/'static-storage-policy.json'),args.profile,elf_hash,map_hash)
        device_receipt = read_json(args.calibration_device_receipt)
        validate_image_receipt(device_receipt,args.profile,bin_hash)
        directory = args.device_evidence or args.calibration_raw_log.parent
        device = validate_device(directory,device_receipt,args.profile,bin_hash,firmware,core)
        run_receipt = read_json(args.device_run_receipt)
        if (run_receipt.get('rawSha256') != digest(args.calibration_raw_log)
                or run_receipt.get('imageSha256') != bin_hash
                or run_receipt.get('sourceHead') != firmware['revision']
                or run_receipt.get('profile') != args.profile.removeprefix('esp32c6-')
                or run_receipt.get('flashAndSmokeExit') != 0
                or run_receipt.get('calibrationValidated') is not True
                or run_receipt.get('calibrationRows') != 6
                or run_receipt.get('deviceManifest') != read_json(directory/'device-manifest.json')):
            raise ProofInputError('raw capture/device run receipt is not bound to this image/source/board')
        device['runReceiptSha256'] = digest(args.device_run_receipt)
        sdkconfig = read_json(args.sdkconfig)
        capacity = sdkconfig.get('ESP_MAIN_TASK_STACK_SIZE')
        if type(capacity) is not int or capacity <= 0:
            raise ProofInputError('SDK configuration has no positive ESP_MAIN_TASK_STACK_SIZE')
        args.output_dir.mkdir(parents=True,exist_ok=True)
        # A failed command leaves no accepted receipt. Publish the receipt and
        # manifest last; foreign files are never ingested into the manifest.
        with evidence_workspace(args.output_dir) as out:
            raw = args.calibration_raw_log.read_bytes()
            epoch,boundaries = first_epoch(raw)
            (out/'first-epoch.log').write_bytes(epoch)
            validator = repo/'Tests/embedded/validate-heap-trace-calibration.mjs'
            run_command(['node',str(validator),'--extract-raw',str(out/'first-epoch.log'),str(out/'calibration-extracted-from-raw.csv')],out,'calibration-extract')
            extracted = out/'calibration-extracted-from-raw.csv'
            if extracted.read_bytes() != args.calibration_csv.read_bytes():
                raise ProofInputError('calibration rows differ from complete first-epoch extraction')
            run_command(['node',str(validator),str(extracted)],out,'calibration-validate')
            controls = parse_calibration(extracted)
            env = dict(os.environ)
            env['AXOLOTY_CORPUS_MANIFEST'] = str(repo/'Applications/device-smoke-agent/fixtures/manifest.json')
            env.pop('EMBEDDED_VALIDATOR',None)
            env.pop('EMBEDDED_VALIDATOR_FACTORY',None)
            run_command(['node',str(repo/'Platforms/esp32c6-idf/tools/validate-smoke.mjs'),str(out/'first-epoch.log'),str(out/'smoke-result.json'),device['baseMac'],'120'],out,'smoke',env=env)
            smoke = read_json(out/'smoke-result.json')['validation']
            if smoke.get('passed') is not True or smoke.get('counts') != {'passed':312,'failed':0}:
                raise ProofInputError('first epoch does not pass all 312 smoke cases')
            frozen_elf, frozen_rom = out/'input.elf',out/'input-rom.elf'
            frozen_elf.write_bytes(elf.read_bytes())
            frozen_rom.write_bytes(args.rom_elf.read_bytes())
            if digest(frozen_elf) != elf_hash or digest(frozen_rom) != ROM_SHA256:
                raise ProofInputError('artifact changed before disassembly')
            disassembly_hash,rom_disassembly_hash = run_disassembler(frozen_elf,frozen_rom,out,args.tool_dir)
            from initialization_interval import Program,prove
            program = Program(frozen_elf.read_bytes(),(out/'firmware.disassembly.txt').read_text(),
                              frozen_rom.read_bytes(),(out/'rom.disassembly.txt').read_text())
            inventory = read_json(repo/'Applications/device-smoke-agent/storage-inventory.json')
            required_guards = [symbol['rawName'] for entry in inventory['entries'] for symbol in entry['expectedSymbols']
                               if symbol['role'] == 'lazy-initialization-control-candidate']
            proof = prove(program,capacity,required_guards)
            write_json(out/'initialization-cfg.json',proof)
            state_name = one_symbol((out/'firmware.symbols.txt').read_text(),lambda n:'__axoloty_application_state' in n,'State backing')
            states = [r for r in program.rows if r[0] == state_name]
            if len(states) != 1 or states[0][2:4] != (4,1) or states[0][5] != 8:
                raise ProofInputError('selected generated State is not four-byte zero-backed STT_OBJECT')
            storage_classes = []
            guarded = {row['symbol'] for row in proof['applicationLazyControls']}
            for owner in inventory['entries']:
                members = []
                for expected in owner['expectedSymbols']:
                    matching = [row for row in program.rows if row[0] == expected['rawName']]
                    if len(matching) != 1:
                        raise ProofInputError('inventory symbol missing or ambiguous')
                    name,address,size,kind,section,section_type = matching[0]
                    if expected['role'] == 'lazy-initialization-control-candidate' and name not in guarded:
                        raise ProofInputError('inventoried lazy control outside initializer graph')
                    members.append({'symbol':name,'address':address,'size':size,'section':section,
                                    'classification':'zero-backed static' if section_type == 8 else 'file-backed initial data',
                                    'role':expected['role']})
                storage_classes.append({'owner':owner['owner'],'members':members})
            receipt = {
                'schema':'axoloty.first-init-proof-receipt.v2','status':'PASS','profile':args.profile,
                'artifact':{'elfSha256':elf_hash,'mapSha256':map_hash,'binSha256':bin_hash,'romElfSha256':ROM_SHA256},
                'producer':{'firmwareRevision':firmware['revision'],'coreRevision':core['sha'],
                            'buildProvenanceSha256':digest(args.profile_evidence/'build-provenance.json'),
                            'productSourceSetSha256':source_hash,'coreLockSha256':digest(repo/'axoloty-core.lock.json')},
                'tool':{'generatorSha256':digest(Path(__file__)),'engineSha256':digest(Path(__file__).with_name('initialization_interval.py')),
                        'containerImageId':IMAGE if args.tool_dir is None else None,
                        'objdumpSha256':OBJDUMP_SHA256,'nmSha256':NM_SHA256,
                        'objdumpVersion':(out/'objdump-version.txt').read_text().splitlines()[0],
                        'firmwareDisassemblySha256':disassembly_hash,'romDisassemblySha256':rom_disassembly_hash},
                'staticStorage':{'status':'PASS','accounting':'conservative-combined-object-debit','chargedBytes':budget['actual_bytes'],
                                 'ceilingBytes':STORAGE_LIMIT,'headroomBytes':budget['headroom_bytes'],'inventoryCoverageComplete':False,
                                 'reportSha256':digest(args.profile_evidence/'linked-static-storage-budget.json')},
                'initializationStack':{key:value for key,value in proof.items() if key not in ('initializerGraph','intervalAndCallersGraph','allocatorEntriesPresent')},
                'initializationCfgSha256':digest(out/'initialization-cfg.json'),
                'allocatorObserver':{'status':'PASS','initializationNoHeap':'PASS: closed initializer graph plus calibrated named production observer and successful first-init gate',
                                     'coverageComplete':False,'wholeImageNoHeap':False,'controlsUseSeparateIntervals':True,
                                     'controls':controls,'device':device,'calibrationReceiptSha256':digest(args.calibration_device_receipt),
                                     'calibrationRawLogSha256':digest(args.calibration_raw_log),'calibrationCsvSha256':digest(extracted),
                                     'epoch':boundaries,'epochSha256':digest(out/'first-epoch.log'),'smoke':smoke},
                'state':{'symbol':state_name,'address':states[0][1],'size':4,'initialization':'zero-backed BSS; later ordinary count load is outside dynamic initialization'},
                'inventoriedStorage':{'sourceOwnershipComplete':False,'entries':storage_classes},
                'sdkConfiguration':{'sha256':digest(args.sdkconfig),'mainTaskStackBytes':capacity},
                'limitations':['Exact retained image proof; parent still owns committed-candidate builds and device validation.',
                               'No complete source ownership or whole-image allocator/control coverage claim.',*proof['scope']],
            }
            write_json(out/'first-init-proof.json',receipt)
            names = sorted(name for name in OUTPUT_NAMES if name != 'artifact-sha256.json' and (out/name).is_file())
            write_json(out/'artifact-sha256.json',{name:digest(out/name) for name in names})
            for name in names+['artifact-sha256.json']:
                os.replace(out/name,args.output_dir/name)
        print(json.dumps({'status':'PASS','profile':args.profile,'maximumStackBytes':proof['maximumStackBytes'],
                          'configuredStackBytes':capacity,'chargedStaticBytes':budget['actual_bytes']},sort_keys=True))
        return 0
    except (OSError,ValueError,KeyError,TypeError,ProofInputError,subprocess.SubprocessError) as error:
        print(f'final-init-proof: {error}',file=sys.stderr)
        return 1


if __name__ == '__main__':
    raise SystemExit(main())
