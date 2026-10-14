#!/usr/bin/env bash
# Regression test for the `doc-paths` invariant in Tools/check-invariants.sh.
#
# The invariant is what stops a README.md or AGENTS.md from pointing a reader
# at a path that moved or never existed. It has two outcomes that matter: it
# passes when every relative link and every backticked repository path
# resolves, and it fails when one does not. A reference that is not a path (a
# URL, an anchor, a repository name, a branch) must be ignored rather than
# judged. A repository with no entry-point doc skips, and a skip is not a pass.
#
# The rule itself is small, but it is the only thing that catches a stale
# documented path, and it has no other test. The test drives the real
# `check-invariants.sh` over throwaway repositories, so each outcome is
# observed rather than assumed. It needs only bash, git, and python3, and it
# runs in the toolchain-free `repo` tier.
#
# Exit status: 0 all cases pass, 1 a case failed, 69 git or python3 is absent.

set -uo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repo_root" || exit 1

for tool in git python3; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        echo "test-check-invariants-doc-paths: $tool is not on PATH" >&2
        exit 69
    fi
done

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

failures=0
case_number=0

# A throwaway repository root holding only the invariant script. The script
# resolves its root from its own path, so a copy is enough to run the real
# rule; the rule is self-contained (bash, git, python3 only).
new_case() {
    case_number=$((case_number + 1))
    case_dir="$tmp/case-$case_number"
    mkdir -p "$case_dir/Tools"
    cp "$repo_root/Tools/check-invariants.sh" "$case_dir/Tools/check-invariants.sh"
    git -C "$case_dir" init -q
}

# write <case-dir> <repo-relative-path> <line>. One line per call.
write() {
    local dir="$1" path="$2" line="$3"
    mkdir -p "$dir/$(dirname "$path")"
    printf '%s\n' "$line" > "$dir/$path"
}

# run <case-dir>. Stage the tree so `git ls-files` sees it, then run the real
# rule. Earlier rules fail on the throwaway tree; only doc-paths is judged.
run() {
    git -C "$1" add -A >/dev/null 2>&1
    bash "$1/Tools/check-invariants.sh" 2>&1
}

# expect <case> <output> <required-substring> <forbidden-substring>. Only the
# doc-paths lines are judged; the copied script reports other rules too.
expect() {
    local case="$1" output="$2" want="$3" forbid="$4" line
    line="$(printf '%s\n' "$output" | grep -E '\[doc-paths\]' || true)"
    if ! printf '%s\n' "$line" | grep -Fq "$want"; then
        printf 'FAIL [%s] expected the doc-paths line to contain:\n  %s\nobserved:\n%s\n' \
            "$case" "$want" "${line:-<no doc-paths line>}" >&2
        failures=$((failures + 1))
        return
    fi
    if [ -n "$forbid" ] && printf '%s\n' "$line" | grep -Fq "$forbid"; then
        printf 'FAIL [%s] the doc-paths line must not contain %s:\n%s\n' \
            "$case" "$forbid" "$line" >&2
        failures=$((failures + 1))
        return
    fi
    printf 'ok       [%s] %s\n' "$case" "$want"
}

# A relative link that resolves from the file's own directory passes.
new_case
write "$case_dir" README.md '[guide](docs/guide.md)'
write "$case_dir" docs/guide.md 'guide'
output="$(run "$case_dir")"
expect link-resolves "$output" 'ok       [doc-paths]' 'VIOLATION'

# A relative link to a file that is not there fails and names the target.
new_case
write "$case_dir" README.md '[guide](docs/missing.md)'
output="$(run "$case_dir")"
expect link-broken "$output" 'VIOLATION [doc-paths] README.md references docs/missing.md' 'ok       [doc-paths]'

# A backticked repository path that resolves from the repository root passes.
new_case
write "$case_dir" AGENTS.md 'Run `Tools/prepare-core.sh` before a build.'
write "$case_dir" Tools/prepare-core.sh 'prepare'
output="$(run "$case_dir")"
expect code-resolves "$output" 'ok       [doc-paths]' 'VIOLATION'

# The exact shape that motivated the rule: an inline path in a subdirectory
# guide that resolves neither from that directory nor from the root fails.
new_case
write "$case_dir" Platforms/AGENTS.md '`cmake/axoloty-source.cmake` is the pattern to copy.'
output="$(run "$case_dir")"
expect code-broken "$output" 'VIOLATION [doc-paths] Platforms/AGENTS.md references cmake/axoloty-source.cmake' 'ok       [doc-paths]'

# A reference that is not a path is ignored: an absolute URL, an in-page
# anchor, a repository name, and a branch name all pass.
new_case
write "$case_dir" README.md '[core](https://example.invalid/x) [top](#top) `phynics/axoloty` `origin/main`'
output="$(run "$case_dir")"
expect non-paths-ignored "$output" 'ok       [doc-paths]' 'VIOLATION'

# A doc-path reference that resolves from a subdirectory file's own directory
# passes even though the root copy does not exist.
new_case
write "$case_dir" Transports/README.md 'See [the backend](zenoh-pico/README.md).'
write "$case_dir" Transports/zenoh-pico/README.md 'backend'
output="$(run "$case_dir")"
expect subdirectory-link "$output" 'ok       [doc-paths]' 'VIOLATION'

# A repository with no README.md or AGENTS.md skips, and a skip is not a pass.
new_case
write "$case_dir" docs/notes.md 'notes'
output="$(run "$case_dir")"
expect no-docs "$output" 'skipped  [doc-paths]' 'ok       [doc-paths]'

if [ "$failures" -ne 0 ]; then
    printf '\ntest-check-invariants-doc-paths: %d case(s) failed\n' "$failures" >&2
    exit 1
fi
printf '\ntest-check-invariants-doc-paths: all doc-paths cases passed\n'
