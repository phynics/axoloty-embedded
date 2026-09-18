#!/usr/bin/env bash
# Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.
#
# Release one profile as a compatibility certificate for one exact Axoloty
# revision, or produce a clearly labelled compatibility preview.
#
# A release:
#   1. forces strict Core preparation, so a dirty or off-lock Core checkout is
#      refused by Tools/prepare-core.sh itself rather than by a re-implemented
#      check;
#   2. builds the profile, which writes build provenance and the release
#      manifest candidate;
#   3. flashes and qualifies the image on the board named by AXOLOTY_DEVICE_PORT,
#      writing an evidence record under docs/evidence/;
#   4. rewrites the manifest so it carries the qualification;
#   5. validates the manifest against the lock, VERSION, the profile, and the
#      evidence; and
#   6. publishes it to releases/<profile>/<version>.json for review.
#
# It never pushes, tags, or commits. A preview:
#   * builds against an off-lock Axoloty candidate named by the operator;
#   * is labelled preview in its manifest and is never a compatibility claim;
#   * is written only into the proof workspace and is never published.
#
# Usage:
#   Tools/release.sh --profile <name>
#   Tools/release.sh --profile <name> --preview <40-char Axoloty SHA>
#
# Environment:
#   AXOLOTY_DEVICE_PORT  Required for a release; names the board, never guessed.
#   AXOLOTY_SOURCE_DIR   Optional local Core checkout; preview requires it.
#   AXOLOTY_SCRATCH / EMBEDDED_PROOF_ROOT / EMBEDDED_EVIDENCE_DIR  Passed through.

set -euo pipefail

usage() {
    sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'
}

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repo_root" || exit 2

profile=''
preview_revision=''
while [ $# -gt 0 ]; do
    case "$1" in
        --profile) profile="${2:-}"; shift 2 || exit 2 ;;
        --preview) preview_revision="${2:-}"; shift 2 || exit 2 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "release: unknown argument: $1" >&2; exit 2 ;;
    esac
done

if [ -z "$profile" ]; then
    echo "release: --profile <name> is required" >&2
    exit 2
fi

profile_dir="$repo_root/Profiles/$profile"
if [ ! -f "$profile_dir/profile.json" ]; then
    echo "release: no such profile: $profile" >&2
    exit 2
fi

platform="$(node -e 'process.stdout.write(require(process.argv[1]).platform)' "$profile_dir/profile.json")"
manifest_writer="$repo_root/Platforms/$platform/tools/write-release-manifest.sh"
if [ ! -x "$manifest_writer" ]; then
    echo "release: platform $platform has no release-manifest writer" >&2
    exit 2
fi
version="$(cat "$repo_root/VERSION")"

scratch="${AXOLOTY_SCRATCH:-$repo_root/.axoloty}"
proof_root="${EMBEDDED_PROOF_ROOT:-$scratch/firmware}"
evidence_dir="${EMBEDDED_EVIDENCE_DIR:-$proof_root/working-evidence}"
candidate="$evidence_dir/release-manifest.json"

# Strict preparation is the release contract; never weaken it here.
export AXOLOTY_STRICT_CORE=1

if [ -n "$preview_revision" ]; then
    case "$preview_revision" in
        [0-9a-f]*) ;;
        *) echo "release: --preview must be a lowercase hexadecimal SHA" >&2; exit 2 ;;
    esac
    if [ "${#preview_revision}" -ne 40 ]; then
        echo "release: --preview must be a full 40-character SHA" >&2
        exit 2
    fi
    export AXOLOTY_PREVIEW_CORE_REVISION="$preview_revision"
    printf '\n== compatibility preview: %s against Axoloty candidate %s\n' "$profile" "$preview_revision"
    echo "   This is not a compatibility claim and nothing will be published."
    "$profile_dir/build.sh"
    if ! python3 Tools/validate-release-manifest.py "$repo_root" "$candidate"; then
        echo "release: the preview manifest is malformed" >&2
        exit 1
    fi
    echo
    echo "Preview manifest: $candidate"
    echo "Preview complete; no release record was written."
    exit 0
fi

if [ -z "${AXOLOTY_DEVICE_PORT:-}" ]; then
    echo "release: AXOLOTY_DEVICE_PORT must name the board; a release is qualified on real hardware" >&2
    exit 2
fi

destination="$repo_root/releases/$profile/$version.json"
if [ -e "$destination" ]; then
    echo "release: $destination already exists; release records are immutable" >&2
    exit 1
fi

printf '\n== release: %s at %s\n' "$profile" "$version"
echo "   Core: strict preparation of the locked revision"
"$profile_dir/build.sh"
"$profile_dir/qualify.sh"

# Rewrite the manifest now that qualification evidence exists, then validate it
# before it is published.
"$manifest_writer" "$profile_dir"
if [ ! -f "$candidate" ]; then
    echo "release: no manifest was produced: $candidate" >&2
    exit 1
fi
if ! python3 Tools/validate-release-manifest.py "$repo_root" "$candidate" --require-qualified; then
    echo "release: the manifest is not a valid compatibility certificate; refusing to publish" >&2
    exit 1
fi

mkdir -p "$(dirname "$destination")"
cp "$candidate" "$destination"
if ! python3 Tools/validate-release-manifest.py "$repo_root" "$destination" --require-qualified; then
    echo "release: published manifest failed validation: $destination" >&2
    exit 1
fi

echo
echo "Release record written: $destination"
echo "Review it, then commit it, then tag the release:"
echo "  git add $destination"
echo "  git commit -m \"chore(release): publish $profile $version\""
echo "  git tag v$version"
echo "This command did not commit, tag, or push."
