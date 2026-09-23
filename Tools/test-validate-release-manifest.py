#!/usr/bin/env python3
# Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

"""Exercise release-manifest validation without requiring a firmware toolchain."""

import json
import subprocess
import sys
import tempfile
from pathlib import Path


ROOT = Path(__file__).resolve().parent.parent
VALIDATOR = ROOT / "Tools" / "validate-release-manifest.py"
IMAGE_SHA = "a" * 64
FIRMWARE_SHA = "b" * 40


def write_json(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, indent=2) + "\n", encoding="utf-8")


def run(repo, manifest, *options):
    return subprocess.run(
        [sys.executable, str(VALIDATOR), str(repo), str(manifest), *options],
        capture_output=True,
        text=True,
        check=False,
    )


def fixture(repo):
    lock = json.loads((ROOT / "axoloty-core.lock.json").read_text(encoding="utf-8"))["core"]
    profile = "esp32c6-mqtt"
    for axis, name in (("Applications", "device-smoke-agent"), ("Platforms", "esp32c6-idf"), ("Transports", "mqtt-espidf")):
        (repo / axis / name).mkdir(parents=True)
    write_json(repo / "axoloty-core.lock.json", {"schemaVersion": 1, "core": lock})
    (repo / "VERSION").write_text("0.8.2-embedded.9\n", encoding="utf-8")
    write_json(repo / "Profiles" / profile / "profile.json", {
        "name": profile,
        "application": "device-smoke-agent",
        "platform": "esp32c6-idf",
        "transport": "mqtt-espidf",
        "board": "ESP32-C6-DevKitC-1",
    })
    (repo / "Platforms" / "esp32c6-idf" / "dependencies.lock").write_text("  idf:\n    version: 5.4.0\n", encoding="utf-8")
    evidence_path = repo / "docs" / "evidence" / "esp32c6-mqtt-smoke.json"
    write_json(evidence_path, {
        "schemaVersion": 1,
        "profile": profile,
        "check": "smoke",
        "tier": "device",
        "status": "passed",
        "recordedAt": "2026-09-22",
        "device": "ESP32-C6 fixture",
        "firmwareSHA256": IMAGE_SHA,
        "coreRevision": lock["revision"],
        "protocol": "fixture",
        "result": "passed",
    })
    manifest_path = repo / "releases" / profile / "0.8.2-embedded.9.json"
    write_json(manifest_path, {
        "schemaVersion": 1,
        "mode": "release",
        "profile": profile,
        "application": "device-smoke-agent",
        "platform": "esp32c6-idf",
        "board": "ESP32-C6-DevKitC-1",
        "transport": {
            "name": "mqtt-espidf",
            "backend": "esp-idf/mqtt",
            "version": "5.4.0",
            "versionSource": "Platforms/esp32c6-idf/dependencies.lock",
        },
        "compatibility": {"scope": "profile", "status": "qualified", "description": "fixture"},
        "axoloty": {
            "version": lock["version"],
            "tag": lock["tag"],
            "sha": lock["revision"],
            "dirty": False,
            "contractSha256": "c" * 64,
        },
        "embedded": {"version": "0.8.2-embedded.9", "sha": FIRMWARE_SHA, "dirty": False},
        "toolchain": {"swift": "Swift fixture", "sdk": "ESP-IDF fixture", "target": "esp32c6"},
        "configurationFingerprint": "d" * 64,
        "image": {"path": "axoloty-swift.bin", "sha256": IMAGE_SHA, "byteCount": 1},
        "resources": None,
        "qualification": {
            "status": "qualified",
            "evidence": [{
                "path": "docs/evidence/esp32c6-mqtt-smoke.json",
                "check": "smoke",
                "status": "passed",
                "coreRevision": lock["revision"],
                "firmwareSHA256": IMAGE_SHA,
            }],
        },
    })
    return manifest_path


def require(result, expected, message):
    if result.returncode != expected:
        raise SystemExit("%s\nstdout:\n%s\nstderr:\n%s" % (message, result.stdout, result.stderr))


with tempfile.TemporaryDirectory() as temporary:
    repo = Path(temporary) / "repository"
    manifest = fixture(repo)
    require(run(repo, manifest, "--require-qualified"), 0, "clean qualified manifest was rejected")
    relative = subprocess.run(
        [sys.executable, str(VALIDATOR), ".", str(manifest.relative_to(repo)), "--require-qualified"],
        cwd=repo,
        capture_output=True,
        text=True,
        check=False,
    )
    require(relative, 0, "relative repository root was rejected")
    document = json.loads(manifest.read_text(encoding="utf-8"))
    document["embedded"]["dirty"] = True
    write_json(manifest, document)
    require(run(repo, manifest, "--require-qualified"), 1, "dirty firmware manifest was accepted")
    revocation = repo / "releases" / "revocations" / "esp32c6-mqtt" / "0.8.2-embedded.9.json"
    write_json(revocation, {
        "schemaVersion": 1,
        "status": "revoked",
        "manifestPath": "releases/esp32c6-mqtt/0.8.2-embedded.9.json",
        "reason": "fixture revocation",
    })
    require(run(repo, manifest, "--require-qualified"), 1, "revoked certificate was accepted")
    allowed = run(repo, manifest, "--require-qualified", "--allow-revoked")
    require(allowed, 0, "tracked revocation was rejected")
    if not allowed.stdout.startswith("revoked  [release-manifest]"):
        raise SystemExit("revoked certificate did not report its status")
    document["embedded"]["sha"] = "not-a-commit"
    write_json(manifest, document)
    require(run(repo, manifest, "--require-qualified", "--allow-revoked"), 0, "valid revocation did not quarantine the historical certificate")
    revocation_record = json.loads(revocation.read_text(encoding="utf-8"))
    revocation_record["manifestPath"] = "releases/another-profile/other.json"
    write_json(revocation, revocation_record)
    require(run(repo, manifest, "--require-qualified", "--allow-revoked"), 1, "invalid revocation record was accepted")

print("release-manifest validator checks passed")
