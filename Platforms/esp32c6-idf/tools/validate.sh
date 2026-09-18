#!/bin/sh
# Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

# Prepare the locked Core revision and validate its preparation report before
# any firmware build. Core is reached only through Tools/prepare-core.sh; this
# wrapper never discovers Core by path and never reads a Core build directory.
#
# Environment:
#   AXOLOTY_SCRATCH          Scratch root. Default: <repo>/.axoloty
#   AXOLOTY_SOURCE_DIR       Local Core checkout passed through to prepare-core.
#   AXOLOTY_PROOF_RUN_ID     Stable, filesystem-safe run identifier.
#   EMBEDDED_PROOF_ROOT      Caller-owned proof workspace. Default: <scratch>/firmware
#   EMBEDDED_BUILD_DIR       ESP-IDF build directory.
#   EMBEDDED_EVIDENCE_DIR    Evidence output directory.
#
# Exit status: 0 prepared and validated, 1 invariant failure, 64 bad usage,
# 69 missing tool.

set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
platform_dir=$(CDPATH= cd -- "$script_dir/.." && pwd)
repo_root=$(git -C "$script_dir" rev-parse --show-toplevel)

scratch=${AXOLOTY_SCRATCH:-"$repo_root/.axoloty"}
proof_run_id=${AXOLOTY_PROOF_RUN_ID:-manual}
proof_root=${EMBEDDED_PROOF_ROOT:-"$scratch/firmware"}
build_dir=${EMBEDDED_BUILD_DIR:-"$proof_root/build"}
evidence_dir=${EMBEDDED_EVIDENCE_DIR:-"$proof_root/working-evidence"}
source_report="$scratch/core-preparation.json"
preparation="$evidence_dir/preparation.json"
clean_room="$evidence_dir/clean-room.json"

if [ -z "$proof_run_id" ] ||
    ! printf '%s' "$proof_run_id" | grep -Eq '^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$'; then
    echo "error: AXOLOTY_PROOF_RUN_ID must be a stable filesystem-safe identifier" >&2
    exit 64
fi
if [ ! -f "$repo_root/axoloty-core.lock.json" ]; then
    echo "error: axoloty-core.lock.json is missing under $repo_root" >&2
    exit 64
fi
if ! command -v node >/dev/null 2>&1; then
    echo "error: node is required to validate the preparation report" >&2
    exit 69
fi

mkdir -p "$evidence_dir"

# The single supported preparation entry point. It writes
# <scratch>/core-preparation.json and prints the path.
AXOLOTY_SOURCE_DIR=${AXOLOTY_SOURCE_DIR:-} AXOLOTY_SCRATCH="$scratch" \
    AXOLOTY_STRICT_CORE=${AXOLOTY_STRICT_CORE:-} \
    AXOLOTY_PREVIEW_CORE_REVISION=${AXOLOTY_PREVIEW_CORE_REVISION:-} \
    "$repo_root/Tools/prepare-core.sh" > "$evidence_dir/consumer-preparation.stdout"
cp "$source_report" "$preparation"

REPORT="$preparation" PREPARATION_SCRATCH="$scratch" node --input-type=module <<'JS'
import fs from "node:fs";
import path from "node:path";

const reportPath = process.env.REPORT;
const scratch = path.resolve(process.env.PREPARATION_SCRATCH);
const report = JSON.parse(fs.readFileSync(reportPath, "utf8"));
if (report.schemaVersion !== 1 || report.status !== "prepared") {
  throw new Error("the Core preparation report is not a supported prepared report");
}
const expectedPackages = ["AxolotyWire", "AxolotyObjectModel", "AxolotyProtocol", "AxolotyCoatyModels", "AxolotyStaticRuntime"];
if (!Array.isArray(report.portablePackages) || report.portablePackages.length !== expectedPackages.length ||
    report.portablePackages.some((entry, index) => entry?.name !== expectedPackages[index])) {
  throw new Error("the preparation report portable package order is not supported");
}
const coreRoot = path.resolve(report.core.sourceDir);
const under = (root, candidate, label) => {
  if (typeof root !== "string" || typeof candidate !== "string" || !path.isAbsolute(root) || !path.isAbsolute(candidate)) {
    throw new Error(`${label} paths must be absolute`);
  }
  const value = path.relative(root, candidate);
  if (value.startsWith("..") || path.isAbsolute(value)) {
    throw new Error(`${label} escapes its declared root: ${candidate}`);
  }
};
for (const packageInfo of report.portablePackages) under(coreRoot, packageInfo.sourcePath, packageInfo.name);
under(scratch, report.staticRuntimeMacro.scratchDir, "preparation scratch");
under(report.staticRuntimeMacro.scratchDir, report.staticRuntimeMacro.executable, "macro executable");
under(report.staticRuntimeMacro.scratchDir, report.jsonCore.sourceDir, "_JSONCore source");
if (typeof report.jsonCore.revision !== "string" || !/^[0-9a-f]{40}$/.test(report.jsonCore.revision)) {
  throw new Error("preparation report has an invalid _JSONCore revision");
}
console.log(`preparation report is valid for Core ${report.core.sha.slice(0, 12)}`);
JS

# The clean-room proof is Tools/check-invariants.sh, which fails closed. Its
# rule 7b is the private-reference content scan the pre-split wrapper ran with
# ripgrep; moving it into the rule set means it runs on every checkout, not
# only inside this build. The record below cites that rule by name, and is only
# reached when the checker exited zero.
if ! "$repo_root/Tools/check-invariants.sh" > "$evidence_dir/check-invariants.log" 2>&1; then
    cat "$evidence_dir/check-invariants.log" >&2
    echo "error: repository invariants failed; see $evidence_dir/check-invariants.log" >&2
    exit 1
fi

PREPARATION="$preparation" CLEAN_ROOM="$clean_room" PROOF_RUN_ID="$proof_run_id" \
    CORE_ROOT="$(node -p 'require(process.argv[1]).core.sourceDir' "$preparation")" \
    FIRMWARE_ROOT="$repo_root" \
    CHECK_LOG="$evidence_dir/check-invariants.log" node --input-type=module <<'JS'
import fs from "node:fs";
const record = {
  schemaVersion: 1,
  status: "passed",
  coreRoot: process.env.CORE_ROOT,
  firmwareRoot: process.env.FIRMWARE_ROOT,
  portableSourceCopied: false,
  proofRunId: process.env.PROOF_RUN_ID,
  privateReferenceScan: "passed",
  privateReferenceScanRule: "check-invariants.sh rule 7b (private-reference)",
  privateReferenceScanExcluded: "docs/, .testing/, AGENTS.md files, Tools/check-invariants.sh",
  invariantLog: process.env.CHECK_LOG,
  manifest: process.env.PREPARATION,
};
const temporary = `${process.env.CLEAN_ROOM}.tmp-${process.pid}`;
fs.writeFileSync(temporary, `${JSON.stringify(record, null, 2)}\n`, { mode: 0o644 });
fs.renameSync(temporary, process.env.CLEAN_ROOM);
JS

if [ "${EMBEDDED_VALIDATE_FINAL:-0}" = 1 ]; then
    final_proof="$evidence_dir/go-proof.json"
    if [ ! -f "$final_proof" ]; then
        echo "error: final proof is incomplete; go-proof.json is missing" >&2
        exit 1
    fi
    node "$script_dir/validate-go-proof.mjs" \
        "$evidence_dir" "$build_dir" \
        "$(node -p 'require(process.argv[1]).core.sourceDir' "$preparation")" \
        "$repo_root" \
        "$(node -p 'require(process.argv[1]).core.sha' "$preparation")" \
        "$(node -p 'require(process.argv[1]).staticRuntimeMacro.scratchDir' "$preparation")" \
        "${EMBEDDED_DEVICE:-}" "$proof_run_id"
fi

echo "Core preparation validated"
echo "  report: $preparation"
echo "  clean-room evidence: $clean_room"
