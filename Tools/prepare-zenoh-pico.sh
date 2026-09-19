#!/bin/sh
# Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

# Fetch the pinned zenoh-pico revision into scratch and write a preparation
# report the ESP-IDF component wrapper reads.
#
# This mirrors Tools/prepare-core.sh: the build never fetches, and the report
# is the only source of the prepared checkout path and revision. Run it before
# building the esp32c6-zenoh profile.
#
# The pin lives in Platforms/esp32c6-idf/dependencies/zenoh-pico.lock.json. Its
# version and revision come from phynics/axoloty issue #797
# (docs/dependencies/zenoh.md); this repository does not choose them.
#
# Environment:
#   AXOLOTY_SCRATCH   Scratch root. Default: <repo>/.axoloty
#
# Exit status: 0 prepared, 1 fetch or pin mismatch, 64 bad usage,
# 69 git or node missing.

set -eu

script_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
repo_root=$(git -C "$script_dir" rev-parse --show-toplevel)
lock="$repo_root/Platforms/esp32c6-idf/dependencies/zenoh-pico.lock.json"
scratch=${AXOLOTY_SCRATCH:-"$repo_root/.axoloty"}
checkout="$scratch/zenoh-pico"
report="$scratch/zenoh-pico-preparation.json"

if ! command -v git >/dev/null 2>&1; then
    echo "prepare-zenoh-pico: git is required to fetch the pinned revision" >&2
    exit 69
fi
if ! command -v node >/dev/null 2>&1; then
    echo "prepare-zenoh-pico: node is required to read the pin and write the report" >&2
    exit 69
fi
if [ ! -f "$lock" ]; then
    echo "prepare-zenoh-pico: the pin is missing: $lock" >&2
    exit 64
fi

read_pin() {
    node -e 'const p = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8")); process.stdout.write(String(p[process.argv[2]] ?? ""));' \
        "$lock" "$1"
}

url=$(read_pin url)
version=$(read_pin version)
revision=$(read_pin revision)
license=$(read_pin license)
if [ -z "$url" ] || [ -z "$version" ] ||
    ! printf '%s' "$revision" | grep -Eq '^[0-9a-f]{40}$'; then
    echo "prepare-zenoh-pico: the pin is malformed: $lock" >&2
    exit 64
fi

mkdir -p "$scratch"
if [ ! -d "$checkout/.git" ]; then
    rm -rf "$checkout"
    git init --quiet "$checkout"
    git -C "$checkout" remote add origin "$url"
fi
git -C "$checkout" remote set-url origin "$url"
if ! git -C "$checkout" fetch --quiet --depth 1 origin "$revision"; then
    echo "prepare-zenoh-pico: could not fetch $revision from $url" >&2
    exit 1
fi
git -C "$checkout" checkout --quiet --detach FETCH_HEAD

actual=$(git -C "$checkout" rev-parse HEAD)
if [ "$actual" != "$revision" ]; then
    echo "prepare-zenoh-pico: fetched $actual, expected the pinned $revision" >&2
    exit 1
fi

LOCK_PATH="$lock" CHECKOUT="$checkout" REPORT="$report" \
    VERSION="$version" REVISION="$revision" LICENSE="$license" \
    node --input-type=module <<'JS'
import crypto from "node:crypto";
import fs from "node:fs";
import path from "node:path";

const record = {
  schemaVersion: 1,
  status: "prepared",
  component: "eclipse-zenoh/zenoh-pico",
  version: process.env.VERSION,
  revision: process.env.REVISION,
  license: process.env.LICENSE,
  sourceDir: path.resolve(process.env.CHECKOUT),
  pinPath: path.relative(path.resolve(path.dirname(process.env.REPORT)), process.env.LOCK_PATH),
  pinSha256: crypto.createHash("sha256").update(fs.readFileSync(process.env.LOCK_PATH)).digest("hex"),
};
const temporary = `${process.env.REPORT}.tmp-${process.pid}`;
fs.writeFileSync(temporary, `${JSON.stringify(record, null, 2)}\n`, { mode: 0o644 });
fs.renameSync(temporary, process.env.REPORT);
JS

echo "zenoh-pico prepared"
echo "  revision: $revision"
echo "  checkout: $checkout"
echo "  report: $report"
