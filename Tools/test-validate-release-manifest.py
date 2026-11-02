#!/usr/bin/env python3
# Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

"""Exercise release-manifest validation without requiring a firmware toolchain."""

import copy
import json
import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path


ROOT = Path(__file__).resolve().parent.parent
VALIDATOR = ROOT / "Tools" / "validate-release-manifest.py"
REPOSITORY_LOCK = json.loads((ROOT / "axoloty-core.lock.json").read_text(encoding="utf-8"))["core"]
# Release certificates require a tagged lock. The fixture names a tag even when
# the repository lock is between releases.
LOCK = {**REPOSITORY_LOCK, "tag": REPOSITORY_LOCK.get("tag") or "v" + REPOSITORY_LOCK["version"]}
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
                "tier": "device",
                "coreRevision": lock["revision"],
                "firmwareSHA256": IMAGE_SHA,
                "firmwareRevision": FIRMWARE_SHA,
                "device": "ESP32-C6 fixture",
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
        "firmwareRevision": FIRMWARE_SHA,
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
    untagged_lock = {**LOCK, "tag": None}
    write_json(repo / "axoloty-core.lock.json", {"schemaVersion": 1, "core": untagged_lock})
    document = json.loads(manifest.read_text(encoding="utf-8"))
    document["axoloty"]["tag"] = None
    write_json(manifest, document)
    require(run(repo, manifest, "--require-qualified"), 1, "a certificate against an untagged lock was accepted")
    write_json(repo / "axoloty-core.lock.json", {"schemaVersion": 1, "core": LOCK})
    document["axoloty"]["tag"] = LOCK["tag"]
    write_json(manifest, document)
    require(run(repo, manifest, "--require-qualified"), 0, "restoring the tagged lock did not re-qualify the manifest")
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
    # A build-size report is evidence about this image: a failed budget or a
    # report for another image's byte count must not ride into a certificate.
    original = json.loads(manifest.read_text(encoding="utf-8"))
    if shutil.which("node"):
        # Invoke the real writer with a hermetic size tool, then validate its report.
        writer = ROOT / "Platforms/esp32c6-idf/tools/write-size-report.mjs"
        binary = base / "firmware.bin"
        binary.write_bytes(b"x")
        import hashlib
        actual_sha = hashlib.sha256(b"x").hexdigest()
        original["image"]["sha256"] = actual_sha
        original["qualification"]["evidence"][0]["firmwareSHA256"] = actual_sha
        evidence = repo / "docs/evidence/esp32c6-mqtt-smoke.json"
        evidence_doc = json.loads(evidence.read_text())
        evidence_doc["firmwareSHA256"] = actual_sha
        write_json(evidence, evidence_doc)
        profile_path = repo / "Profiles/esp32c6-mqtt/profile.json"
        profile_doc = json.loads(profile_path.read_text())
        profile_doc["budgets"] = {"basis": "fixture", "build": {"imageBytes": 2}}
        write_json(profile_path, profile_doc)
        policy_path, prep_path, output = base / "policy.json", base / "prep.json", base / "size.json"
        write_json(policy_path, {"schema": "axoloty.app-static-storage-policy.v1", "profile": "esp32c6-mqtt", "status": "enforced"})
        write_json(prep_path, {"schemaVersion": 1, "status": "prepared", "core": {"sha": LOCK["revision"]}})
        sdkconfig_path = base / "sdkconfig"
        sdkconfig_path.write_text('CONFIG_IDF_TARGET="esp32c6"\n')
        size_tool = base / "size-tool"
        size_tool.write_text("#!/bin/sh\nprintf 'section size addr\n.iram0.text 1 1\n.dram0.data 1 1\n.dram0.bss 1 1\n.flash.text 1 1\n.flash.rodata 1 1\nTotal 5\n'\n")
        size_tool.chmod(0o755)
        partition = base / "partitions.csv"
        partition.write_text("factory,app,factory,0,100,\n")
        subprocess.run(["node", str(writer), str(binary), str(binary), str(partition), str(profile_path), str(policy_path), str(prep_path), str(sdkconfig_path), "configured", str(output), str(size_tool)], check=True, capture_output=True)
        # Failed runs clear stale output, but never delete an input through an alias.
        bad_policy = base / "bad-policy.json"
        write_json(bad_policy, {"status": "not-applicable"})
        command = ["node", str(writer), str(binary), str(binary), str(partition), str(profile_path), str(bad_policy), str(prep_path), str(sdkconfig_path), "configured", str(output), str(size_tool)]
        assert subprocess.run(command, capture_output=True).returncode != 0 and not output.exists()
        subprocess.run(["node", str(writer), str(binary), str(binary), str(partition), str(profile_path), str(policy_path), str(prep_path), str(sdkconfig_path), "configured", str(output), str(size_tool)], check=True, capture_output=True)
        alias = base / "alias"
        os_link = __import__("os").link
        os_link(binary, alias)
        alias_command = command.copy()
        alias_command[10] = str(alias)
        assert subprocess.run(alias_command, capture_output=True).returncode != 0
        assert binary.read_bytes() == b"x" and alias.read_bytes() == b"x"
        # Exercise the manifest writer on the report at the artifact's real path.
        profile_doc["qualification"] = {"requiredChecks": [{"check": "smoke", "artifact": "release", "records": 1, "units": 1}]}
        write_json(profile_path, profile_doc)
        preparation = {"schemaVersion": 1, "status": "prepared", "core": {"sha": LOCK["revision"], "dirty": False}, "contractSHA256": "c" * 64}
        write_json(prep_path, preparation)
        provenance = base / "provenance.json"
        write_json(provenance, {"schemaVersion": 1, "status": "passed", "core": {"sha": LOCK["revision"], "dirty": False}, "firmware": {"revision": FIRMWARE_SHA, "dirty": False}, "artifact": {"path": str(binary), "sha256": actual_sha, "byteCount": 1}, "toolchain": {"swift": "fixture", "espIdf": "fixture", "target": "esp32c6"}})
        generator = ROOT / "Platforms/esp32c6-idf/tools/write-release-manifest.mjs"
        generated = base / "generated.json"
        generate = ["node", str(generator), str(repo), str(profile_path), str(repo / "axoloty-core.lock.json"), str(repo / "VERSION"), str(prep_path), str(provenance), str(generated)]
        subprocess.run(generate, check=True, capture_output=True)
        require(run(repo, generated, "--require-qualified"), 0, "writer to manifest validation failed")
        # A preview uses the prepared revision, even when the profile names the lock.
        preview_sha = "f" * 40
        profile_doc["core"] = {"revision": LOCK["revision"]}
        write_json(profile_path, profile_doc)
        preparation["core"]["sha"] = preview_sha
        write_json(prep_path, preparation)
        subprocess.run(["node", str(writer), str(binary), str(binary), str(partition), str(profile_path), str(policy_path), str(prep_path), str(sdkconfig_path), "configured", str(output), str(size_tool)], check=True, capture_output=True)
        preview_report = json.loads(output.read_text())
        assert preview_report["coreRevision"] == preview_sha
        provenance_doc = json.loads(provenance.read_text())
        provenance_doc["core"]["sha"] = preview_sha
        write_json(provenance, provenance_doc)
        subprocess.run(generate, check=True, capture_output=True, env={**os.environ, "AXOLOTY_PREVIEW_CORE_REVISION": preview_sha})
        require(run(repo, generated), 0, "preview report did not bind to actual Core")
        generated_doc = json.loads(generated.read_text())
        generated_doc["resources"]["report"]["coreRevision"] = LOCK["revision"]
        write_json(generated, generated_doc)
        require(run(repo, generated), 1, "preview accepted the declared lock instead of actual Core")
        preparation["core"]["sha"] = LOCK["revision"]
        write_json(prep_path, preparation)
        subprocess.run(["node", str(writer), str(binary), str(binary), str(partition), str(profile_path), str(policy_path), str(prep_path), str(sdkconfig_path), "configured", str(output), str(size_tool)], check=True, capture_output=True)
        valid_report = json.loads(output.read_text())
        original["schemaVersion"] = 2
        original["qualification"]["requiredChecks"] = profile_doc["qualification"]["requiredChecks"]
        with_report = copy.deepcopy(original)
        with_report["resources"] = {"available": True, "report": valid_report}
        write_json(manifest, with_report)
        require(run(repo, manifest, "--require-qualified"), 0, "real size report rejected")
        # The network-configured variant of a smoke profile (#136): the real writer
        # reports it as not-applicable, and the validator accepts that only on an
        # unqualified manifest of a profile whose budgets declare networkStack false.
        net_profile = copy.deepcopy(profile_doc)
        net_profile["budgets"]["networkStack"] = False
        write_json(profile_path, net_profile)

        def variant_report_for(state):
            subprocess.run(["node", str(writer), str(binary), str(binary), str(partition), str(profile_path), str(policy_path), str(prep_path), str(sdkconfig_path), state, str(output), str(size_tool)], check=True, capture_output=True)
            return json.loads(output.read_text())

        def variant_manifest(report, status="unqualified"):
            document = copy.deepcopy(original)
            document["resources"] = {"available": True, "report": report}
            document["qualification"]["status"] = status
            document["compatibility"]["status"] = status
            return document

        for state in ("configured", "placeholder"):
            net_report = variant_report_for(state)
            assert net_report["enforcement"]["status"] == "not-applicable", state
            assert net_report["configuration"]["networkConfigured"] is True
            write_json(manifest, variant_manifest(net_report))
            require(run(repo, manifest), 0, "writer's network variant report rejected (%s)" % state)
            # Never usable on a certified release image.
            require(run(repo, manifest, "--require-qualified"), 1, "network variant accepted as a published release")
            write_json(manifest, variant_manifest(net_report, "qualified"))
            require(run(repo, manifest), 1, "network variant accepted on a qualified manifest")
        net_report = variant_report_for("configured")
        tampered = copy.deepcopy(net_report)
        tampered["configuration"]["networkConfigured"] = False
        write_json(manifest, variant_manifest(tampered))
        require(run(repo, manifest), 1, "network variant accepted for an image without a network stack")
        tampered = copy.deepcopy(net_report)
        tampered["enforcement"]["reason"] = "some other reason"
        write_json(manifest, variant_manifest(tampered))
        require(run(repo, manifest), 1, "unknown not-applicable reason accepted")
        # A profile whose budgets do not exclude the network stack cannot use it.
        write_json(profile_path, profile_doc)
        write_json(manifest, variant_manifest(net_report))
        require(run(repo, manifest), 1, "network variant accepted for a profile that budgets the networked image")
        write_json(profile_path, net_profile)
        require(run(repo, manifest), 0, "network variant rejected after restoring the profile flag")
        write_json(profile_path, profile_doc)
        subprocess.run(["node", str(writer), str(binary), str(binary), str(partition), str(profile_path), str(policy_path), str(prep_path), str(sdkconfig_path), "configured", str(output), str(size_tool)], check=True, capture_output=True)
        write_json(manifest, with_report)
        mutations = [
            lambda r: r.update(kind="typo"),
            lambda r: r.update(schemaVersion=2),
            lambda r: r.update(profile="foreign"),
            lambda r: r.update(application="foreign"),
            lambda r: r.update(platform="foreign"),
            lambda r: r.update(transport="foreign"),
            lambda r: r.update(coreRevision="f" * 40),
            lambda r: r["image"].update(sha256=hashlib.sha256(b"y").hexdigest()),
            lambda r: r["image"].update(bytes=2),
            lambda r: r["enforcement"].update(status="failed"),
            lambda r: r["enforcement"]["results"][0].update(passed=False),
            lambda r: r["enforcement"].update(results=[]),
            lambda r: r["metrics"].update(imageBytes=True),
            lambda r: r.pop("configuration"),
            lambda r: r["configuration"].update(name="production"),
            lambda r: r["configuration"].update(sdkconfigSha256="z"),
            lambda r: r["configuration"].update(networkConfigured="yes"),
            lambda r: r["configuration"].update(networkPlaceholder=True, networkConfigured=False),
            lambda r: r["configuration"].update(networkPlaceholder=False),
            lambda r: r["configuration"].update(extra=1),
            lambda r: r.update(enforcement={"status": "not-configured", "reason": "the profile declares no build budgets"}, budgets=None),
        ]
        for mutate in mutations:
            changed = copy.deepcopy(with_report)
            mutate(changed["resources"]["report"])
            write_json(manifest, changed)
            require(run(repo, manifest, "--require-qualified"), 1, "malformed or foreign size report accepted")
        variant = copy.deepcopy(with_report)
        variant["resources"]["report"].update(budgets=None, enforcement={"status": "not-applicable", "reason": "configured C-only carrier qualification image"})
        write_json(manifest, variant)
        require(run(repo, manifest, "--require-qualified"), 1, "qualified MQTT C-only report accepted")
        # A Zenoh C-only scenario is a variant, never the qualified release artifact.
        validator = __import__("importlib.util").util.spec_from_file_location("validator", ROOT / "Tools/validate-release-manifest.py")
        module = __import__("importlib.util").util.module_from_spec(validator)
        validator.loader.exec_module(module)
        variant_profile = copy.deepcopy(profile_doc)
        variant_profile["transport"] = "zenoh-pico"
        variant_profile["qualification"] = {"requiredChecks": [{"check": "c-only-carrier-scenario", "artifact": "variant"}]}
        variant["transport"]["name"] = "zenoh-pico"
        variant["resources"]["report"]["transport"] = "zenoh-pico"
        variant["qualification"]["status"] = "unqualified"
        assert module.validate_size_report(variant["resources"]["report"], variant, variant_profile) == []
        variant["qualification"]["status"] = "qualified"
        assert module.validate_size_report(variant["resources"]["report"], variant, variant_profile)
        # A placeholder-built report is valid and says so; runtime budgets are declared floors.
        placeholder_doc = copy.deepcopy(with_report)
        placeholder_doc["resources"]["report"]["configuration"].update(networkPlaceholder=True)
        assert module.validate_size_report(placeholder_doc["resources"]["report"], placeholder_doc, profile_doc) == []
        runtime_profile = copy.deepcopy(profile_doc)
        runtime_profile["budgets"]["runtime"] = {"minimumFreeHeapBytes": 242000, "stackRemainingBytes": 2000}
        assert module.validate_size_report(with_report["resources"]["report"], with_report, runtime_profile) == []
        for bad_runtime in ({}, {"minimumFreeHeap": 1}, {"stackRemainingBytes": 0}, {"stackRemainingBytes": "5"}, []):
            runtime_profile["budgets"]["runtime"] = bad_runtime
            assert module.validate_size_report(with_report["resources"]["report"], with_report, runtime_profile)
        corrupt = copy.deepcopy(with_report)
        corrupt["resources"]["report"]["metrics"]["staticRamBytes"] = 0
        write_json(manifest, corrupt)
        require(run(repo, manifest, "--require-qualified"), 1, "inconsistent static RAM accepted")
        overflow = copy.deepcopy(with_report)
        overflow["resources"]["report"]["metrics"].update(iramTextBytes=9007199254740991, initializedDataBytes=1, dramBssBytes=1, staticRamBytes=9007199254740991)
        write_json(manifest, overflow)
        require(run(repo, manifest, "--require-qualified"), 1, "overflowing static RAM sum accepted")
        profile_doc["budgets"] = {"basis": "fixture", "buid": {"imageBytes": 2}}
        write_json(profile_path, profile_doc)
        corrupt = copy.deepcopy(with_report)
        corrupt["resources"]["report"].update(budgets=None, enforcement={"status": "not-configured", "reason": "the profile declares no build budgets"})
        write_json(manifest, corrupt)
        require(run(repo, manifest, "--require-qualified"), 1, "unknown outer budget key accepted")
        command[6] = str(policy_path)
        assert subprocess.run(command, capture_output=True).returncode != 0 and not output.exists()
        profile_doc.pop("budgets")
        write_json(profile_path, profile_doc)
        original["image"]["sha256"] = IMAGE_SHA
        original["qualification"]["evidence"][0]["firmwareSHA256"] = IMAGE_SHA
        evidence_doc["firmwareSHA256"] = IMAGE_SHA
        write_json(evidence, evidence_doc)
    else:
        print("SKIP: size report integration requires node")
    write_json(manifest, original)
    # A profile that declares budgets.build cannot release without a size
    # report, unless the release is a named pre-report certificate.
    budget_profile_path = repo / "Profiles/esp32c6-mqtt/profile.json"
    budget_profile = json.loads(budget_profile_path.read_text())
    budget_profile["budgets"] = {"basis": "fixture", "build": {"imageBytes": 2}}
    write_json(budget_profile_path, budget_profile)
    result = run(repo, manifest, "--require-qualified")
    require(result, 1, "null resources with declared budgets accepted for a new version")
    assert "must carry a size report" in result.stderr + result.stdout, result.stderr
    grandfathered_spec = __import__("importlib.util").util.spec_from_file_location("gf", VALIDATOR)
    grandfathered = __import__("importlib.util").util.module_from_spec(grandfathered_spec)
    grandfathered_spec.loader.exec_module(grandfathered)
    assert grandfathered.SIZE_REPORT_GRANDFATHERED == {
        "esp32c6-mqtt/0.8.2-embedded.2", "esp32c6-mqtt/0.10.0-embedded.2",
        "esp32c6-zenoh/0.10.0-embedded.1", "esp32c6-zenoh/0.10.0-embedded.2",
    }
    old_manifest = repo / "releases" / "esp32c6-mqtt" / ("%s-embedded.2.json" % LOCK["version"])
    old_document = copy.deepcopy(original)
    old_document["embedded"]["version"] = "0.10.0-embedded.2"
    old_repo_version = (repo / "VERSION").read_text()
    (repo / "VERSION").write_text("0.10.0-embedded.2\n")
    write_json(old_manifest, old_document)
    old_result = run(repo, old_manifest, "--require-qualified")
    require(old_result, 0, "a grandfathered pre-report certificate was rejected")
    (repo / "VERSION").write_text(old_repo_version)
    old_manifest.unlink()
    budget_profile.pop("budgets")
    write_json(budget_profile_path, budget_profile)
    require(run(repo, manifest, "--require-qualified"), 0, "null resources without declared budgets rejected")
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
    # Schema 2: a qualified manifest must satisfy every check it requires, so a
    # hand-edited status cannot cite one passed record for the whole profile.
    document = json.loads(manifest.read_text(encoding="utf-8"))
    schema_two = copy.deepcopy(document)
    schema_two["schemaVersion"] = 2
    schema_two["qualification"]["requiredChecks"] = [{"check": "smoke", "artifact": "release", "records": 1, "units": 1}]
    write_json(manifest, schema_two)
    require(run(repo, manifest, "--require-qualified"), 0, "a complete schema 2 manifest was rejected")
    for label, requirement in (
            ("a missing required check", {"check": "router-restart", "artifact": "variant", "records": 1, "units": 1}),
            ("too few records", {"check": "smoke", "artifact": "release", "records": 2, "units": 1}),
            ("too few units", {"check": "smoke", "artifact": "release", "records": 1, "units": 2})):
        incomplete = copy.deepcopy(schema_two)
        incomplete["qualification"]["requiredChecks"] = [requirement]
        write_json(manifest, incomplete)
        require(run(repo, manifest, "--require-qualified"), 1, "a qualified manifest accepted %s" % label)
    no_requirements = copy.deepcopy(schema_two)
    no_requirements["qualification"].pop("requiredChecks")
    write_json(manifest, no_requirements)
    require(run(repo, manifest, "--require-qualified"), 1, "a schema 2 manifest with no required checks was accepted")
    write_json(manifest, document)
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

    # --- docs/evidence decides, and a requalification can satisfy the rules. ---
    # A dry run of what #73 will do, for both certified profiles with their real
    # required checks: every record is written by the real evidence writer from one
    # firmware revision, the real generator computes the manifest, and the
    # validator accepts it. Then each way of keeping an old pass alive is refused.
    if shutil.which("node"):
        import hashlib
        WRITER = ROOT / "Tests/embedded/write-device-evidence.mjs"
        RECORD_WRITER = ROOT / "Tests/embedded/evidence-record.mjs"
        GENERATOR = ROOT / "Platforms/esp32c6-idf/tools/write-release-manifest.mjs"
        REVISION = "c" * 40
        OLD_REVISION = "d" * 40

        def write_record(repo, profile, check, name, status, image, revision, device):
            """Writes one record through the real writers, as a device runner would."""
            script = """
const { deviceEvidenceRecord } = await import(process.env.DRY_WRITER);
const { writeEvidenceRecord } = await import(process.env.DRY_RECORD_WRITER);
const { output, profile, check, status, image, revision, device, core } = JSON.parse(process.env.DRY_SPEC);
const proof = { result: "passed", smoke: { validation: { passed: true, counts: { passed: 1 } } },
                firmwareSha256: image, firmwareRevision: revision, coreSha: core };
const record = deviceEvidenceRecord(proof, { device }, { profile, check, cases: "fixture cases" });
record.status = status;
writeEvidenceRecord(record, output, { withheldDir: output + ".withheld" });
"""
            output = repo / "docs" / "evidence" / ("%s-%s-%s.json" % (profile, check, name))
            output.parent.mkdir(parents=True, exist_ok=True)
            subprocess.run(["node", "--input-type=module", "-e", script], env={**os.environ,
                "DRY_WRITER": str(WRITER), "DRY_RECORD_WRITER": str(RECORD_WRITER), "DRY_SPEC": json.dumps({
                    "output": str(output), "profile": profile, "check": check, "status": status, "image": image,
                    "revision": revision, "device": device, "core": LOCK["revision"]})},
                check=True, capture_output=True, text=True)
            return output

        for profile, transport in (("esp32c6-mqtt", "mqtt-espidf"), ("esp32c6-zenoh", "zenoh-pico")):
            dry = base / ("dry-run-" + profile)
            published = fixture(dry, profile, transport)
            published.unlink()
            shutil.rmtree(dry / "docs" / "evidence")
            required_checks = json.loads((ROOT / "Profiles" / profile / "profile.json").read_text(encoding="utf-8"))["qualification"]["requiredChecks"]
            profile_path = dry / "Profiles" / profile / "profile.json"
            dry_profile = json.loads(profile_path.read_text(encoding="utf-8"))
            dry_profile["qualification"] = {"requiredChecks": required_checks}
            write_json(profile_path, dry_profile)
            artifact = base / (profile + ".bin")
            artifact.write_bytes(profile.encode())
            image = hashlib.sha256(profile.encode()).hexdigest()
            preparation_path = base / (profile + "-preparation.json")
            write_json(preparation_path, {"schemaVersion": 1, "status": "prepared", "core": {"sha": LOCK["revision"], "dirty": False}, "contractSHA256": "c" * 64})
            provenance_path = base / (profile + "-provenance.json")
            write_json(provenance_path, {"schemaVersion": 1, "status": "passed", "core": {"sha": LOCK["revision"], "dirty": False},
                                         "firmware": {"revision": REVISION, "dirty": False},
                                         "artifact": {"path": str(artifact), "sha256": image, "byteCount": len(profile)},
                                         "toolchain": {"swift": "fixture", "espIdf": "fixture", "target": "esp32c6"}})
            candidate = base / (profile + "-candidate.json")
            environment = {key: value for key, value in os.environ.items() if key != "AXOLOTY_PREVIEW_CORE_REVISION"}

            def generate_candidate():
                subprocess.run(["node", str(GENERATOR), str(dry), str(profile_path), str(dry / "axoloty-core.lock.json"), str(dry / "VERSION"),
                                str(preparation_path), str(provenance_path), str(candidate)], check=True, capture_output=True, env=environment)
                return json.loads(candidate.read_text(encoding="utf-8"))

            variants = []
            for required in required_checks:
                for index in range(required["records"]):
                    record_image = image if required["artifact"] == "release" else hashlib.sha256(("%s%d" % (required["check"], index)).encode()).hexdigest()
                    device = "unit-%d" % (index % required["units"])
                    path = write_record(dry, profile, required["check"], str(index), "passed", record_image, REVISION, device)
                    if required["artifact"] == "variant":
                        variants.append((required["check"], str(index), record_image, device, path))
            qualified = generate_candidate()
            if qualified["qualification"]["status"] != "qualified":
                raise SystemExit("%s dry run: the generator did not qualify: %s" % (profile, qualified["qualification"]["outstanding"]))
            if qualified["embedded"]["sha"] != REVISION:
                raise SystemExit("%s dry run: the certificate does not name the build's revision" % profile)
            require(run(dry, candidate, "--require-qualified"), 0, "%s dry run: the validator refused the generated certificate" % profile)
            published.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy(candidate, published)
            require(run(dry, published, "--require-qualified"), 0, "%s dry run: the published certificate did not validate" % profile)

            check, name, variant_image, device, variant_path = variants[0]
            fresh = variant_path.read_text(encoding="utf-8")

            def expect_refused(document, message, reason):
                write_json(published, document)
                result = run(dry, published, "--require-qualified")
                require(result, 1, "%s: %s" % (profile, message))
                if reason not in result.stderr:
                    raise SystemExit("%s: %s: expected %r in:\n%s" % (profile, message, reason, result.stderr))
                write_json(published, qualified)

            # A failure beside the pass that the manifest leaves out (#134 follow-up).
            sidecar = write_record(dry, profile, check, name, "failed", variant_image, REVISION, device)
            sidecar = variant_path.with_name(variant_path.stem + ".failed.json")
            if not sidecar.exists():
                raise SystemExit("%s: the writer did not carry the failure beside the pass" % profile)
            expect_refused(qualified, "a manifest omitting a failure sidecar validated", "is a failed record of this profile and the manifest does not cite it")
            # Citing the sidecar does not help: the check has a failed record.
            citing = copy.deepcopy(qualified)
            citing["qualification"]["evidence"].append({
                "path": "docs/evidence/" + sidecar.name, "check": check, "tier": "device", "status": "failed",
                "coreRevision": LOCK["revision"], "firmwareSHA256": variant_image, "firmwareRevision": REVISION, "device": device})
            expect_refused(citing, "a manifest citing a failure sidecar validated", "has a record that did not pass for this build")
            # Restating the failure as a pass is caught against the record.
            restated = copy.deepcopy(citing)
            restated["qualification"]["evidence"][-1]["status"] = "passed"
            expect_refused(restated, "a manifest restating a failure as a pass validated", "cites status 'passed', but the record says 'failed'")
            sidecar.unlink()
            # A record the manifest leaves out, and one it invents.
            required_only = copy.deepcopy(qualified)
            required_only["qualification"]["evidence"] = [e for e in required_only["qualification"]["evidence"] if e["path"] != "docs/evidence/" + variant_path.name]
            expect_refused(required_only, "a manifest omitting a required record validated", "the manifest does not cite it")
            invented = copy.deepcopy(qualified)
            invented["qualification"]["evidence"].append(dict(invented["qualification"]["evidence"][0], path="docs/evidence/%s-absent.json" % profile))
            expect_refused(invented, "a manifest citing an absent record validated", "is not a record of this profile")
            # A cited value that is not what the record says.
            altered = copy.deepcopy(qualified)
            altered["qualification"]["evidence"][0]["device"] = "another unit"
            expect_refused(altered, "a manifest misquoting a record validated", "cites device")
            # A smaller check list, or the older schema that had none.
            fewer = copy.deepcopy(qualified)
            fewer["qualification"]["requiredChecks"] = fewer["qualification"]["requiredChecks"][:1]
            expect_refused(fewer, "a manifest dropping required checks validated", "does not match the profile")
            older = copy.deepcopy(qualified)
            older["schemaVersion"] = 1
            expect_refused(older, "a schema 1 manifest skipped the required checks", "must be schema 2")

            # The never-rerun case: a variant pass from older firmware, with the
            # right Core and a valid checksum. The generator and the validator both
            # refuse, and the message says what to do.
            old_pass = json.loads(fresh)
            old_pass["firmwareRevision"] = OLD_REVISION
            write_json(variant_path, old_pass)
            blocked = generate_candidate()
            if blocked["qualification"]["status"] != "unqualified" or not any("rerun it at this revision" in item for item in blocked["qualification"]["outstanding"]):
                raise SystemExit("%s: the generator qualified a variant from older firmware" % profile)
            stale = copy.deepcopy(qualified)
            for entry in stale["qualification"]["evidence"]:
                if entry["path"] == "docs/evidence/" + variant_path.name:
                    entry["firmwareRevision"] = OLD_REVISION
            expect_refused(stale, "a variant pass from older firmware validated", "rerun it at this revision")
            # A record that names no revision at all cannot qualify either.
            legacy = json.loads(fresh)
            legacy.pop("firmwareRevision")
            write_json(variant_path, legacy)
            for entry in stale["qualification"]["evidence"]:
                if entry["path"] == "docs/evidence/" + variant_path.name:
                    entry["firmwareRevision"] = None
            expect_refused(stale, "a variant pass with no firmware revision validated", "rerun it at this revision")
            # Rerunning it at this revision restores the certificate.
            variant_path.write_text(fresh, encoding="utf-8")
            require(run(dry, published, "--require-qualified"), 0, "%s: rerunning the variant did not restore the certificate" % profile)

            # The next requalification: a rerun from newer firmware makes the
            # published certificate stale, and its revocation record retires it, as a
            # lock move requires. Without that step the certificate fails validation.
            rerun = json.loads(fresh)
            rerun["firmwareRevision"] = OLD_REVISION
            rerun["firmwareSHA256"] = "e" * 64
            write_json(variant_path, rerun)
            stale_result = run(dry, published, "--require-qualified", "--allow-revoked")
            require(stale_result, 1, "%s: a certificate whose record was rerun stayed valid" % profile)
            if "needs a revocation record marking it superseded" not in stale_result.stderr:
                raise SystemExit("%s: the stale certificate did not say what to do:\n%s" % (profile, stale_result.stderr))
            write_json(dry / "releases" / "revocations" / profile / published.name, {
                "schemaVersion": 1, "status": "revoked",
                "manifestPath": "releases/%s/%s" % (profile, published.name),
                "reason": "Superseded by the requalification.",
            })
            require(run(dry, published, "--require-qualified", "--allow-revoked"), 0, "%s: the superseded certificate did not leave through its revocation" % profile)

    # The writer refuses to record a device run it cannot name a revision for.
    if shutil.which("node"):
        refused = subprocess.run(["node", "--input-type=module", "-e", """
const { deviceEvidenceRecord } = await import(process.env.DRY_WRITER);
deviceEvidenceRecord({ result: "passed", smoke: { validation: { passed: true, counts: {} } }, firmwareSha256: "a", coreSha: "b" }, { device: "u" }, { profile: "p", check: "c", cases: "x" });
"""], env={**os.environ, "DRY_WRITER": str(ROOT / "Tests/embedded/write-device-evidence.mjs")}, capture_output=True, text=True)
        if refused.returncode == 0 or "without the firmware revision" not in refused.stderr:
            raise SystemExit("the evidence writer accepted a proof with no firmware revision")

    # The exemption is exact: the two current certificates validate in this
    # repository, and the same document naming another commit does not.
    for key, commit in {"esp32c6-mqtt/0.10.0-embedded.2": "0b4bc08406f25b1a4cb61423cc955a2690c54a1c",
                        "esp32c6-zenoh/0.10.0-embedded.2": "e6543e140b226001765c925de4e566c3e29cb5e0"}.items():
        real = ROOT / "releases" / (key + ".json")
        if not real.exists():
            continue
        result = run(ROOT, real, "--require-qualified", "--allow-revoked")
        require(result, 0, "%s no longer validates" % key)
        if result.stdout.startswith("ok"):
            forged = json.loads(real.read_text(encoding="utf-8"))
            if forged["embedded"]["sha"] != commit:
                raise SystemExit("%s names another commit than the exemption" % key)
            forged["embedded"]["sha"] = "e" * 40
            forged_path = base / key.replace("/", "-")
            write_json(forged_path, forged)
            require(run(ROOT, forged_path, "--require-qualified"), 1, "%s stayed exempt under another commit" % key)

print("release-manifest validator checks passed")
