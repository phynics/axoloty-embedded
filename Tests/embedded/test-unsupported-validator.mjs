// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

// Focused hardware-free checks for the smoke validator's unsupported status.

import assert from "node:assert/strict";
import { createEmbeddedSwiftSmokeValidator, checksum } from "../../Platforms/esp32c6-idf/tools/validate-smoke.mjs";

const allowed = new Set(["capability:will"]);
const validator = createEmbeddedSwiftSmokeValidator(new Set(["capability:will"]), allowed);
let sequence = 0;
let prior = 0;
const send = (caseId, operation, stage, status, counts) => {
  const record = { schemaVersion: 2, runId: "embedded-swift-smoke-v2", sequence, caseId, operation, stage, status };
  if (counts) record.counts = counts;
  record.checksum = checksum(record, prior);
  prior = record.checksum;
  sequence += 1;
  return validator.observe(JSON.stringify(record));
};

assert.equal(send("boot", "boot", "boot", "started"), false);
assert.equal(send("capability:will", "smokeCheck", "execute", "unsupported"), false);
assert.equal(send("summary", "summary", "summary", "completed", { passed: 0, failed: 0, unsupported: 1 }), false);
const completionChecksumInput = {
  schemaVersion: 2,
  runId: "embedded-swift-smoke-v2",
  sequence,
  caseId: "completion",
  operation: "complete",
  stage: "completion",
  status: "completed",
  counts: { passed: 0, failed: 0, unsupported: 1 },
};
completionChecksumInput.checksum = checksum(completionChecksumInput, prior);
completionChecksumInput.finalChecksum = completionChecksumInput.checksum;
assert.equal(validator.observe(JSON.stringify(completionChecksumInput)), true);
assert.deepEqual(validator.result().counts, { passed: 0, failed: 0, unsupported: 1 });

const forbidden = createEmbeddedSwiftSmokeValidator(new Set(["capability:will"]));
const boot = { schemaVersion: 2, runId: "embedded-swift-smoke-v2", sequence: 0,
  caseId: "boot", operation: "boot", stage: "boot", status: "started" };
boot.checksum = checksum(boot, 0);
forbidden.observe(JSON.stringify(boot));
const invalidUnsupported = { schemaVersion: 2, runId: "embedded-swift-smoke-v2", sequence: 1,
  caseId: "capability:will", operation: "smokeCheck", stage: "execute", status: "unsupported" };
invalidUnsupported.checksum = checksum(invalidUnsupported, boot.checksum);
forbidden.observe(JSON.stringify(invalidUnsupported));
assert.equal(forbidden.result().passed, false, "unsupported must be explicitly allowed by a profile validator");

console.log("unsupported smoke status tests passed");
