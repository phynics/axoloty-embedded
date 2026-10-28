# Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.
"""Classify the selected ESP-IDF image and optional app storage policy."""

from __future__ import annotations

import argparse
import json
from pathlib import Path
import sys


class PolicyError(Exception):
    """The configured build or selected application policy is invalid."""


def unique_object(pairs: list[tuple[str, object]]) -> dict:
    value = {}
    for key, item in pairs:
        if key in value:
            raise PolicyError(f"duplicate JSON key {key!r}")
        value[key] = item
    return value


def read_object(path: Path, label: str) -> dict:
    try:
        value = json.loads(path.read_text(encoding="utf-8"), object_pairs_hook=unique_object)
    except (OSError, json.JSONDecodeError) as error:
        raise PolicyError(f"cannot read {label} {path}: {error}") from error
    if not isinstance(value, dict):
        raise PolicyError(f"{label} {path} must contain a JSON object")
    return value


def classify(cache_path: Path, manifest_path: Path, inventory_path: Path) -> str:
    """Return c-only, swift-not-configured, or swift-configured:<map member>."""
    try:
        cache_lines = cache_path.read_text(encoding="utf-8").splitlines()
    except OSError as error:
        raise PolicyError(f"cannot read configured CMake cache {cache_path}: {error}") from error
    key = "AXOLOTY_QUALIFICATION_CARRIER_SCENARIO:BOOL="
    values = [line[len(key):] for line in cache_lines if line.startswith(key)]
    if len(values) != 1 or values[0] not in ("ON", "OFF"):
        raise PolicyError("configured CMake cache must contain exactly one normalized "
                          "AXOLOTY_QUALIFICATION_CARRIER_SCENARIO BOOL")
    if values[0] == "ON":
        transport_prefix = "AXOLOTY_TRANSPORT_DIR:"
        transport_values = [line.split("=", 1)[1] for line in cache_lines
                            if line.startswith(transport_prefix) and "=" in line]
        if len(transport_values) != 1 or Path(transport_values[0]).name != "zenoh-pico":
            raise PolicyError("configured C-only carrier qualification image must select zenoh-pico")
        return "c-only"

    manifest = read_object(manifest_path, "selected app manifest")
    capacities = manifest.get("capacities")
    if not isinstance(capacities, dict):
        raise PolicyError(f"{manifest_path} capacities must be an object")
    field = "applicationStaticStorageBytes"
    if field not in capacities:
        return "swift-not-configured"
    ceiling = capacities[field]
    if not isinstance(ceiling, int) or isinstance(ceiling, bool) or not 0 < ceiling <= 0xFFFFFFFF:
        raise PolicyError(f"{manifest_path} capacities.{field} must be a positive UInt32")

    inventory = read_object(inventory_path, "selected app storage inventory")
    app_name = manifest.get("name")
    if (inventory.get("schemaVersion") != 1 or inventory.get("app") != app_name
            or not isinstance(app_name, str) or not app_name):
        raise PolicyError(f"{inventory_path} must be schemaVersion 1 for selected app {app_name!r}")
    member = inventory.get("expectedMapMember")
    if (not isinstance(member, str) or not member or "/" in member or "\\" in member
            or Path(member).name != member or not member.endswith((".o", ".obj"))):
        raise PolicyError(f"{inventory_path} must declare an SDK-neutral expectedMapMember .o or .obj basename")
    return f"swift-configured:{member}"


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--cache", type=Path, required=True)
    parser.add_argument("--app-manifest", type=Path, required=True)
    parser.add_argument("--inventory", type=Path, required=True)
    args = parser.parse_args(argv)
    try:
        print(classify(args.cache, args.app_manifest, args.inventory))
        return 0
    except PolicyError as error:
        print(f"static-storage policy: {error}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
