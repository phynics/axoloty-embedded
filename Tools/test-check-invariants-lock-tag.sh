#!/usr/bin/env bash
# Regression test for the `lock-tag` invariant in Tools/check-invariants.sh.
#
# The invariant is what stops a Core lock from naming a release tag that does
# not resolve to the revision the lock pins. It has three outcomes: it passes
# when the tag resolves to the locked commit, it fails when the tag resolves
# to a different commit, and it skips when the tag cannot be resolved at all.
# A wrong label that is never resolved must not read as a pass, and a tag that
# does resolve must not read as a skip.
#
# The rule itself is small, but it is the only thing that catches a lock whose
# tag and revision disagree, and it has no other test. The test drives the
# real `check-invariants.sh` over throwaway lock files and a throwaway Core
# git repository, so each outcome is observed rather than assumed. It needs
# only bash, git, grep, and python3, and it runs in the toolchain-free `repo`
# tier.
#
# Exit status: 0 all cases pass, 1 a case failed, 69 git or python3 is absent.

set -uo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repo_root" || exit 1

for tool in git python3; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        echo "test-check-invariants-lock-tag: $tool is not on PATH" >&2
        exit 69
    fi
done

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

failures=0

# A throwaway Core checkout with two commits and one tag on each, so a tag can
# resolve either to the locked revision or to a different one.
core="$tmp/core"
mkdir -p "$core"
git -C "$core" init -q
git -C "$core" config user.email test@example.invalid
git -C "$core" config user.name 'lock-tag test'
printf 'a\n' > "$core/file"
git -C "$core" add file
git -C "$core" commit -qm 'first'
locked="$(git -C "$core" rev-parse HEAD)"
git -C "$core" tag v-locked
printf 'b\n' > "$core/file"
git -C "$core" commit -qam 'second'
other="$(git -C "$core" rev-parse HEAD)"
git -C "$core" tag v-other

# A throwaway repository root holding only the invariant script. The script
# resolves its root from its own path, so a copy is enough to run the real
# rule; the rule is self-contained (bash, git, grep, python3 only).
fake="$tmp/repo"
mkdir -p "$fake/Tools"
cp "$repo_root/Tools/check-invariants.sh" "$fake/Tools/check-invariants.sh"
git -C "$fake" init -q

# write_lock <tag> <revision> <url>. An empty tag is written as JSON null.
write_lock() {
    python3 - "$fake/axoloty-core.lock.json" "$1" "$2" "$3" <<'PY'
import json, sys
path, tag, revision, url = sys.argv[1:5]
json.dump({
    "schemaVersion": 1,
    "core": {
        "identity": "phynics/axoloty",
        "url": url,
        "revision": revision,
        "revisionFormat": "git-commit-sha1",
        "version": "0.8.2",
        "tag": tag or None,
        "consumerContractPath": "docs/embedded-consumer-contract.md",
    },
}, open(path, "w"))
PY
}

# run <source-dir-or-empty> <tag> <revision> <url>. `env -u` removes any
# inherited AXOLOTY_SOURCE_DIR so the URL path is exercised deliberately.
run() {
    write_lock "$2" "$3" "$4"
    if [ -n "$1" ]; then
        AXOLOTY_SOURCE_DIR="$1" bash "$fake/Tools/check-invariants.sh" 2>&1
    else
        env -u AXOLOTY_SOURCE_DIR bash "$fake/Tools/check-invariants.sh" 2>&1
    fi
}

# expect <case> <output> <required-substring> <forbidden-substring>. Only the
# lock-tag line is judged; the copied script reports other rules too.
expect() {
    local case="$1" output="$2" want="$3" forbid="$4" line
    line="$(printf '%s\n' "$output" | grep -E '\[lock-tag\]' || true)"
    if ! printf '%s\n' "$line" | grep -Fq "$want"; then
        printf 'FAIL [%s] expected the lock-tag line to contain:\n  %s\nobserved:\n%s\n' \
            "$case" "$want" "${line:-<no lock-tag line>}" >&2
        failures=$((failures + 1))
        return
    fi
    if [ -n "$forbid" ] && printf '%s\n' "$line" | grep -Fq "$forbid"; then
        printf 'FAIL [%s] the lock-tag line must not contain %s:\n%s\n' \
            "$case" "$forbid" "$line" >&2
        failures=$((failures + 1))
        return
    fi
    printf 'ok       [%s] %s\n' "$case" "$want"
}

# The tag resolves through the lock URL to a different commit than the lock
# pins: the label is wrong, so the rule must fail, not skip or pass.
output="$(run '' v-other "$locked" "$core")"
expect mismatch-remote "$output" \
    "VIOLATION [lock-tag] the lock names v-other but pins ${locked:0:12}" \
    "ok       [lock-tag]"

# The same mismatch, resolved through a local Core checkout. The local path
# must take precedence over the URL, and must still fail.
output="$(run "$core" v-other "$locked" "$tmp/missing.git")"
expect mismatch-local "$output" \
    "VIOLATION [lock-tag] the lock names v-other but pins ${locked:0:12}" \
    "ok       [lock-tag]"

# The tag resolves correctly, but the lock pins the other commit: the reverse
# direction of the mismatch must also fail.
output="$(run "$core" v-locked "$other" "$core")"
expect mismatch-reversed "$output" \
    "VIOLATION [lock-tag] the lock names v-locked but pins ${other:0:12}" \
    "ok       [lock-tag]"

# A tag that resolves to the locked revision passes. The URL is unreachable,
# so this proves the local checkout is enough.
output="$(run "$core" v-locked "$locked" "$tmp/missing.git")"
expect resolved-local "$output" \
    "ok       [lock-tag] Core tag v-locked is the locked revision ${locked:0:12}" \
    "VIOLATION"

# The same resolution through `git ls-remote` against the lock URL, with no
# local checkout. This is the path a toolchain-free CI checkout takes.
output="$(run '' v-locked "$locked" "$core")"
expect resolved-remote "$output" \
    "ok       [lock-tag] Core tag v-locked is the locked revision ${locked:0:12}" \
    "VIOLATION"

# A null tag is the documented between-releases state; it passes and tells the
# reader that no certificate can be written from this lock.
output="$(run "$core" '' "$locked" "$core")"
expect null-tag "$output" \
    "ok       [lock-tag] the lock names no Core tag" \
    "VIOLATION"

# A tag that cannot be resolved through either path skips. A skip is not a
# pass, and a non-null tag must never reach the pass line here.
output="$(run "$core" v-missing "$locked" "$tmp/missing.git")"
expect unresolvable "$output" \
    "skipped  [lock-tag] could not resolve Core tag v-missing" \
    "ok       [lock-tag]"

if [ "$failures" -ne 0 ]; then
    printf '\ntest-check-invariants-lock-tag: %d case(s) failed\n' "$failures" >&2
    exit 1
fi
printf '\ntest-check-invariants-lock-tag: all lock-tag cases passed\n'
