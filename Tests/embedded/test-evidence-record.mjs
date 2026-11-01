// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

// What a run that does not pass may do to a tracked record (#117), including the
// two ways the first version of this rule was unsafe: a failure on a new image
// must not leave the proof of an old one certifiable, and one withheld attempt
// must not erase another.

import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { failureSidecarPath, writeEvidenceRecord } from "./evidence-record.mjs";
import { unexecutedEvidenceRecord, writeUnexecutedEvidence } from "./write-unexecuted-evidence.mjs";

const root = fs.mkdtempSync(path.join(os.tmpdir(), "evidence-record-"));
const withheldDir = path.join(root, "withheld");
const target = path.join(root, "docs", "evidence", "profile-check.json");
const sidecar = failureSidecarPath(target);
const read = (file) => JSON.parse(fs.readFileSync(file, "utf8"));
const record = (status, extra = {}) => ({ schemaVersion: 1, profile: "p", check: "c", status, ...extra });
const quiet = (action) => {
  const original = console.error;
  console.error = () => {};
  try { return action(); } finally { console.error = original; }
};
const write = (candidate) => quiet(() => writeEvidenceRecord(candidate, target, { withheldDir }));

assert.equal(sidecar, path.join(root, "docs", "evidence", "profile-check.failed.json"));

// A first record is written whatever its status; unexecuted and failed replace each other.
assert.equal(write(record("unexecuted", { reason: "r" })).written, true);
assert.equal(read(target).status, "unexecuted");
assert.equal(write(record("failed", { result: "x" })).written, true);
assert.equal(read(target).status, "failed");
assert.equal(fs.existsSync(sidecar), false);

// A passed record replaces both.
assert.equal(write(record("passed", { result: "1/1 passed", firmwareSHA256: "a".repeat(64) })).written, true);
assert.equal(read(target).result, "1/1 passed");
assert.equal(write(record("passed", { result: "2/2 passed", firmwareSHA256: "a".repeat(64) })).written, true);

// A failure on another image keeps the old proof and is carried beside it, where
// the release manifest generator reads it as a failed record for the check.
const failure = write(record("failed", { result: "image B failed", firmwareSHA256: "b".repeat(64) }));
assert.equal(failure.written, true);
assert.equal(failure.path, sidecar);
assert.equal(read(target).result, "2/2 passed");
assert.equal(read(sidecar).firmwareSHA256, "b".repeat(64));

// An unexecuted attempt afterwards changes neither, and a second one does not
// erase the first: every withheld record has a name of its own.
const first = write(record("unexecuted", { reason: "first" }));
const instant = new Date("2026-11-01T12:00:00.000Z");
const at = (reason) => quiet(() => writeEvidenceRecord(record("unexecuted", { reason }), target, { withheldDir, now: () => instant }));
const third = at("same instant, once");
const fourth = at("same instant, twice");
assert.notEqual(third.path, fourth.path);
assert.equal(read(third.path).reason, "same instant, once");
assert.equal(read(fourth.path).reason, "same instant, twice");
const second = write(record("unexecuted", { reason: "second" }));
assert.equal(first.written, false);
assert.equal(second.written, false);
assert.notEqual(first.path, second.path);
assert.equal(read(first.path).reason, "first");
assert.equal(read(second.path).reason, "second");
assert.equal(read(target).result, "2/2 passed");
assert.equal(read(sidecar).result, "image B failed");

assert.equal(fs.readdirSync(withheldDir).length, 4);

// A later pass clears the failure.
assert.equal(write(record("passed", { result: "3/3 passed", firmwareSHA256: "b".repeat(64) })).written, true);
assert.equal(fs.existsSync(sidecar), false);
assert.equal(read(target).result, "3/3 passed");

// The unexecuted writer goes through the same rule and never touches a passed record.
const outcome = quiet(() => writeUnexecutedEvidence(
  unexecutedEvidenceRecord({ profile: "p", check: "c", reason: "the board vanished" }), target));
assert.notEqual(outcome, target);
assert.equal(read(target).status, "passed");
assert.ok(!outcome.startsWith(path.dirname(target)));
fs.rmSync(path.dirname(outcome), { recursive: true, force: true });

fs.rmSync(root, { recursive: true, force: true });
console.log("evidence-record: all checks passed");
