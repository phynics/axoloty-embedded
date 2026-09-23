#!/usr/bin/env python3
# Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.
#
# Validate one per-profile release manifest against the repository it came from.
#
# The manifest is the compatibility certificate, so validation is a set of
# cross-checks against authoritative sources, never a schema read alone:
#   * the lock decides the Axoloty revision for a release;
#   * VERSION decides the embedded version;
#   * the profile decides the application, platform, transport, and board;
#   * docs/evidence decides qualification, and a qualified manifest must cite a
#     passed device record whose artifact and Core revision match this build.
#
# Stdlib only, so it runs in the toolchain-free `repo` tier. The same validator
# runs on every tracked manifest and on the manifest a release path is about to
# publish.
#
# Usage: validate-release-manifest.py <repo-root> <manifest.json> [--require-qualified] [--allow-revoked]
# Exit:  0 valid, 1 invalid, 2 usage.

import json
import os
import re
import sys

HEX40 = re.compile(r"[0-9a-f]{40}")
HEX64 = re.compile(r"[0-9a-f]{64}")
VERSION = re.compile(r"^(\d+\.\d+\.\d+)-embedded\.([1-9]\d*)$")
STATUSES = {"passed", "failed", "unexecuted"}


def load(path):
    try:
        with open(path, encoding="utf-8") as handle:
            return json.load(handle)
    except (OSError, ValueError) as error:
        raise ValueError("%s is not readable JSON: %s" % (path, error))


def is_nonempty_string(value):
    return isinstance(value, str) and value.strip() != ""


def is_within(candidate, directory):
    return os.path.commonpath([candidate, directory]) == directory and candidate != directory


def load_revocation(repo_root, manifest_path):
    """Return the immutable revocation record for a tracked certificate."""
    releases_dir = os.path.join(repo_root, "releases")
    if not is_within(manifest_path, releases_dir):
        return None, []
    relative_manifest = os.path.relpath(manifest_path, releases_dir)
    if relative_manifest.startswith("revocations" + os.sep):
        return None, []
    revocation_path = os.path.join(releases_dir, "revocations", relative_manifest)
    if not os.path.isfile(revocation_path):
        return None, []
    try:
        record = load(revocation_path)
    except ValueError as error:
        return None, ["revocation %s is invalid: %s" % (revocation_path, error)]
    if not isinstance(record, dict):
        return None, ["revocation %s must be a JSON object" % revocation_path]
    expected_manifest_path = os.path.relpath(manifest_path, repo_root)
    problems = []
    if record.get("schemaVersion") != 1:
        problems.append("revocation %s: schemaVersion must be 1" % revocation_path)
    if record.get("status") != "revoked":
        problems.append("revocation %s: status must be revoked" % revocation_path)
    if record.get("manifestPath") != expected_manifest_path:
        problems.append("revocation %s: manifestPath must be %r" % (revocation_path, expected_manifest_path))
    if not is_nonempty_string(record.get("reason")):
        problems.append("revocation %s: reason is required" % revocation_path)
    return record, problems


def validate_evidence(record, path):
    """Return a list of problems, mirroring docs/evidence.md."""
    problems = []
    if record.get("schemaVersion") != 1:
        problems.append("%s: schemaVersion must be 1" % path)
    status = record.get("status")
    if status not in STATUSES:
        problems.append("%s: status must be one of %s" % (path, sorted(STATUSES)))
    for field in ("profile", "check", "recordedAt"):
        if not record.get(field):
            problems.append("%s: %s is required" % (path, field))
    tier = record.get("tier")
    if tier not in {"build", "component", "device", None}:
        problems.append("%s: tier must be build, component, or device when present, found %r" % (path, tier))
    if status in {"passed", "failed"}:
        # docs/evidence.md: a build runs in the pinned container and has no
        # board, so it names the toolchain; a component record names the
        # compiled component and its artifact hash; a device record names the
        # unit and the protocol it drove. Requiring the device fields of a
        # build record made every qualified manifest citing one invalid.
        if tier == "component":
            required = ["component", "artifactSHA256", "coreRevision", "result", "toolchain"]
        else:
            required = ["firmwareSHA256", "coreRevision", "result"]
            if tier == "build":
                required.append("toolchain")
            else:
                required.extend(["device", "protocol"])
        for field in required:
            if not record.get(field):
                problems.append("%s: an executed %s record must name %s"
                                % (path, tier or "device", field))
        checksum = str(record.get("firmwareSHA256", ""))
        if checksum and not HEX64.fullmatch(checksum):
            problems.append("%s: firmwareSHA256 must be 64 lowercase hexadecimal characters" % path)
        artifact = str(record.get("artifactSHA256", ""))
        if artifact and not HEX64.fullmatch(artifact):
            problems.append("%s: artifactSHA256 must be 64 lowercase hexadecimal characters" % path)
        revision = str(record.get("coreRevision", ""))
        if revision and not HEX40.fullmatch(revision):
            problems.append("%s: coreRevision must be a full commit SHA" % path)
    elif status == "unexecuted" and not record.get("reason"):
        problems.append("%s: an unexecuted record must state a reason" % path)
    return problems


def validate(repo_root, manifest_path, require_qualified, allow_revoked):
    repo_root = os.path.abspath(repo_root)
    manifest_path = os.path.abspath(manifest_path)
    manifest = load(manifest_path)
    revocation, revocation_problems = load_revocation(repo_root, manifest_path)
    if allow_revoked and revocation is not None:
        return revocation_problems, revocation

    problems = []
    problems.extend(revocation_problems)

    if manifest.get("schemaVersion") != 1:
        problems.append("schemaVersion must be 1, found %r" % manifest.get("schemaVersion"))
    mode = manifest.get("mode")
    if mode not in {"release", "preview"}:
        problems.append("mode must be release or preview, found %r" % mode)

    # --- Profile identity and the declared axes. -----------------------------
    profile_name = manifest.get("profile")
    profile = None
    if not is_nonempty_string(profile_name):
        problems.append("profile is required")
    else:
        profile_path = os.path.join(repo_root, "Profiles", profile_name, "profile.json")
        if not os.path.isfile(profile_path):
            problems.append("profile %r has no Profiles/%s/profile.json" % (profile_name, profile_name))
        else:
            profile = load(profile_path)
            for field in ("application", "platform", "board"):
                declared = profile.get(field)
                if not is_nonempty_string(declared):
                    problems.append("Profiles/%s/profile.json does not declare %s" % (profile_name, field))
                elif manifest.get(field) != declared:
                    problems.append("%s is %r but the profile declares %r" % (field, manifest.get(field), declared))
            declared_transport = profile.get("transport")
            manifest_transport = manifest.get("transport")
            manifest_transport_name = manifest_transport.get("name") if isinstance(manifest_transport, dict) else None
            if not is_nonempty_string(declared_transport):
                problems.append("Profiles/%s/profile.json does not declare transport" % profile_name)
            elif manifest_transport_name != declared_transport:
                problems.append("transport.name is %r but the profile declares %r"
                                % (manifest_transport_name, declared_transport))
            for field, axis in (("application", "Applications"), ("platform", "Platforms"), ("transport", "Transports")):
                value = manifest.get(field) if field != "transport" else manifest_transport_name
                if is_nonempty_string(value) and not os.path.isdir(os.path.join(repo_root, axis, value)):
                    problems.append("%s %r does not exist under %s/" % (field, value, axis))

    if not is_nonempty_string(manifest.get("board")):
        problems.append("board is required; a release names the qualified board")

    # --- Transport backend. --------------------------------------------------
    transport = manifest.get("transport")
    if not isinstance(transport, dict):
        problems.append("transport must be an object")
        transport = {}
    for field in ("name", "backend", "version", "versionSource"):
        if not is_nonempty_string(transport.get(field)):
            problems.append("transport.%s is required" % field)

    # --- Axoloty identity: the lock decides a release. -----------------------
    axoloty = manifest.get("axoloty")
    if not isinstance(axoloty, dict):
        problems.append("axoloty must be an object")
        axoloty = {}
    axoloty_sha = str(axoloty.get("sha", ""))
    if not HEX40.fullmatch(axoloty_sha):
        problems.append("axoloty.sha must be a full 40-character commit SHA, found %r" % axoloty.get("sha"))
    if axoloty.get("dirty") is not False:
        problems.append("axoloty.dirty must be false; a release is built from a clean Core checkout")
    if not is_nonempty_string(axoloty.get("contractSha256")) or not HEX64.fullmatch(str(axoloty.get("contractSha256", ""))):
        problems.append("axoloty.contractSha256 must be a SHA-256")

    lock_path = os.path.join(repo_root, "axoloty-core.lock.json")
    lock = load(lock_path) if os.path.isfile(lock_path) else {}
    lock_core = lock.get("core") if isinstance(lock.get("core"), dict) else {}
    if mode == "release":
        if axoloty_sha != lock_core.get("revision"):
            problems.append("axoloty.sha does not match the lock revision")
        if axoloty.get("version") != lock_core.get("version"):
            problems.append("axoloty.version does not match the lock version")
        if axoloty.get("tag") != lock_core.get("tag"):
            problems.append("axoloty.tag does not match the lock tag")
    elif mode == "preview":
        if axoloty_sha == lock_core.get("revision"):
            problems.append("a preview manifest must build an off-lock Axoloty revision")
        if axoloty.get("version") is not None or axoloty.get("tag") is not None:
            problems.append("a preview manifest must not assert an Axoloty version or tag")

    # --- Embedded identity: VERSION decides. ---------------------------------
    embedded = manifest.get("embedded")
    if not isinstance(embedded, dict):
        problems.append("embedded must be an object")
        embedded = {}
    version_path = os.path.join(repo_root, "VERSION")
    if not os.path.isfile(version_path):
        problems.append("VERSION is missing")
    else:
        with open(version_path, encoding="utf-8") as handle:
            version_text = handle.read().strip()
        if embedded.get("version") != version_text:
            problems.append("embedded.version %r does not match VERSION %r" % (embedded.get("version"), version_text))
        match = VERSION.fullmatch(version_text)
        if not match:
            problems.append("VERSION is not <base>-embedded.<revision>: %r" % version_text)
        elif mode != "preview" and match.group(1) != lock_core.get("version"):
            problems.append("VERSION base %s does not match the lock version %s" % (match.group(1), lock_core.get("version")))
    if not HEX40.fullmatch(str(embedded.get("sha", ""))):
        problems.append("embedded.sha must be a full 40-character commit SHA")
    if embedded.get("dirty") is not False:
        problems.append("embedded.dirty must be false; a release is built from a clean firmware checkout")

    # --- Toolchain, configuration, image. ------------------------------------
    toolchain = manifest.get("toolchain")
    if not isinstance(toolchain, dict):
        problems.append("toolchain must be an object")
        toolchain = {}
    for field in ("swift", "sdk", "target"):
        if not is_nonempty_string(toolchain.get(field)):
            problems.append("toolchain.%s is required; the build observed it" % field)

    if not HEX64.fullmatch(str(manifest.get("configurationFingerprint", ""))):
        problems.append("configurationFingerprint must be a SHA-256")

    image = manifest.get("image")
    if not isinstance(image, dict):
        problems.append("image must be an object")
        image = {}
    if not is_nonempty_string(image.get("path")) or os.path.basename(image.get("path", "")) != image.get("path"):
        problems.append("image.path must be a file name, not a machine path")
    image_sha = str(image.get("sha256", ""))
    if not HEX64.fullmatch(image_sha):
        problems.append("image.sha256 must be a SHA-256")
    byte_count = image.get("byteCount")
    if not isinstance(byte_count, int) or isinstance(byte_count, bool) or byte_count <= 0:
        problems.append("image.byteCount must be a positive integer")

    resources = manifest.get("resources")
    if resources is not None:
        if not isinstance(resources, dict) or resources.get("available") is not True or not isinstance(resources.get("report"), dict):
            problems.append("resources must be null or {available: true, report: {...}}")

    # --- Qualification: evidence decides, and it must match this build. ------
    qualification = manifest.get("qualification")
    if not isinstance(qualification, dict):
        problems.append("qualification must be an object")
        qualification = {}
    status = qualification.get("status")
    if status not in {"qualified", "unqualified"}:
        problems.append("qualification.status must be qualified or unqualified")
    entries = qualification.get("evidence")
    if not isinstance(entries, list):
        problems.append("qualification.evidence must be a list")
        entries = []
    matching = 0
    evidence_dir = os.path.abspath(os.path.join(repo_root, "docs", "evidence"))
    for entry in entries:
        if not isinstance(entry, dict) or not is_nonempty_string(entry.get("path")):
            problems.append("each qualification.evidence entry must name a path")
            continue
        relative = entry["path"]
        candidate = os.path.abspath(os.path.join(repo_root, relative))
        if not is_within(candidate, evidence_dir):
            problems.append("evidence path %r is outside docs/evidence" % relative)
            continue
        if not os.path.isfile(candidate):
            problems.append("evidence path %r does not exist" % relative)
            continue
        record = load(candidate)
        for problem in validate_evidence(record, relative):
            problems.append(problem)
        if (entry.get("status") == "passed" and entry.get("coreRevision") == axoloty_sha
                and entry.get("firmwareSHA256") == image_sha):
            matching += 1
    if status == "qualified" and matching == 0:
        problems.append("a qualified manifest needs a passed evidence record for this Core revision and image checksum")
    if require_qualified and status != "qualified":
        problems.append("this manifest is not qualified; a published release must be")
    if revocation is not None and not allow_revoked:
        problems.append("this release certificate is revoked: %s" % revocation["reason"])

    # --- Compatibility statement. --------------------------------------------
    compatibility = manifest.get("compatibility")
    if not isinstance(compatibility, dict):
        problems.append("compatibility must be an object")
        compatibility = {}
    if compatibility.get("scope") != "profile":
        problems.append("compatibility.scope must be profile; compatibility is per profile")
    expected_status = "preview" if mode == "preview" else status
    if compatibility.get("status") != expected_status:
        problems.append("compatibility.status must be %r, found %r" % (expected_status, compatibility.get("status")))
    if not is_nonempty_string(compatibility.get("description")):
        problems.append("compatibility.description is required")

    return problems, revocation


def main(argv):
    args = [argument for argument in argv if argument not in {"--require-qualified", "--allow-revoked"}]
    require_qualified = "--require-qualified" in argv
    allow_revoked = "--allow-revoked" in argv
    if len(args) != 3:
        sys.stderr.write("usage: validate-release-manifest.py <repo-root> <manifest.json> [--require-qualified] [--allow-revoked]\n")
        return 2
    repo_root, manifest_path = args[1], args[2]
    try:
        problems, revocation = validate(repo_root, manifest_path, require_qualified, allow_revoked)
    except ValueError as error:
        sys.stderr.write("VIOLATION [release-manifest] %s\n" % error)
        return 1
    for problem in problems:
        sys.stderr.write("VIOLATION [release-manifest] %s\n" % problem)
    if problems:
        return 1
    mode = load(manifest_path).get("mode")
    if revocation is not None:
        print("revoked  [release-manifest] %s: %s" % (manifest_path, revocation["reason"]))
    elif mode == "release":
        print("ok       [release-manifest] %s is a valid profile compatibility certificate" % manifest_path)
    else:
        print("ok       [release-manifest] %s is a well-formed compatibility preview (not a claim)" % manifest_path)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
