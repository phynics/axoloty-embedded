// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

// Writes the build-stage size report for a linked image and enforces the
// profile's build budgets. The report lands beside the artifact as `size.json`,
// where the release manifest generator picks it up as `resources`.
//
// Usage: write-size-report.mjs <elf> <bin> <partitions.csv> <profile.json> <policy.json> <output> [size-tool]
//
// Exit status: 0 within budget or not applicable, 1 a budget was exceeded or
// the inputs are unusable, 64 bad usage.

import { execFileSync } from "node:child_process";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

/** The metrics a profile may budget, in report order. */
export const BUDGET_METRICS = ["imageBytes", "flashTextBytes", "staticRamBytes", "dramBssBytes"];

/** Parses `size -A` output into a map from section name to byte size. */
export function parseSizeA(text) {
  const sections = new Map();
  for (const line of text.split(/\r?\n/)) {
    const match = /^(\.\S+)\s+(\d+)\s+(\d+)\s*$/.exec(line);
    if (match) sections.set(match[1], Number(match[2]));
  }
  return sections;
}

/** Sums the named sections; a missing section counts as zero. */
const sum = (sections, names) => names.reduce((total, name) => total + (sections.get(name) ?? 0), 0);

/**
 * Derives the reported metrics from section sizes and the image size.
 *
 * `staticRamBytes` is the instruction RAM, initialized data, zero-initialized
 * data, and no-init sections together, the figure #63 calls static D/IRAM.
 */
export function computeMetrics(sections, imageBytes) {
  const iramTextBytes = sum(sections, [".iram0.text", ".iram0.text_end"]);
  const iramDataBytes = sum(sections, [".iram0.data"]);
  const dramDataBytes = sum(sections, [".dram0.data"]);
  const dramBssBytes = sum(sections, [".dram0.bss"]);
  const noinitBytes = sum(sections, [".noinit"]);
  return {
    imageBytes,
    flashTextBytes: sum(sections, [".flash.text"]),
    flashRodataBytes: sum(sections, [".flash.rodata", ".flash.appdesc"]),
    iramTextBytes,
    initializedDataBytes: iramDataBytes + dramDataBytes,
    dramBssBytes: dramBssBytes + noinitBytes,
    staticRamBytes: iramTextBytes + iramDataBytes + dramDataBytes + dramBssBytes + noinitBytes,
  };
}

/** Reads the size of the factory application partition from a partition table. */
export function appPartitionBytes(csvText) {
  for (const line of csvText.split(/\r?\n/)) {
    const fields = line.split(",").map(field => field.trim());
    if (fields.length >= 5 && fields[1] === "app" && /^(factory|ota_0)$/.test(fields[2])) {
      return Number(fields[4]);
    }
  }
  throw new Error("the partition table has no factory application partition");
}

/** Compares measured metrics with the declared budgets. */
export function verdicts(metrics, budgets) {
  return BUDGET_METRICS.filter(metric => budgets[metric] !== undefined).map(metric => ({
    metric,
    measured: metrics[metric],
    budget: budgets[metric],
    headroomBytes: budgets[metric] - metrics[metric],
    passed: metrics[metric] <= budgets[metric],
  }));
}

/** Finds the toolchain's `size` program. */
function locateSizeTool(explicit) {
  if (explicit) return explicit;
  const roots = [process.env.IDF_TOOLS_PATH, "/opt/esp/tools"].filter(Boolean);
  for (const root of roots) {
    const base = path.join(root, "tools", "riscv32-esp-elf");
    if (!fs.existsSync(base)) continue;
    for (const version of fs.readdirSync(base)) {
      const candidate = path.join(base, version, "riscv32-esp-elf", "bin", "riscv32-esp-elf-size");
      if (fs.existsSync(candidate)) return candidate;
    }
  }
  return "riscv32-esp-elf-size";
}

/** Builds the report for one image. */
export function buildReport({ sizeText, imageBytes, partitionBytes, profile, policy }) {
  const identity = {
    profile: profile.name,
    application: profile.application,
    platform: profile.platform,
    transport: profile.transport,
    coreRevision: profile.core?.revision ?? null,
  };
  const metrics = computeMetrics(parseSizeA(sizeText), imageBytes);
  const image = {
    bytes: imageBytes,
    appPartitionBytes: partitionBytes,
    partitionHeadroomBytes: partitionBytes - imageBytes,
  };
  const budgets = profile.budgets?.build ?? null;
  const basis = profile.budgets?.basis ?? null;
  if (policy?.status === "not-applicable") {
    return {
      schemaVersion: 1,
      kind: "build-size",
      ...identity,
      metrics,
      image,
      budgets: null,
      enforcement: { status: "not-applicable", reason: policy.reason ?? "the image is a configured qualification variant" },
    };
  }
  if (!budgets) {
    return {
      schemaVersion: 1,
      kind: "build-size",
      ...identity,
      metrics,
      image,
      budgets: null,
      enforcement: { status: "not-configured", reason: "the profile declares no build budgets" },
    };
  }
  const results = verdicts(metrics, budgets);
  return {
    schemaVersion: 1,
    kind: "build-size",
    ...identity,
    metrics,
    image,
    budgets: { basis, build: budgets },
    enforcement: { status: results.every(result => result.passed) ? "passed" : "failed", results },
  };
}

function main() {
  const [elf, bin, partitions, profilePath, policyPath, output, explicitTool] = process.argv.slice(2);
  if (![elf, bin, partitions, profilePath, policyPath, output].every(Boolean)) {
    console.error("usage: write-size-report.mjs elf bin partitions.csv profile.json policy.json output [size-tool]");
    process.exit(64);
  }
  const profile = JSON.parse(fs.readFileSync(profilePath, "utf8"));
  const policy = fs.existsSync(policyPath) ? JSON.parse(fs.readFileSync(policyPath, "utf8")) : null;
  const sizeText = execFileSync(locateSizeTool(explicitTool), ["-A", elf], { encoding: "utf8" });
  const report = buildReport({
    sizeText,
    imageBytes: fs.statSync(bin).size,
    partitionBytes: appPartitionBytes(fs.readFileSync(partitions, "utf8")),
    profile,
    policy,
  });
  fs.writeFileSync(output, `${JSON.stringify(report, null, 2)}\n`);
  const status = report.enforcement.status;
  if (status === "passed") {
    console.log(`size budget: ${report.enforcement.results.length} metrics within budget`);
  } else if (status === "failed") {
    for (const result of report.enforcement.results.filter(entry => !entry.passed)) {
      console.error(`size budget exceeded: ${result.metric} is ${result.measured} B against a budget of ${result.budget} B`);
    }
    process.exit(1);
  } else {
    console.log(`size budget: ${status}${report.enforcement.reason ? ` (${report.enforcement.reason})` : ""}`);
  }
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) main();
