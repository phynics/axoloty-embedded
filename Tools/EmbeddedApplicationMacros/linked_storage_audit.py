# Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.
"""Read-only final ELF and linker-map storage measurement for Embedded62 Unit 1."""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import struct
import sys
import tempfile
from pathlib import Path

VERSION = "embedded62-linked-storage-audit/1"
INVENTORY_VERSION = "axoloty.app-storage-inventory-join.v1"
ALLOC = 0x2
WRITE = 0x1


class AuditError(Exception):
    """An input cannot support the requested measurement."""


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def cstring(table: bytes, offset: int) -> str:
    if offset < 0 or offset >= len(table):
        raise AuditError("invalid ELF string-table offset")
    end = table.find(b"\0", offset)
    if end < 0:
        raise AuditError("unterminated ELF string")
    return table[offset:end].decode("utf-8", "replace")


def parse_elf(data: bytes) -> dict:
    if len(data) < 52 or data[:4] != b"\x7fELF":
        raise AuditError("malformed ELF header")
    elf_class, encoding = data[4], data[5]
    if elf_class not in (1, 2) or encoding not in (1, 2):
        raise AuditError("unsupported ELF class or byte order")
    endian = "<" if encoding == 1 else ">"
    if elf_class == 1:
        fmt = endian + "HHIIIIIHHHHHH"
        header = struct.unpack_from(fmt, data, 16)
        machine, shoff, shentsize, shnum, shstrndx = header[1], header[5], header[10], header[11], header[12]
        section_fmt = endian + "IIIIIIIIII"
        symbol_fmt = endian + "IIIBBH"
    else:
        if len(data) < 64:
            raise AuditError("truncated ELF64 header")
        header = struct.unpack_from(endian + "HHIQQQIHHHHHH", data, 16)
        machine, shoff, shentsize, shnum, shstrndx = header[1], header[5], header[10], header[11], header[12]
        section_fmt = endian + "IIQQQQIIQQ"
        symbol_fmt = endian + "IBBHQQ"
    if machine != 243:
        raise AuditError(f"unsupported ELF architecture machine={machine}")
    if shnum == 0 or shstrndx >= shnum or shentsize < struct.calcsize(section_fmt):
        raise AuditError("unsupported extended or malformed ELF section table")
    if shoff + shentsize * shnum > len(data):
        raise AuditError("ELF section table is outside the file")
    raw_sections = [struct.unpack_from(section_fmt, data, shoff + i * shentsize) for i in range(shnum)]
    string_sec = raw_sections[shstrndx]
    shstr = data[string_sec[4]:string_sec[4] + string_sec[5]]
    sections = []
    for index, row in enumerate(raw_sections):
        name = cstring(shstr, row[0])
        section = {"index": index, "name": name, "type": row[1], "flags": row[2], "address": row[3],
                   "offset": row[4], "size": row[5], "link": row[6], "info": row[7], "alignment": row[8],
                   "entry_size": row[9]}
        if section["type"] != 8 and section["offset"] + section["size"] > len(data):
            raise AuditError(f"ELF section {name} is outside the file")
        sections.append(section)
    symbols = []
    for section in sections:
        if section["type"] not in (2, 11):
            continue
        if section["link"] >= len(sections):
            raise AuditError("symbol table has invalid string-table link")
        strings = sections[section["link"]]
        strtab = data[strings["offset"]:strings["offset"] + strings["size"]]
        ent_size = section["entry_size"] or struct.calcsize(symbol_fmt)
        if ent_size < struct.calcsize(symbol_fmt) or section["size"] % ent_size:
            raise AuditError("malformed ELF symbol table")
        for pos in range(section["offset"], section["offset"] + section["size"], ent_size):
            row = struct.unpack_from(symbol_fmt, data, pos)
            if elf_class == 1:
                name_off, value, size, info, other, shndx = row
            else:
                name_off, info, other, shndx, value, size = row
            name = cstring(strtab, name_off) if name_off else ""
            if not name or not size or shndx >= len(sections):
                continue
            target = sections[shndx]
            if target["flags"] & (ALLOC | WRITE) != (ALLOC | WRITE):
                continue
            if value < target["address"] or value + size > target["address"] + target["size"]:
                raise AuditError(f"writable symbol range outside section: {name}")
            symbols.append({"name": name, "address": value, "size": size, "section": target["name"],
                            "section_index": shndx, "kind": "OBJECT" if (info & 0xF) == 1 else "other"})
    if not sections:
        raise AuditError("ELF has no sections")
    return {"class": 32 if elf_class == 1 else 64, "endianness": "little" if encoding == 1 else "big",
            "architecture": "RISC-V", "sections": sections, "symbols": symbols}


OUT_SECTION = re.compile(r"^([^\s].*?)\s+0x([0-9a-fA-F]+)\s+0x([0-9a-fA-F]+)\s*$")
OUT_NAME_ONLY = re.compile(r"^(\.[^\s]+)\s*$")
OUT_CONTINUATION = re.compile(r"^\s+0x([0-9a-fA-F]+)\s+0x([0-9a-fA-F]+)\s*$")
INPUT = re.compile(r"^\s+(\.[^\s]+)\s+0x([0-9a-fA-F]+)\s+0x([0-9a-fA-F]+)\s+(.+?)\s*$")
INPUT_NAME_ONLY = re.compile(r"^\s+(\.[^\s]+)\s*$")
INPUT_CONTINUATION = re.compile(r"^\s+0x([0-9a-fA-F]+)\s+0x([0-9a-fA-F]+)\s+(.+?)\s*$")
FILL = re.compile(r"^\s+\*fill\*\s+0x([0-9a-fA-F]+)\s+0x([0-9a-fA-F]+)\s*$")
ARCHIVE_MEMBER_IDENTITY = re.compile(r"^(?:[^()/\s]+/)*[^()/\s]+\.a\(([^()/\s]+\.(?:o|obj))\)$")
PLAIN_OBJECT_IDENTITY = re.compile(r"^(?:[^()/\s]+/)*[^()/\s]+\.(?:o|obj)$")


def object_member(identity: str) -> str | None:
    """Return a validated archive member or plain object basename."""
    archive_member = ARCHIVE_MEMBER_IDENTITY.fullmatch(identity)
    if archive_member:
        return archive_member.group(1)
    if PLAIN_OBJECT_IDENTITY.fullmatch(identity):
        return identity.rsplit("/", 1)[-1]
    return None


def parse_map(text: str, object_identity: str) -> dict:
    lines = text.splitlines()
    contributions = []
    current = None
    found_identity = False
    pending_input = None
    pending_output = None
    for line_number, line in enumerate(lines, 1):
        header = OUT_SECTION.match(line)
        if header:
            if pending_input is not None:
                raise AuditError(f"incomplete multiline map input record before line {line_number}")
            current = {"name": header.group(1), "address": int(header.group(2), 16), "size": int(header.group(3), 16), "inputs": []}
            contributions.append(current)
            continue
        if pending_output is not None:
            continuation = OUT_CONTINUATION.match(line)
            if continuation:
                address, size = continuation.groups()
                current = {"name": pending_output, "address": int(address, 16), "size": int(size, 16), "inputs": []}
                contributions.append(current)
                pending_output = None
                continue
            # GNU ld also prints non-allocated debug output names without a
            # range. Ignore those; any required writable ELF section will
            # fail the exact name/address/size coverage check in measure().
            pending_output = None
            current = None
        name_only = OUT_NAME_ONLY.match(line)
        if name_only:
            pending_output = name_only.group(1)
            current = None
            continue
        if current is None or not current["name"].startswith("."):
            continue
        if pending_input is not None:
            continuation = INPUT_CONTINUATION.match(line)
            if continuation:
                address, size, owner = continuation.groups()
                item = {"input_section": pending_input, "address": int(address, 16), "size": int(size, 16), "owner": owner}
                current["inputs"].append(item)
                if owner == object_identity:
                    found_identity = True
                pending_input = None
                continue
            # GNU ld emits a section name on one line and its address, size,
            # and object on the next. Do not silently discard that record.
            raise AuditError(f"unsupported or incomplete multiline map input at line {line_number}")
        row = INPUT.match(line)
        fill = FILL.match(line)
        if row:
            name, address, size, owner = row.groups()
            item = {"input_section": name, "address": int(address, 16), "size": int(size, 16), "owner": owner}
            current["inputs"].append(item)
            if owner == object_identity:
                found_identity = True
        elif INPUT_NAME_ONLY.match(line):
            pending_input = INPUT_NAME_ONLY.match(line).group(1)
        elif fill:
            address, size = fill.groups()
            current["inputs"].append({"input_section": "*fill*", "address": int(address, 16), "size": int(size, 16), "owner": "linker padding"})
    if pending_input is not None:
        raise AuditError("incomplete multiline map input at end of file")
    if pending_output is not None:
        raise AuditError("incomplete multiline output section at end of file")
    if not found_identity:
        raise AuditError(f"combined object not found in writable map contributions: {object_identity}")
    return {"writable_outputs": contributions}


def merged_bytes(ranges: list[tuple[int, int]]) -> int:
    total = 0
    end = None
    for start, stop in sorted(ranges):
        if end is None or start > end:
            total += stop - start
            end = stop
        elif stop > end:
            total += stop - end
            end = stop
    return total


def writable_section_class(name: str) -> str:
    lowered = name.lower()
    if "bss" in lowered:
        return "bss"
    if "data" in lowered and "rodata" not in lowered:
        return "data"
    if name in {".noinit", ".rtc_reserved", ".iram0.text_end", ".flash_rodata_dummy", ".dram0.heap_start"}:
        return "reserved-or-runtime-boundary"
    if "rodata" in lowered:
        return "read-only-content-with-writable-ELF-flag"
    raise AuditError(f"unsupported allocated writable ELF section category: {name}")


def conflicting_overlaps(symbols: list[dict]) -> list[dict]:
    conflicts = []
    by_section = {}
    for symbol in symbols:
        by_section.setdefault(symbol["section_index"], []).append(symbol)
    for group in by_section.values():
        group.sort(key=lambda s: (s["address"], s["address"] + s["size"], s["name"]))
        active = []
        for symbol in group:
            active = [item for item in active if item["address"] + item["size"] > symbol["address"]]
            for prior in active:
                if (prior["address"], prior["size"]) != (symbol["address"], symbol["size"]):
                    conflicts.append({"left": prior["name"], "right": symbol["name"]})
            active.append(symbol)
    return conflicts


def measure(elf_bytes: bytes, map_bytes: bytes, object_identity: str, profile: str,
            firmware_source_sha: str | None = None, core_sha: str | None = None) -> dict:
    elf = parse_elf(elf_bytes)
    linker_map = parse_map(map_bytes.decode("utf-8", "replace"), object_identity)
    alloc_write = [s for s in elf["sections"] if s["flags"] & (ALLOC | WRITE) == (ALLOC | WRITE)]
    for section in alloc_write:
        section["accounting_class"] = writable_section_class(section["name"])
    data_sections = [s for s in alloc_write if s["accounting_class"] == "data"]
    bss_sections = [s for s in alloc_write if s["accounting_class"] == "bss"]
    symbols = sorted(elf["symbols"], key=lambda s: (s["address"], s["size"], s["name"]))
    alias_groups = {}
    for symbol in symbols:
        key = (symbol["address"], symbol["size"], symbol["section"])
        alias_groups.setdefault(key, []).append(symbol["name"])
    overlaps = conflicting_overlaps(symbols)
    if overlaps:
        raise AuditError("conflicting writable symbol ranges: " + json.dumps(overlaps, sort_keys=True))
    object_sections = []
    map_outputs = {}
    for item in linker_map["writable_outputs"]:
        if item["name"] in map_outputs:
            raise AuditError(f"ambiguous duplicate linker map output section {item['name']}")
        map_outputs[item["name"]] = item
    measured_sections = [s for s in alloc_write if s["size"]]
    for section in measured_sections:
        mapped = map_outputs.get(section["name"])
        if mapped is None or mapped["address"] != section["address"] or mapped["size"] != section["size"]:
            raise AuditError(f"linker map does not completely cover writable ELF section {section['name']}")
        end = mapped["address"] + mapped["size"]
        ranges = []
        for item in mapped["inputs"]:
            if item["address"] < mapped["address"] or item["address"] + item["size"] > end:
                raise AuditError(f"map input range outside output section {section['name']}")
            if item["size"]:
                ranges.append((item["address"], item["address"] + item["size"], item))
        ranges.sort(key=lambda value: (value[0], value[1]))
        cursor = mapped["address"]
        for start, stop, item in ranges:
            if start > cursor:
                raise AuditError(f"incomplete map input coverage in {section['name']} at 0x{cursor:x}")
            cursor = max(cursor, stop)
        if cursor != end:
            raise AuditError(f"incomplete map input coverage in {section['name']} at 0x{cursor:x}")
    for output in linker_map["writable_outputs"]:
        if output["name"] not in {s["name"] for s in alloc_write}:
            continue
        matching = [item for item in output["inputs"] if item["owner"] == object_identity and item["size"]]
        if matching:
            selected = list(matching)
            selected_ids = {id(item) for item in selected}
            # Linker *fill* rows touching a combined object's input contribution
            # are alignment debit. They are included once, not also charged as
            # symbol bytes.
            changed = True
            while changed:
                changed = False
                ranges = [(item["address"], item["address"] + item["size"]) for item in selected]
                for item in output["inputs"]:
                    if item["input_section"] != "*fill*" or id(item) in selected_ids:
                        continue
                    start, stop = item["address"], item["address"] + item["size"]
                    if any(stop == left or start == right for left, right in ranges):
                        selected.append(item)
                        selected_ids.add(id(item))
                        changed = True
            object_sections.extend({**item, "output_section": output["name"]} for item in selected)
    if not object_sections:
        raise AuditError("combined object has no sized writable input-section contribution")
    object_ranges = [(x["address"], x["address"] + x["size"]) for x in object_sections]
    report_symbols = []
    for symbol in symbols:
        aliases = sorted(alias_groups[(symbol["address"], symbol["size"], symbol["section"])])
        generated = "__axoloty_application_state" in symbol["name"]
        phase = "phase4AgentA" if "phase4AgentA" in symbol["name"] else "phase4AgentB" if "phase4AgentB" in symbol["name"] else None
        report_symbols.append({**symbol, "aliases": aliases, "range_bytes_union": symbol["size"] if aliases[0] == symbol["name"] else 0,
                              "recognized_identity": "generated-state" if generated else phase,
                              "ownership": "unresolved source ownership; raw ELF identity only"})
    combined_bytes = merged_bytes([(x["address"], x["address"] + x["size"]) for x in object_sections])
    report = {
        "schema": "axoloty.linked-storage-measurement.v1", "tool": {"version": VERSION}, "profile": profile,
        "measurement_only": True,
        "artifact_attribution": {"firmware_source_sha": firmware_source_sha, "core_sha": core_sha,
                                 "integrated_revision": False},
        "input": {"elf_sha256": sha256(elf_bytes), "map_sha256": sha256(map_bytes), "combined_object_identity": object_identity},
        "elf": {"architecture": elf["architecture"], "class_bits": elf["class"], "endianness": elf["endianness"]},
        "writable_allocated_sections": [{"name": s["name"], "address": s["address"], "size": s["size"], "alignment": s["alignment"], "type": s["type"], "accounting_class": s["accounting_class"]} for s in alloc_write],
        "whole_image": {"data_bytes": sum(s["size"] for s in data_sections), "data_sections": [s["name"] for s in data_sections],
                        "bss_bytes": sum(s["size"] for s in bss_sections), "bss_sections": [s["name"] for s in bss_sections]},
        "writable_symbols": report_symbols,
        "exact_symbol_union_bytes": merged_bytes([(s["address"], s["address"] + s["size"]) for s in symbols]),
        "exact_symbol_range_count": len(symbols),
        "identified_symbols": [s for s in report_symbols if s["recognized_identity"]],
        "combined_object": {"accounting": "conservative upper bound; whole writable input contributions replace symbol charges",
                            "writable_contributions": object_sections, "conservative_debit_bytes": combined_bytes,
                            "symbol_ranges_inside_contributions": merged_bytes([(max(a, c), min(b, d)) for a, b in [(s["address"], s["address"] + s["size"]) for s in symbols] for c, d in object_ranges if max(a, c) < min(b, d)])},
        "aggregate_charged_static_bytes": combined_bytes,
        "attribution": {"complete": False, "reason": "map object membership is not source ownership; this unit intentionally reports a conservative combined-object debit"},
        "pending": ["storage-budget acceptance", "source-ownership completeness", "first-init trace", "initialization stack proof", "whole-image heap behavior"],
    }
    return report


def join_inventory(inventory: dict, symbols: list[dict], map_outputs: list[dict],
                   source_root: Path, inventory_sha256: str, expected_map_owner: str,
                   section_types: dict[str, int] | None = None) -> dict:
    """Join explicit source identities to exact writable ELF symbol names."""
    if not isinstance(inventory, dict):
        raise AuditError("inventory root must be an object")
    if inventory.get("schemaVersion") != 1 or not isinstance(inventory.get("entries"), list):
        raise AuditError("inventory must use schemaVersion 1 and contain entries")
    inventory_map_member = inventory.get("expectedMapMember")
    if not isinstance(inventory_map_member, str) or object_member(inventory_map_member) != inventory_map_member:
        raise AuditError("inventory must declare expectedMapMember as an exact .o or .obj basename")
    expected_member = object_member(expected_map_owner)
    if expected_member is None:
        raise AuditError("--combined-object must use archive-member or plain-object linker identity syntax")
    if inventory_map_member != expected_member:
        raise AuditError("inventory expectedMapMember does not match --combined-object member: "
                         f"{inventory_map_member!r} != {expected_member!r}")
    owners = set()
    expected_names = set()
    joined = []
    unmatched = []
    ambiguous = []
    charged_ranges = set()
    for entry in inventory["entries"]:
        if not isinstance(entry, dict):
            raise AuditError("inventory entries must be objects")
        owner = entry.get("owner")
        if not isinstance(owner, str) or not owner or owner in owners:
            raise AuditError(f"inventory has missing or duplicate logical owner: {owner!r}")
        owners.add(owner)
        if entry.get("category") not in {"app-state", "app-global", "initialization-control"}:
            raise AuditError(f"inventory entry {owner} has unsupported category")
        source_path = entry.get("sourcePath")
        source_name = entry.get("sourceName")
        source_kind = entry.get("sourceKind")
        if (not isinstance(source_path, str) or not isinstance(source_name, str)
                or source_kind not in {"swift-source", "generator-source"}):
            raise AuditError(f"inventory entry {owner} lacks source identity")
        if ((source_path.endswith(".swift")) != (source_kind == "swift-source")):
            raise AuditError(f"inventory sourceKind does not match source path kind for {owner}: {source_path}")
        source_file = (source_root / source_path).resolve()
        try:
            source_file.relative_to(source_root.resolve())
            source_bytes = source_file.read_bytes()
        except (ValueError, OSError) as error:
            raise AuditError(f"inventory source path unavailable for {owner}: {source_path}") from error
        if source_name.encode() not in source_bytes:
            raise AuditError(f"source identity {source_name!r} not found in {source_path}")
        expected = entry.get("expectedSymbols")
        if not isinstance(expected, list) or not expected:
            raise AuditError(f"inventory entry {owner} has no expected ELF symbols")
        for identity in expected:
            raw_name = identity.get("rawName") if isinstance(identity, dict) else None
            role = identity.get("role") if isinstance(identity, dict) else None
            if not isinstance(raw_name, str) or not isinstance(role, str):
                raise AuditError(f"inventory entry {owner} has malformed symbol identity")
            if raw_name in expected_names:
                raise AuditError(f"ELF symbol assigned to multiple inventory entries: {raw_name}")
            expected_names.add(raw_name)
            matches = [symbol for symbol in symbols if symbol["name"] == raw_name]
            if not matches:
                unmatched.append({"owner": owner, "raw_name": raw_name, "reason": "expected-symbol-missing"})
                continue
            if len(matches) != 1:
                ambiguous.append({"owner": owner, "raw_name": raw_name, "reason": "multiple-exact-symbol-identities",
                                  "match_count": len(matches)})
                continue
            symbol = matches[0]
            section_class = writable_section_class(symbol["section"])
            if section_class not in {"data", "bss"}:
                raise AuditError(f"inventory symbol is outside .data/.bss: {raw_name} ({symbol['section']})")
            section_type = (section_types or {}).get(symbol["section"])
            if section_type == 8:
                initialization_category = "zero-backed"
                initialization_evidence = "ELF SHT_NOBITS section"
            elif section_type == 1:
                initialization_category = "file-backed-writable-bytes"
                initialization_evidence = "ELF SHT_PROGBITS section; initializer value is not inferred"
            else:
                raise AuditError(f"inventory symbol has unsupported or unknown ELF section type: {raw_name}")
            stop = symbol["address"] + symbol["size"]
            map_matches = []
            for output in map_outputs:
                if output["name"] != symbol["section"]:
                    continue
                for item in output["inputs"]:
                    if item["size"] and item["address"] <= symbol["address"] and stop <= item["address"] + item["size"]:
                        map_matches.append({"output_section": output["name"], "input_section": item["input_section"],
                                            "linker_owner": item["owner"], "address": item["address"], "size": item["size"]})
            if len(map_matches) != 1:
                ambiguous.append({"owner": owner, "raw_name": raw_name,
                                  "reason": "map-input-range-not-unique", "matches": map_matches})
                continue
            actual_map_owner = map_matches[0]["linker_owner"]
            actual_member = object_member(actual_map_owner)
            if actual_member is None:
                raise AuditError("containing map input has unsupported archive-member or plain-object syntax: "
                                 f"{actual_map_owner!r}")
            if actual_map_owner != expected_map_owner or actual_member != inventory_map_member:
                unmatched.append({"owner": owner, "raw_name": raw_name,
                                  "reason": "map-owner-contract-mismatch",
                                  "expected_map_owner": expected_map_owner,
                                  "expected_map_member": inventory_map_member,
                                  "actual_map_owner": actual_map_owner,
                                  "actual_map_member": actual_member})
                continue
            aliases = sorted(other["name"] for other in symbols
                             if other["address"] == symbol["address"] and other["size"] == symbol["size"]
                             and other["section"] == symbol["section"] and other["name"] != raw_name)
            range_key = (symbol["section"], symbol["address"], symbol["size"])
            range_charge = 0 if range_key in charged_ranges else symbol["size"]
            charged_ranges.add(range_key)
            joined.append({"owner": owner, "category": entry.get("category"), "source_reference_evidence": {
                               "path": source_path, "name": source_name, "sha256": sha256(source_bytes),
                               "source_kind": source_kind, "match": "byte-substring",
                               "evidence_scope": "lexical-source-reference-only",
                               "does_not_prove": ["AST declaration or scope", "compiled origin of the ELF symbol"]},
                           "raw_name": raw_name, "symbol_role": role,
                           "address": symbol["address"], "size": symbol["size"],
                           "section": symbol["section"], "range": {"start": symbol["address"], "end_exclusive": stop},
                           "initialization_category": initialization_category,
                           "initialization_evidence": initialization_evidence,
                           "map_input": map_matches[0], "aliases": aliases,
                           "range_bytes_charged": range_charge})
    if unmatched or ambiguous:
        raise AuditError("inventory join failed: " + json.dumps({"unmatched": unmatched, "ambiguous": ambiguous}, sort_keys=True))
    by_owner = {}
    for symbol in joined:
        by_owner.setdefault(symbol["owner"], []).append(symbol)
    section_ranges = {}
    for item in joined:
        section_ranges.setdefault(item["section"], []).append((item["address"], item["address"] + item["size"]))
    joined_union = sum(merged_bytes(ranges) for ranges in section_ranges.values())
    coverage = inventory.get("coverage")
    return {"schema": INVENTORY_VERSION, "inventory": {"path": str((source_root / inventory.get("path", "")).resolve()),
            "sha256": inventory_sha256, "app": inventory.get("app"),
            "expected_map_member": inventory_map_member, "combined_object_identity": expected_map_owner},
        "join_status": "matched", "recognized_logical_owners": sorted(by_owner), "symbols": joined,
        "joined_symbol_union_bytes": joined_union,
        "unmatched": unmatched, "ambiguous": ambiguous, "optimized_away_or_unemitted": [],
        "candidate_scope": "exact expected identities in this explicit inventory only",
        "source_coverage": {"complete": False, "verified": False,
            "inventory_claimed_complete": isinstance(coverage, dict) and coverage.get("complete") is True,
            "reason": "the auditor performs no source-wide declaration or ownership analysis; inventory claims cannot establish completeness"},
        "merged_attribution": {"status": "conservative-combined-object-debit-retained",
            "note": "ELF symbols identify listed ranges; map object membership does not prove source ownership of neighboring bytes."}}


def selftest() -> None:
    assert object_member("esp-idf/main/libmain.a(AgentExchange.swift.obj)") == "AgentExchange.swift.obj"
    assert object_member("Objects/AgentExchange.swift.obj") == "AgentExchange.swift.obj"
    assert object_member("libmain.a(path/AgentExchange.swift.obj)") is None
    assert object_member("AgentExchange.swift.obj.backup") is None
    assert merged_bytes([(0, 8), (0, 8), (4, 12), (20, 24)]) == 16
    # A miniature ELF/map model exercises nonzero .data, zero-backed .bss,
    # input padding, full-object debit, and missing/malformed input rejection.
    def elf_fixture(data_name: bytes = b".data") -> bytes:
        # Construct an ELF32 RISC-V image with .data (8 bytes), .bss (16 bytes),
        # and two same-range aliases plus a distinct symbol.
        names = b"\0.shstrtab\0.strtab\0.symtab\0" + data_name + b"\0.bss\0"
        strs = b"\0state\0state_alias\0tail\0"
        names_off = 52
        str_off = names_off + len(names)
        sym_off = str_off + len(strs)
        data_off = sym_off + 4 * 16
        bss_off = data_off + 8
        shoff = bss_off
        sections = [
            (0, 0, 0, 0, 0, 0, 0, 0, 0, 0),
            (names.index(b".shstrtab"), 3, 0, 0, names_off, len(names), 0, 0, 1, 0),
            (names.index(b".strtab"), 3, 0, 0, str_off, len(strs), 0, 0, 1, 0),
            (names.index(b".symtab"), 2, 0, 0, sym_off, 64, 2, 1, 4, 16),
            (names.index(data_name), 1, 3, 0x1000, data_off, 8, 0, 0, 4, 0),
            (names.index(b".bss"), 8, 3, 0x2000, bss_off, 16, 0, 0, 4, 0),
        ]
        out = bytearray(b"\0" * 52)
        out.extend(names); out.extend(strs)
        out.extend(b"\0" * 16)
        for name, value, size in ((1, 0x1000, 4), (7, 0x1000, 4), (19, 0x2000, 8)):
            out.extend(struct.pack("<IIIBBH", name, value, size, 0x11, 0, 4 if value == 0x1000 else 5))
        out.extend(b"12345678")
        shoff = len(out)
        for row in sections:
            out.extend(struct.pack("<IIIIIIIIII", *row))
        header = struct.pack("<HHIIIIIHHHHHH", 2, 243, 1, 0, 0, shoff, 0, 52, 32, 0, 40, 6, 1)
        out[:16] = b"\x7fELF\x01\x01\x01" + b"\0" * 9
        out[16:52] = header
        return bytes(out)
    fake_map = (".data 0x1000 0x8\n .data 0x1000 0x8 combined.o\n"
                ".bss 0x2000 0x10\n .bss 0x2000 0x8 combined.o\n *fill* 0x2008 0x8\n")
    result = measure(elf_fixture(), fake_map.encode(), "combined.o", "fixture")
    assert result["whole_image"]["data_bytes"] == 8 and result["whole_image"]["bss_bytes"] == 16
    assert result["exact_symbol_union_bytes"] == 12
    assert result["combined_object"]["conservative_debit_bytes"] == 24
    assert result["combined_object"]["symbol_ranges_inside_contributions"] == 12
    # This is the parent finding: the output section still matches the ELF,
    # but deleting the combined object's nonzero .bss row must fail closed.
    omitted_bss = fake_map.replace(" .bss 0x2000 0x8 combined.o\n", "")
    try:
        measure(elf_fixture(), omitted_bss.encode(), "combined.o", "fixture")
    except AuditError as error:
        assert "incomplete map input coverage" in str(error)
    else:
        raise AssertionError("map with omitted combined-object .bss row accepted")
    # GNU ld multiline records are accepted, but incomplete and ambiguous
    # ranges are rejected by the same production measure path.
    multiline_map = (".data 0x1000 0x8\n .data\n  0x1000 0x8 combined.o\n"
                    ".bss 0x2000 0x10\n .bss\n  0x2000 0x8 combined.o\n *fill* 0x2008 0x8\n")
    assert measure(elf_fixture(), multiline_map.encode(), "combined.o", "fixture")["combined_object"]["conservative_debit_bytes"] == 24
    for invalid_map, expected in (
        (fake_map.replace(" *fill* 0x2008 0x8\n", ""), "incomplete map input coverage"),
        (fake_map.replace(" *fill* 0x2008 0x8\n", " .other 0x3000 0x8 other.o\n"), "outside output section"),
        (fake_map.replace("combined.o", "combined.o.extra"), "combined object not found"),
        (fake_map.replace(" .bss 0x2000 0x8 combined.o\n", " .bss\n"), "incomplete multiline map input"),
        (fake_map + ".data 0x1000 0x8\n .data 0x1000 0x8 combined.o\n", "ambiguous duplicate linker map output"),
    ):
        try:
            measure(elf_fixture(), invalid_map.encode(), "combined.o", "fixture")
        except AuditError as error:
            assert expected in str(error), (expected, str(error))
        else:
            raise AssertionError(f"invalid map accepted; expected {expected}")
    unknown_map = fake_map.replace(".data", ".writableXX")
    try:
        measure(elf_fixture(b".writableXX"), unknown_map.encode(), "combined.o", "fixture")
    except AuditError as error:
        assert "unsupported allocated writable ELF section category" in str(error)
    else:
        raise AssertionError("unknown writable ELF section category accepted")
    assert not conflicting_overlaps([{"section_index": 1, "address": 0, "size": 8, "name": "outer"},
                                     {"section_index": 1, "address": 0, "size": 8, "name": "alias"}])
    assert conflicting_overlaps([{"section_index": 1, "address": 0, "size": 12, "name": "outer"},
                                 {"section_index": 1, "address": 4, "size": 2, "name": "nested"}])
    # The opt-in inventory join uses exact raw identities, separates a lazy
    # control word from its similarly named backing, accepts .data/.bss, and
    # reports same-range aliases without charging them twice.
    with tempfile.TemporaryDirectory() as directory:
        root = Path(directory)
        (root / "State.swift").write_text("struct State {}\n", encoding="utf-8")
        (root / "Agents.swift").write_text("var phase4AgentA = 0\n", encoding="utf-8")
        (root / "Generate.mjs").write_text("const generatedWorkspace = 0;\n", encoding="utf-8")
        fixture_symbols = [
            {"name": "stateBacking", "address": 0x1000, "size": 4, "section": ".data", "section_index": 1},
            {"name": "stateAlias", "address": 0x1000, "size": 4, "section": ".data", "section_index": 1},
            {"name": "phase4AgentABacking", "address": 0x2000, "size": 8, "section": ".bss", "section_index": 2},
            {"name": "phase4AgentAControl", "address": 0x2010, "size": 4, "section": ".bss", "section_index": 2},
            {"name": "generatedWorkspace", "address": 0x2018, "size": 4, "section": ".bss", "section_index": 2},
        ]
        fixture_outputs = [
            {"name": ".data", "inputs": [{"input_section": ".data", "address": 0x1000, "size": 8, "owner": "combined.o"}]},
            {"name": ".bss", "inputs": [{"input_section": ".bss", "address": 0x2000, "size": 0x20, "owner": "combined.o"}]},
        ]
        inventory = {"schemaVersion": 1, "app": "fixture", "expectedMapMember": "combined.o", "entries": [
            {"owner": "State", "category": "app-state", "sourcePath": "State.swift", "sourceKind": "swift-source", "sourceName": "State",
             "expectedSymbols": [{"rawName": "stateBacking", "role": "backing"},
                                 {"rawName": "stateAlias", "role": "alias"}]},
            {"owner": "phase4AgentA", "category": "app-global", "sourcePath": "Agents.swift", "sourceKind": "swift-source", "sourceName": "phase4AgentA",
             "expectedSymbols": [{"rawName": "phase4AgentABacking", "role": "backing"},
                                 {"rawName": "phase4AgentAControl", "role": "lazy-control"}]},
            {"owner": "generatedWorkspace", "category": "app-global", "sourcePath": "Generate.mjs", "sourceKind": "generator-source", "sourceName": "generatedWorkspace",
             "expectedSymbols": [{"rawName": "generatedWorkspace", "role": "backing"}]},
        ]}
        joined = join_inventory(inventory, fixture_symbols, fixture_outputs, root, "fixture-inventory-hash", "combined.o",
                                {".data": 1, ".bss": 8})
        assert joined["join_status"] == "matched"
        assert joined["joined_symbol_union_bytes"] == 20
        assert joined["source_coverage"]["complete"] is False
        assert joined["source_coverage"]["verified"] is False
        assert joined["symbols"][0]["source_reference_evidence"]["evidence_scope"] == "lexical-source-reference-only"
        state_result = next(item for item in joined["symbols"] if item["raw_name"] == "stateBacking")
        assert state_result["section"] == ".data" and state_result["aliases"] == ["stateAlias"]
        assert state_result["initialization_category"] == "file-backed-writable-bytes"
        assert state_result["range_bytes_charged"] == 4
        alias_result = next(item for item in joined["symbols"] if item["raw_name"] == "stateAlias")
        assert alias_result["aliases"] == ["stateBacking"] and alias_result["range_bytes_charged"] == 0
        assert sum(item["range_bytes_charged"] for item in joined["symbols"]) == 20
        generated = next(item for item in joined["symbols"] if item["raw_name"] == "generatedWorkspace")
        assert generated["source_reference_evidence"]["source_kind"] == "generator-source"
        assert generated["source_reference_evidence"]["evidence_scope"] == "lexical-source-reference-only"
        agent = [item for item in joined["symbols"] if item["owner"] == "phase4AgentA"]
        assert {item["symbol_role"]: item["size"] for item in agent} == {"backing": 8, "lazy-control": 4}
        assert all(item["section"] == ".bss" for item in agent)
        assert all(item["initialization_category"] == "zero-backed" for item in agent)
        missing = [dict(item) for item in fixture_symbols if item["name"] != "phase4AgentAControl"]
        try:
            join_inventory(inventory, missing, fixture_outputs, root, "fixture", "combined.o", {".data": 1, ".bss": 8})
        except AuditError as error:
            assert "expected-symbol-missing" in str(error)
        else:
            raise AssertionError("missing expected inventory symbol accepted")
        ambiguous = fixture_symbols + [dict(fixture_symbols[-1])]
        try:
            join_inventory(inventory, ambiguous, fixture_outputs, root, "fixture", "combined.o", {".data": 1, ".bss": 8})
        except AuditError as error:
            assert "multiple-exact-symbol-identities" in str(error)
        else:
            raise AssertionError("ambiguous exact inventory symbol accepted")
        asserted_coverage = {**inventory, "coverage": {"complete": True, "method": "untrusted"}}
        forced_incomplete = join_inventory(asserted_coverage, fixture_symbols, fixture_outputs, root, "fixture",
                                           "combined.o", {".data": 1, ".bss": 8})
        assert forced_incomplete["source_coverage"] == {
            "complete": False, "verified": False, "inventory_claimed_complete": True,
            "reason": "the auditor performs no source-wide declaration or ownership analysis; inventory claims cannot establish completeness"}
        unrelated_outputs = [dict(output, inputs=[dict(item, owner="other/libforeign.a(combined.o)") for item in output["inputs"]])
                             for output in fixture_outputs]
        try:
            join_inventory(inventory, fixture_symbols, unrelated_outputs, root, "fixture", "combined.o",
                           {".data": 1, ".bss": 8})
        except AuditError as error:
            assert "map-owner-contract-mismatch" in str(error)
            assert "other/libforeign.a(combined.o)" in str(error)
        else:
            raise AssertionError("unique map containment from an unrelated object was accepted")
        for missing_member in ({key: value for key, value in inventory.items() if key != "expectedMapMember"},
                               {**inventory, "expectedMapMember": ""}):
            try:
                join_inventory(missing_member, fixture_symbols, fixture_outputs, root, "fixture", "combined.o",
                               {".data": 1, ".bss": 8})
            except AuditError as error:
                assert "expectedMapMember" in str(error)
            else:
                raise AssertionError("missing or empty expected map member accepted")
        for wrong_member in ("other.obj", "prefix-combined.o", "path/combined.o"):
            try:
                join_inventory({**inventory, "expectedMapMember": wrong_member}, fixture_symbols,
                               fixture_outputs, root, "fixture", "combined.o", {".data": 1, ".bss": 8})
            except AuditError as error:
                assert "expectedMapMember" in str(error) or "does not match --combined-object member" in str(error)
            else:
                raise AssertionError(f"mismatched or lookalike expected map member accepted: {wrong_member}")
        for invalid_identity in ("libbad.a(path/combined.o)", "bad archive.a(combined.o)", "combined.o(suffix)"):
            try:
                join_inventory(inventory, fixture_symbols, fixture_outputs, root, "fixture", invalid_identity,
                               {".data": 1, ".bss": 8})
            except AuditError as error:
                assert "linker identity syntax" in str(error)
            else:
                raise AssertionError(f"malformed --combined-object identity accepted: {invalid_identity}")
    try:
        measure(elf_fixture(), fake_map.encode(), "missing.o", "fixture")
    except AuditError:
        pass
    else:
        raise AssertionError("missing object accepted")
    try:
        parse_elf(b"bad")
    except AuditError:
        pass
    else:
        raise AssertionError("malformed ELF accepted")


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--elf", type=Path)
    parser.add_argument("--map", dest="map_path", type=Path)
    parser.add_argument("--combined-object", help="exact object identity as it appears in linker map rows")
    parser.add_argument("--profile", default="unspecified")
    parser.add_argument("--firmware-source-sha")
    parser.add_argument("--core-sha")
    parser.add_argument("--inventory", type=Path, help="opt-in app-owned explicit storage inventory JSON")
    parser.add_argument("--output", type=Path, help="write JSON to this file; stdout otherwise")
    parser.add_argument("--selftest", action="store_true")
    args = parser.parse_args(argv)
    try:
        if args.selftest:
            selftest()
            print("PASS linked-storage audit fixtures")
            return 0
        if not args.elf or not args.map_path or not args.combined_object:
            parser.error("--elf, --map, and --combined-object are required")
        report = measure(args.elf.read_bytes(), args.map_path.read_bytes(), args.combined_object, args.profile,
                         args.firmware_source_sha, args.core_sha)
        if args.inventory:
            inventory_bytes = args.inventory.read_bytes()
            inventory = json.loads(inventory_bytes)
            inventory["path"] = str(args.inventory.resolve())
            elf = parse_elf(args.elf.read_bytes())
            linker_map = parse_map(args.map_path.read_bytes().decode("utf-8", "replace"), args.combined_object)
            report["inventory_join"] = join_inventory(inventory, elf["symbols"],
                linker_map["writable_outputs"], args.inventory.resolve().parent,
                sha256(inventory_bytes), args.combined_object,
                {section["name"]: section["type"] for section in elf["sections"]})
        output = json.dumps(report, sort_keys=True, indent=2) + "\n"
        if args.output:
            args.output.write_text(output, encoding="utf-8")
        else:
            sys.stdout.write(output)
        return 0
    except (AuditError, OSError, UnicodeError, ValueError) as error:
        print(f"linked-storage audit: {error}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
