// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

// A smoke run that hit the monitor deadline before the device finished reads as
// a deadline expiry, not as a device failure (#116). A failure the device
// reported stays a device failure.

import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { classifyDeadlineExpiry, failureResult } from "../../Platforms/esp32c6-idf/tools/validate-smoke.mjs";
import { deviceEvidenceRecord } from "./write-device-evidence.mjs";

const deadline = { end: "deadline", deadlineSeconds: 120 };

const expired = classifyDeadlineExpiry(failureResult("summary", "missing summary record"), deadline);
assert.equal(expired.passed, false);
assert.equal(expired.deadlineExpired, true);
assert.match(expired.diagnostic, /^monitor deadline of 120 s expired before the device finished: missing summary record$/);
assert.equal(expired.reason, expired.diagnostic);
assert.equal(expired.stage, "summary");

// Not an expiry: the device reported the failure, or the monitor ended another way.
const reported = failureResult("execute", "failed test record: x");
assert.equal(classifyDeadlineExpiry(reported, deadline), reported);
const early = failureResult("summary", "missing summary record");
assert.equal(classifyDeadlineExpiry(early, { end: "failed", deadlineSeconds: 120 }), early);
assert.equal(classifyDeadlineExpiry(early, undefined), early);
const ok = { passed: true, reason: "ok" };
assert.equal(classifyDeadlineExpiry(ok, deadline), ok);

// The command line path: a truncated log with a deadline end says so in its result.
const dir = fs.mkdtempSync(path.join(os.tmpdir(), "monitor-deadline-"));
const log = path.join(dir, "serial.log");
const resultPath = path.join(dir, "result.json");
fs.writeFileSync(log, "I (100) boot: nothing structured yet\n");
const tool = path.resolve(import.meta.dirname, "../../Platforms/esp32c6-idf/tools/validate-smoke.mjs");
const run = (env) => {
  try {
    execFileSync("node", [tool, log, resultPath, "test-device", "120"], { env: { ...process.env, ...env }, stdio: "pipe" });
  } catch { /* a failed validation exits nonzero; the result file is the output */ }
  return JSON.parse(fs.readFileSync(resultPath, "utf8"));
};
const withDeadline = run({ EMBEDDED_MONITOR_END: "deadline", EMBEDDED_MONITOR_ELAPSED: "120" });
assert.match(withDeadline.validation.diagnostic, /monitor deadline of 120 s expired/);
assert.deepEqual(withDeadline.monitor, { end: "deadline", deadlineSeconds: 120, elapsedSeconds: 120 });
const bare = run({ EMBEDDED_MONITOR_END: "", EMBEDDED_MONITOR_ELAPSED: "" });
assert.equal(bare.validation.diagnostic, "missing boot record");
assert.equal(bare.monitor, undefined);
fs.rmSync(dir, { recursive: true, force: true });

// The evidence record carries the deadline and the time the run needed.
const proof = {
  result: "passed", firmwareSha256: "a".repeat(64), coreSha: "b".repeat(40),
  smoke: { validation: { passed: true, counts: { passed: 3 } }, monitor: { end: "completed", deadlineSeconds: 240, elapsedSeconds: 97 } },
};
const record = deviceEvidenceRecord(proof, { device: "unit" }, { profile: "p", check: "c", cases: "cases" });
assert.equal(record.monitorDeadlineSeconds, 240);
assert.equal(record.monitorElapsedSeconds, 97);
delete proof.smoke.monitor;
assert.equal("monitorDeadlineSeconds" in deviceEvidenceRecord(proof, { device: "unit" }, { profile: "p", check: "c", cases: "cases" }), false);

console.log("monitor-deadline: all checks passed");
