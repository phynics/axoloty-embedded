// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

// A run that does not pass must never replace a passed tracked record (#117).

import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { writeEvidenceRecord } from "./evidence-record.mjs";
import { unexecutedEvidenceRecord, writeUnexecutedEvidence } from "./write-unexecuted-evidence.mjs";

const root = fs.mkdtempSync(path.join(os.tmpdir(), "evidence-record-"));
const withheldDir = path.join(root, "withheld");
const target = path.join(root, "docs", "evidence", "profile-check.json");
const read = (file) => JSON.parse(fs.readFileSync(file, "utf8"));
const passed = { schemaVersion: 1, profile: "p", check: "c", status: "passed", result: "1/1 passed" };
const quiet = (action) => {
  const original = console.error;
  console.error = () => {};
  try { return action(); } finally { console.error = original; }
};

// A first record is written whatever its status.
assert.equal(writeEvidenceRecord({ ...passed, status: "unexecuted", reason: "r" }, target, { withheldDir }).written, true);
assert.equal(read(target).status, "unexecuted");

// Unexecuted and failed records replace one another; a passed record replaces both.
assert.equal(writeEvidenceRecord({ ...passed, status: "failed", result: "x" }, target, { withheldDir }).written, true);
assert.equal(writeEvidenceRecord(passed, target, { withheldDir }).written, true);
assert.equal(read(target).status, "passed");

// A passed record is replaced by a passed one (a new proof), never by a failure or a non-run.
assert.equal(writeEvidenceRecord({ ...passed, result: "2/2 passed" }, target, { withheldDir }).written, true);
for (const status of ["failed", "unexecuted"]) {
  const result = quiet(() => writeEvidenceRecord({ ...passed, status, reason: "r", result: "x" }, target, { withheldDir }));
  assert.equal(result.written, false);
  assert.equal(read(target).status, "passed");
  assert.equal(read(target).result, "2/2 passed");
  assert.equal(read(path.join(withheldDir, "profile-check.json")).status, status);
}

// The unexecuted writer goes through the same rule.
const outcome = quiet(() => writeUnexecutedEvidence(
  unexecutedEvidenceRecord({ profile: "p", check: "c", reason: "the board vanished" }), target));
assert.notEqual(outcome, target);
assert.equal(read(target).status, "passed");
fs.rmSync(path.dirname(outcome), { recursive: true, force: true });

// The default withheld location is outside the tracked directory.
assert.ok(!outcome.startsWith(path.dirname(target)));

fs.rmSync(root, { recursive: true, force: true });
console.log("evidence-record: all checks passed");
