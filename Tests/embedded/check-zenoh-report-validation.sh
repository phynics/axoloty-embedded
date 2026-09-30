#!/bin/sh
# Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

# Proves the Core preparation report is a contract, not a hint.
#
# `Tests/embedded/run-zenoh-host-test.sh` must refuse a report that is missing a
# field the locked Core publishes, that names a path outside the root the report
# itself names, that spells a path non-canonically, or whose digest does not
# match the header. This check drives those refusals with focused mutations of a
# real prepared report and asserts each one fails, then asserts the unmutated
# report still passes.
#
# The mutations are applied to a copy in a temporary directory. No Core source is
# copied into this repository and the real report is never modified, so the
# fixture proves the refusals rather than restating the contract.
#
# It also guards against the opposite failure: a check that rejects everything
# would pass every case here. The unmutated report must run the seam to
# completion.
#
# Exit status: 0 passed, 1 failed, 69 required tool or the Core report is absent.

set -eu

script_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
repo_root=$(CDPATH='' cd -- "$script_dir/../.." && pwd)

for tool in node python3; do
    command -v "$tool" >/dev/null 2>&1 || {
        echo "check-zenoh-report-validation: $tool is required" >&2
        exit 69
    }
done

scratch=${AXOLOTY_SCRATCH:-"$repo_root/.axoloty"}
report=${AXOLOTY_PREPARATION_REPORT:-"$scratch/core-preparation.json"}
if [ ! -f "$report" ]; then
    if ! "$repo_root/Tools/prepare-core.sh" >/dev/null 2>&1; then
        echo "check-zenoh-report-validation: Core preparation did not produce $report" >&2
        exit 69
    fi
fi
[ -f "$report" ] || {
    echo "check-zenoh-report-validation: Core preparation report is missing: $report" >&2
    exit 69
}

# The real report must carry the contract before any mutation means anything.
for field in zenohCore.facadeHeader zenohCore.facadeHeaderSHA256 zenohCore.moduleMap; do
    node -e '
const fs = require("fs");
const document = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
let value = document;
for (const key of process.argv[2].split(".")) {
    if (typeof value !== "object" || value === null || !(key in value)) process.exit(1);
    value = value[key];
}
if (typeof value !== "string" || value === "") process.exit(1);
' "$report" "$field" || {
        echo "check-zenoh-report-validation: the prepared report has no $field, so there is no contract to test" >&2
        exit 69
    }
done

# Every fixture that needs a real file outside a root the report names writes it
# here, so nothing is created beside the Core checkout or beside caller scratch.
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
ZENOH_FIXTURE_WORK="$work"
export ZENOH_FIXTURE_WORK

mutate() {
    # mutate <name> <python-mutation>
    name="$1"
    mutation="$2"
    python3 - "$report" "$work/$name.json" "$mutation" <<'PY'
import json, os, sys

source, destination, mutation = sys.argv[1], sys.argv[2], sys.argv[3]
with open(source) as handle:
    document = json.load(handle)


def value_of(path):
    cursor = document
    for key in path.split("."):
        cursor = cursor[key]
    return cursor


def drop(path):
    cursor = document
    keys = path.split(".")
    for key in keys[:-1]:
        cursor = cursor[key]
    cursor.pop(keys[-1], None)


def replace(path, value):
    cursor = document
    keys = path.split(".")
    for key in keys[:-1]:
        cursor = cursor[key]
    cursor[keys[-1]] = value


def dot_segment(path):
    """An existing path spelled with a `.` segment, which is not canonical."""
    current = value_of(path)
    head, _, tail = current.rpartition("/")
    replace(path, head + "/./" + tail)


def retag(path):
    """Same length, different digest: only a real comparison catches this."""
    current = value_of(path)
    tail = "00" if not current.endswith("00") else "11"
    replace(path, current[:-2] + tail)


def upper(path):
    replace(path, value_of(path).upper())


def fixture_path(relative):
    """A path inside this check's own scratch, outside every root the report names."""
    return os.path.join(os.environ["ZENOH_FIXTURE_WORK"], relative)


def header_outside_core(path):
    """A real copy of the header that is outside the Core checkout.

    Byte-identical, so its digest still matches the report and containment is
    the only thing left to catch. Existence matters too: a path that is not
    there at all is refused earlier, for the wrong reason.
    """
    with open(value_of("zenohCore.facadeHeader"), "rb") as source:
        payload = source.read()
    leaf = fixture_path("outside-core/axoloty_zenoh.h")
    os.makedirs(os.path.dirname(leaf), exist_ok=True)
    with open(leaf, "wb") as handle:
        handle.write(payload)
    replace(path, leaf)


def module_map_outside_scratch(path):
    with open(value_of("zenohCore.moduleMap")) as source:
        payload = source.read()
    leaf = fixture_path("outside-scratch/module.modulemap")
    os.makedirs(os.path.dirname(leaf), exist_ok=True)
    with open(leaf, "w") as handle:
        handle.write(payload)
    replace(path, leaf)


def module_map_directory(path):
    """The real module map's directory: it exists, and it is not a file."""
    current = value_of(path)
    replace(path, current.rsplit("/", 1)[0])


def header_directory(path):
    """The real header's directory: it exists, and it is not a file."""
    current = value_of(path)
    replace(path, current.rsplit("/", 1)[0])


if mutation.startswith("drop:"):
    drop(mutation[len("drop:"):])
elif mutation.startswith("replace:"):
    _, path, value = mutation.split(":", 2)
    replace(path, value)
elif mutation.startswith("dot-segment:"):
    dot_segment(mutation[len("dot-segment:"):])
elif mutation.startswith("retag:"):
    retag(mutation[len("retag:"):])
elif mutation.startswith("upper:"):
    upper(mutation[len("upper:"):])
elif mutation == "outside-header":
    header_outside_core("zenohCore.facadeHeader")
elif mutation == "outside-module-map":
    module_map_outside_scratch("zenohCore.moduleMap")
elif mutation == "module-map-directory":
    module_map_directory("zenohCore.moduleMap")
elif mutation == "header-directory":
    header_directory("zenohCore.facadeHeader")
else:
    sys.exit("unknown mutation: %r" % mutation)

os.makedirs(os.path.dirname(destination) or ".", exist_ok=True)
with open(destination, "w") as handle:
    json.dump(document, handle, indent=2, sort_keys=True)
PY
}

expect_failure() {
    name="$1"
    description="$2"
    mutate "$name" "$3"
    set +e
    AXOLOTY_PREPARATION_REPORT="$work/$name.json" \
        "$script_dir/run-zenoh-host-test.sh" >"$work/$name.log" 2>&1
    status=$?
    set -e
    if [ "$status" -eq 0 ]; then
        echo "check-zenoh-report-validation: FAILED to refuse $description" >&2
        cat "$work/$name.log" >&2
        exit 1
    fi
    if [ "$status" -eq 69 ]; then
        echo "check-zenoh-report-validation: $description reported 69 (could not run)" >&2
        echo "instead of a failure; a malformed report is not a missing capability" >&2
        cat "$work/$name.log" >&2
        exit 1
    fi
    echo "ok   refused $description (exit $status)"
}

echo "== valid report: the seam must still run"
set +e
AXOLOTY_PREPARATION_REPORT="$report" "$script_dir/run-zenoh-host-test.sh" >"$work/valid.log" 2>&1
valid_status=$?
set -e
case "$valid_status" in
    0) echo "ok   the unmutated report passes the seam" ;;
    # 69 is the seam's "could not run": a missing compiler or an unproducible
    # report. That is this check's 69 too, and it must not be reported as a
    # contract failure, nor as a pass.
    69)
        echo "check-zenoh-report-validation: the Zenoh seam could not run here" >&2
        cat "$work/valid.log" >&2
        exit 69
        ;;
    *)
        echo "check-zenoh-report-validation: the unmutated report did not pass the seam" >&2
        cat "$work/valid.log" >&2
        exit 1
        ;;
esac

echo "== malformed reports: the seam must refuse each one"
expect_failure no-checksum \
    "a report with no zenohCore.facadeHeaderSHA256" \
    "drop:zenohCore.facadeHeaderSHA256"
expect_failure no-module-map \
    "a report with no zenohCore.moduleMap" \
    "drop:zenohCore.moduleMap"
expect_failure short-checksum \
    "a report whose digest is not 64 characters" \
    "replace:zenohCore.facadeHeaderSHA256:abc123"
expect_failure uppercase-checksum \
    "a report whose digest is not lowercase hexadecimal" \
    "upper:zenohCore.facadeHeaderSHA256"
expect_failure wrong-checksum \
    "a report whose digest does not match the header" \
    "retag:zenohCore.facadeHeaderSHA256"
expect_failure noncanonical-header \
    "a report that spells the header path non-canonically" \
    "dot-segment:zenohCore.facadeHeader"
expect_failure noncanonical-module-map \
    "a report that spells the module map non-canonically" \
    "dot-segment:zenohCore.moduleMap"
expect_failure header-outside-core \
    "a byte-identical header outside the Core checkout it names" \
    "outside-header"
expect_failure module-map-outside-scratch \
    "a real module map outside caller-owned scratch" \
    "outside-module-map"
expect_failure module-map-is-a-directory \
    "a report whose module map names a directory" \
    "module-map-directory"
expect_failure header-is-a-directory \
    "a report whose header names a directory" \
    "header-directory"
expect_failure relative-header \
    "a report whose header is a relative path" \
    "replace:zenohCore.facadeHeader:axoloty_zenoh.h"
expect_failure relative-module-map \
    "a report whose module map is a relative path" \
    "replace:zenohCore.moduleMap:module.modulemap"

echo "check-zenoh-report-validation: passed"
