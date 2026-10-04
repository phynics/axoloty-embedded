// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

// The C-only carrier scenario stream, selected by the device harness through
// EMBEDDED_VALIDATOR and EMBEDDED_VALIDATOR_FACTORY.
//
// It validates the same JSON Lines shape as the host check, but a device run
// cannot drive every step, so it accepts `unavailable` for the steps a bare
// device cannot force. It never accepts a missing or failed step: a step that
// was not driven is counted, not passed off as a pass.

import { validateCarrierRun } from "./validate-carrier-runner.mjs";

/** Creates the validator for the C-only carrier scenario device stream. */
export function createEmbeddedCarrierScenarioValidator() {
  const lines = [];
  return {
    observe(line) {
      if (typeof line === "string" && line.trim().length > 0) {
        lines.push(line.trim());
      }
      return false;
    },
    result() {
      const validation = validateCarrierRun(lines, { allowUnavailable: true });
      const counts = {
        passed: validation.passedCount,
        failed: validation.failedCount,
        unavailable: validation.unavailableCount,
      };
      const unavailableSteps = [];
      for (const line of lines) {
        if (!line.startsWith("{")) continue;
        let record;
        try {
          record = JSON.parse(line);
        } catch {
          continue;
        }
        if (record.scenario !== "axoloty-zenoh-carrier" || record.step === "summary") continue;
        if (record.result === "unavailable") unavailableSteps.push(record.step);
      }
      if (validation.passed) {
        return {
          passed: true,
          reason: `carrier scenario validated: ${counts.passed} passed, ${counts.unavailable} unavailable, ${counts.failed} failed`,
          counts,
          unavailableSteps,
        };
      }
      return {
        passed: false,
        reason: validation.problems.join("; ") || "carrier scenario validation failed",
        counts,
        unavailableSteps,
      };
    },
  };
}
