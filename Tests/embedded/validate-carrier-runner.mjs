// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

// Validates the JSON Lines stream the C-only carrier scenario emits.
//
// It checks structure and completeness, never a numeric threshold: the carrier
// scenario has no observed baseline yet, so a threshold here would be invented
// rather than measured. A step is required; whether its result is acceptable
// is the caller's decision. The host preflight demands every step pass. A
// device caller may pass `--allow-unavailable` so a step the environment could
// not drive is reported as unavailable rather than a failure, and the gate
// then records an unexecuted result.

import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

export const carrierScenarioName = "axoloty-zenoh-carrier";
export const requiredCarrierSteps = Object.freeze([
  "cold_boot",
  "session_state",
  "open_publisher",
  "subscribe",
  "bidirectional_traffic",
  "router_lifecycle",
  "router_absent_then_present",
  "queue_saturation",
  "continuous_traffic",
  "maximum_payload",
  "oversized_payload",
  "clean_shutdown",
  "repeated_reconnect",
]);

const allowedResults = new Set(["pass", "fail", "unavailable"]);

/** Validates parsed-or-raw JSON Lines from the carrier scenario. */
export function validateCarrierRun(lines, options = {}) {
  const allowUnavailable = options.allowUnavailable === true;
  const problems = [];
  const steps = new Map();
  let summary = null;

  for (const raw of lines) {
    const line = typeof raw === "string" ? raw.trim() : "";
    if (line.length === 0 || !line.startsWith("{")) {
      // Device chatter around the JSONL is not part of this stream.
      continue;
    }
    let record;
    try {
      record = JSON.parse(line);
    } catch {
      problems.push(`line is not JSON: ${line.slice(0, 80)}`);
      continue;
    }
    if (record.scenario !== carrierScenarioName) {
      continue;
    }
    if (record.step === "summary") {
      summary = record;
      continue;
    }
    if (typeof record.step !== "string" || !requiredCarrierSteps.includes(record.step)) {
      problems.push(`unknown carrier step: ${String(record.step)}`);
      continue;
    }
    if (steps.has(record.step)) {
      problems.push(`duplicate carrier step: ${record.step}`);
      continue;
    }
    if (!allowedResults.has(record.result)) {
      problems.push(`invalid result for ${record.step}: ${String(record.result)}`);
      continue;
    }
    steps.set(record.step, record);
  }

  for (const step of requiredCarrierSteps) {
    if (!steps.has(step)) {
      problems.push(`missing carrier step: ${step}`);
    }
  }
  if (summary === null) {
    problems.push("missing carrier summary line");
  }

  const observedPassed = [...steps.values()].filter(record => record.result === "pass").length;
  const observedFailed = [...steps.values()].filter(record => record.result === "fail").length;
  const observedUnavailable = [...steps.values()].filter(record => record.result === "unavailable").length;

  if (summary !== null) {
    if (summary.steps !== steps.size) {
      problems.push(`summary.steps ${String(summary.steps)} does not match ${steps.size} observed steps`);
    }
    if (summary.passed !== observedPassed) {
      problems.push(`summary.passed ${String(summary.passed)} does not match ${observedPassed} observed passes`);
    }
    if (summary.failed !== observedFailed) {
      problems.push(`summary.failed ${String(summary.failed)} does not match ${observedFailed} observed failures`);
    }
    if (summary.unavailable !== observedUnavailable) {
      problems.push(`summary.unavailable ${String(summary.unavailable)} does not match ${observedUnavailable} observed unavailable steps`);
    }
    if (!summary.carrier || typeof summary.carrier !== "object" || Array.isArray(summary.carrier)) {
      problems.push("summary carries no carrier counter object");
    }
    if (!summary.resources || typeof summary.resources !== "object" || Array.isArray(summary.resources)) {
      problems.push("summary carries no resources object");
    }
    if (!allowUnavailable && summary.unavailable !== 0) {
      problems.push(`summary reports ${String(summary.unavailable)} unavailable steps`);
    }
  }

  const acceptable = allowUnavailable ? new Set(["pass", "unavailable"]) : new Set(["pass"]);
  for (const step of requiredCarrierSteps) {
    const record = steps.get(step);
    if (record && !acceptable.has(record.result)) {
      problems.push(`required carrier step ${step} is ${record.result}`);
    }
  }

  return {
    passed: problems.length === 0,
    scenario: carrierScenarioName,
    steps: steps.size,
    passedCount: observedPassed,
    failedCount: observedFailed,
    unavailableCount: observedUnavailable,
    problems,
    summary,
  };
}

async function runCLI() {
  const args = process.argv.slice(2);
  const allowUnavailable = args.includes("--allow-unavailable");
  const file = args.find(argument => !argument.startsWith("--"));
  if (!file) {
    console.error("usage: validate-carrier-runner.mjs <jsonl-file> [--allow-unavailable]");
    process.exit(64);
  }
  const lines = fs.readFileSync(file, "utf8").split(/\r?\n/);
  const result = validateCarrierRun(lines, { allowUnavailable });
  process.stdout.write(`${JSON.stringify(result, null, 2)}\n`);
  if (!result.passed) {
    process.exitCode = 1;
  }
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  runCLI().catch(error => {
    console.error(`validate-carrier-runner: ${error.message}`);
    process.exit(1);
  });
}
