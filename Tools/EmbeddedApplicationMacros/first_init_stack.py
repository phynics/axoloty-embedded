#!/usr/bin/env python3
# Copyright (c) 2026 Axoloty contributors. Licensed under the MIT License.
"""Diagnostic-only first-initialization stack observations for linked RISC-V output."""

from __future__ import annotations

import argparse
import hashlib
import heapq
import json
import os
import re
import struct
import subprocess
import sys
import tempfile
from dataclasses import dataclass, field
from pathlib import Path


@dataclass(frozen=True)
class Instruction:
    address: int
    mnemonic: str
    operands: str
    target: int | None
    text: str
    size: int = 4
    encoding: str | None = None


@dataclass
class Function:
    name: str
    start: int
    size: int
    instructions: list[Instruction] = field(default_factory=list)
    symbol_sizes: dict[str, int] = field(default_factory=dict)
    symbol_kinds: dict[str, str] = field(default_factory=dict)

    @property
    def end(self) -> int:
        return self.start + self.size


SYM = re.compile(r"^\s*([0-9a-fA-F]+)\s+([0-9a-fA-F]+)\s+(\w)\s+(.+?)\s*$")
INS = re.compile(r"^\s*([0-9a-fA-F]+):\s+(?:([0-9a-fA-F]{4,8})\s+)?([.\w]+)(?:\s+(.*?))?\s*$")
TARGET = re.compile(r"#\s*(?:0x)?([0-9a-fA-F]+)")


def sha(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def bind_rom_contracts(document: dict, elf_digest: str, idf_version: str, target: str) -> tuple[dict[int, dict], bool]:
    # A caller-controlled digest only binds a claim to an image. It does not
    # establish ROM body bytes or provenance, so numeric stack claims are never
    # trusted here.
    del elf_digest, idf_version, target
    return {}, bool(document.get("records"))


def map_contains_bss(map_text: str, address: int, size: int) -> bool:
    sections = []
    for line in map_text.splitlines():
        match = re.match(r"^\s*\.(?:dram\d*\.bss|bss)\s+0x([0-9a-fA-F]+)\s+0x([0-9a-fA-F]+)", line)
        if match:
            start, extent = (int(value, 16) for value in match.groups())
            sections.append((start, start + extent))
    return any(start <= address and address + size <= end for start, end in sections)


def parse_symbols(text: str) -> tuple[dict[int, Function], dict[str, Function]]:
    groups: dict[int, list[tuple[str, int, str]]] = {}
    by_name: dict[str, Function] = {}
    for line in text.splitlines():
        match = SYM.match(line)
        if not match:
            continue
        addr, size, kind, name = match.groups()
        size_i = int(size, 16)
        if size_i == 0:
            continue
        groups.setdefault(int(addr, 16), []).append((name, size_i, kind))
    by_addr: dict[int, Function] = {}
    for address, aliases in groups.items():
        max_size = max(size for _, size, _kind in aliases)
        max_names = sorted({name for name, size, _kind in aliases if size == max_size})
        # Do not choose an alias by listing order or by a name heuristic. When
        # the largest extent has several names, retain the complete alias set.
        display_name = max_names[0] if len(max_names) == 1 else " | ".join(max_names)
        fn = Function(
            display_name,
            address,
            max_size,
            symbol_sizes={name: size for name, size, _kind in aliases},
            symbol_kinds={name: kind for name, _size, kind in aliases},
        )
        by_addr[address] = fn
        for name, _size, _kind in aliases:
            by_name[name] = fn
    return by_addr, by_name


def parse_disassembly(text: str, by_addr: dict[int, Function], by_name: dict[str, Function] | None = None) -> None:
    decoded: list[Instruction] = []
    for line in text.splitlines():
        match = INS.match(line)
        if not match:
            continue
        addr_s, encoding, mnemonic, operands = match.groups()
        addr = int(addr_s, 16)
        operands = operands or ""
        target_match = TARGET.search(operands)
        if target_match is None:
            target_match = re.search(r",\s*(?:0x)?([0-9a-fA-F]+)\s*<", operands)
        if target_match is None and mnemonic.lower() in ("j", "c.j", "jal", "c.jal"):
            target_match = re.match(r"\s*(?:0x)?([0-9a-fA-F]+)\s*<", operands)
        target = int(target_match.group(1), 16) if target_match else None
        decoded.append(Instruction(addr, mnemonic.lower(), operands, target, line.strip(), len(encoding) // 2 if encoding else 4, encoding))

    # Sweep sorted instructions and symbol extents together. GNU symbol headers
    # are labels, not ownership boundaries; retain every overlapping ELF
    # function extent without scanning every symbol for every instruction.
    functions = sorted(by_addr.values(), key=lambda fn: (fn.start, fn.end))
    pending = iter(functions)
    next_function = next(pending, None)
    active: dict[int, Function] = {}
    endings: list[tuple[int, int]] = []
    for instruction in sorted(decoded, key=lambda item: item.address):
        while next_function is not None and next_function.start <= instruction.address:
            active[next_function.start] = next_function
            heapq.heappush(endings, (next_function.end, next_function.start))
            next_function = next(pending, None)
        while endings and endings[0][0] <= instruction.address:
            _end, start = heapq.heappop(endings)
            active.pop(start, None)
        for fn in active.values():
            if instruction.address < fn.end:
                fn.instructions.append(instruction)
    for fn in by_addr.values():
        fn.instructions.sort(key=lambda item: item.address)
    if by_name is not None:
        for alias in by_name.values():
            canonical = by_addr.get(alias.start)
            if canonical is not None:
                alias.instructions = canonical.instructions


ABI_REGS = ("zero", "ra", "sp", "gp", "tp", "t0", "t1", "t2", "s0", "s1", "a0", "a1", "a2", "a3", "a4", "a5", "a6", "a7", "s2", "s3", "s4", "s5", "s6", "s7", "s8", "s9", "s10", "s11", "t3", "t4", "t5", "t6")
REG_ALIASES = {f"x{index}": name for index, name in enumerate(ABI_REGS)}


def reg(value: str) -> str:
    value = value.strip()
    return REG_ALIASES.get(value, value)


def stack_step(ins: Instruction) -> int | None:
    """Return signed sp delta, or None for an unsupported sp write."""
    parts = [part.strip() for part in ins.operands.split(",")]
    if not parts or reg(parts[0]) != "sp":
        return 0
    if ins.mnemonic == "c.addi" and len(parts) == 2 and reg(parts[0]) == "sp":
        try:
            return int(parts[1], 0)
        except ValueError:
            return None
    if ins.mnemonic == "c.addi16sp" and len(parts) == 2 and reg(parts[0]) == "sp":
        try:
            return int(parts[1], 0)
        except ValueError:
            return None
    if ins.mnemonic in ("addi", "c.addi", "c.addi16sp") and len(parts) == 3 and reg(parts[1]) == "sp":
        try:
            return int(parts[2], 0)
        except ValueError:
            return None
    return None


BRANCHES = {"beq", "bne", "blt", "bge", "bltu", "bgeu", "beqz", "bnez", "blez", "bgez", "bltz", "bgtz", "c.beqz", "c.bnez"}
RETURNS = {"ret", "c.ret"}
UNCOND_JUMPS = {"j", "c.j"}
SYSTEM_TRAPS = {"ecall", "ebreak", "c.ebreak", "wfi", "unimp", "mret", "sret"}
SUPPORTED_LINEAR = set("add addi and andi auipc div divu fence li lui mul mulh mulhsu mulhu mv neg nop not or ori rem remu seqz sgtz sll slli slt slti sltiu sltu snez sra srai srl srli sub xor xori zext.b lb lbu lh lhu lw sb sh sw csrr csrrc csrrci csrrs csrrsi csrw csrci csrsi amoadd.w amoadd.w.aqrl amoand.w.aqrl amoor.w.aqrl lr.w lr.w.aq sc.w sc.w.rl c.addi c.addi16sp c.li c.lui c.mv c.add c.nop c.lw c.sw c.lwsp c.swsp c.li c.slli c.srli c.srai c.andi c.sub c.xor c.or c.and c.addi4spn c.zext.b c.sext.b c.zext.h c.sext.h c.zext.w c.not c.neg".split())


def successors(fn: Function, index: int, starts: set[int]) -> tuple[list[int], bool, str | None]:
    ins = fn.instructions[index]
    next_instruction = fn.instructions[index + 1] if index + 1 < len(fn.instructions) else None
    next_addr = next_instruction.address if next_instruction and next_instruction.address == ins.address + ins.size else None
    m = ins.mnemonic
    if m in RETURNS or (m in ("jr", "c.jr") and reg(ins.operands) == "ra"):
        return [], True, None
    if m in SYSTEM_TRAPS:
        return [], False, "system trap/exception flow is not modeled"
    if m in UNCOND_JUMPS:
        if ins.target in starts:
            return [ins.target], False, None
        return [], True, None if ins.target is not None else "unresolved direct jump"
    if m in BRANCHES:
        if ins.target is None or ins.target not in starts:
            return [], False, f"branch target {ins.target!r} is absent from the function instruction graph"
        if next_addr is None or next_addr not in starts:
            return [], False, "branch fallthrough instruction is missing or discontinuous"
        return [ins.target, next_addr], False, None
    if m in ("jr", "c.jr") and reg(ins.operands) == "t0":
        return [], True, None
    if m in ("jr", "c.jr"):
        return [], False, "indirect control transfer (including outlined link-register continuation)"
    if m in ("jal", "c.jal"):
        args = [part.strip() for part in ins.operands.split(",")]
        rd = reg(args[0]) if len(args) > 1 else "ra"
        if rd == "zero":
            return ([ins.target] if ins.target in starts else []), False, None if ins.target is not None else "unresolved direct jump"
    if m == "jalr":
        args = [part.strip() for part in ins.operands.split(",")]
        rd = reg(args[0]) if len(args) > 1 else "ra"
        if rd == "zero":
            return [], False, "indirect tail transfer"
    if m in ("jal", "c.jal"):
        args = [part.strip() for part in ins.operands.split(",")]
        rd = reg(args[0]) if len(args) > 1 else "ra"
        if rd != "zero" and rd not in ABI_REGS:
            return [], False, f"unsupported link register {rd!r}"
        if rd == "zero":
            return ([ins.target] if ins.target in starts else []), False, None if ins.target is not None else "unresolved direct jump"
        if ins.target is None:
            return [], False, "direct call target is missing"
        if next_addr is None or next_addr not in starts:
            return [], False, "call fallthrough instruction is missing or discontinuous"
        return [next_addr], False, None
    if m == "jalr":
        args = [part.strip() for part in ins.operands.split(",")]
        rd = reg(args[0]) if len(args) > 1 else "ra"
        if rd != "zero":
            if ins.target is None:
                return [], False, "indirect call/continuation target is not proven by local control flow"
            if next_addr is None or next_addr not in starts:
                return [], False, "call fallthrough instruction is missing or discontinuous"
            return [next_addr], False, None
        return [], False, "indirect tail transfer"
    if m not in SUPPORTED_LINEAR:
        return [], False, f"unsupported instruction/control-flow semantics for {m}"
    if next_addr is None or next_addr not in starts:
        return [], False, "missing or discontinuous fallthrough instruction"
    return [next_addr], False, None


def analyze_frame(fn: Function, linkreg_return: bool = False) -> dict:
    instructions = fn.instructions
    if not instructions:
        return {"frameBytes": None, "unresolved": [f"0x{fn.start:x}: missing linked body"]}
    starts = {ins.address for ins in instructions}
    index_by_pc = {ins.address: i for i, ins in enumerate(instructions)}
    work = [(instructions[0].address, 0, ((instructions[0].address, 0),))]
    seen: set[tuple[int, int]] = set()
    exits = 0
    min_delta = 0
    issues: set[str] = set()
    if len(starts) != len(instructions):
        issues.add(f"0x{fn.start:x}: duplicate instruction address in function body")
    if instructions[0].address != fn.start:
        issues.add(f"0x{fn.start:x}: first decoded instruction does not start at the symbol address")
    for left, right in zip(instructions, instructions[1:]):
        if left.address + left.size != right.address:
            issues.add(f"0x{left.address:x}: instruction gap before 0x{right.address:x}")
    while work:
        pc, delta, path = work.pop()
        if (pc, delta) in seen:
            continue
        seen.add((pc, delta))
        ins = instructions[index_by_pc[pc]]
        parts = [part.strip() for part in ins.operands.split(",")]
        writes_ra = (
            ins.mnemonic in ("jal", "jalr", "c.jal") and (not parts or reg(parts[0]) == "ra" or ins.mnemonic == "c.jal")
        ) or (bool(parts) and reg(parts[0]) == "ra" and ins.mnemonic not in BRANCHES | UNCOND_JUMPS | RETURNS | {"jr", "c.jr", "sw", "sh", "sb", "c.sw", "c.swsp"})
        if writes_ra:
            issues.add(f"0x{pc:x}: link-register write/return convention is not proven: {ins.text}")
        change = stack_step(ins)
        if change is None:
            issues.add(f"0x{pc:x}: unsupported/dynamic write to sp: {ins.text}")
            continue
        after = delta + change
        min_delta = min(min_delta, after)
        dest = reg(ins.operands.split(",", 1)[0]) if ins.operands else ""
        if dest == "sp" and ins.mnemonic not in ("addi", "c.addi", "c.addi16sp"):
            issues.add(f"0x{pc:x}: unsupported stack-pointer write: {ins.text}")
            continue
        if ins.mnemonic in ("jr", "c.jr") and reg(ins.operands) == "t0" and not linkreg_return:
            succ, is_exit, problem = [], False, "unproven jr t0 continuation without a jal t0 caller"
        else:
            succ, is_exit, problem = successors(fn, index_by_pc[pc], starts)
        if problem:
            issues.add(f"0x{pc:x}: {problem}: {ins.text}")
        if is_exit:
            exits += 1
            if after != 0:
                issues.add(f"0x{pc:x}: return with sp delta {after}, expected 0")
        for next_pc in succ:
            earlier = next((old_delta for old_pc, old_delta in reversed(path) if old_pc == next_pc), None)
            if earlier is not None:
                if earlier != after:
                    issues.add(f"0x{pc:x}: stack-changing control-flow cycle returns to 0x{next_pc:x} with delta {after} (was {earlier})")
                continue
            work.append((next_pc, after, path + ((next_pc, after),)))
    if exits == 0:
        issues.add(f"0x{fn.start:x}: no proven return path")
    return {"frameBytes": -min_delta if min_delta <= 0 else None, "minimumStackPointerDelta": min_delta, "unresolved": sorted(issues), "observedReturnPaths": exits}


def call_sites(fn: Function) -> list[tuple[Instruction, int | None, str]]:
    result = []
    for ins in fn.instructions:
        if ins.mnemonic not in ("jal", "c.jal", "jalr"):
            continue
        args = [part.strip() for part in ins.operands.split(",")]
        rd = reg(args[0]) if len(args) > 1 else "ra"
        if rd == "zero":
            # jal x0 is a direct tail edge. jalr x0 is an indirect tail
            # transfer and must remain visible as unresolved evidence.
            result.append((ins, ins.target, "tail-call" if ins.target is not None else "tail-transfer"))
            continue
        result.append((ins, ins.target, "call" if rd == "ra" else "outlined-link"))
    for ins in fn.instructions:
        if ins.mnemonic in UNCOND_JUMPS and ins.target is not None and not fn.start <= ins.target < fn.end:
            result.append((ins, ins.target, "tail-call"))
    return result


def callback_argument_value(fn: Function, call_pc: int, register: str = "a1") -> int | None:
    """Track constants only when no earlier branch can bypass their definition."""
    values: dict[str, int] = {}
    for ins in fn.instructions:
        if ins.address >= call_pc:
            break
        mnemonic = ins.mnemonic
        parts = [part.strip() for part in ins.operands.split(",")]
        if mnemonic in BRANCHES | UNCOND_JUMPS or mnemonic in ("jr", "c.jr", "ret", "c.ret", "c.j"):
            # We do not construct a CFG or prove block dominance here. A
            # constant after any control-flow split is candidate-only.
            return None
        if mnemonic in ("jal", "c.jal", "jalr"):
            destination = reg(parts[0]) if len(parts) > 1 else "ra"
            if mnemonic != "c.jal" and destination == "zero":
                # A zero-link transfer does not return to the following
                # instruction. Do not track definitions from skipped text.
                return None
            # Calls may clobber the ABI caller-saved registers.
            for name in ("ra", "t0", "t1", "t2", "a0", "a1", "a2", "a3", "a4", "a5", "a6", "a7", "t3", "t4", "t5", "t6"):
                values.pop(name, None)
            continue
        if not parts:
            continue
        dest = reg(parts[0])
        if dest not in ABI_REGS or dest == "zero":
            continue
        source_value = values.get(reg(parts[1])) if len(parts) > 1 else None
        values.pop(dest, None)
        try:
            if mnemonic == "auipc" and len(parts) == 2:
                immediate = int(parts[1], 0)
                immediate &= 0xFFFFF
                if immediate & 0x80000:
                    immediate -= 0x100000
                values[dest] = (ins.address + (immediate << 12)) & 0xFFFFFFFF
            elif mnemonic == "lui" and len(parts) == 2:
                immediate = int(parts[1], 0)
                values[dest] = (immediate << 12) & 0xFFFFFFFF
            elif mnemonic == "li" and len(parts) == 2:
                values[dest] = int(parts[1], 0)
            elif mnemonic == "mv" and len(parts) == 2 and source_value is not None:
                values[dest] = source_value
            elif mnemonic == "addi" and len(parts) == 3 and source_value is not None:
                values[dest] = (source_value + int(parts[2].split()[0], 0)) & 0xFFFFFFFF
        except ValueError:
            values.pop(dest, None)
    return values.get(register)


def trace_interval_evidence(root: Function, begin: Function, hook: Function, end: Function) -> dict:
    """Report static call-site address order without claiming execution order."""
    calls = {target: ins.address for ins, target, _kind in call_sites(root)}
    values = {"beginCallPc": calls.get(begin.start), "hookCallPc": calls.get(hook.start), "endCallPc": calls.get(end.start)}
    observed = all(isinstance(pc, int) for pc in values.values()) and values["beginCallPc"] < values["hookCallPc"] < values["endCallPc"]
    return {
        **{name: (f"0x{value:x}" if value is not None else None) for name, value in values.items()},
        "addressOrderObserved": observed,
        "controlFlowOrderProven": False,
    }


class InputBindingError(ValueError):
    """The supplied linked text artifacts do not match the ELF image."""


class InputError(ValueError):
    """An external command-line input is missing or has an invalid shape."""


def read_input(path: Path, label: str) -> str:
    try:
        return path.read_text()
    except (OSError, UnicodeError) as error:
        raise InputError(f"cannot read {label} {path}: {error}") from error


def read_bytes_input(path: Path, label: str) -> bytes:
    try:
        return path.read_bytes()
    except OSError as error:
        raise InputError(f"cannot read {label} {path}: {error}") from error


def read_json_input(path: Path, label: str) -> object:
    try:
        return json.loads(read_input(path, label))
    except json.JSONDecodeError as error:
        raise InputError(f"invalid JSON in {label} {path}: {error.msg} at line {error.lineno}, column {error.colno}") from error


def json_object(value: object, label: str) -> dict:
    if not isinstance(value, dict):
        raise InputError(f"{label} must be a JSON object")
    return value


def parse_address(value: object, label: str) -> int:
    if not isinstance(value, str) or not value:
        raise InputError(f"{label} must be a hexadecimal or decimal address string")
    try:
        address = int(value, 0)
    except ValueError as error:
        raise InputError(f"{label} is not a valid address: {value!r}") from error
    if not 0 <= address <= 0xFFFFFFFF:
        raise InputError(f"{label} is outside the ELF32 address range: {value!r}")
    return address


def validate_build_config(value: object) -> dict:
    document = json_object(value, "build config")
    idf_version = document.get("IDF_VERSION")
    if not isinstance(idf_version, str):
        raise InputError("build config must contain string IDF_VERSION")
    if idf_version != "5.4.0":
        raise InputError(f"expected the exact ESP-IDF 5.4.0 build config, found {idf_version!r}")
    return document


def validate_callback_contract(value: object) -> dict:
    document = json_object(value, "callback contract")
    digest = document.get("elfSha256")
    if not isinstance(digest, str):
        raise InputError("callback contract must contain string elfSha256")
    sites = document.get("sites")
    if not isinstance(sites, list):
        raise InputError("callback contract must contain a sites array")
    for index, raw_record in enumerate(sites):
        record = json_object(raw_record, f"callback sites[{index}]")
        caller = record.get("caller")
        if not isinstance(caller, str) or not caller:
            raise InputError(f"callback sites[{index}].caller must be a non-empty string")
        parse_address(record.get("callPc"), f"callback sites[{index}].callPc")
        if "evidencePc" in record:
            parse_address(record["evidencePc"], f"callback sites[{index}].evidencePc")
        callback = json_object(record.get("callback"), f"callback sites[{index}].callback")
        symbol = callback.get("symbol")
        if not isinstance(symbol, str) or not symbol:
            raise InputError(f"callback sites[{index}].callback.symbol must be a non-empty string")
        parse_address(callback.get("address"), f"callback sites[{index}].callback.address")
    return document


def validate_rom_contract(value: object) -> dict:
    document = json_object(value, "ROM contract")
    for field_name in ("schemaVersion", "idfVersion", "target", "records"):
        if field_name not in document:
            raise InputError(f"ROM contract is missing {field_name}")
    if isinstance(document["schemaVersion"], bool) or not isinstance(document["schemaVersion"], int) or document["schemaVersion"] != 1:
        raise InputError("ROM contract schemaVersion must be integer 1")
    if not isinstance(document["idfVersion"], str) or not isinstance(document["target"], str):
        raise InputError("ROM contract idfVersion and target must be strings")
    records = document["records"]
    if not isinstance(records, list):
        raise InputError("ROM contract records must be an array")
    for index, raw_record in enumerate(records):
        record = json_object(raw_record, f"ROM contract records[{index}]")
        parse_address(record.get("address"), f"ROM contract records[{index}].address")
        if "complete" in record and not isinstance(record["complete"], bool):
            raise InputError(f"ROM contract records[{index}].complete must be boolean")
        if "stackBytes" in record and (isinstance(record["stackBytes"], bool) or not isinstance(record["stackBytes"], int) or record["stackBytes"] < 0):
            raise InputError(f"ROM contract records[{index}].stackBytes must be a non-negative integer")
        if "inputs" in record and not isinstance(record["inputs"], dict):
            raise InputError(f"ROM contract records[{index}].inputs must be an object")
    return document


def invalidate_output(path: Path) -> None:
    try:
        path.parent.mkdir(parents=True, exist_ok=True)
        if path.is_dir() and not path.is_symlink():
            raise InputError(f"output path is a directory: {path}")
        path.unlink(missing_ok=True)
    except OSError as error:
        raise InputError(f"cannot invalidate prior output {path}: {error}") from error


def paths_alias(first: Path, second: Path) -> bool:
    """Compare paths across normalization, symlinks, and existing hardlinks."""
    try:
        if first.resolve(strict=False) == second.resolve(strict=False):
            return True
        return os.path.samefile(first, second)
    except (FileNotFoundError, NotADirectoryError):
        return False
    except (OSError, RuntimeError) as error:
        raise InputError(f"cannot safely compare input and output paths: {error}") from error


def reject_output_aliases(output: Path, inputs: list[Path]) -> None:
    for input_path in inputs:
        if paths_alias(output, input_path):
            raise InputError(f"output path aliases input {input_path}: {output}")


def preflight_output_and_inputs(argv: list[str]) -> tuple[Path | None, list[Path]]:
    """Collect exact file-option paths without validating unrelated arguments."""
    parser = argparse.ArgumentParser(add_help=False, allow_abbrev=False)
    path_options = (
        "--elf", "--map", "--disassembly", "--symbols", "--build-config",
        "--callbacks", "--rom-contract",
    )
    for option in path_options:
        parser.add_argument(option, action="append", nargs="?", type=Path, default=[])
    parser.add_argument("--out", action="append", nargs="?", type=Path, default=[])
    values, _unknown = parser.parse_known_args(argv)
    input_paths = [
        path
        for option in path_options
        for path in getattr(values, option[2:].replace("-", "_"))
        if path is not None
    ]
    output_path = values.out[-1] if values.out else None
    return output_path, input_paths


def invalidate_preflight_output(parser: argparse.ArgumentParser, argv: list[str]) -> None:
    """Invalidate one unambiguous destination after checking every known input."""
    output_path, input_paths = preflight_output_and_inputs(argv)
    if output_path is None:
        return
    try:
        reject_output_aliases(output_path, input_paths)
        invalidate_output(output_path)
    except InputError as error:
        parser.error(str(error))


def write_report_atomic(path: Path, report: dict) -> None:
    temporary: Path | None = None
    try:
        with tempfile.NamedTemporaryFile("w", encoding="utf-8", dir=path.parent, prefix=f".{path.name}.", suffix=".tmp", delete=False) as output:
            temporary = Path(output.name)
            output.write(json.dumps(report, indent=2, sort_keys=True) + "\n")
            output.flush()
            os.fsync(output.fileno())
        os.replace(temporary, path)
        temporary = None
    except OSError as error:
        try:
            path.unlink(missing_ok=True)
        except OSError:
            pass
        raise InputError(f"cannot write current report to {path}: {error}") from error
    finally:
        if temporary is not None:
            try:
                temporary.unlink(missing_ok=True)
            except OSError:
                pass


def elf32_riscv_image(data: bytes) -> tuple[list[tuple[str, int, int, int, str, int]], list[tuple[int, int, int, bytes]]]:
    """Read ELF32 symbol rows and executable section bytes without external packages."""
    if len(data) < 52 or data[:6] != b"\x7fELF\x01\x01":
        raise InputBindingError("ELF must be a complete little-endian ELF32 image")
    header = struct.unpack_from("<HHIIIIIHHHHHH", data, 16)
    machine, section_offset, section_entry_size, section_count, string_index = header[1], header[5], header[10], header[11], header[12]
    section_fmt = "<IIIIIIIIII"
    symbol_fmt = "<IIIBBH"
    if machine != 243 or section_count == 0 or string_index >= section_count or section_entry_size < struct.calcsize(section_fmt):
        raise InputBindingError("unsupported or malformed RISC-V ELF section table")
    if section_offset + section_entry_size * section_count > len(data):
        raise InputBindingError("ELF section table is truncated")
    rows = [struct.unpack_from(section_fmt, data, section_offset + i * section_entry_size) for i in range(section_count)]
    shstr_row = rows[string_index]
    shstr = data[shstr_row[4]:shstr_row[4] + shstr_row[5]]
    def cstring(table: bytes, offset: int) -> str:
        if offset >= len(table):
            raise InputBindingError("ELF string offset is invalid")
        end = table.find(b"\0", offset)
        if end < 0:
            raise InputBindingError("ELF string is unterminated")
        return table[offset:end].decode("utf-8", "replace")
    sections = []
    for index, row in enumerate(rows):
        name = cstring(shstr, row[0])
        section = {"index": index, "name": name, "type": row[1], "flags": row[2], "address": row[3], "offset": row[4], "size": row[5], "link": row[6], "entrySize": row[9]}
        if section["type"] != 8 and section["offset"] + section["size"] > len(data):
            raise InputBindingError(f"ELF section {name} is truncated")
        sections.append(section)
    symbols: list[tuple[str, int, int, int, str, int]] = []
    for section in sections:
        if section["type"] not in (2, 11):
            continue
        if section["link"] >= len(sections):
            raise InputBindingError("ELF symbol table string section is invalid")
        strings_section = sections[section["link"]]
        strings = data[strings_section["offset"]:strings_section["offset"] + strings_section["size"]]
        entry_size = section["entrySize"] or struct.calcsize(symbol_fmt)
        if entry_size < struct.calcsize(symbol_fmt) or section["size"] % entry_size:
            raise InputBindingError("ELF symbol table is malformed")
        for position in range(section["offset"], section["offset"] + section["size"], entry_size):
            name_off, value, size, info, _other, shndx = struct.unpack_from(symbol_fmt, data, position)
            if name_off and size and (shndx < len(sections) or shndx == 0xFFF1):
                section_name = "ABS" if shndx == 0xFFF1 else sections[shndx]["name"]
                section_type = 0 if shndx == 0xFFF1 else sections[shndx]["type"]
                symbols.append((cstring(strings, name_off), value, size, info & 0xF, section_name, section_type))
    executable = []
    for section in sections:
        if section["flags"] & 0x4 and section["type"] != 8:
            executable.append((section["address"], section["address"] + section["size"], section["offset"], data[section["offset"]:section["offset"] + section["size"]]))
    return symbols, executable


def validate_linked_inputs(elf_data: bytes, symbol_text: str, functions: dict[int, Function]) -> None:
    elf_symbols, executable = elf32_riscv_image(elf_data)
    by_name: dict[str, set[tuple[int, int]]] = {}
    for name, address, size, _symbol_type, _section, _section_type in elf_symbols:
        by_name.setdefault(name, set()).add((address, size))
    for line in symbol_text.splitlines():
        match = SYM.match(line)
        if not match:
            continue
        address_s, size_s, kind, name = match.groups()
        if (int(address_s, 16), int(size_s, 16)) not in by_name.get(name, set()):
            raise InputBindingError(f"symbol listing does not match ELF: {name} ({kind})")
    elf_extents: dict[int, int] = {}
    for _name, address, size, symbol_type, section_name, _section_type in elf_symbols:
        in_executable_section = section_name != "ABS" and any(start <= address and address + size <= end for start, end, _offset, _contents in executable)
        if symbol_type == 2 and in_executable_section:  # in-image STT_FUNC
            elf_extents[address] = max(elf_extents.get(address, 0), size)
    for fn in functions.values():
        actual_extent = elf_extents.get(fn.start)
        text_claims_function = any(kind.upper() in {"T", "W"} for kind in fn.symbol_kinds.values())
        if actual_extent is None:
            if text_claims_function:
                raise InputBindingError(f"symbol listing claims a function without ELF STT_FUNC metadata at 0x{fn.start:x}")
            continue
        if actual_extent != fn.size:
            raise InputBindingError(
                f"analyzed function extent does not match the largest ELF symbol range at 0x{fn.start:x}"
            )
        pcs: set[int] = set()
        for ins in fn.instructions:
            if ins.address in pcs:
                raise InputBindingError(f"duplicate instruction address 0x{ins.address:x} in {fn.name}")
            pcs.add(ins.address)
            if ins.encoding is None:
                raise InputBindingError(f"missing instruction encoding at 0x{ins.address:x}")
            size = len(ins.encoding) // 2
            matching = [item for item in executable if item[0] <= ins.address and ins.address + size <= item[1]]
            if len(matching) != 1:
                raise InputBindingError(f"instruction address 0x{ins.address:x} is not uniquely inside executable ELF bytes")
            start, _end, _offset, contents = matching[0]
            raw = contents[ins.address - start:ins.address - start + size]
            if raw != int(ins.encoding, 16).to_bytes(size, "little"):
                raise InputBindingError(f"disassembly encoding mismatch at 0x{ins.address:x}")
        cursor = fn.start
        for ins in sorted(fn.instructions, key=lambda item: item.address):
            if ins.address != cursor:
                raise InputBindingError(
                    f"disassembly leaves function bytes uncovered at 0x{cursor:x} in {fn.name}"
                )
            cursor += ins.size
        if cursor != fn.end:
            raise InputBindingError(
                f"disassembly leaves trailing function bytes uncovered at 0x{cursor:x} in {fn.name}"
            )


def analyze(root: Function, hook: Function, by_addr: dict[int, Function], callbacks: dict[str, list[str]], rom: dict[str, dict], profile: str, input_hashes: dict[str, str], by_name: dict[str, Function] | None = None) -> dict:
    unresolved: set[str] = set()
    frames: dict[str, dict] = {}
    edges: list[dict] = []
    allocator_present: set[str] = set()
    allocator_reachable: set[str] = set()
    indirect_sites: list[dict] = []
    rom_requirements: list[dict] = []
    frame = analyze_frame(root)
    frames[root.name] = frame
    if frame["frameBytes"] is None or frame["unresolved"]:
        unresolved.update(f"{root.name}: {x}" for x in frame["unresolved"])
    # The entry's live frame is counted; traverse only the designated init hook, excluding normal run.
    todo = [(hook, (root.name,), (), False)]
    visited = set()
    while todo:
        fn, ancestors, callback_context, linkreg_return = todo.pop()
        if fn.name in ancestors:
            unresolved.add(f"{fn.name}@0x{fn.start:x}: recursive call path")
            continue
        key = (fn.name, ancestors[-1] if ancestors else "", callback_context)
        if key in visited:
            continue
        visited.add(key)
        local = analyze_frame(fn, linkreg_return)
        frames[fn.name] = local
        if local["frameBytes"] is None or local["unresolved"]:
            unresolved.update(f"{fn.name}: {x}" for x in local["unresolved"])
        for ins, target, kind in call_sites(fn):
            annotation_name = None
            if target is not None:
                annotation_name = re.search(r"<([^>]+)>", ins.operands)
                annotation_name = annotation_name.group(1) if annotation_name else None
            call_key = f"{fn.name}@0x{ins.address:x}"
            targets: list[tuple[Function, str]] = []
            callback_names = callbacks.get(call_key, [])
            if target is None and callback_context:
                callback_names = list(callback_context)
                edge_owner = f"{fn.name}@0x{ins.address:x}"
            else:
                edge_owner = call_key
            if target is not None and target in by_addr:
                targets.append((by_addr[target], kind))
                if not by_addr[target].instructions:
                    missing = {"caller": fn.name, "pc": f"0x{ins.address:x}", "address": f"0x{target:x}", "symbol": by_addr[target].name}
                    rom_requirements.append(missing)
                    unresolved.add(f"{call_key}: linked symbol {by_addr[target].name} has no body at 0x{target:x}")
            elif target is not None and target in rom:
                contract = rom[target]
                edges.append({"caller": fn.name, "pc": f"0x{ins.address:x}", "kind": "rom", "target": contract.get("name", f"0x{target:x}"), "resolution": "contract"})
                if not contract.get("complete") or not isinstance(contract.get("stackBytes"), int):
                    unresolved.add(f"{call_key}: incomplete ROM body contract at 0x{target:x}")
                else:
                    frames[contract.get("name", f"ROM@0x{target:x}")] = {"frameBytes": contract["stackBytes"], "evidence": "digest-bound ROM contract", "unresolved": []}
                continue
            elif target is not None:
                edges.append({"caller": fn.name, "pc": f"0x{ins.address:x}", "kind": kind, "target": annotation_name or f"0x{target:x}", "resolution": "missing-body"})
                unresolved.add(f"{call_key}: linked body/ROM contract missing for target 0x{target:x}")
                if target < 0x40800000:
                    rom_requirements.append({"caller": fn.name, "pc": f"0x{ins.address:x}", "address": f"0x{target:x}", "symbol": annotation_name or "unknown"})
                continue
            for callback_name in callback_names:
                candidates = [by_name[callback_name]] if by_name and callback_name in by_name else [candidate for candidate in by_addr.values() if candidate.name == callback_name]
                if candidates:
                    targets.extend((candidate, "callback") for candidate in candidates)
                else:
                    unresolved.add(f"{edge_owner}: callback body missing for {callback_name}")
            if target is None and not callback_names:
                unresolved.add(f"{call_key}: unresolved indirect call target")
                if kind in ("tail-transfer", "tail-call"):
                    edges.append({"caller": fn.name, "pc": f"0x{ins.address:x}", "kind": kind, "target": "unknown", "resolution": "unresolved"})
                indirect_sites.append({"caller": fn.name, "pc": f"0x{ins.address:x}", "instruction": ins.text, "allocatorIdentity": "unknown"})
                continue
            for callee, edge_kind in targets:
                edges.append({"caller": fn.name, "pc": f"0x{ins.address:x}", "kind": edge_kind, "target": callee.name, "resolution": "exact"})
                if re.search(r"(?:^|_)(?:malloc|calloc|realloc|free|heap_caps_\w+)(?:$|_)", callee.name, re.I):
                    allocator_reachable.add(callee.name)
                context = tuple(callback_names) if callee.name == "swift_once" or "swift_once" in callee.name else ()
                todo.append((callee, ancestors + (fn.name,), context, kind == "outlined-link"))
    # Presence is an image inventory fact, not proof of reachability.
    for candidate in by_addr.values():
        if re.search(r"(?:^|_)(?:malloc|calloc|realloc|free|heap_caps_\w+)(?:$|_)", candidate.name, re.I):
            allocator_present.add(candidate.name)
    edges = list({(edge["caller"], edge["pc"], edge["kind"], edge["target"], edge["resolution"]): edge for edge in edges}.values())
    rom_requirements = list({(item["caller"], item["pc"], item["address"], item["symbol"]): item for item in rom_requirements}.values())
    indirect_sites = list({(item["caller"], item["pc"]): item for item in indirect_sites}.values())
    graph_complete = not unresolved
    bound = None
    if not unresolved:
        # Conservative sum over all reachable functions. Path-sensitive per-function frames are proven,
        # while call paths retain caller frames. This report currently avoids claiming a max if any edge
        # class (including outlined jalr continuations) cannot be closed.
        bound = sum(item["frameBytes"] or 0 for item in frames.values())
        if any(edge["kind"] == "outlined-link" for edge in edges):
            unresolved.add("outlined-link continuation frame replacement is not yet proven from register dataflow")
            bound = None
    if bound is not None:
        unresolved.add("no owner-supplied initialization stack ceiling; policy status remains unresolved")
        bound = None
    # These values depend on caller-supplied mnemonic/operand text. Matching
    # instruction encodings to ELF bytes does not decode or authenticate that
    # text, so no numeric frame or bound claim is emitted.
    diagnostic_frames = {}
    for name, item in frames.items():
        diagnostic_frames[name] = {
            **item,
            "candidateFrameBytes": item.get("frameBytes"),
            "frameBytes": None,
            "semantics": "unverified external disassembly; candidate only",
        }
    return {
        "schemaVersion": 3,
        "status": "UNRESOLVED",
        "diagnosticOnly": True,
        "executionClaims": False,
        "disassemblySemantics": "unverified external mnemonic and operand text; ELF encoding match does not decode semantics",
        "profile": profile,
        "inputHashes": input_hashes,
        "entry": root.name,
        "hook": hook.name,
        "entryFrameBytes": None,
        "knownPathLowerBoundBytes": None,
        "candidateKnownFrameSumBytes": None,
        "candidateKnownFrameSumSemantics": "not computed; control flow and disassembly semantics are unverified",
        "maximumStackBytes": None,
        "policyLimitBytes": None,
        "localFrames": {name: diagnostic_frames[name] for name in sorted(diagnostic_frames)},
        "callGraph": sorted(
            [
                {**edge, "resolution": "candidate; disassembly semantics unverified"}
                if edge.get("resolution") in ("exact", "contract") else edge
                for edge in edges
            ],
            key=lambda edge: (edge["caller"], edge["pc"], edge["target"]),
        ),
        "allocatorSymbolsPresent": sorted(allocator_present),
        "allocatorSymbolsReachable": sorted(allocator_reachable),
        "allocatorCandidatesForCalibration": sorted(allocator_present),
        "allocatorReachabilityStatus": "incomplete; control flow and disassembly semantics are unverified",
        "unresolvedIndirectCallsites": sorted(indirect_sites, key=lambda item: (item["caller"], item["pc"])),
        "missingROMBodyRequirements": sorted(rom_requirements, key=lambda item: (item["caller"], item["pc"])),
        "unresolved": sorted(unresolved | {"external disassembly semantics are unverified; diagnostic observations cannot establish execution paths or stack bounds"}),
    }


def run_self_tests() -> None:
    # Compact fixtures cover path-sensitive frame restoration and fail-closed edges.
    def fixture(body: str) -> Function:
        fn = Function("fixture", 0x1000, len(body.splitlines()) * 4)
        for i, line in enumerate(body.splitlines()):
            m, *rest = line.split(" ", 1)
            fn.instructions.append(Instruction(0x1000 + i * 4, m, rest[0] if rest else "", None, line))
        return fn

    ordinary = fixture("addi sp,sp,-16\nsw ra,12(sp)\naddi sp,sp,16\nret")
    assert analyze_frame(ordinary)["frameBytes"] == 16 and not analyze_frame(ordinary)["unresolved"]
    branches = Function("branch", 0x1000, 20, [
        Instruction(0x1000, "addi", "sp,sp,-16", None, "addi sp,sp,-16"),
        Instruction(0x1004, "beqz", "a0, 100c # 100c", 0x100C, "beqz a0,100c"),
        Instruction(0x1008, "addi", "sp,sp,-16", None, "addi sp,sp,-16"),
        Instruction(0x100C, "addi", "sp,sp,16", None, "addi sp,sp,16"),
        Instruction(0x1010, "ret", "", None, "ret"),
    ])
    branch_result = analyze_frame(branches)
    assert branch_result["frameBytes"] == 32
    assert any("return with sp delta" in x for x in branch_result["unresolved"])
    compressed = fixture("c.addi sp,-16\nc.addi sp,16\nc.ret")
    assert analyze_frame(compressed)["frameBytes"] == 16 and not analyze_frame(compressed)["unresolved"]
    dynamic = fixture("mv sp,a0\nret")
    assert analyze_frame(dynamic)["unresolved"]
    bad_restore = fixture("addi sp,sp,-16\nret")
    assert any("return with sp delta" in x for x in analyze_frame(bad_restore)["unresolved"])
    indirect = Instruction(0x1000, "jalr", "ra,0(t0)", None, "jalr ra,0(t0)")
    assert indirect.target is None
    assert stack_step(Instruction(0x1000, "addi", "sp,sp,-12", None, "addi sp,sp,-12")) == -12
    assert call_sites(Function("out", 0x1000, 8, [Instruction(0x1000, "jal", "t0, 2000 # 2000", 0x2000, "jal t0,2000")]))[0][2] == "outlined-link"
    entry = Function("entry", 0x1000, 16, [Instruction(0x1000,"addi","sp,sp,-12",None,"addi sp,sp,-12"), Instruction(0x1004,"jal","ra,2000 # 2000",0x2000,"jal ra,2000"), Instruction(0x1008,"addi","sp,sp,12",None,"addi sp,sp,12"), Instruction(0x100C,"ret","",None,"ret")])
    hook = Function("hook", 0x2000, 16, [Instruction(0x2000,"addi","sp,sp,-12",None,"addi sp,sp,-12"), Instruction(0x2004,"jal","ra,3000 # 3000",0x3000,"jal ra,3000"), Instruction(0x2008,"addi","sp,sp,12",None,"addi sp,sp,12"), Instruction(0x200C,"ret","",None,"ret")])
    nested = Function("nested", 0x3000, 12, [Instruction(0x3000,"addi","sp,sp,-8",None,"addi sp,sp,-8"), Instruction(0x3004,"addi","sp,sp,8",None,"addi sp,sp,8"), Instruction(0x3008,"ret","",None,"ret")])
    simple = analyze(entry, hook, {fn.start: fn for fn in (entry, hook, nested)}, {}, {}, "synthetic", {})
    assert simple["localFrames"]["entry"]["candidateFrameBytes"] == 12
    assert simple["localFrames"]["nested"]["candidateFrameBytes"] == 8
    assert simple["maximumStackBytes"] is None  # blockers never expose a partial numeric upper bound
    exact_entry = Function("exact-entry", 0x1800, 12, [Instruction(0x1800,"addi","sp,sp,-288",None,"addi sp,sp,-288"), Instruction(0x1804,"addi","sp,sp,288",None,"addi sp,sp,288"), Instruction(0x1808,"ret","",None,"ret")])
    exact_hook = Function("exact-hook", 0x1900, 20, [Instruction(0x1900,"addi","sp,sp,-16",None,"addi sp,sp,-16"), Instruction(0x1904,"jal","ra,1a00 # 1a00",0x1A00,"jal ra,1a00"), Instruction(0x1908,"jal","ra,1b00 # 1b00",0x1B00,"jal ra,1b00"), Instruction(0x190C,"addi","sp,sp,16",None,"addi sp,sp,16"), Instruction(0x1910,"ret","",None,"ret")])
    once = Function("swift_once", 0x1A00, 12, [Instruction(0x1A00,"addi","sp,sp,-16",None,"addi sp,sp,-16"), Instruction(0x1A04,"addi","sp,sp,16",None,"addi sp,sp,16"), Instruction(0x1A08,"ret","",None,"ret")])
    schema = Function("schema_WZ", 0x1B00, 12, [Instruction(0x1B00,"addi","sp,sp,-288",None,"addi sp,sp,-288"), Instruction(0x1B04,"addi","sp,sp,288",None,"addi sp,sp,288"), Instruction(0x1B08,"ret","",None,"ret")])
    candidate_report = analyze(exact_entry, exact_hook, {fn.start: fn for fn in (exact_entry, exact_hook, once, schema)}, {}, {}, "synthetic", {})
    assert candidate_report["schemaVersion"] == 3
    assert candidate_report["knownPathLowerBoundBytes"] is None
    assert candidate_report["candidateKnownFrameSumBytes"] is None
    assert candidate_report["entryFrameBytes"] is None and candidate_report["maximumStackBytes"] is None
    assert candidate_report["localFrames"]["exact-entry"]["frameBytes"] is None
    assert candidate_report["localFrames"]["exact-entry"]["candidateFrameBytes"] == 288
    assert candidate_report["status"] == "UNRESOLVED" and candidate_report["executionClaims"] is False
    # Forged operands can change a diagnostic candidate while byte data is
    # unchanged. They must never become accepted frames or numeric bounds.
    forged_candidates = []
    for immediate in (-16, -288):
        forged_entry = Function(
            "exact-entry",
            exact_entry.start,
            exact_entry.size,
            [
                Instruction(ins.address, ins.mnemonic, f"sp,sp,{immediate}" if ins.address == exact_entry.start else ins.operands,
                            ins.target, ins.text, ins.size, ins.encoding)
                for ins in exact_entry.instructions
            ],
        )
        forged_report = analyze(forged_entry, exact_hook, {fn.start: fn for fn in (forged_entry, exact_hook, once, schema)}, {}, {}, "synthetic", {})
        forged_candidates.append(forged_report["localFrames"]["exact-entry"]["candidateFrameBytes"])
        assert forged_report["localFrames"]["exact-entry"]["frameBytes"] is None
        assert all(forged_report[key] is None for key in ("entryFrameBytes", "knownPathLowerBoundBytes", "candidateKnownFrameSumBytes", "maximumStackBytes"))
        assert forged_report["status"] == "UNRESOLVED" and forged_report["executionClaims"] is False
    assert forged_candidates == [16, 288]
    branch_valid = Function("branch", 0x1000, 28, [
        Instruction(0x1000,"addi","sp,sp,-16",None,"addi sp,sp,-16"),
        Instruction(0x1004,"beqz","a0, 1014 # 1014",0x1014,"beqz a0,1014"),
        Instruction(0x1008,"addi","sp,sp,-16",None,"addi sp,sp,-16"),
        Instruction(0x100C,"addi","sp,sp,32",None,"addi sp,sp,32"),
        Instruction(0x1010,"j","1018 <branch+0x18>",0x1018,"j 1018"),
        Instruction(0x1014,"addi","sp,sp,16",None,"addi sp,sp,16"),
        Instruction(0x1018,"ret","",None,"ret"),
    ])
    assert analyze_frame(branch_valid)["frameBytes"] == 32 and not analyze_frame(branch_valid)["unresolved"]
    recursive = Function("recursive", 0x4000, 8, [Instruction(0x4000,"jal","ra,4000 # 4000",0x4000,"jal ra,4000"), Instruction(0x4004,"ret","",None,"ret")])
    recursive_root = Function("root", 0x5000, 8, [Instruction(0x5000,"jal","ra,6000 # 6000",0x6000,"jal ra,6000"), Instruction(0x5004,"ret","",None,"ret")])
    recursive_report = analyze(recursive_root, recursive, {fn.start: fn for fn in (recursive_root, recursive)}, {}, {}, "synthetic", {})
    assert any("recursive call path" in reason for reason in recursive_report["unresolved"])
    indirect = Function("indirect", 0x7000, 8, [Instruction(0x7000,"jalr","a1",None,"jalr a1"), Instruction(0x7004,"ret","",None,"ret")])
    indirect_root = Function("root2", 0x8000, 8, [Instruction(0x8000,"jal","ra,7000 # 7000",0x7000,"jal ra,7000"), Instruction(0x8004,"ret","",None,"ret")])
    indirect_report = analyze(indirect_root, indirect, {fn.start: fn for fn in (indirect_root, indirect)}, {}, {}, "synthetic", {})
    assert any("unresolved indirect call target" in reason for reason in indirect_report["unresolved"])
    callback = Function("swift_once", 0x9000, 8, [Instruction(0x9000,"jalr","a1",None,"jalr a1"), Instruction(0x9004,"ret","",None,"ret")])
    callback_target = Function("callback", 0xA000, 8, [Instruction(0xA000,"ret","",None,"ret")])
    callback_root = Function("root3", 0xB000, 8, [Instruction(0xB000,"jal","ra,c000 # c000",0xC000,"jal ra,c000"), Instruction(0xB004,"ret","",None,"ret")])
    callback_hook = Function("hook3", 0xC000, 8, [Instruction(0xC000,"jal","ra,9000 # 9000",0x9000,"jal ra,9000"), Instruction(0xC004,"ret","",None,"ret")])
    cb_report = analyze(callback_root, callback_hook, {fn.start: fn for fn in (callback_root, callback_hook, callback, callback_target)}, {"hook3@0xc000": ["callback"]}, {}, "synthetic", {})
    assert any(edge["kind"] == "callback" and edge["target"] == "callback" for edge in cb_report["callGraph"])
    outlined = Function("outlined", 0xD000, 8, [Instruction(0xD000,"jr","t0",None,"jr t0")])
    outroot = Function("outroot", 0xE000, 8, [Instruction(0xE000,"ret","",None,"ret")])
    outhook = Function("outhook", 0xF100, 8, [Instruction(0xF100,"jal","t0,d000 # d000",0xD000,"jal t0,d000"), Instruction(0xF104,"ret","",None,"ret")])
    outreport = analyze(outroot, outhook, {fn.start: fn for fn in (outroot, outhook, outlined)}, {}, {}, "synthetic", {})
    assert outreport["localFrames"]["outlined"]["unresolved"] == []
    assert any(edge["kind"] == "outlined-link" for edge in outreport["callGraph"])
    missing = Function("missingrom", 0xF000, 8, [Instruction(0xF000,"jal","ra,400004a8 # 400004a8 <memcpy>",0x400004A8,"jal ra,400004a8"), Instruction(0xF004,"ret","",None,"ret")])
    missingroot = Function("root4", 0x11000, 8, [Instruction(0x11000,"ret","",None,"ret")])
    memcpy_without_body = Function("memcpy", 0x400004A8, 4, [])
    miss_report = analyze(missingroot, missing, {fn.start: fn for fn in (missingroot, missing, memcpy_without_body)}, {}, {}, "synthetic", {})
    assert any("has no body" in reason for reason in miss_report["unresolved"])
    assert any(item["symbol"] == "memcpy" for item in miss_report["missingROMBodyRequirements"])
    tail = Function("tail", 0x12000, 8, [Instruction(0x12000,"j","13000 <callee>",0x13000,"j 13000" )])
    tailroot = Function("tailroot", 0x14000, 8, [Instruction(0x14000,"ret","",None,"ret")])
    tail_report = analyze(tailroot, tail, {fn.start: fn for fn in (tailroot, tail, Function("callee",0x13000,4,[Instruction(0x13000,"ret","",None,"ret")]))}, {}, {}, "synthetic", {})
    assert any(edge["kind"] == "tail-call" for edge in tail_report["callGraph"])
    # Digest mismatch is the contract loader's required stale-evidence rejection.
    stale_doc = {"idfVersion":"5.4.0", "target":"esp32c6", "records":[{"address":"0x10", "inputs":{"elfSha256":"wrong"}}]}
    assert bind_rom_contracts(stale_doc, "expected", "5.4.0", "esp32c6")[1]
    # External conditional targets, gaps, duplicate PCs, traps, and unknown
    # instructions must never disappear into a transparent fallthrough.
    outside_branch = Function("outside", 0x2000, 12, [
        Instruction(0x2000, "beqz", "a0, 90000000 # 90000000", 0x90000000, "beqz a0,90000000"),
        Instruction(0x2004, "ret", "", None, "ret"),
    ])
    assert any("branch target" in issue for issue in analyze_frame(outside_branch)["unresolved"])
    missing_fallthrough = Function("missing-fallthrough", 0x2100, 12, [
        Instruction(0x2100, "beqz", "a0, 2108 # 2108", 0x2108, "beqz a0,2108"),
        Instruction(0x2108, "ret", "", None, "ret"),
    ])
    assert any("fallthrough" in issue or "gap" in issue for issue in analyze_frame(missing_fallthrough)["unresolved"])
    duplicate_pc = Function("duplicate", 0x2200, 8, [Instruction(0x2200,"ret","",None,"ret"), Instruction(0x2200,"ret","",None,"ret")])
    assert any("duplicate instruction" in issue for issue in analyze_frame(duplicate_pc)["unresolved"])
    for trap in ("ecall", "ebreak", "wfi", "mret", "sret"):
        trapped = fixture(f"{trap}\nret")
        assert any("system trap" in issue for issue in analyze_frame(trapped)["unresolved"])
    exception_branch = Function("exception-branch",0x2400,12,[
        Instruction(0x2400,"beqz","a0, 2408 # 2408",0x2408,"beqz a0,2408"),
        Instruction(0x2404,"mret","",None,"mret"),
        Instruction(0x2408,"ret","",None,"ret"),
    ])
    assert any("system trap" in issue for issue in analyze_frame(exception_branch)["unresolved"])
    overwritten_ra = Function("overwritten-ra",0x2500,8,[
        Instruction(0x2500,"mv","ra,a5",None,"mv ra,a5"),
        Instruction(0x2504,"ret","",None,"ret"),
    ])
    assert any("link-register write/return convention" in issue for issue in analyze_frame(overwritten_ra)["unresolved"])
    unsupported = fixture("mystery_control\nret")
    assert any("unsupported instruction/control-flow" in issue for issue in analyze_frame(unsupported)["unresolved"])
    # All link registers are call edges. An unsupported return convention is
    # unresolved and cannot collapse a 500-byte callee to the 32-byte caller.
    for linkreg in ("t3", "t4", "t5", "t6", "s2", "s11", "a2", "a7", "x28", "x31"):
        linked = Function("links", 0x2300, 8, [Instruction(0x2300,"jal",f"{linkreg}, 3000 # 3000",0x3000,f"jal {linkreg},3000"), Instruction(0x2304,"ret","",None,"ret")])
        assert call_sites(linked) and call_sites(linked)[0][2] == "outlined-link"
    large_callee = Function("large",0x3000,12,[Instruction(0x3000,"addi","sp,sp,-500",None,"addi sp,sp,-500"),Instruction(0x3004,"addi","sp,sp,500",None,"addi sp,sp,500"),Instruction(0x3008,"jr","t3",None,"jr t3")])
    large_hook = Function("large-hook",0x2400,12,[Instruction(0x2400,"addi","sp,sp,-16",None,"addi sp,sp,-16"),Instruction(0x2404,"jal","t3, 3000 # 3000",0x3000,"jal t3,3000"),Instruction(0x2408,"ret","",None,"ret")])
    large_entry = Function("large-entry",0x2500,8,[Instruction(0x2500,"addi","sp,sp,-16",None,"addi sp,sp,-16"),Instruction(0x2504,"ret","",None,"ret")])
    large_report = analyze(large_entry,large_hook,{f.start:f for f in (large_entry,large_hook,large_callee)}, {}, {}, "synthetic", {})
    assert large_report["localFrames"]["large"]["candidateFrameBytes"] == 500 and large_report["maximumStackBytes"] is None
    # Caller dataflow must reach a1 through AUIPC/ADDI and reject a nearby
    # callback address loaded into another register.
    cbflow = Function("cbflow",0x4000,12,[Instruction(0x4000,"auipc","a0, 0x2",None,"auipc a0,0x2"),Instruction(0x4004,"addi","a0,a0,16",None,"addi a0,a0,16"),Instruction(0x4008,"jal","ra, 5000 # 5000",0x5000,"jal ra,5000")])
    assert callback_argument_value(cbflow,0x4008,"a1") is None
    assert callback_argument_value(cbflow,0x4008,"a0") == 0x6010
    skipped_lui = Function("skipped-lui",0x4100,16,[
        Instruction(0x4100,"beqz","a0, 410c # 410c",0x410C,"beqz a0,410c"),
        Instruction(0x4104,"lui","a1, 0x5",None,"lui a1,0x5"),
        Instruction(0x4108,"addi","a1,a1,16",None,"addi a1,a1,16"),
        Instruction(0x410C,"jal","ra, 5000 # 5000",0x5000,"jal ra,5000"),
    ])
    assert callback_argument_value(skipped_lui,0x410C,"a1") is None
    across_cjal = Function("across-cjal",0x4200,12,[
        Instruction(0x4200,"lui","a1, 0x5",None,"lui a1,0x5"),
        Instruction(0x4204,"c.jal","5000 <callee>",0x5000,"c.jal 5000"),
        Instruction(0x4208,"jal","ra, 6000 # 6000",0x6000,"jal ra,6000"),
    ])
    assert callback_argument_value(across_cjal,0x4208,"a1") is None
    for transfer, operands in (("jal", "zero, 420c"), ("jal", "x0, 420c"), ("jalr", "zero, 0(t0)"), ("jalr", "x0, 0(t0)"), ("j", "420c"), ("c.j", "420c")):
        skipped_transfer = Function("skipped-transfer", 0x4300, 16, [
            Instruction(0x4300, transfer, operands, 0x430C if transfer in ("jal", "j", "c.j") else None, f"{transfer} {operands}"),
            Instruction(0x4304, "lui", "a1, 0x1", None, "lui a1,0x1"),
            Instruction(0x4308, "addi", "a1,a1,1024", None, "addi a1,a1,1024"),
            Instruction(0x430C, "jal", "ra, 5000", 0x5000, "jal ra,5000"),
        ])
        assert callback_argument_value(skipped_transfer, 0x430C, "a1") is None, transfer
    # Ascending PCs do not prove execution order: the branch can skip begin.
    skipped_begin_root = Function("skip-begin",0x4300,20,[
        Instruction(0x4300,"beqz","a0, 4308 # 4308",0x4308,"beqz a0,4308"),
        Instruction(0x4304,"jal","ra, 5000 # 5000",0x5000,"jal ra,5000"),
        Instruction(0x4308,"jal","ra, 6000 # 6000",0x6000,"jal ra,6000"),
        Instruction(0x430C,"jal","ra, 7000 # 7000",0x7000,"jal ra,7000"),
        Instruction(0x4310,"ret","",None,"ret"),
    ])
    interval = trace_interval_evidence(
        skipped_begin_root,
        Function("begin",0x5000,4), Function("hook",0x6000,4), Function("end",0x7000,4),
    )
    assert interval["addressOrderObserved"] is True and interval["controlFlowOrderProven"] is False
    # jal x0 tail edges remain visible, including on only one branch. A 512
    # byte allocator target cannot disappear behind the conditional return.
    malloc = Function("malloc",0x8000,8,[
        Instruction(0x8000,"addi","sp,sp,-512",None,"addi sp,sp,-512"),
        Instruction(0x8004,"addi","sp,sp,512",None,"addi sp,sp,512"),
    ])
    conditional_tail = Function("conditional-tail",0x8100,12,[
        Instruction(0x8100,"beqz","a0, 8108 # 8108",0x8108,"beqz a0,8108"),
        Instruction(0x8104,"jal","zero, 8000 # 8000 <malloc>",0x8000,"jal zero,8000"),
        Instruction(0x8108,"ret","",None,"ret"),
    ])
    tail_root = Function("tail-root",0x8200,4,[Instruction(0x8200,"ret","",None,"ret")])
    tail_diagnostic = analyze(tail_root,conditional_tail,{f.start:f for f in (tail_root,conditional_tail,malloc)}, {}, {}, "synthetic", {})
    assert any(edge["kind"] == "tail-call" and edge["target"] == "malloc" for edge in tail_diagnostic["callGraph"])
    assert "malloc" in tail_diagnostic["allocatorSymbolsReachable"]
    assert tail_diagnostic["allocatorReachabilityStatus"].startswith("incomplete")
    indirect_tail = Function("indirect-tail",0x8300,4,[Instruction(0x8300,"jalr","zero, 0(t0)",None,"jalr zero,0(t0)")])
    indirect_tail_report = analyze(tail_root,indirect_tail,{tail_root.start:tail_root,indirect_tail.start:indirect_tail}, {}, {}, "synthetic", {})
    assert any(edge["kind"] == "tail-transfer" and edge["resolution"] == "unresolved" for edge in indirect_tail_report["callGraph"])
    assert indirect_tail_report["allocatorReachabilityStatus"].startswith("incomplete")
    forged_rom = {"idfVersion":"5.4.0","target":"esp32c6","records":[{"address":"0x400004a8","complete":True,"stackBytes":0,"inputs":{"elfSha256":"expected"}}]}
    assert bind_rom_contracts(forged_rom,"expected","5.4.0","esp32c6") == ({}, True)
    # Same-address aliases use the largest listed extent regardless of input
    # order. Every name resolves to that shared, full-range code object.
    alias_texts = (
        "1000 0002 T small_alias\n1000 0008 T larger_func\n",
        "1000 0008 T larger_func\n1000 0002 T small_alias\n",
    )
    alias_views = []
    for alias_text in alias_texts:
        aliases, alias_names = parse_symbols(alias_text)
        assert set(alias_names) == {"small_alias", "larger_func"}
        assert aliases[0x1000].size == alias_names["small_alias"].size == 8
        assert aliases[0x1000].symbol_sizes == {"small_alias": 2, "larger_func": 8}
        alias_disassembly = "1000 <small_alias>:\n 1000: 8082 c.ret\n1002 <local_label>:\n 1002: 8082 c.ret\n 1004: 8082 c.ret\n 1006: 8082 c.ret\n"
        parse_disassembly(alias_disassembly, aliases, alias_names)
        assert len(alias_names["small_alias"].instructions) == 4
        alias_views.append((aliases[0x1000].name, aliases[0x1000].size, [i.address for i in aliases[0x1000].instructions]))
    assert alias_views[0] == alias_views[1]
    overlapping = {
        0x1100: Function("enclosing", 0x1100, 8),
        0x1102: Function("nested", 0x1102, 2),
    }
    parse_disassembly(
        "1100 <enclosing>:\n 1100: 8082 c.ret\n1102 <local_label>:\n 1102: 8082 c.ret\n 1104: 8082 c.ret\n 1106: 8082 c.ret\n",
        overlapping,
    )
    assert [item.address for item in overlapping[0x1100].instructions] == [0x1100, 0x1102, 0x1104, 0x1106]
    assert [item.address for item in overlapping[0x1102].instructions] == [0x1102]
    # A malformed/truncated image fails binding. Real-input tests also mutate
    # one byte and one symbol row in the caller's saved ELF/disassembly pair.
    try:
        elf32_riscv_image(b"\x7fELF")
    except InputBindingError:
        pass
    else:
        raise AssertionError("truncated ELF accepted")
    def minimal_elf32(
        text_bytes: bytes = b"\x82\x80",
        symbols: tuple[tuple[str, int, int, int, int], ...] = (("fixture", 0x1000, 2, 0x12, 1),),
    ) -> bytes:
        data = bytearray(0x100)
        data[0:16] = b"\x7fELF\x01\x01\x01" + bytes(9)
        data.extend(text_bytes)  # caller-selected executable bytes
        strtab = bytearray(b"\0")
        entries = []
        for name, address, size, info, shndx in symbols:
            name_offset = len(strtab)
            strtab.extend(name.encode() + b"\0")
            entries.append(struct.pack("<IIIBBH", name_offset, address, size, info, 0, shndx))
        shstrtab = b"\0.text\0.symtab\0.strtab\0.shstrtab\0"
        symoff = (len(data) + 3) & ~3
        symtab = bytes(16) + b"".join(entries)
        stroff = symoff + len(symtab)
        shstroff = stroff + len(strtab)
        data.extend(bytes(symoff - len(data)))
        data.extend(symtab + strtab + shstrtab)
        shoff = (len(data) + 3) & ~3
        data.extend(bytes(shoff - len(data)))
        shstr = {".text": 1, ".symtab": 7, ".strtab": 15, ".shstrtab": 23}
        section_headers = [bytes(40)]
        section_headers.append(struct.pack("<IIIIIIIIII", shstr[".text"], 1, 6, 0x1000, 0x100, len(text_bytes), 0, 0, 2, 0))
        section_headers.append(struct.pack("<IIIIIIIIII", shstr[".symtab"], 2, 0, 0, symoff, len(symtab), 3, 1, 4, 16))
        section_headers.append(struct.pack("<IIIIIIIIII", shstr[".strtab"], 3, 0, 0, stroff, len(strtab), 0, 0, 1, 0))
        section_headers.append(struct.pack("<IIIIIIIIII", shstr[".shstrtab"], 3, 0, 0, shstroff, len(shstrtab), 0, 0, 1, 0))
        data.extend(b"".join(section_headers))
        struct.pack_into("<HHIIIIIHHHHHH", data, 16, 2, 243, 1, 0, 0, shoff, 0, 52, 0, 0, 40, 5, 4)
        return bytes(data)
    tiny_fn = Function("fixture", 0x1000, 2, [Instruction(0x1000,"c.ret","",None,"c.ret",2,"8082")])
    tiny_symbols = "1000 0002 T fixture\n"
    tiny_elf = minimal_elf32()
    validate_linked_inputs(tiny_elf, tiny_symbols, {tiny_fn.start: tiny_fn})
    # Absolute ROM function symbols have no linked executable body to cover.
    # They remain unresolved when reached by the graph, but do not create a
    # false in-image disassembly truncation failure.
    rom_symbol = "1000 0002 A rom_function\n"
    rom_fn = Function("rom_function", 0x1000, 2, symbol_kinds={"rom_function": "A"})
    validate_linked_inputs(minimal_elf32(symbols=(("rom_function", 0x1000, 2, 0x12, 0xFFF1),)), rom_symbol, {rom_fn.start: rom_fn})
    # Text kind B cannot suppress validation when the ELF says STT_FUNC.
    wrong_kind_fn = Function("fixture",0x1000,2,[Instruction(0x1000,"c.ret","",None,"c.ret",2,"0001")],symbol_kinds={"fixture":"B"})
    try:
        validate_linked_inputs(tiny_elf,"1000 0002 B fixture\n",{wrong_kind_fn.start:wrong_kind_fn})
    except InputBindingError as error:
        assert "encoding mismatch" in str(error)
    else:
        raise AssertionError("caller-controlled B kind bypassed ELF STT_FUNC validation")
    alias_bytes = b"\x82\x80\x82\x80\x82\x80\x82\x80"
    alias_elf_symbols = (("small_alias", 0x1000, 2, 0x12, 1), ("larger_func", 0x1000, 8, 0x12, 1))
    full_alias_disassembly = "1000 <small_alias>:\n 1000: 8082 c.ret\n 1002: 8082 c.ret\n 1004: 8082 c.ret\n 1006: 8082 c.ret\n"
    for alias_text in alias_texts:
        alias_functions, alias_by_name = parse_symbols(alias_text)
        parse_disassembly(full_alias_disassembly, alias_functions, alias_by_name)
        validate_linked_inputs(
            minimal_elf32(alias_bytes, alias_elf_symbols),
            alias_text,
            alias_functions,
        )
    # If the text symbol listing omits the larger alias entirely, the ELF's
    # true extent still prevents the smaller listed alias from clipping code.
    hidden_large_alias = "1000 0002 T small_alias\n"
    hidden_alias_functions, _hidden_alias_names = parse_symbols(hidden_large_alias)
    try:
        validate_linked_inputs(
            minimal_elf32(alias_bytes, alias_elf_symbols),
            hidden_large_alias,
            hidden_alias_functions,
        )
    except InputBindingError as error:
        assert "largest ELF symbol range" in str(error)
    else:
        raise AssertionError("smaller listed alias hid the larger ELF function extent")
    bad_bytes_fn = Function("fixture", 0x1000, 2, [Instruction(0x1000,"c.ret","",None,"c.ret",2,"0001")])
    try:
        validate_linked_inputs(tiny_elf, tiny_symbols, {bad_bytes_fn.start: bad_bytes_fn})
    except InputBindingError:
        pass
    else:
        raise AssertionError("mismatched instruction bytes accepted")
    try:
        validate_linked_inputs(tiny_elf, "1000 0004 T fixture\n", {tiny_fn.start: tiny_fn})
    except InputBindingError:
        pass
    else:
        raise AssertionError("mismatched symbol range accepted")
    # The ELF contains a call block after an early return, but the supplied
    # disassembly stops at that return. Matching the first instruction bytes
    # is insufficient: the complete true function extent must be covered.
    hidden_call_bytes = b"\x82\x80\xef\x00\x40\x00\x82\x80"
    truncated_symbols = "1000 0008 T hidden_callee_caller\n"
    truncated_elf = minimal_elf32(hidden_call_bytes, (("hidden_callee_caller", 0x1000, 8, 0x12, 1),))
    truncated_fn = Function("hidden_callee_caller", 0x1000, 8, [Instruction(0x1000, "c.ret", "", None, "c.ret", 2, "8082")])
    # The incomplete parsed view alone looks like a valid zero-frame function.
    assert analyze_frame(truncated_fn)["frameBytes"] == 0 and not analyze_frame(truncated_fn)["unresolved"]
    try:
        validate_linked_inputs(truncated_elf, truncated_symbols, {truncated_fn.start: truncated_fn})
    except InputBindingError as error:
        assert "uncovered" in str(error)
    else:
        raise AssertionError("truncated disassembly with a hidden callee block was accepted")

    # Exercise the actual CLI boundary with an old output already present.
    # Every malformed external shape must produce a controlled error and leave
    # no stale report at the requested output path.
    with tempfile.TemporaryDirectory(prefix="first-init-cli-self-test-") as temporary_directory:
        directory = Path(temporary_directory)
        names = (("entry", 0x1000), ("begin", 0x1002), ("hook", 0x1004), ("end", 0x1006))
        cli_symbols_text = "".join(f"{address:04x} 0002 T {name}\n" for name, address in names)
        cli_disassembly_text = "".join(f"{address:04x} <{name}>:\n {address:04x}: 8082 c.ret\n" for name, address in names)
        cli_elf = minimal_elf32(b"\x82\x80" * len(names), tuple((name, address, 2, 0x12, 1) for name, address in names))
        cli_inputs = {
            "elf": directory / "image.elf",
            "map": directory / "map.txt",
            "symbols": directory / "symbols.txt",
            "disassembly": directory / "disassembly.txt",
            "config": directory / "config.json",
            "callbacks": directory / "callbacks.json",
            "rom": directory / "rom.json",
        }
        cli_inputs["elf"].write_bytes(cli_elf)
        cli_inputs["map"].write_text(".bss 0x2000 0x4\n")
        cli_inputs["symbols"].write_text(cli_symbols_text)
        cli_inputs["disassembly"].write_text(cli_disassembly_text)
        cli_inputs["config"].write_text('{"IDF_VERSION":"5.4.0"}\n')
        cli_inputs["callbacks"].write_text('{"elfSha256":"unused","sites":[]}\n')
        cli_inputs["rom"].write_text('{"schemaVersion":1,"idfVersion":"5.4.0","target":"esp32c6","records":[]}\n')
        output = directory / "report.json"
        cli_base = [
            sys.executable, str(Path(__file__).resolve()), "--elf", str(cli_inputs["elf"]),
            "--map", str(cli_inputs["map"]), "--symbols", str(cli_inputs["symbols"]),
            "--disassembly", str(cli_inputs["disassembly"]), "--build-config", str(cli_inputs["config"]),
            "--entry", "entry", "--hook", "hook", "--begin", "begin", "--end", "end",
            "--state-symbol", "State", "--out", str(output),
        ]
        malformed_cases = (
            ("config top-level list", "--build-config", "[]"),
            ("truncated config JSON", "--build-config", "{"),
            ("callbacks top-level list", "--callbacks", "[]"),
            ("truncated callbacks JSON", "--callbacks", "{"),
            ("callback missing fields", "--callbacks", '{"elfSha256":"unused","sites":[{}]}'),
            ("callback boolean address", "--callbacks", '{"elfSha256":"unused","sites":[{"caller":"hook","callPc":true,"callback":{"symbol":"fn","address":"0x1000"}}]}'),
            ("callback integer address", "--callbacks", '{"elfSha256":"unused","sites":[{"caller":"hook","callPc":4096,"callback":{"symbol":"fn","address":"0x1000"}}]}'),
            ("callback out-of-range address", "--callbacks", '{"elfSha256":"unused","sites":[{"caller":"hook","callPc":"0x100000000","callback":{"symbol":"fn","address":"0x1000"}}]}'),
            ("ROM top-level list", "--rom-contract", "[]"),
            ("ROM float schema version", "--rom-contract", '{"schemaVersion":1.0,"idfVersion":"5.4.0","target":"esp32c6","records":[]}'),
            ("ROM malformed address", "--rom-contract", '{"schemaVersion":1,"idfVersion":"5.4.0","target":"esp32c6","records":[{"address":true}]}'),
        )
        for label, option, payload in malformed_cases:
            input_path = cli_inputs["config"] if option == "--build-config" else (cli_inputs["rom"] if option == "--rom-contract" else cli_inputs["callbacks"])
            input_path.write_text(payload)
            output.write_text('{"oldReport":true}\n')
            result = subprocess.run(cli_base + [option, str(input_path)], capture_output=True, text=True, check=False)
            assert result.returncode != 0, label
            assert "Traceback" not in result.stderr, (label, result.stderr)
            assert not output.exists(), (label, output.read_text() if output.exists() else "")
        cli_inputs["config"].write_text('{"IDF_VERSION":"5.4.0"}\n')
        parser_error_options = (
            "--elf", "--map", "--disassembly", "--symbols", "--build-config",
            "--callbacks", "--rom-contract", "--entry", "--hook", "--begin",
            "--end", "--state-symbol", "--profile",
        )
        for option in parser_error_options:
            input_snapshot = {path: path.read_bytes() for path in cli_inputs.values()}
            for argv in (cli_base + [option], cli_base[:-2] + [option, "--out", str(output)]):
                output.write_text('{"oldReport":true}\n')
                result = subprocess.run(argv, capture_output=True, text=True, check=False)
                assert result.returncode == 2, (option, argv, result.returncode, result.stderr)
                assert "Traceback" not in result.stderr, (option, result.stderr)
                assert not output.exists(), (option, argv, output.read_text() if output.exists() else "")
                assert {path: path.read_bytes() for path in cli_inputs.values()} == input_snapshot, option
        input_snapshot = {path: path.read_bytes() for path in cli_inputs.values()}
        for argv in (cli_base + ["--self-test=no"], cli_base[:-2] + ["--self-test=no", "--out", str(output)]):
            output.write_text('{"oldReport":true}\n')
            result = subprocess.run(argv, capture_output=True, text=True, check=False)
            assert result.returncode == 2 and "Traceback" not in result.stderr, result.stderr
            assert not output.exists()
            assert {path: path.read_bytes() for path in cli_inputs.values()} == input_snapshot
        output.write_text('{"oldReport":true}\n')
        config_before_parse_error_alias = cli_inputs["config"].read_bytes()
        collision_parse_error = subprocess.run(
            cli_base[:-2] + ["--entry", "--out", str(cli_inputs["config"])],
            capture_output=True, text=True, check=False,
        )
        assert collision_parse_error.returncode == 2 and "aliases input" in collision_parse_error.stderr
        assert "Traceback" not in collision_parse_error.stderr
        assert cli_inputs["config"].read_bytes() == config_before_parse_error_alias
        assert output.read_text() == '{"oldReport":true}\n'
        collision_after_parse_error = subprocess.run(
            cli_base[:-2] + ["--out", str(cli_inputs["config"]), "--entry", "--build-config", str(cli_inputs["config"])],
            capture_output=True, text=True, check=False,
        )
        assert collision_after_parse_error.returncode == 2 and "aliases input" in collision_after_parse_error.stderr
        assert "Traceback" not in collision_after_parse_error.stderr
        assert cli_inputs["config"].read_bytes() == config_before_parse_error_alias
        output.write_text('{"oldReport":true}\n')
        missing_output_value = subprocess.run(
            cli_base + ["--out"], capture_output=True, text=True, check=False,
        )
        assert missing_output_value.returncode == 2 and "Traceback" not in missing_output_value.stderr
        assert output.read_text() == '{"oldReport":true}\n'
        alternate_output = directory / "alternate-old-report.json"
        alternate_output.write_text('{"alternate":true}\n')
        missing_final_output_value = subprocess.run(
            cli_base + ["--out", str(alternate_output), "--out"],
            capture_output=True, text=True, check=False,
        )
        assert missing_final_output_value.returncode == 2 and "Traceback" not in missing_final_output_value.stderr
        assert output.read_text() == '{"oldReport":true}\n'
        assert alternate_output.read_text() == '{"alternate":true}\n'
        output.write_text('{"oldReport":true}\n')
        result = subprocess.run(cli_base + ["--unknown-option"], capture_output=True, text=True, check=False)
        assert result.returncode != 0 and "Traceback" not in result.stderr and not output.exists()
        output.write_text('{"oldReport":true}\n')
        help_result = subprocess.run(cli_base + ["--help"], capture_output=True, text=True, check=False)
        assert help_result.returncode == 0 and output.read_text() == '{"oldReport":true}\n'
        abbreviated_result = subprocess.run(cli_base[:-2] + ["--ou", str(output)], capture_output=True, text=True, check=False)
        assert abbreviated_result.returncode != 0 and "Traceback" not in abbreviated_result.stderr
        assert "unrecognized arguments" in abbreviated_result.stderr
        assert output.read_text() == '{"oldReport":true}\n'
        cli_inputs["config"].write_text('{"IDF_VERSION":"5.4.0"}\n')
        repeated_result = subprocess.run(
            cli_base + ["--out", str(cli_inputs["config"]), "--out", str(output)],
            capture_output=True, text=True, check=False,
        )
        assert repeated_result.returncode == 2 and output.exists(), (repeated_result.returncode, repeated_result.stderr)
        assert cli_inputs["config"].read_text() == '{"IDF_VERSION":"5.4.0"}\n'
        assert json.loads(output.read_text())["status"] == "UNRESOLVED"
        output.write_text('{"oldReport":true}\n')
        literal_alias = subprocess.run(
            [*cli_base[:-2], "--build-config", str(cli_inputs["config"]), "--out", str(cli_inputs["config"])],
            capture_output=True, text=True, check=False,
        )
        assert literal_alias.returncode != 0 and "aliases input" in literal_alias.stderr
        assert cli_inputs["config"].read_text() == '{"IDF_VERSION":"5.4.0"}\n'
        assert output.read_text() == '{"oldReport":true}\n'
        dot_alias = cli_inputs["config"].parent / "unused" / ".." / "config.json"
        dot_alias_result = subprocess.run(
            [*cli_base[:-2], "--out", str(dot_alias)], capture_output=True, text=True, check=False,
        )
        assert dot_alias_result.returncode != 0 and "aliases input" in dot_alias_result.stderr
        hardlink_output = directory / "config-hardlink.json"
        os.link(cli_inputs["config"], hardlink_output)
        hardlink_result = subprocess.run(
            [*cli_base[:-2], "--out", str(hardlink_output)], capture_output=True, text=True, check=False,
        )
        assert hardlink_result.returncode != 0 and "aliases input" in hardlink_result.stderr
        assert cli_inputs["config"].read_text() == '{"IDF_VERSION":"5.4.0"}\n'
        output_symlink = directory / "output-to-config.json"
        output_symlink.symlink_to(cli_inputs["config"])
        symlink_output_result = subprocess.run(
            [*cli_base[:-2], "--out", str(output_symlink)], capture_output=True, text=True, check=False,
        )
        assert symlink_output_result.returncode != 0 and "aliases input" in symlink_output_result.stderr
        assert cli_inputs["config"].read_text() == '{"IDF_VERSION":"5.4.0"}\n' and output_symlink.is_symlink()
        input_symlink = directory / "config-to-report.json"
        input_symlink.symlink_to(output)
        input_symlink_result = subprocess.run(
            [*cli_base[:-2], "--build-config", str(input_symlink), "--out", str(output)],
            capture_output=True, text=True, check=False,
        )
        assert input_symlink_result.returncode != 0 and "aliases input" in input_symlink_result.stderr
        assert input_symlink.is_symlink() and output.read_text() == '{"oldReport":true}\n'
        parent_target = directory / "nested-parent"
        parent_target.mkdir()
        parent_alias = directory / "parent-link"
        parent_alias.symlink_to(parent_target, target_is_directory=True)
        parent_alias_result = subprocess.run(
            [*cli_base[:-2], "--out", str(parent_alias / ".." / "config.json")],
            capture_output=True, text=True, check=False,
        )
        assert parent_alias_result.returncode != 0 and "aliases input" in parent_alias_result.stderr
        assert cli_inputs["config"].read_text() == '{"IDF_VERSION":"5.4.0"}\n'
        equals_output = directory / "equals" / "report.json"
        equals_result = subprocess.run(
            [*cli_base[:-2], f"--out={equals_output}"], capture_output=True, text=True, check=False,
        )
        assert equals_result.returncode == 2 and equals_output.exists()
        bare_separator_result = subprocess.run(
            cli_base + ["--", "--unknown-option"], capture_output=True, text=True, check=False,
        )
        assert bare_separator_result.returncode != 0 and "Traceback" not in bare_separator_result.stderr
        assert not output.exists()
        missing_input = directory / "missing-callbacks.json"
        output.write_text('{"oldReport":true}\n')
        result = subprocess.run(cli_base + ["--callbacks", str(missing_input)], capture_output=True, text=True, check=False)
        assert result.returncode != 0 and "Traceback" not in result.stderr and not output.exists()
        blocked_output = directory / "output-directory"
        blocked_output.mkdir()
        blocked_args = [*cli_base[:-1], str(blocked_output)]
        result = subprocess.run(blocked_args, capture_output=True, text=True, check=False)
        assert result.returncode != 0 and "Traceback" not in result.stderr and blocked_output.is_dir()
    print("first_init_stack self-test: adversarial control-flow and evidence checks passed")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, allow_abbrev=False)
    parser.add_argument("--self-test", action="store_true")
    parser.add_argument("--elf", type=Path, action="append", default=[])
    parser.add_argument("--map", dest="map_file", type=Path, action="append", default=[])
    parser.add_argument("--disassembly", type=Path, action="append", default=[])
    parser.add_argument("--symbols", type=Path, action="append", default=[])
    parser.add_argument("--build-config", type=Path, action="append", default=[], help="exact build config.env containing IDF_VERSION")
    parser.add_argument("--entry", help="exact entry function symbol name")
    parser.add_argument("--hook", help="exact first-init hook function symbol name")
    parser.add_argument("--begin", help="exact trace-begin function symbol name")
    parser.add_argument("--end", help="exact trace-end function symbol name")
    parser.add_argument("--state-symbol", help="exact generated State symbol name")
    parser.add_argument("--callbacks", type=Path, action="append", default=[], help="JSON object mapping caller@0xPC to exact callback symbol list")
    parser.add_argument("--rom-contract", type=Path, action="append", default=[], help="JSON list of digest-bound exact ROM-address records")
    parser.add_argument("--profile", default="unknown")
    parser.add_argument("--out", type=Path, action="append", default=[])
    argv = sys.argv[1:]
    try:
        args, unknown = parser.parse_known_args(argv)
    except SystemExit as error:
        if error.code != 0:
            invalidate_preflight_output(parser, argv)
        raise
    if args.self_test:
        if unknown:
            parser.error(f"unrecognized arguments: {' '.join(unknown)}")
        run_self_tests()
        return 0
    output_path, input_paths = preflight_output_and_inputs(argv)
    if output_path is not None:
        try:
            reject_output_aliases(output_path, input_paths)
            invalidate_output(output_path)
        except InputError as error:
            parser.error(str(error))
    if unknown:
        parser.error(f"unrecognized arguments: {' '.join(unknown)}")
    args.elf = args.elf[-1] if args.elf else None
    args.map_file = args.map_file[-1] if args.map_file else None
    args.disassembly = args.disassembly[-1] if args.disassembly else None
    args.symbols = args.symbols[-1] if args.symbols else None
    args.build_config = args.build_config[-1] if args.build_config else None
    args.callbacks = args.callbacks[-1] if args.callbacks else None
    args.rom_contract = args.rom_contract[-1] if args.rom_contract else None
    args.out = output_path
    required = (args.elf, args.map_file, args.disassembly, args.symbols, args.build_config, args.entry, args.hook, args.begin, args.end, args.state_symbol, args.out)
    if not all(required):
        parser.error("--elf --map --disassembly --symbols --build-config --entry --hook --begin --end --state-symbol and --out are required")
    try:
        paths = {"elf": args.elf, "map": args.map_file, "disassembly": args.disassembly, "symbols": args.symbols, "buildConfig": args.build_config}
        for input_name, input_path in paths.items():
            read_bytes_input(input_path, input_name)
        build_config = validate_build_config(read_json_input(args.build_config, "build config"))
        idf_version = build_config["IDF_VERSION"]
        symbols_text = read_input(args.symbols, "symbols")
        try:
            by_addr, by_name = parse_symbols(symbols_text)
            parse_disassembly(read_input(args.disassembly, "disassembly"), by_addr, by_name)
        except ValueError as error:
            raise InputError(f"invalid symbols or disassembly input: {error}") from error
        root, hook = by_name.get(args.entry), by_name.get(args.hook)
        begin, end = by_name.get(args.begin), by_name.get(args.end)
        if root is None or hook is None or begin is None or end is None:
            raise InputError("entry/hook/begin/end symbol missing from symbol table")
        interval = trace_interval_evidence(root, begin, hook, end)
        interval_ok = False  # static address order is not a control-flow proof
        callbacks: dict[str, list[str]] = {}
        callback_evidence_unverified: list[str] = []
        callback_contract = None
        elf_digest = sha(args.elf)
        if args.callbacks:
            callback_contract = validate_callback_contract(read_json_input(args.callbacks, "callback contract"))
            if callback_contract["elfSha256"] != elf_digest:
                callback_evidence_unverified.append("callback contract ELF digest mismatch")
            for index, record in enumerate(callback_contract["sites"]):
                caller = record["caller"]
                pc = parse_address(record["callPc"], f"callback sites[{index}].callPc")
                callback_name = record["callback"]["symbol"]
                callback_address = parse_address(record["callback"]["address"], f"callback sites[{index}].callback.address")
                actual = by_name.get(callback_name)
                caller_fn = by_name.get(caller)
                call_ins = next((ins for ins in caller_fn.instructions if ins.address == pc), None) if caller_fn else None
                swift_once_target = by_name.get("swift_once")
                if (
                    actual is None
                    or actual.start != callback_address
                    or call_ins is None
                    or call_ins.target != (swift_once_target.start if swift_once_target else None)
                    or caller_fn is None
                    or callback_argument_value(caller_fn, pc) != callback_address
                ):
                    callback_evidence_unverified.append(f"callback argument a1 is not proven for {caller}@0x{pc:x}")
                elif callback_contract["elfSha256"] == elf_digest:
                    callbacks[f"{caller}@{pc:#x}"] = [callback_name]
        rom_document = validate_rom_contract(read_json_input(args.rom_contract, "ROM contract")) if args.rom_contract else {"schemaVersion": 1, "idfVersion": "5.4.0", "target": "esp32c6", "records": []}
        rom: dict[int, dict] = {}
        rom, stale_rom = bind_rom_contracts(rom_document, elf_digest, idf_version, "esp32c6")
        hashes = {name: sha(path) for name, path in paths.items()}
        report = analyze(root, hook, by_addr, callbacks, rom, args.profile, hashes, by_name)
        binding_error = None
        elf_symbols = []
        elf_data = read_bytes_input(args.elf, "ELF")
        try:
            elf_symbols, _executable = elf32_riscv_image(elf_data)
            validate_linked_inputs(elf_data, symbols_text, by_addr)
        except InputBindingError as error:
            binding_error = str(error)
        report["inputEvidenceUnverified"] = True
        report["inputEvidenceBindingError"] = binding_error
        if binding_error:
            report["status"] = "UNRESOLVED"
            report["maximumStackBytes"] = None
            report["knownPathLowerBoundBytes"] = None
            report["unresolved"].append(f"ELF/disassembly/symbol binding failed: {binding_error}")
        if callback_evidence_unverified:
            report["status"] = "UNRESOLVED"
            report["maximumStackBytes"] = None
            report["unresolved"].extend(callback_evidence_unverified)
        report["firstInitInterval"] = interval
        report["callGraph"].append({"caller": root.name, "pc": interval["hookCallPc"], "kind": "entry-hook-candidate", "target": hook.name, "resolution": "unresolved; control-flow order unproven"})
        report["callbackContractSha256"] = sha(args.callbacks) if args.callbacks else None
        report["inputHashes"].update({"callbacks": sha(args.callbacks) if args.callbacks else None, "romContract": sha(args.rom_contract) if args.rom_contract else None})
        report["stackBoundMethod"] = "diagnostic candidates only; external disassembly semantics and control-flow order are unverified; no numeric stack bound is produced"
        if not interval_ok:
            report["status"] = "UNRESOLVED"
            report["maximumStackBytes"] = None
            report["unresolved"].append("entry trace begin, hook, and end control-flow order is not proven; static address order is observational only")
        state_evidence = None
        state_records = [record for record in elf_symbols if record[0] == args.state_symbol]
        if len(state_records) == 1:
            name, address, size, symbol_type, _section_name, section_type = state_records[0]
            guard = any((args.state_symbol.split("Vvp")[0] in item.name and ("_Wz" in item.name or "_WZ" in item.name)) for item in by_addr.values())
            if symbol_type == 1 and section_type == 8 and size == 4 and not guard:
                state_evidence = {"symbol": name, "address": f"0x{address:x}", "sizeBytes": size, "elfSymbolType": "STT_OBJECT", "elfSectionType": "SHT_NOBITS", "storage": "candidate zero-backed ELF object", "initializer": "none evidenced; no matching lazy guard/accessor symbol", "classification": "candidate ordinary State backing access; disassembly semantics and trace execution are unverified"}
        report["generatedStateEvidence"] = state_evidence
        if state_evidence is None:
            report["status"] = "UNRESOLVED"
            report["maximumStackBytes"] = None
            report["unresolved"].append("generated State is not proven four-byte zero-backed BSS without a lazy guard/accessor")
        report["elfSha256"] = hashes["elf"]
        report["analyzerSha256"] = sha(Path(__file__))
        report["sourceRevision"] = None
        report["sourceRevisionEvidence"] = "unknown; ELF producer provenance is not bound to this revision"
        report["toolchainEvidence"] = {"idfVersion": idf_version, "configSha256": hashes["buildConfig"], "target": "esp32c6", "note": "5.4.2 design sample is not accepted"}
        report["staleRomContracts"] = stale_rom
        if report["staleRomContracts"]:
            report["status"] = "UNRESOLVED"
            report["maximumStackBytes"] = None
            report["unresolved"].append("caller-supplied ROM stack claims have no verified body or trusted provenance")
        write_report_atomic(args.out, report)
        print(f"{report['status']}: {args.out}")
        return 0 if report["status"] == "PASS" else 2
    except InputError as error:
        parser.error(str(error))


if __name__ == "__main__":
    sys.exit(main())
