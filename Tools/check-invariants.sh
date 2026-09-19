#!/usr/bin/env bash
# Mechanically enforces the ownership invariants stated in AGENTS.md.
#
# Every rule here exists because prose alone did not stop the mistake. A rule
# is the enforceable half of an invariant: when the invariant changes, change
# the rule in the same commit.
#
# Needs only bash, git, grep, and python3. It never compiles, flashes, or
# probes hardware, so it runs in every environment including CI and a
# toolchain-free checkout.
#
# Exit status: 0 all rules pass, 1 one or more violations, 2 bad usage.

set -uo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repo_root" || exit 2

violations=0
checked=0
skipped=0

fail() {
    printf 'VIOLATION [%s] %s\n' "$1" "$2" >&2
    violations=$((violations + 1))
}

pass() {
    printf 'ok       [%s] %s\n' "$1" "$2"
    checked=$((checked + 1))
}

skip() {
    printf 'skipped  [%s] %s\n' "$1" "$2"
    skipped=$((skipped + 1))
}

# Tracked files only. An untracked scratch file is not a repository claim, and
# .axoloty/ holds the fetched Core checkout, which is never ours to judge.
tracked() {
    git ls-files -- "$@" 2>/dev/null | grep -v '^\.axoloty/' || true
}

# Source files under an axis directory, excluding documentation.
axis_sources() {
    tracked "$1" | grep -E '\.(swift|c|h|cpp|hpp|cmake|txt|yml|yaml|json|csv|defaults|sh)$' || true
}

CORE_MODULES='AxolotyWire AxolotyObjectModel AxolotyProtocol AxolotyCoatyModels AxolotyStaticRuntime'

# ---------------------------------------------------------------------------
# 1. The lock is well formed and authoritative.
# ---------------------------------------------------------------------------

lock_revision=''
if [ ! -f axoloty-core.lock.json ]; then
    fail lock 'axoloty-core.lock.json is missing'
else
    lock_report="$(python3 - axoloty-core.lock.json <<'PY'
import json, re, sys
try:
    with open(sys.argv[1]) as handle:
        document = json.load(handle)
except (OSError, ValueError) as error:
    print("ERR the lock is not readable JSON: %s" % error)
    raise SystemExit(0)
problems = []
if document.get("schemaVersion") != 1:
    problems.append("schemaVersion must be 1, found %r" % document.get("schemaVersion"))
core = document.get("core")
if not isinstance(core, dict):
    problems.append("core must be an object")
    core = {}
revision = core.get("revision", "")
if not re.fullmatch(r"[0-9a-f]{40}", str(revision)):
    problems.append("core.revision must be 40 lowercase hexadecimal characters, found %r" % revision)
if core.get("revisionFormat") != "git-commit-sha1":
    problems.append("core.revisionFormat must be git-commit-sha1")
if core.get("identity") != "phynics/axoloty":
    problems.append("core.identity must be phynics/axoloty, found %r" % core.get("identity"))
for field in ("url", "version", "consumerContractPath"):
    if not core.get(field):
        problems.append("core.%s is required" % field)
for problem in problems:
    print("ERR " + problem)
if not problems:
    print("REV " + revision)
PY
)"
    while IFS= read -r line; do
        case "$line" in
            ERR*) fail lock "${line#ERR }" ;;
            REV*) lock_revision="${line#REV }" ;;
        esac
    done <<< "$lock_report"
    [ -n "$lock_revision" ] && pass lock "Core revision ${lock_revision:0:12} is well formed"
fi

# ---------------------------------------------------------------------------
# 2. No portable Core source is copied into this repository.
# ---------------------------------------------------------------------------
# Portable packages are compiled in place from the locked checkout. A copy
# forks the one-Core invariant silently, so three independent signals look for
# one: a module-named directory, a local target declaration, and, when a Core
# checkout is reachable, a filename collision with real portable sources.

copy_violation=0
for module in $CORE_MODULES _JSONCore; do
    hits="$(tracked '*' | grep -E "(^|/)${module}/" || true)"
    if [ -n "$hits" ]; then
        fail core-copy "a directory named ${module}/ holds tracked files; portable Core is compiled in place, never copied"
        copy_violation=1
    fi
done

manifest_hits="$(tracked '*/Package.swift' 'Package.swift' || true)"
for manifest in $manifest_hits; do
    for module in $CORE_MODULES; do
        if grep -qE "\.(target|systemLibrary)\([^)]*name:[[:space:]]*\"${module}\"" "$manifest" 2>/dev/null; then
            fail core-copy "$manifest declares $module as a local target; depend on the prepared Core report instead"
            copy_violation=1
        fi
    done
done

# A Core checkout is used here for comparison only, never to build from. The
# build boundary stays exactly as docs/core-dependency.md states it:
# Tools/prepare-core.sh and its report. AXOLOTY_CORE_COMPARE_DIR is the
# explicit opt-in for a reviewer or an agent that already has a checkout to
# hand and wants the strongest available copied-source signal.
core_dir=''
if [ -n "${AXOLOTY_CORE_COMPARE_DIR:-}" ] && [ -d "${AXOLOTY_CORE_COMPARE_DIR}" ]; then
    core_dir="$AXOLOTY_CORE_COMPARE_DIR"
elif [ -n "${AXOLOTY_SOURCE_DIR:-}" ] && [ -d "${AXOLOTY_SOURCE_DIR}" ]; then
    core_dir="$AXOLOTY_SOURCE_DIR"
elif [ -d .axoloty/core ]; then
    core_dir="$(find .axoloty/core -maxdepth 1 -mindepth 1 -type d | head -1)"
fi

if [ -n "$core_dir" ] && [ -d "$core_dir/Packages" ]; then
    core_names="$(find "$core_dir/Packages" -name '*.swift' -type f -printf '%f\n' 2>/dev/null | sort -u)"
    local_names="$(tracked '*.swift' | xargs -r -n1 basename 2>/dev/null | sort -u)"
    collisions="$(comm -12 <(echo "$core_names") <(echo "$local_names") 2>/dev/null || true)"
    if [ -n "$collisions" ]; then
        fail core-copy "these filenames also exist in portable Core, which suggests copied source: $(echo "$collisions" | tr '\n' ' ')"
        copy_violation=1
    else
        pass core-copy 'no tracked Swift filename collides with portable Core source'
    fi
else
    skip core-copy 'no Core checkout reachable, so the filename comparison did not run (set AXOLOTY_CORE_COMPARE_DIR to a checkout to enable it; name and manifest rules still applied)'
fi

[ "$copy_violation" -eq 0 ] && pass core-copy 'no module-named directory and no local Core target declaration'

# ---------------------------------------------------------------------------
# 3. An application names no board, SDK, or broker.
# ---------------------------------------------------------------------------
# An application is what the firmware does. The moment it can name ESP-IDF or
# MQTT, the application x platform x transport axes stop being separable and
# the second board becomes a rewrite.

app_tokens='esp32|esp-idf|esp_idf|idf_component|freertos|nvs_flash|esp_wifi|sdkconfig|partitions\.csv|mqtt|zenoh|zenoh_pico|zenoh-pico'
app_sources="$(axis_sources 'Applications/*')"
app_bad=0
for file in $app_sources; do
    hits="$(grep -nEi "$app_tokens" "$file" 2>/dev/null | head -3 || true)"
    if [ -n "$hits" ]; then
        fail application-neutral "$file names a board, SDK, or broker: $(echo "$hits" | head -1 | cut -c1-120)"
        app_bad=1
    fi
done
if [ -z "$app_sources" ]; then
    skip application-neutral 'Applications/ holds no source yet'
elif [ "$app_bad" -eq 0 ]; then
    pass application-neutral 'no application names a board, SDK, or broker'
fi

# ---------------------------------------------------------------------------
# 4. A transport contains no protocol rule.
# ---------------------------------------------------------------------------
# A transport owns carrier mechanics. Every protocol rule lives in
# AxolotyProtocol, which is Axoloty's to own. A rule that gets restated in a
# transport is a second source of truth that no Core test covers.

protocol_tokens='import AxolotyProtocol|import AxolotyCoatyModels|ProtocolProcessor|ProtocolSubscriptionRegistry|BorrowedProtocolFrame|InlineProtocolActionSink|coaty/3'
transport_sources="$(axis_sources 'Transports/*')"
transport_bad=0
for file in $transport_sources; do
    hits="$(grep -nE "$protocol_tokens" "$file" 2>/dev/null | head -3 || true)"
    if [ -n "$hits" ]; then
        fail transport-carrier-only "$file states a protocol rule: $(echo "$hits" | head -1 | cut -c1-120)"
        transport_bad=1
    fi
done
if [ -z "$transport_sources" ]; then
    skip transport-carrier-only 'Transports/ holds no source yet'
elif [ "$transport_bad" -eq 0 ]; then
    pass transport-carrier-only 'no transport states a protocol rule'
fi

# ---------------------------------------------------------------------------
# 5. A platform owns no protocol behavior.
# ---------------------------------------------------------------------------

# The wire benchmark is a measurement fixture. It mirrors AxolotyWire's JSON
# scanning in C for on-device timing, is not linked into any firmware image,
# and is not platform integration; it is exempt from the protocol-rule scan.
platform_sources="$(axis_sources 'Platforms/*' | grep -v '/benchmark/' || true)"
platform_bad=0
for file in $platform_sources; do
    hits="$(grep -nE "$protocol_tokens" "$file" 2>/dev/null | head -3 || true)"
    if [ -n "$hits" ]; then
        fail platform-integration-only "$file states a protocol rule: $(echo "$hits" | head -1 | cut -c1-120)"
        platform_bad=1
    fi
done
if [ -z "$platform_sources" ]; then
    skip platform-integration-only 'Platforms/ holds no source yet'
elif [ "$platform_bad" -eq 0 ]; then
    pass platform-integration-only 'no platform states a protocol rule'
fi

# ---------------------------------------------------------------------------
# 6. Never read Core outside the prepared report.
# ---------------------------------------------------------------------------
# Parent-directory discovery and root .build scanning were the exact failures
# the pre-split gate in axoloty#845 had to disprove. They do not come back.

escape_bad=0
for file in $(tracked '*.sh' '*.cmake' 'CMakeLists.txt' '*/CMakeLists.txt' '*.py' '*.yml' '*.yaml'); do
    [ "$file" = 'Tools/check-invariants.sh' ] && continue
    if grep -nE '\.\./\.\./\.\.|axoloty/\.build|/\.build/' "$file" >/dev/null 2>&1; then
        fail core-boundary "$file discovers Core by path or reads a Core .build directory; use Tools/prepare-core.sh and its report"
        escape_bad=1
    fi
done
[ "$escape_bad" -eq 0 ] && pass core-boundary 'no parent-directory discovery and no Core .build read'

# ---------------------------------------------------------------------------
# 7. A profile is one declarative application x platform x transport selection.
# ---------------------------------------------------------------------------

profile_dirs="$(find Profiles -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort || true)"
if [ -z "$profile_dirs" ]; then
    skip profile-shape 'no profile exists yet'
else
    for profile in $profile_dirs; do
        manifest="$profile/profile.json"
        if [ ! -f "$manifest" ]; then
            fail profile-shape "$profile has no profile.json"
            continue
        fi
        report="$(python3 - "$manifest" "$lock_revision" "$repo_root" <<'PY'
import json, os, sys
manifest_path, lock_revision, repo_root = sys.argv[1], sys.argv[2], sys.argv[3]
try:
    with open(manifest_path) as handle:
        profile = json.load(handle)
except (OSError, ValueError) as error:
    print("ERR %s is not readable JSON: %s" % (manifest_path, error))
    raise SystemExit(0)

problems = []
for field in ("name", "application", "platform", "transport"):
    if not profile.get(field):
        problems.append("%s is missing required field %r" % (manifest_path, field))

# One transport, chosen at compile time. A list here is the beginning of a
# plugin system the epic explicitly refused.
transport = profile.get("transport")
if isinstance(transport, (list, tuple, dict)):
    problems.append("%s selects %d transports; a profile selects exactly one"
                    % (manifest_path, len(transport)))

for field, axis in (("application", "Applications"), ("platform", "Platforms"), ("transport", "Transports")):
    value = profile.get(field)
    if isinstance(value, str) and value:
        target = os.path.join(repo_root, axis, value)
        if not os.path.isdir(target):
            problems.append("%s names %s %r, but %s/%s does not exist"
                            % (manifest_path, field, value, axis, value))

core = profile.get("core") or {}
claimed = core.get("revision") if isinstance(core, dict) else None
if not claimed:
    problems.append("%s does not record core.revision; a profile claims an exact Axoloty revision" % manifest_path)
elif lock_revision and claimed != lock_revision:
    problems.append("%s claims Core %s but the lock is at %s" % (manifest_path, claimed[:12], lock_revision[:12]))

for problem in problems:
    print("ERR " + problem)
PY
)"
        if [ -n "$report" ]; then
            while IFS= read -r line; do
                [ -n "$line" ] && fail profile-shape "${line#ERR }"
            done <<< "$report"
        else
            pass profile-shape "$manifest selects one application, platform, and transport at the locked Core revision"
        fi
    done
fi

# ---------------------------------------------------------------------------
# 7b. No private Core reference.
# ---------------------------------------------------------------------------
# The pre-split firmware validate wrapper ran this as a ripgrep content scan
# and failed closed on a match. It is a rule here instead of a build-time scan
# so that it runs on every checkout, with or without a toolchain, and so that
# no evidence record can claim it passed without it having run.
#
# Firmware must never name Core's package layout, its build directory, its
# private support tests, or the pre-split resolver scripts. Those are the exact
# couplings the split had to disprove.

private_tokens='Packages/|/\.build/|Tests/Support|resolve-embedded-core|prepare-embedded-core'
private_bad=0
# Prose and harness logs are excluded: docs must be able to quote an original
# Axoloty path when recording provenance, and .testing/ holds captured tool
# output rather than firmware source. Every firmware file stays in the scan.
for file in $(tracked '*' | grep -vE '^(\.testing/|docs/|\.github/|README\.md|AGENTS\.md|[A-Za-z]+/AGENTS\.md|Tools/check-invariants\.sh)'); do
    [ -f "$file" ] || continue
    hits="$(grep -nE "$private_tokens" "$file" 2>/dev/null | head -2 || true)"
    if [ -n "$hits" ]; then
        fail private-reference "$file names Core's private layout: $(echo "$hits" | head -1 | cut -c1-110)"
        private_bad=1
    fi
done
[ "$private_bad" -eq 0 ] && pass private-reference 'no tracked firmware file names Core package layout, .build, private support tests, or a pre-split resolver'

# ---------------------------------------------------------------------------
# 8. No committed credentials.
# ---------------------------------------------------------------------------
# Device paths, credentials, reachability, and live timing belong in operator
# configuration, never in the tree.

secret_bad=0
for file in $(tracked '*' | grep -vE '^(docs/|\.github/|README\.md|AGENTS\.md|Tools/check-invariants\.sh)'); do
    [ -f "$file" ] || continue
    hits="$(grep -nEi '(ssid|psk|passphrase|password|broker_user|mqtt_pass)[[:space:]]*[:=][[:space:]]*"[^"]{3,}"' "$file" 2>/dev/null |
            grep -vEi '"(|CONFIG_[A-Z0-9_]+|\$\{[^}]+\}|<[^>]+>|changeme|placeholder|example|redacted|TODO)"' | head -2 || true)"
    if [ -n "$hits" ]; then
        fail no-credentials "$file appears to hold a literal credential: $(echo "$hits" | head -1 | cut -c1-100)"
        secret_bad=1
    fi
done
[ "$secret_bad" -eq 0 ] && pass no-credentials 'no literal Wi-Fi or broker credential is tracked'

# ---------------------------------------------------------------------------
# 9. Evidence records are well formed, and a claim carries evidence.
# ---------------------------------------------------------------------------
# See docs/evidence.md. Unexecuted is a legal, honest state. A pass without a
# device, an artifact checksum, and a Core commit is not evidence. A record
# that names a Core revision must name the lock's revision: after a lock raise,
# a stale passed record is a compatibility claim for a revision the repository
# no longer ships, and it must not survive a checkout silently. Imported
# evidence is exempt because its importedFrom block records where it came
# from.

evidence_files="$(tracked 'docs/evidence/*.json' || true)"
if [ -z "$evidence_files" ]; then
    skip evidence 'no evidence record exists yet'
else
    evidence_bad=0
    for record in $evidence_files; do
        report="$(python3 - "$record" "$lock_revision" <<'PY'
import json, re, sys
path, lock_revision = sys.argv[1], sys.argv[2]
try:
    with open(path) as handle:
        record = json.load(handle)
except (OSError, ValueError) as error:
    print("ERR %s is not readable JSON: %s" % (path, error))
    raise SystemExit(0)

problems = []
if record.get("schemaVersion") != 1:
    problems.append("%s: schemaVersion must be 1" % path)

status = record.get("status")
allowed = {"passed", "failed", "unexecuted"}
if status not in allowed:
    problems.append("%s: status must be one of %s, found %r" % (path, sorted(allowed), status))

for field in ("profile", "check", "recordedAt"):
    if not record.get(field):
        problems.append("%s: %s is required" % (path, field))

tier = record.get("tier")
if tier not in {"build", "component", "device", None}:
    problems.append("%s: tier must be build, component, or device when present, found %r" % (path, tier))

if status in {"passed", "failed"}:
    # An executed claim names what ran it and what it ran. A build runs in a
    # container and has no device; a component check compiles one pinned
    # component and has no firmware image; a device run must name the board and
    # the protocol it drove. Requiring the device fields of a build record made
    # an honest passed build unrepresentable.
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
    if checksum and not re.fullmatch(r"[0-9a-f]{64}", checksum):
        problems.append("%s: firmwareSHA256 must be 64 lowercase hexadecimal characters" % path)
    artifact = str(record.get("artifactSHA256", ""))
    if artifact and not re.fullmatch(r"[0-9a-f]{64}", artifact):
        problems.append("%s: artifactSHA256 must be 64 lowercase hexadecimal characters" % path)
    revision = str(record.get("coreRevision", ""))
    if revision and not re.fullmatch(r"[0-9a-f]{40}", revision):
        problems.append("%s: coreRevision must be a full 40-character commit SHA" % path)
elif status == "unexecuted":
    if not record.get("reason"):
        problems.append("%s: an unexecuted record must state a reason" % path)

# A record describes one Core revision. After the lock moves, a record for the
# superseded revision is stale, and a "passed" one is worse: it reads as a
# compatibility claim for the current lock while describing the old one.
# Imported evidence keeps its original revision and cites its origin, so it is
# exempt.
revision_value = record.get("coreRevision")
if revision_value and not record.get("importedFrom") and lock_revision:
    if revision_value != lock_revision:
        problems.append(
            "%s: coreRevision %s does not match the locked Core revision %s; "
            "regenerate or remove the record when the lock moves"
            % (path, str(revision_value)[:12], lock_revision[:12]))

for problem in problems:
    print("ERR " + problem)
PY
)"
        if [ -n "$report" ]; then
            while IFS= read -r line; do
                [ -n "$line" ] && fail evidence "${line#ERR }"
            done <<< "$report"
            evidence_bad=1
        fi
    done
    [ "$evidence_bad" -eq 0 ] && pass evidence "$(echo "$evidence_files" | wc -l | tr -d ' ') evidence record(s) are well formed"
fi

# ---------------------------------------------------------------------------
# 10. A release manifest is a certificate, and VERSION names the cycle.
# ---------------------------------------------------------------------------
# See docs/releases.md. A release manifest is a compatibility claim for one
# profile at one exact Axoloty revision. It is produced by the build, and this
# rule re-checks it against the lock, VERSION, the profile, and docs/evidence
# on every checkout. A preview manifest is never a certificate and is never
# tracked here. A rule, not a prose promise, so the format cannot rot silently.

version_value=''
if [ ! -f VERSION ]; then
    fail release 'VERSION is missing; the embedded version has no source'
else
    version_value="$(cat VERSION)"
    version_report="$(python3 - VERSION <<'PY'
import json, re, sys
version_text = open(sys.argv[1]).read().strip()
match = re.fullmatch(r"(\d+\.\d+\.\d+)-embedded\.([1-9]\d*)", version_text)
if not match:
    print("ERR VERSION is not <base>-embedded.<revision>: %r" % version_text)
    raise SystemExit(0)
try:
    with open("axoloty-core.lock.json") as handle:
        lock_version = json.load(handle).get("core", {}).get("version")
except (OSError, ValueError):
    lock_version = None
if lock_version is None:
    print("ERR could not read the lock version to check VERSION")
elif match.group(1) != lock_version:
    print("ERR VERSION base %s does not match the lock version %s" % (match.group(1), lock_version))
PY
)"
    version_bad=0
    while IFS= read -r line; do
        case "$line" in
            ERR*) fail release "${line#ERR }"; version_bad=1 ;;
        esac
    done <<< "$version_report"
    [ "$version_bad" -eq 0 ] && pass release "VERSION ${version_value} tracks the locked Axoloty version"
fi

manifest_files="$(tracked 'releases/*/*.json' || true)"
if [ -z "$manifest_files" ]; then
    skip release 'no tracked release manifest exists yet'
else
    for manifest in $manifest_files; do
        if manifest_report="$(python3 Tools/validate-release-manifest.py "$repo_root" "$manifest" --require-qualified 2>&1)"; then
            pass release "$manifest is a valid, qualified profile certificate"
        else
            while IFS= read -r line; do
                [ -n "$line" ] && fail release "${line#VIOLATION \[release-manifest\] }"
            done <<< "$manifest_report"
        fi
    done
fi

# ---------------------------------------------------------------------------

printf '\ncheck-invariants: %d passed, %d skipped, %d violation(s)\n' "$checked" "$skipped" "$violations"
[ "$violations" -eq 0 ] || exit 1
