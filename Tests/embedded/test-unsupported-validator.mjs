// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

// Focused hardware-free checks for the smoke validator's unsupported status.

import assert from "node:assert/strict";
import { checksum } from "../../Platforms/esp32c6-idf/tools/validate-smoke.mjs";
import {
  createEmbeddedZenohNetworkValidator,
  expectedZenohNetworkTests,
} from "./network-validator.mjs";

const unsupportedCases = new Set([
  "network:lastWillUnsupported",
  "network:receiveUnsupported",
]);

const createStream = (statuses, counts) => {
  const lines = [];
  let sequence = 0;
  let previousChecksum = 0;
  const append = (caseId, operation, stage, status, recordCounts) => {
    const record = {
      schemaVersion: 2,
      runId: "embedded-swift-smoke-v2",
      sequence,
      caseId,
      operation,
      stage,
      status,
    };
    if (recordCounts) record.counts = recordCounts;
    record.checksum = checksum(record, previousChecksum);
    previousChecksum = record.checksum;
    sequence += 1;
    lines.push(JSON.stringify(record));
  };

  append("boot", "boot", "boot", "started");
  for (const caseId of expectedZenohNetworkTests) {
    append(caseId, "smokeCheck", "execute", statuses.get(caseId) ?? "passed");
  }
  append("summary", "summary", "summary", "completed", counts);
  const completion = {
    schemaVersion: 2,
    runId: "embedded-swift-smoke-v2",
    sequence,
    caseId: "completion",
    operation: "complete",
    stage: "completion",
    status: "completed",
    counts,
  };
  completion.checksum = checksum(completion, previousChecksum);
  completion.finalChecksum = completion.checksum;
  lines.push(JSON.stringify(completion));
  return lines;
};

const unsupportedStatuses = new Map([...unsupportedCases].map(caseId => [caseId, "unsupported"]));
const expectedCounts = {
  passed: expectedZenohNetworkTests.size - unsupportedCases.size,
  failed: 0,
  unsupported: unsupportedCases.size,
};
const validator = createEmbeddedZenohNetworkValidator();
for (const line of createStream(unsupportedStatuses, expectedCounts)) {
  validator.observe(line);
}
assert.deepEqual(validator.result().counts, expectedCounts,
  "the actual Zenoh network profile validator counts unsupported cases separately");

const oldPassStatuses = new Map([...unsupportedCases].map(caseId => [caseId, "passed"]));
const forgedPassCounts = {
  passed: expectedZenohNetworkTests.size,
  failed: 0,
  unsupported: unsupportedCases.size,
};
const rejectsPassAsUnsupported = createEmbeddedZenohNetworkValidator();
for (const line of createStream(oldPassStatuses, forgedPassCounts)) {
  rejectsPassAsUnsupported.observe(line);
}
assert.equal(rejectsPassAsUnsupported.result().passed, false,
  "old pass-as-unsupported records are rejected");

const unknownUnsupported = new Map([["network:publish", "unsupported"]]);
const rejectsUnsupportedPublish = createEmbeddedZenohNetworkValidator();
for (const line of createStream(unknownUnsupported, {
  passed: expectedZenohNetworkTests.size - 1,
  failed: 0,
  unsupported: 1,
})) {
  rejectsUnsupportedPublish.observe(line);
}
assert.equal(rejectsUnsupportedPublish.result().passed, false,
  "profile validator rejects unsupported statuses outside the declared capabilities");

console.log("profile-specific unsupported network validation tests passed");
