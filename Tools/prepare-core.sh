#!/usr/bin/env bash
# Resolves the locked Axoloty Core revision and prepares it for a firmware
# build through the supported consumer preparation contract.
#
# A clean clone needs no prepared sibling checkout: the locked revision is
# fetched into caller-owned scratch space. AXOLOTY_SOURCE_DIR selects a local
# checkout instead, for coordinated development.
#
# Environment:
#   AXOLOTY_SOURCE_DIR   Absolute path to a local Axoloty checkout (optional).
#   AXOLOTY_SCRATCH      Scratch root. Default: <repo>/.axoloty
#   AXOLOTY_STRICT_CORE  1 requires the selected revision and a clean checkout.
#                        Defaults to 1 when CI is set, otherwise 0.
#   AXOLOTY_PREVIEW_CORE_REVISION  A 40-character Axoloty candidate SHA to
#                        prepare instead of the lock. This is the explicit
#                        compatibility-preview mode: it still requires a clean
#                        checkout, but it is deliberately off-lock and its
#                        result is never a compatibility claim. Never set this
#                        for a release or for ordinary CI.
#
# Writes <scratch>/core-preparation.json and prints its path.

set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
lock_path="$repo_root/axoloty-core.lock.json"
scratch="${AXOLOTY_SCRATCH:-$repo_root/.axoloty}"

if [ -n "${AXOLOTY_STRICT_CORE:-}" ]; then
    strict="$AXOLOTY_STRICT_CORE"
elif [ -n "${CI:-}" ]; then
    strict=1
else
    strict=0
fi

die() {
    echo "prepare-core: $1" >&2
    exit 1
}

read_lock() {
    python3 - "$lock_path" "$1" <<'PY'
import json, sys
with open(sys.argv[1]) as handle:
    document = json.load(handle)
if document.get("schemaVersion") != 1:
    sys.exit("unsupported lock schemaVersion: %r" % document.get("schemaVersion"))
print(document["core"][sys.argv[2]])
PY
}

[ -f "$lock_path" ] || die "missing lock file: $lock_path"

core_url="$(read_lock url)"
core_revision="$(read_lock revision)"
core_version="$(read_lock version)"

case "$core_revision" in
    [0-9a-f]*) [ "${#core_revision}" -eq 40 ] || die "lock revision must be a full 40-character SHA" ;;
    *) die "lock revision must be a lowercase hexadecimal SHA" ;;
esac

preview_revision="${AXOLOTY_PREVIEW_CORE_REVISION:-}"
if [ -n "$preview_revision" ]; then
    case "$preview_revision" in
        [0-9a-f]*) ;;
        *) die "AXOLOTY_PREVIEW_CORE_REVISION must be a lowercase hexadecimal SHA" ;;
    esac
    [ "${#preview_revision}" -eq 40 ] ||
        die "AXOLOTY_PREVIEW_CORE_REVISION must be a full 40-character SHA"
    [ "$preview_revision" != "$core_revision" ] ||
        die "AXOLOTY_PREVIEW_CORE_REVISION equals the locked revision; preview mode is only for an off-lock candidate"
    expected_revision="$preview_revision"
    echo "prepare-core: PREVIEW mode: preparing Axoloty candidate $preview_revision (lock is $core_revision); this is not a compatibility claim" >&2
else
    expected_revision="$core_revision"
fi

mkdir -p "$scratch"

checkout_revision() {
    git -C "$1" rev-parse HEAD
}

is_dirty() {
    [ -n "$(git -C "$1" status --porcelain)" ]
}

if [ -n "${AXOLOTY_SOURCE_DIR:-}" ]; then
    core_dir="$AXOLOTY_SOURCE_DIR"
    case "$core_dir" in
        /*) ;;
        *) die "AXOLOTY_SOURCE_DIR must be an absolute path" ;;
    esac
    # A linked worktree keeps .git as a file, so ask Git rather than test -d.
    git -C "$core_dir" rev-parse --git-dir >/dev/null 2>&1 ||
        die "AXOLOTY_SOURCE_DIR is not a Git checkout: $core_dir"
    core_dir="$(cd "$core_dir" && pwd -P)"

    selected_revision="$(checkout_revision "$core_dir")"
    if is_dirty "$core_dir"; then
        dirty=true
    else
        dirty=false
    fi

    if [ "$strict" = "1" ]; then
        [ "$dirty" = false ] || die "AXOLOTY_SOURCE_DIR is dirty and strict mode is on: $core_dir"
        [ "$selected_revision" = "$expected_revision" ] || die "AXOLOTY_SOURCE_DIR is at $selected_revision but the required revision is $expected_revision"
    else
        [ "$dirty" = false ] || echo "prepare-core: warning: local Core checkout is dirty" >&2
        [ "$selected_revision" = "$expected_revision" ] || echo "prepare-core: warning: local Core is at $selected_revision, required revision is $expected_revision" >&2
    fi
    echo "prepare-core: using local Core $core_dir at $selected_revision (dirty=$dirty)"
else
    core_dir="$scratch/core/$expected_revision"
    if [ ! -d "$core_dir/.git" ]; then
        mkdir -p "$core_dir"
        git -C "$core_dir" init -q
        git -C "$core_dir" remote add origin "$core_url" 2>/dev/null || true
        # GitHub serves an exact commit, so no full history is fetched.
        git -C "$core_dir" fetch -q --depth 1 origin "$expected_revision"
        git -C "$core_dir" checkout -q --detach FETCH_HEAD
    fi
    selected_revision="$(checkout_revision "$core_dir")"
    [ "$selected_revision" = "$expected_revision" ] || die "fetched Core is at $selected_revision, expected $expected_revision"
    dirty=false
    echo "prepare-core: using fetched Core $core_dir at $selected_revision"
fi

tools_scratch="$scratch/core-tools"
tooling_build="$scratch/core-tooling-build"
report="$scratch/core-preparation.json"
mkdir -p "$tools_scratch" "$tooling_build"

if [ -n "$preview_revision" ]; then
    echo "prepare-core: preparing Axoloty preview candidate $expected_revision through the supported consumer contract"
else
    echo "prepare-core: preparing Axoloty $core_version through the supported consumer contract"
fi
AXOLOTY_SOURCE_DIR="$core_dir" swift run \
    --package-path "$core_dir/Tools" \
    --scratch-path "$tooling_build" \
    axoloty-tool embedded consumer prepare \
    --scratch "$tools_scratch" \
    --output "$report" >/dev/null

[ -f "$report" ] || die "preparation report was not written: $report"

python3 - "$report" "$expected_revision" "$strict" <<'PY'
import json, sys
report_path, expected_revision, strict = sys.argv[1], sys.argv[2], sys.argv[3]
with open(report_path) as handle:
    report = json.load(handle)
if report.get("schemaVersion") != 1:
    sys.exit("prepare-core: unsupported preparation schemaVersion: %r" % report.get("schemaVersion"))
if report.get("status") != "prepared":
    sys.exit("prepare-core: preparation status is %r" % report.get("status"))
core = report["core"]
if strict == "1":
    if core["sha"] != expected_revision:
        sys.exit("prepare-core: preparation reports %s, required revision is %s" % (core["sha"], expected_revision))
    if core["dirty"]:
        sys.exit("prepare-core: preparation reports a dirty Core checkout")
print("prepare-core: Core %s (dirty=%s), contract %s"
      % (core["sha"][:12], str(core["dirty"]).lower(), report["contractSHA256"][:12]))
PY

echo "prepare-core: ready"
echo "$report"
