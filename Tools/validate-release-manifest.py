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

# An ESP-IDF dependency manifest supplies SDK components, not independently
# pinned libraries. The one transport whose backend comes from it is the
# SDK-supplied MQTT client, so an ESP-IDF-sourced backend identity is pinned
# here. A manifest cannot cite the correct SDK version while naming a library
# the image does not use; a new ESP-IDF-sourced transport must extend this map
# and the generator together.
ESPIDF_BACKENDS = {"mqtt-espidf": "esp-idf/mqtt"}

# Certificates issued before the size report existed carry `resources: null`.
# They stay valid through this closed list of exact `<profile>/<version>`
# entries. Never add a new release here: a release of a profile that declares
# `budgets.build` must carry a size report.
SIZE_REPORT_GRANDFATHERED = frozenset({
    "esp32c6-mqtt/0.8.2-embedded.2",
    "esp32c6-mqtt/0.10.0-embedded.2",
    "esp32c6-zenoh/0.10.0-embedded.1",
    "esp32c6-zenoh/0.10.0-embedded.2",
})


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


def espidf_component_version(text, component):
    """Return the version pinned for a component in an ESP-IDF dependencies.lock."""
    lines = text.splitlines()
    start = None
    for index, line in enumerate(lines):
        if re.match(r"^ {2}[^\s].*:\s*$", line) and line.strip() == "%s:" % component:
            start = index
            break
    if start is None:
        return None
    for line in lines[start + 1:]:
        if re.match(r"^ {2}[^\s]", line):
            break
        match = re.match(r"^ {4}version:\s*'?([^'\s]+)'?\s*$", line)
        if match:
            return match.group(1)
    return None


def validate_transport_source(transport, source_path, relative):
    """Cross-check the manifest transport identity against the file it cites."""
    problems = []
    if source_path.endswith(".json"):
        try:
            source = load(source_path)
        except ValueError as error:
            return ["%s is not readable JSON: %s" % (relative, error)]
        if not isinstance(source, dict):
            return ["%s must be a JSON object" % relative]
        component = source.get("component")
        if is_nonempty_string(component) and transport.get("backend") != component:
            problems.append("transport.backend %r does not match %s component %r"
                            % (transport.get("backend"), relative, component))
        version = source.get("version")
        if not is_nonempty_string(version):
            problems.append("%s does not declare a version" % relative)
        elif transport.get("version") != version:
            problems.append("transport.version %r does not match %s version %r"
                            % (transport.get("version"), relative, version))
        revision = source.get("revision")
        if revision is None:
            if transport.get("revision") is not None:
                problems.append("transport.revision is %r but %s pins no revision"
                                % (transport.get("revision"), relative))
        elif transport.get("revision") != revision:
            problems.append("transport.revision %r does not match %s revision %r"
                            % (transport.get("revision"), relative, revision))
    else:
        if not is_nonempty_string(transport.get("component")):
            problems.append("transport.component is required when the backend version comes from an ESP-IDF dependency manifest")
            return problems
        expected_backend = ESPIDF_BACKENDS.get(transport.get("name"))
        if expected_backend is None:
            problems.append("transport.name %r has no ESP-IDF backend identity" % transport.get("name"))
        elif transport.get("backend") != expected_backend:
            problems.append("transport.backend %r does not match the ESP-IDF backend %r for transport %r"
                            % (transport.get("backend"), expected_backend, transport.get("name")))
        try:
            with open(source_path, encoding="utf-8") as handle:
                text = handle.read()
        except OSError as error:
            return ["%s is not readable: %s" % (relative, error)]
        version = espidf_component_version(text, transport["component"])
        if version is None:
            problems.append("transport.component %r is not a component of %s" % (transport["component"], relative))
        elif transport.get("version") != version:
            problems.append("transport.version %r does not match %s component %r version %r"
                            % (transport.get("version"), relative, transport["component"], version))
        if transport.get("revision") is not None:
            problems.append("transport.revision must be null for an ESP-IDF dependency manifest")
    return problems


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


SIZE_METRICS = ("imageBytes", "flashTextBytes", "flashRodataBytes", "iramTextBytes",
                "initializedDataBytes", "dramBssBytes", "staticRamBytes")
BUDGET_METRICS = ("imageBytes", "flashTextBytes", "staticRamBytes", "dramBssBytes")
MAX_SAFE_INTEGER = 9007199254740991


def safe_integer(value, minimum=0):
    return type(value) is int and minimum <= value <= MAX_SAFE_INTEGER


def validate_size_report(report, manifest, profile):
    """Check the complete writer contract and bind measurements to this manifest."""
    problems = []
    def check(condition, message):
        if not condition:
            problems.append("resources.report." + message)
    if not isinstance(report, dict):
        return ["resources.report must be an object"]
    check(set(report) == {"schemaVersion", "kind", "profile", "application", "platform", "transport", "coreRevision", "metrics", "image", "budgets", "enforcement"}, "has invalid fields")
    check(type(report.get("schemaVersion")) is int and report.get("schemaVersion") == 1 and report.get("kind") == "build-size", "has invalid schema or kind")
    for field, expected in (("profile", manifest.get("profile")), ("application", manifest.get("application")),
                            ("platform", manifest.get("platform")), ("transport", (manifest.get("transport") if isinstance(manifest.get("transport"), dict) else {}).get("name")),
                            ("coreRevision", (manifest.get("axoloty") if isinstance(manifest.get("axoloty"), dict) else {}).get("sha"))):
        check(is_nonempty_string(expected) and report.get(field) == expected, field + " does not match manifest")
    metrics = report.get("metrics")
    valid_metrics = isinstance(metrics, dict) and set(metrics) == set(SIZE_METRICS) and all(safe_integer(v) for v in metrics.values())
    check(valid_metrics, "metrics are invalid")
    if valid_metrics:
        total = metrics["iramTextBytes"] + metrics["initializedDataBytes"] + metrics["dramBssBytes"]
        check(safe_integer(total) and metrics["staticRamBytes"] == total, "static RAM does not match components")
    image = report.get("image")
    valid_image = isinstance(image, dict) and set(image) == {"bytes", "sha256", "appPartitionBytes", "partitionHeadroomBytes"}
    if valid_image:
        valid_image = (safe_integer(image["bytes"], 1) and safe_integer(image["appPartitionBytes"], 1)
                       and type(image["partitionHeadroomBytes"]) is int
                       and abs(image["partitionHeadroomBytes"]) <= MAX_SAFE_INTEGER
                       and image["partitionHeadroomBytes"] == image["appPartitionBytes"] - image["bytes"]
                       and isinstance(image["sha256"], str) and bool(HEX64.fullmatch(image["sha256"])))
    check(valid_image, "image is invalid")
    if valid_image:
        check(image["bytes"] == (manifest.get("image") if isinstance(manifest.get("image"), dict) else {}).get("byteCount") and image["sha256"] == (manifest.get("image") if isinstance(manifest.get("image"), dict) else {}).get("sha256"), "image does not match manifest image")
        if valid_metrics:
            check(metrics["imageBytes"] == image["bytes"], "image metric does not match image bytes")
    enforcement = report.get("enforcement")
    if not isinstance(enforcement, dict):
        return problems + ["resources.report.enforcement must be an object"]
    status = enforcement.get("status")
    check(status in ("passed", "not-applicable", "not-configured"), "enforcement status is invalid")
    declared = profile.get("budgets", {}) if isinstance(profile, dict) else {}
    declared_build = declared.get("build") if isinstance(declared, dict) else None
    if isinstance(profile, dict) and "budgets" in profile:
        check(isinstance(declared, dict) and set(declared) <= {"basis", "build"} and ("basis" not in declared or is_nonempty_string(declared["basis"])), "profile budgets are invalid")
    if isinstance(declared, dict) and "build" in declared:
        check(isinstance(declared_build, dict) and bool(declared_build) and set(declared_build) <= set(BUDGET_METRICS) and all(safe_integer(v, 1) for v in declared_build.values()), "profile build budgets are invalid")
    if status in ("passed", "failed"):
        budgets = report.get("budgets")
        valid_budgets = isinstance(budgets, dict) and set(budgets) == {"basis", "build"} and isinstance(budgets.get("build"), dict)
        if valid_budgets:
            build = budgets["build"]
            valid_budgets = bool(build) and set(build) <= set(BUDGET_METRICS) and all(safe_integer(v, 1) for v in build.values())
        check(valid_budgets, "budgets are invalid")
        if valid_budgets:
            check(build == declared_build and budgets["basis"] == declared.get("basis"), "budgets do not match profile")
            expected = [dict(metric=k, measured=metrics[k], budget=build[k], headroomBytes=build[k]-metrics[k], passed=metrics[k] <= build[k]) for k in BUDGET_METRICS if k in build] if valid_metrics else None
            check(set(enforcement) == {"status", "results"} and type(enforcement.get("results")) is list and json.dumps(enforcement.get("results"), sort_keys=True) == json.dumps(expected, sort_keys=True) and expected is not None and all(x["passed"] for x in expected) == (status == "passed"), "verdicts are inconsistent")
    elif status in ("not-applicable", "not-configured"):
        reason = "configured C-only carrier qualification image" if status == "not-applicable" else "the profile declares no build budgets"
        check(report.get("budgets") is None and enforcement == {"status": status, "reason": reason}, "enforcement is inconsistent")
        if status == "not-applicable":
            qualification = manifest.get("qualification")
            requirements = (profile.get("qualification") or {}).get("requiredChecks", []) if isinstance(profile, dict) and isinstance(profile.get("qualification"), dict) else []
            check(isinstance(qualification, dict) and qualification.get("status") == "unqualified" and isinstance(profile, dict) and profile.get("transport") == "zenoh-pico" and isinstance(requirements, list) and any(isinstance(r, dict) and r.get("check") == "c-only-carrier-scenario" and r.get("artifact") == "variant" for r in requirements), "C-only report requires the unqualified Zenoh qualification variant")
        if status == "not-configured":
            check(declared_build is None, "not-configured contradicts profile budgets")
    return problems


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


def required_check_problems(required_checks, entries, core_sha, image_sha):
    """Return why the cited evidence does not satisfy the required checks."""
    if not isinstance(required_checks, list) or not required_checks:
        return ["qualification.requiredChecks must name at least one check"]
    problems = []
    for required in required_checks:
        check = required.get("check") if isinstance(required, dict) else None
        artifact = required.get("artifact") if isinstance(required, dict) else None
        record_count = required.get("records") if isinstance(required, dict) else None
        units = required.get("units") if isinstance(required, dict) else None
        if (not is_nonempty_string(check) or artifact not in {"release", "variant"}
                or not isinstance(record_count, int) or isinstance(record_count, bool) or record_count < 1
                or not isinstance(units, int) or isinstance(units, bool) or units < 1):
            problems.append("malformed required check: %r" % (required,))
            continue
        records = [entry for entry in entries if isinstance(entry, dict) and entry.get("check") == check]
        accepted = [entry for entry in records
                    if entry.get("tier") in {"device", None}
                    and entry.get("status") == "passed"
                    and entry.get("coreRevision") == core_sha
                    and (entry.get("firmwareSHA256") == image_sha if artifact == "release"
                         else HEX64.fullmatch(str(entry.get("firmwareSHA256", ""))))]
        observed = {entry.get("device") for entry in accepted if is_nonempty_string(entry.get("device"))}
        if not records:
            problems.append("required check %s has no record" % check)
        elif len(accepted) != len(records):
            problems.append("required check %s has a record that did not pass for this build" % check)
        elif len(accepted) < record_count:
            problems.append("required check %s has %d of %d required records" % (check, len(accepted), record_count))
        elif len(observed) < units:
            problems.append("required check %s ran on %d of %d required units" % (check, len(observed), units))
    return problems


def validate(repo_root, manifest_path, require_qualified, allow_revoked):
    repo_root = os.path.abspath(repo_root)
    manifest_path = os.path.abspath(manifest_path)
    manifest = load(manifest_path)
    revocation, revocation_problems = load_revocation(repo_root, manifest_path)
    if allow_revoked and revocation is not None:
        return revocation_problems, revocation
    # A JSON document that is not an object cannot be a certificate. Report it
    # as a violation instead of failing later on an unrelated attribute access.
    if not isinstance(manifest, dict):
        return ["manifest must be a JSON object, found %s" % type(manifest).__name__], revocation

    problems = []
    problems.extend(revocation_problems)

    # Schema 1 predates required checks. It stays readable so that a published
    # certificate remains valid; the writer only produces schema 2.
    if manifest.get("schemaVersion") not in {1, 2}:
        problems.append("schemaVersion must be 1 or 2, found %r" % manifest.get("schemaVersion"))
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

    # --- Transport backend: identity and version from the pinned source. -----
    transport = manifest.get("transport")
    if not isinstance(transport, dict):
        problems.append("transport must be an object")
        transport = {}
    for field in ("name", "backend", "version", "versionSource"):
        if not is_nonempty_string(transport.get(field)):
            problems.append("transport.%s is required" % field)
    # `component` names the pinned entry that supplies the backend, and
    # `revision` is the backend commit when its source pins one. Both are
    # required because a backend with no identity is not a certificate.
    if "component" not in transport:
        problems.append("transport.component is required; it names the pinned entry that supplies the backend")
    elif transport.get("component") is not None and not is_nonempty_string(transport.get("component")):
        problems.append("transport.component must be a non-empty string or null")
    if "revision" not in transport:
        problems.append("transport.revision is required; it is the pinned backend commit or null")
    elif transport.get("revision") is not None and not HEX40.fullmatch(str(transport.get("revision"))):
        problems.append("transport.revision must be null or a full commit SHA")

    version_source = transport.get("versionSource")
    if is_nonempty_string(version_source):
        platform_name = manifest.get("platform")
        platform_dir = (os.path.abspath(os.path.join(repo_root, "Platforms", platform_name))
                        if is_nonempty_string(platform_name) else None)
        if os.path.isabs(version_source) or ".." in version_source.split("/"):
            problems.append("transport.versionSource must be a repository-relative path")
        else:
            source_path = os.path.abspath(os.path.join(repo_root, version_source))
            if platform_dir is None or not is_within(source_path, platform_dir):
                problems.append("transport.versionSource %r is outside Platforms/%s"
                                % (version_source, platform_name))
            elif not os.path.isfile(source_path):
                problems.append("transport.versionSource %r does not exist" % version_source)
            else:
                problems.extend(validate_transport_source(transport, source_path, version_source))

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
        if not is_nonempty_string(axoloty.get("tag")):
            problems.append("axoloty.tag is required; a release certificate must name a tagged Core revision")
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
    declares_build_budgets = isinstance(profile, dict) and isinstance(profile.get("budgets"), dict) \
        and "build" in profile["budgets"]
    release_key = "%s/%s" % (profile_name, embedded.get("version"))
    if resources is None:
        if declares_build_budgets and release_key not in SIZE_REPORT_GRANDFATHERED:
            problems.append("resources is null but profile %s declares budgets.build; a release must carry a size report" % profile_name)
    else:
        if not isinstance(resources, dict) or set(resources) != {"available", "report"} or resources.get("available") is not True:
            problems.append("resources must be null or {available: true, report: {...}}")
        else:
            problems.extend(validate_size_report(resources["report"], manifest, profile))

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
        # docs/evidence.md: only a device record carries the compatibility
        # claim. A build or component record proves the artifact compiles, so a
        # qualified manifest must not be able to cite one as device evidence.
        if (entry.get("status") == "passed" and entry.get("coreRevision") == axoloty_sha
                and entry.get("firmwareSHA256") == image_sha
                and record.get("tier") in {"device", None}):
            matching += 1
    if status == "qualified" and matching == 0:
        problems.append("a qualified manifest needs a passed evidence record for this Core revision and image checksum")
    if manifest.get("schemaVersion") == 2:
        outstanding = required_check_problems(qualification.get("requiredChecks"), entries, axoloty_sha, image_sha)
        if status == "qualified":
            problems.extend(outstanding)
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
