#!/usr/bin/env bash
# Pins the smoke protocol's expected case set so coverage cannot shrink quietly.
#
# The device smoke validator decides a run passed by comparing the case IDs it
# observed against three contributions it declares: the named smoke and vector
# sets, and every corpus case crossed with the corpus operations. If a case ID
# is deleted from any of them, every future run still reports a clean pass
# while proving less. Nothing on a board can catch that: the board only ever
# runs what it is asked to run.
#
# So the set is pinned here, as the count and a digest of the sorted IDs. This
# needs only bash and python3, and it runs with no toolchain and no board.
#
# When a case is added or removed deliberately, update the baseline in the same
# commit and say in the message what changed and why. A silent edit here is the
# thing this check exists to prevent.
#
# Exit status: 0 the set matches the baseline, 1 it does not, 2 bad usage.

set -uo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repo_root" || exit 2

validator='Platforms/esp32c6-idf/tools/validate-smoke.mjs'
baseline='Tools/smoke-coverage.baseline'

[ -f "$validator" ] || { echo "check-smoke-coverage: no validator at $validator; nothing to pin" >&2; exit 0; }

actual="$(python3 - "$validator" <<'PY'
import hashlib, json, re, sys
text = open(sys.argv[1]).read()
ids = []
for name in ("expectedSmokeTests", "expectedVectorTests"):
    match = re.search(r'export const %s = new Set\(\[(.*?)\]\);' % name, text, re.S)
    if match is None:
        print("MISSING %s" % name)
        raise SystemExit(0)
    ids.extend(re.findall(r'"([^"]+)"', match.group(1)))

# The validator's full expected set also includes every corpus case crossed
# with the corpus operations (validate-smoke.mjs, expectedEmbeddedSwiftTests).
# Pinning only the two named sets would leave the corpus subset, the largest
# part of the device proof, free to shrink silently.
ops_match = re.search(r'const corpusOperations = \[(.*?)\];', text, re.S)
if ops_match is None:
    print("MISSING corpusOperations")
    raise SystemExit(0)
operations = re.findall(r'"([^"]+)"', ops_match.group(1))
try:
    with open("Applications/device-smoke-agent/fixtures/manifest.json") as handle:
        manifest = json.load(handle)
except (OSError, ValueError) as error:
    print("MANIFEST %s" % error)
    raise SystemExit(0)
for case in manifest.get("cases", []):
    for operation in operations:
        ids.append("corpus:%s:%s" % (case["id"], operation))

unique = sorted(set(ids))
digest = hashlib.sha256("\n".join(unique).encode()).hexdigest()
print("count=%d sha256=%s" % (len(unique), digest))
PY
)"

case "$actual" in
    MANIFEST*) echo "check-smoke-coverage: ${actual#MANIFEST }" >&2; exit 1 ;;
esac

case "$actual" in
    MISSING*) echo "check-smoke-coverage: validator no longer declares ${actual#MISSING }" >&2; exit 1 ;;
esac

if [ ! -f "$baseline" ]; then
    echo "check-smoke-coverage: no baseline; writing $baseline"
    printf '%s\n' "$actual" > "$baseline"
    exit 0
fi

expected="$(cat "$baseline")"
if [ "$actual" = "$expected" ]; then
    echo "check-smoke-coverage: ok, $actual"
    exit 0
fi

echo "check-smoke-coverage: the expected smoke case set changed" >&2
echo "  baseline: $expected" >&2
echo "  actual:   $actual" >&2
echo "Update $baseline in the same commit and explain the change." >&2
exit 1
