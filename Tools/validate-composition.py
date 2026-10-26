#!/usr/bin/env python3
# Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

"""Validate an application × platform × carrier selection before configure."""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path
from typing import Any

from capability_catalog import CARRIER, PLATFORM


class CompositionError(Exception):
    """A profile or axis manifest violates the composition contract."""


def read_json(path: Path) -> dict[str, Any]:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise CompositionError(f"cannot read {path}: {error}") from error
    if not isinstance(value, dict):
        raise CompositionError(f"{path} must contain a JSON object")
    return value


def string_set(value: Any, label: str) -> set[str]:
    if not isinstance(value, list) or any(not isinstance(item, str) for item in value):
        raise CompositionError(f"{label} must be an array of capability names")
    values = set(value)
    if len(values) != len(value):
        raise CompositionError(f"{label} contains a duplicate capability")
    return values


def app_requirements(manifest: dict[str, Any], manifest_path: Path) -> tuple[set[str], set[str], dict[str, int]]:
    requirements = manifest.get("requirements")
    if not isinstance(requirements, dict):
        raise CompositionError(f"{manifest_path} requirements must declare platform and carrier arrays")
    platform_required = string_set(requirements.get("platform"), f"{manifest_path} requirements.platform")
    carrier_required = string_set(requirements.get("carrier"), f"{manifest_path} requirements.carrier")
    unknown_platform = sorted(platform_required - PLATFORM.keys())
    unknown_carrier = sorted(carrier_required - CARRIER.keys())
    if unknown_platform:
        raise CompositionError(f"unknown platform capability name: {', '.join(unknown_platform)}")
    if unknown_carrier:
        raise CompositionError(f"unknown carrier capability name: {', '.join(unknown_carrier)}")
    capacities = manifest.get("capacities")
    if not isinstance(capacities, dict):
        raise CompositionError(f"{manifest_path} capacities must be an object")
    for name in ("maxTopicLength", "maxPayloadSize", "applicationStateBytes"):
        value = capacities.get(name)
        if not isinstance(value, int) or isinstance(value, bool) or value <= 0 or value > 0xFFFFFFFF:
            raise CompositionError(f"{manifest_path} capacities.{name} must be a positive UInt32")
    return platform_required, carrier_required, capacities


def check_requirements(axis: str, required: set[str], available: set[str], selected: str) -> None:
    missing = sorted(required - available)
    if missing:
        names = ", ".join(missing)
        raise CompositionError(f"{axis} '{selected}' does not provide required capability: {names}")


def validate(repo_root: Path, profile_path: Path) -> tuple[set[str], set[str], dict[str, int]]:
    profile = read_json(profile_path)
    if profile.get("schemaVersion", 1) != 1:
        raise CompositionError(f"unsupported profile schema in {profile_path}")
    for field in ("application", "platform", "transport"):
        if not isinstance(profile.get(field), str) or not profile[field]:
            raise CompositionError(f"{profile_path} must select exactly one {field}")

    axes = {
        "application": (repo_root / "Applications" / profile["application"], "app.json"),
        "platform": (repo_root / "Platforms" / profile["platform"], "platform.json"),
        "transport": (repo_root / "Transports" / profile["transport"], "transport.json"),
    }
    manifests: dict[str, dict[str, Any]] = {}
    for axis, (directory, filename) in axes.items():
        manifest_path = directory / filename
        manifest = read_json(manifest_path)
        if manifest.get("schemaVersion") != 1:
            raise CompositionError(f"unsupported {axis} manifest schema: {manifest_path}")
        if manifest.get("name") != profile[axis]:
            raise CompositionError(f"{manifest_path} name does not match selected {axis} '{profile[axis]}'")
        manifests[axis] = manifest

    lock = read_json(repo_root / "axoloty-core.lock.json")
    locked_core = lock.get("core", lock)
    core = profile.get("core")
    if not isinstance(core, dict) or core.get("revision") != locked_core.get("revision"):
        raise CompositionError("profile Core revision does not match axoloty-core.lock.json")

    platform_required, carrier_required, capacities = app_requirements(
        manifests["application"], axes["application"][0] / "app.json"
    )
    platform_available = string_set(manifests["platform"].get("capabilities"), "platform.json capabilities")
    carrier_available = string_set(manifests["transport"].get("capabilities"), "transport.json capabilities")
    unknown_platform = sorted(platform_available - PLATFORM.keys())
    unknown_carrier = sorted(carrier_available - CARRIER.keys())
    if unknown_platform:
        raise CompositionError(f"unknown platform capability name: {', '.join(unknown_platform)}")
    if unknown_carrier:
        raise CompositionError(f"unknown carrier capability name: {', '.join(unknown_carrier)}")
    check_requirements("platform", platform_required, platform_available, profile["platform"])
    check_requirements("carrier", carrier_required, carrier_available, profile["transport"])

    sources = manifests["application"].get("sources")
    if not isinstance(sources, list) or not sources:
        raise CompositionError("app.json sources must be a non-empty array")
    for source in sources:
        if not isinstance(source, str) or not source.endswith(".swift"):
            raise CompositionError(f"application source must be a Swift path: {source!r}")
        path = (axes["application"][0] / source).resolve()
        if not path.is_relative_to(axes["application"][0].resolve()) or not path.is_file():
            raise CompositionError(f"application source is missing or escapes its axis: {source}")
    listed = set(sources)
    discovered = {
        path.relative_to(axes["application"][0]).as_posix()
        for path in axes["application"][0].rglob("*.swift")
        if path.is_file()
    }
    if listed != discovered:
        missing = sorted(discovered - listed)
        stale = sorted(listed - discovered)
        detail = "; ".join(part for part in (
            f"unlisted Swift source: {', '.join(missing)}" if missing else "",
            f"missing listed source: {', '.join(stale)}" if stale else "",
        ) if part)
        raise CompositionError(f"app.json source inventory differs from the application tree ({detail})")

    print(
        f"composition valid: {profile['application']} × {profile['platform']} × {profile['transport']} "
        f"({len(platform_required)} platform, {len(carrier_required)} carrier requirements)"
    )
    return platform_required, carrier_required, capacities


def swift_requirements(
    repo_root: Path, profile_path: Path | None, app_manifest_path: Path | None, output: Path
) -> None:
    if app_manifest_path is None:
        if profile_path is None:
            raise CompositionError("--profile or --app-manifest is required")
        platform_names, carrier_names, capacities = validate(repo_root, profile_path)
    else:
        manifest = read_json(app_manifest_path)
        platform_names, carrier_names, capacities = app_requirements(manifest, app_manifest_path)
    platform_bits = abi_mask(repo_root / "Interop/axoloty_platform_v1.h", platform_names, PLATFORM)
    carrier_bits = abi_mask(repo_root / "Interop/axoloty_carrier_v1.h", carrier_names, CARRIER)
    platform_fields = field_mask(platform_names, PLATFORM)
    carrier_fields = field_mask(carrier_names, CARRIER)
    source = f'''// Generated by Tools/validate-composition.py. Do not edit.
// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

/// The selected application's manifest-derived ABI requirements and bounds.
public enum EmbeddedApplicationRequirements {{
    /// The single fixed requirement record selected for this image.
    public static let current = EmbeddedRequirements(
        platformCapabilities: {platform_bits},
        carrierCapabilities: {carrier_bits},
        platformFunctions: {platform_fields},
        carrierFunctions: {carrier_fields},
        maxTopicLength: {capacities['maxTopicLength']},
        maxPayloadSize: {capacities['maxPayloadSize']},
        applicationStateBytes: {capacities['applicationStateBytes']}
    )
}}
'''
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(source, encoding="utf-8", newline="\n")


def abi_mask(header: Path, names: set[str], catalog: dict[str, tuple[str, tuple[str, ...]]]) -> int:
    macros = {name: int(value, 0) for name, value in re.findall(
        r"^#define\s+(AXOLOTY_(?:PLATFORM|CARRIER)_CAP_[A-Z_]+)\s+UINT64_C\((0x[0-9A-Fa-f]+|[0-9]+)\)",
        header.read_text(encoding="utf-8"), re.MULTILINE
    )}
    mask = 0
    for name in names:
        macro, _ = catalog[name]
        if macro not in macros:
            raise CompositionError(f"{header} has no ABI bit definition for {name}: {macro}")
        mask |= macros[macro]
    return mask


def field_mask(names: set[str], catalog: dict[str, tuple[str, tuple[str, ...]]]) -> int:
    ordered_fields = ordered_function_fields(catalog)
    required = {field for name in names for field in catalog[name][1]}
    return sum(1 << index for index, field in enumerate(ordered_fields) if field in required)


def ordered_function_fields(catalog: dict[str, tuple[str, tuple[str, ...]]]) -> list[str]:
    return list(dict.fromkeys(field for _, fields in catalog.values() for field in fields))


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo-root", type=Path, required=True)
    parser.add_argument("--profile", type=Path)
    parser.add_argument("--app-manifest", type=Path)
    parser.add_argument("--emit-requirements", type=Path)
    arguments = parser.parse_args()
    try:
        if arguments.emit_requirements:
            swift_requirements(
                arguments.repo_root.resolve(),
                arguments.profile.resolve() if arguments.profile else None,
                arguments.app_manifest.resolve() if arguments.app_manifest else None,
                arguments.emit_requirements,
            )
        else:
            if arguments.profile is None:
                raise CompositionError("--profile is required unless --emit-requirements and --app-manifest are supplied")
            validate(arguments.repo_root.resolve(), arguments.profile.resolve())
    except CompositionError as error:
        print(f"composition error: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
