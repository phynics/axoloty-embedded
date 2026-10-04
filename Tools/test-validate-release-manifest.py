#!/usr/bin/env python3
# Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

"""Exercise release-manifest validation without requiring a firmware toolchain."""

import copy
import json
import subprocess
import sys
import tempfile
from pathlib import Path


ROOT = Path(__file__).resolve().parent.parent
VALIDATOR = ROOT / "Tools" / "validate-release-manifest.py"
LOCK = json.loads((ROOT / "axoloty-core.lock.json").read_text(encoding="utf-8"))["core"]
VERSION = "%s-embedded.9" % LOCK["version"]
IMAGE_SHA = "a" * 64
FIRMWARE_SHA = "b" * 40
ZENOH_REVISION = "96006957fddef401c20c8c2d813c2a630b666974"


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


def transport_block(transport):
    if transport == "zenoh-pico":
        return {
            "name": "zenoh-pico",
            "backend": "eclipse-zenoh/zenoh-pico",
            "component": "eclipse-zenoh/zenoh-pico",
            "version": "1.10.0",
            "revision": ZENOH_REVISION,
            "versionSource": "Platforms/esp32c6-idf/dependencies/zenoh-pico.lock.json",
        }
    return {
        "name": "mqtt-espidf",
        "backend": "esp-idf/mqtt",
        "component": "idf",
        "version": "5.4.0",
        "revision": None,
        "versionSource": "Platforms/esp32c6-idf/dependencies.lock",
    }


def manifest_document(lock, profile, transport):
    return {
        "schemaVersion": 1,
        "mode": "release",
        "profile": profile,
        "application": "device-smoke-agent",
        "platform": "esp32c6-idf",
        "board": "ESP32-C6-DevKitC-1",
        "transport": transport_block(transport),
        "compatibility": {"scope": "profile", "status": "qualified", "description": "fixture"},
        "axoloty": {
            "version": lock["version"],
            "tag": lock["tag"],
            "sha": lock["revision"],
            "dirty": False,
            "contractSha256": "c" * 64,
        },
        "embedded": {"version": VERSION, "sha": FIRMWARE_SHA, "dirty": False},
        "toolchain": {"swift": "Swift fixture", "sdk": "ESP-IDF fixture", "target": "esp32c6"},
        "configurationFingerprint": "d" * 64,
        "image": {"path": "axoloty-swift.bin", "sha256": IMAGE_SHA, "byteCount": 1},
        "resources": None,
        "qualification": {
            "status": "qualified",
            "evidence": [{
                "path": "docs/evidence/%s-smoke.json" % profile,
                "check": "smoke",
                "status": "passed",
                "coreRevision": lock["revision"],
                "firmwareSHA256": IMAGE_SHA,
            }],
        },
    }


def fixture(repo, profile, transport):
    lock = LOCK
    for axis, name in (("Applications", "device-smoke-agent"),
                       ("Platforms", "esp32c6-idf"),
                       ("Transports", transport)):
        (repo / axis / name).mkdir(parents=True, exist_ok=True)
    write_json(repo / "axoloty-core.lock.json", {"schemaVersion": 1, "core": lock})
    (repo / "VERSION").write_text(VERSION + "\n", encoding="utf-8")
    write_json(repo / "Profiles" / profile / "profile.json", {
        "name": profile,
        "application": "device-smoke-agent",
        "platform": "esp32c6-idf",
        "transport": transport,
        "board": "ESP32-C6-DevKitC-1",
    })
    (repo / "Platforms" / "esp32c6-idf" / "dependencies.lock").write_text(
        "  idf:\n    version: 5.4.0\n", encoding="utf-8")
    write_json(repo / "Platforms" / "esp32c6-idf" / "dependencies" / "zenoh-pico.lock.json", {
        "schemaVersion": 1,
        "component": "eclipse-zenoh/zenoh-pico",
        "version": "1.10.0",
        "tag": "1.10.0",
        "revision": ZENOH_REVISION,
    })
    evidence_path = repo / "docs" / "evidence" / ("%s-smoke.json" % profile)
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
    manifest_path = repo / "releases" / profile / (VERSION + ".json")
    write_json(manifest_path, manifest_document(lock, profile, transport))
    return manifest_path


def require(result, expected, message):
    if result.returncode != expected:
        raise SystemExit("%s\nstdout:\n%s\nstderr:\n%s" % (message, result.stdout, result.stderr))


def check_transport_mutations(repo, manifest, document, mutations, label):
    for mutate, message in mutations:
        mutated = copy.deepcopy(document)
        mutate(mutated)
        write_json(manifest, mutated)
        require(run(repo, manifest, "--require-qualified"), 1, message)
    write_json(manifest, document)
    require(run(repo, manifest, "--require-qualified"), 0,
            "%s: restoring the manifest did not revalidate" % label)


with tempfile.TemporaryDirectory() as temporary:
    base = Path(temporary)

    # --- MQTT: the existing device-evidence, revocation, and schema checks. ---
    repo = base / "mqtt-repository"
    manifest = fixture(repo, "esp32c6-mqtt", "mqtt-espidf")
    require(run(repo, manifest, "--require-qualified"), 0, "clean qualified manifest was rejected")
    relative = subprocess.run(
        [sys.executable, str(VALIDATOR), ".", str(manifest.relative_to(repo)), "--require-qualified"],
        cwd=repo,
        capture_output=True,
        text=True,
        check=False,
    )
    require(relative, 0, "relative repository root was rejected")
    # docs/evidence.md: a build record proves the artifact compiles, not that
    # the profile works. It must not satisfy a qualified manifest's device
    # evidence, even when its checksum and Core revision match exactly.
    evidence_record = repo / "docs" / "evidence" / "esp32c6-mqtt-smoke.json"
    build_record = json.loads(evidence_record.read_text(encoding="utf-8"))
    build_record["tier"] = "build"
    build_record["toolchain"] = "fixture toolchain"
    write_json(evidence_record, build_record)
    require(run(repo, manifest, "--require-qualified"), 1,
            "a build record was accepted as device qualification")
    build_record["tier"] = "device"
    build_record.pop("toolchain", None)
    write_json(evidence_record, build_record)
    require(run(repo, manifest, "--require-qualified"), 0,
            "restoring the device record did not re-qualify the manifest")
    document = json.loads(manifest.read_text(encoding="utf-8"))
    document["embedded"]["dirty"] = True
    write_json(manifest, document)
    require(run(repo, manifest, "--require-qualified"), 1, "dirty firmware manifest was accepted")
    # The MQTT backend version is the pinned ESP-IDF component, so the manifest
    # must not record a foreign library version or a commit the idf component
    # does not pin.
    document["embedded"]["dirty"] = False
    check_transport_mutations(repo, manifest, document, [
        (lambda d: d["transport"].__setitem__("version", "1.10.0"),
         "MQTT manifest accepted a Zenoh backend version"),
        (lambda d: d["transport"].__setitem__("backend", "eclipse-zenoh/zenoh-pico"),
         "MQTT manifest accepted a foreign backend identity"),
        (lambda d: d["transport"].__setitem__("backend", "esp-idf/not-mqtt"),
         "MQTT manifest accepted a non-canonical ESP-IDF backend identity"),
        (lambda d: d["transport"].__setitem__("revision", ZENOH_REVISION),
         "MQTT manifest accepted a backend revision the idf lock does not pin"),
        (lambda d: d["transport"].__setitem__("component", "zenoh-pico"),
         "MQTT manifest accepted a component the idf lock does not declare"),
        (lambda d: d["transport"].__setitem__(
            "versionSource", "Platforms/esp32c6-idf/dependencies/zenoh-pico.lock.json"),
         "MQTT manifest accepted a foreign version source"),
        (lambda d: d["transport"].__setitem__("versionSource", "../VERSION"),
         "MQTT manifest accepted a version source outside the platform"),
        (lambda d: d["transport"].pop("component"),
         "MQTT manifest omitted the pinned component"),
        (lambda d: d["transport"].pop("revision"),
         "MQTT manifest omitted the backend revision field"),
    ], "MQTT")
    document = json.loads(manifest.read_text(encoding="utf-8"))
    revocation = repo / "releases" / "revocations" / "esp32c6-mqtt" / (VERSION + ".json")
    write_json(revocation, {
        "schemaVersion": 1,
        "status": "revoked",
        "manifestPath": "releases/esp32c6-mqtt/%s.json" % VERSION,
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

    # --- Zenoh: its own lock decides identity, version, and revision. --------
    # The failure this guards against is the generator reading the idf entry
    # and certifying the Zenoh profile with the SDK version as its backend.
    zenoh_repo = base / "zenoh-repository"
    zenoh_manifest = fixture(zenoh_repo, "esp32c6-zenoh", "zenoh-pico")
    require(run(zenoh_repo, zenoh_manifest, "--require-qualified"), 0,
            "clean Zenoh manifest was rejected")
    zenoh_document = json.loads(zenoh_manifest.read_text(encoding="utf-8"))
    check_transport_mutations(zenoh_repo, zenoh_manifest, zenoh_document, [
        (lambda d: d["transport"].__setitem__("version", "5.4.0"),
         "Zenoh manifest accepted the SDK version as its backend version"),
        (lambda d: d["transport"].__setitem__("backend", "zenoh-pico"),
         "Zenoh manifest accepted a non-canonical backend identity"),
        (lambda d: d["transport"].__setitem__("revision", "f" * 40),
         "Zenoh manifest accepted a backend revision the lock does not pin"),
        (lambda d: d["transport"].__setitem__("revision", None),
         "Zenoh manifest dropped the pinned backend revision"),
        (lambda d: d["transport"].pop("component"),
         "Zenoh manifest omitted the pinned component"),
        (lambda d: d["transport"].__setitem__("versionSource", "Platforms/esp32c6-idf/dependencies.lock"),
         "Zenoh manifest cited the SDK dependency manifest"),
    ], "Zenoh")

print("release-manifest validator checks passed")
