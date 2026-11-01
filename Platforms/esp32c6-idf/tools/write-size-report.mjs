// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

// Writes the build-stage size report for a linked image and enforces the
// profile's build budgets. The report lands beside the artifact as `size.json`,
// where the release manifest generator picks it up as `resources`.
//
// Usage: write-size-report.mjs <elf> <bin> <partitions.csv> <profile.json> <policy.json> <preparation.json> <sdkconfig> <network-state> <output> [size-tool]
//
// <network-state> is `configured`, `placeholder`, or `unconfigured`: whether the
// image was built with an operator network header, with the sizing-only
// placeholder, or without one (and so without the network stack).
//
// Exit status: 0 within budget or not applicable, 1 a budget was exceeded or
// the inputs are unusable, 64 bad usage.

import { execFileSync } from "node:child_process";
import crypto from "node:crypto";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

/** The metrics a profile may budget, in report order. */
export const BUDGET_METRICS = ["imageBytes", "flashTextBytes", "staticRamBytes", "dramBssBytes"];

/** The runtime floors a profile may declare; a device run enforces them, not the build. */
export const RUNTIME_METRICS = ["minimumFreeHeapBytes", "stackRemainingBytes"];

/** Parses `size -A` output into a map from section name to byte size. */
export function parseSizeA(text) {
  const sections = new Map();
  const lines = text.split(/\r?\n/);
  const header = lines.findIndex(line => /^section\s+size\s+addr\s*$/.test(line));
  if (header < 0) throw new Error("missing size -A section header");
  let ended = false;
  for (const line of lines.slice(header + 1)) {
    if (!line.trim()) continue;
    const total = /^Total\s+(\d+)\s*$/.exec(line);
    if (total && !ended) {
      if (!Number.isSafeInteger(Number(total[1]))) throw new Error("unsafe total integer");
      ended = true;
      continue;
    }
    if (ended) throw new Error("unexpected data after size -A total");
    const match = /^\s*(\.\S+)\s+(\d+)\s+(\d+)\s*$/.exec(line);
    if (!match) throw new Error(`malformed section row: ${line}`);
    const size = Number(match[2]);
    const address = Number(match[3]);
    if (!Number.isSafeInteger(size) || !Number.isSafeInteger(address)) throw new Error("unsafe section integer");
    if (sections.has(match[1])) throw new Error(`duplicate section: ${match[1]}`);
    sections.set(match[1], size);
  }
  if (!ended) throw new Error("missing size -A total");
  for (const name of [".iram0.text", ".dram0.data", ".dram0.bss", ".flash.text", ".flash.rodata"]) {
    if (!sections.has(name)) throw new Error(`missing required section: ${name}`);
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

/** The network states a build can report. */
export const NETWORK_STATES = ["configured", "placeholder", "unconfigured"];

/**
 * Identifies the build configuration a measurement belongs to: the profile's
 * named configuration, or `default`, the checksum of the resolved sdkconfig,
 * and whether the image links the network stack. A placeholder image is sized
 * with a non-secret stand-in header and is never device evidence.
 */
export function buildConfiguration(profile, sdkconfigText, networkState) {
  if (!NETWORK_STATES.includes(networkState)) throw new Error("invalid network state");
  if (typeof sdkconfigText !== "string" || !sdkconfigText) throw new Error("sdkconfig is required");
  if (profile.configuration !== undefined && (typeof profile.configuration !== "string" || !profile.configuration.trim())) throw new Error("invalid configuration name");
  return {
    name: profile.configuration ?? "default",
    sdkconfigSha256: crypto.createHash("sha256").update(sdkconfigText).digest("hex"),
    networkConfigured: networkState !== "unconfigured",
    ...(networkState === "placeholder" ? { networkPlaceholder: true } : {}),
  };
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
export function buildReport({ sizeText, sdkconfigText, networkState, imageBytes, imageSha256, partitionBytes, profile, policy, coreRevision }) {
  for (const [name, value] of Object.entries({ imageBytes, partitionBytes })) {
    if (!Number.isSafeInteger(value) || value <= 0) throw new Error(`${name} must be a positive safe integer`);
  }
  if (!/^[0-9a-f]{64}$/.test(imageSha256 ?? "")) throw new Error("image SHA-256 is required");
  if (!/^[0-9a-f]{40}$/.test(coreRevision ?? "")) throw new Error("prepared Core revision is required");
  if (!["name", "application", "platform", "transport"].every(key => typeof profile[key] === "string" && profile[key].trim())) throw new Error("profile identity is incomplete");
  if (!policy || policy.schema !== "axoloty.app-static-storage-policy.v1" || policy.profile !== profile.name || !["enforced", "not-configured", "not-applicable"].includes(policy.status) || (policy.status === "not-applicable" && policy.reason !== "configured C-only carrier qualification image")) throw new Error("invalid static storage policy");
  if (profile.budgets !== undefined && (profile.budgets === null || typeof profile.budgets !== "object" || Array.isArray(profile.budgets))) throw new Error("invalid budgets object");
  if (profile.budgets && (Object.keys(profile.budgets).some(key => !["basis", "build", "runtime"].includes(key)) || (profile.budgets.basis !== undefined && (typeof profile.budgets.basis !== "string" || !profile.budgets.basis.trim())))) throw new Error("invalid budgets object");
  const runtime = profile.budgets?.runtime;
  if (runtime !== undefined && (runtime === null || typeof runtime !== "object" || Array.isArray(runtime) || !Object.keys(runtime).length || Object.entries(runtime).some(([key, value]) => !RUNTIME_METRICS.includes(key) || !Number.isSafeInteger(value) || value <= 0))) throw new Error("invalid runtime budgets");
  const build = profile.budgets?.build;
  if (build !== undefined && (build === null || typeof build !== "object" || Array.isArray(build) || !Object.keys(build).length || Object.entries(build).some(([key, value]) => !BUDGET_METRICS.includes(key) || !Number.isSafeInteger(value) || value <= 0))) throw new Error("invalid build budgets");
  if (policy.status === "not-applicable" && profile.transport !== "zenoh-pico") throw new Error("C-only qualification requires zenoh-pico");
  const identity = {
    profile: profile.name,
    application: profile.application,
    platform: profile.platform,
    transport: profile.transport,
    coreRevision,
    configuration: buildConfiguration(profile, sdkconfigText, networkState),
  };
  const metrics = computeMetrics(parseSizeA(sizeText), imageBytes);
  if (Object.values(metrics).some(value => !Number.isSafeInteger(value) || value < 0)) throw new Error("unsafe metric");
  const image = {
    bytes: imageBytes,
    sha256: imageSha256,
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
  const [elf, bin, partitions, profilePath, policyPath, preparationPath, sdkconfig, networkState, output, explicitTool] = process.argv.slice(2);
  if (![elf, bin, partitions, profilePath, policyPath, preparationPath, sdkconfig, networkState, output].every(Boolean)) {
    console.error("usage: write-size-report.mjs elf bin partitions.csv profile.json policy.json preparation.json sdkconfig network-state output [size-tool]");
    process.exit(64);
  }
  // Never truncate or remove an input through a path, symlink, or hard-link alias.
  const inputs = [elf, bin, partitions, profilePath, policyPath, preparationPath, sdkconfig, ...(explicitTool ? [explicitTool] : [])];
  const outputResolved = path.resolve(output);
  const outputStat = fs.existsSync(output) ? fs.statSync(output) : null;
  for (const input of inputs) {
    if (!fs.existsSync(input)) continue;
    const inputStat = fs.statSync(input);
    if (fs.realpathSync(input) === outputResolved || (outputStat && inputStat.dev === outputStat.dev && inputStat.ino === outputStat.ino)) throw new Error("output aliases an input");
  }
  if (fs.existsSync(output) || fs.lstatSync(output, { throwIfNoEntry: false })) {
    if (!fs.lstatSync(output).isFile()) throw new Error("output must be a regular file");
    fs.unlinkSync(output);
  }
  const preparation = JSON.parse(fs.readFileSync(preparationPath, "utf8"));
  if (preparation.schemaVersion !== 1 || preparation.status !== "prepared") throw new Error("Core preparation report is invalid");
  const profile = JSON.parse(fs.readFileSync(profilePath, "utf8"));
  const policy = fs.existsSync(policyPath) ? JSON.parse(fs.readFileSync(policyPath, "utf8")) : null;
  const sizeText = execFileSync(locateSizeTool(explicitTool), ["-A", elf], { encoding: "utf8" });
  const report = buildReport({
    sizeText,
    sdkconfigText: fs.readFileSync(sdkconfig, "utf8"),
    networkState,
    imageBytes: fs.statSync(bin).size,
    imageSha256: crypto.createHash("sha256").update(fs.readFileSync(bin)).digest("hex"),
    coreRevision: preparation.core?.sha,
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
