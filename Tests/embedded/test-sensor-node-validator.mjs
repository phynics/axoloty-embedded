// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import assert from "node:assert/strict";
import { evaluateSensorRun, parseSensorRecord } from "./sensor-node-validator.mjs";

const sample = (readings, overrides = {}) => ({
  event: "sensor-node-metrics", sessions: 0, readings, resolves: 1, rejected: 0, publishFailures: 0,
  freeHeap: 240000, minimumFreeHeap: 230000, stackRemaining: 20000, stackSize: 32768, ...overrides,
});
const advertised = { event: "sensor-node-advertised" };
const healthy = [advertised, sample(5), sample(10), sample(15)];

// Serial lines may carry a log prefix; other lines are not records.
assert.deepEqual(parseSensorRecord('I (12) app: {"event":"sensor-node-advertised"}\r'), advertised);
assert.equal(parseSensorRecord("I (12) wifi: connected"), null);
assert.equal(parseSensorRecord('{"event":"sensor-node-metrics",'), null);

let result = evaluateSensorRun(healthy);
assert.equal(result.passed, true);
assert.equal(result.metrics.samples, 3);
assert.equal(result.metrics.minimumFreeHeapBytes, 230000);
assert.equal(result.counts.passed, 3);

// The lowest sample decides.
result = evaluateSensorRun([advertised, sample(5), sample(10, { stackRemaining: 900 }), sample(15)]);
assert.equal(result.metrics.stackRemainingBytes, 900);

// Each failure mode fails the run and is named.
const fails = (records, budgets, pattern) => {
  const verdict = evaluateSensorRun(records, budgets);
  assert.equal(verdict.passed, false);
  assert.match(verdict.reason, pattern);
  assert.equal(verdict.counts.passed, 0);
};
fails([sample(5), sample(10), sample(15)], null, /never advertised/);
fails([advertised, sample(5), sample(10)], null, /at least 3/);
fails([], null, /never advertised/);
fails([...healthy, { event: "sensor-node-session-ended", stage: "subscribe" }], null, /session-ended.*stage subscribe|stage subscribe/);
fails([...healthy, { event: "sensor-node-session-ended" }], null, /unknown stage/);
fails([...healthy, { event: "sensor-node-restart" }], null, /restart/);
fails([advertised, sample(5), sample(10), sample(15, { publishFailures: 1 })], null, /publish failures/);
fails([advertised, sample(5), sample(10), sample(15, { rejected: 2 })], null, /rejected/);
fails([advertised, sample(5, { resolves: 0 }), sample(10, { resolves: 0 }), sample(15, { resolves: 0 })], null, /no Discover/);
fails([advertised, sample(5), sample(5), sample(15)], null, /did not advance/);

// Runtime budgets are floors.
assert.equal(evaluateSensorRun(healthy, { minimumFreeHeapBytes: 230000, stackRemainingBytes: 20000 }).passed, true);
fails(healthy, { stackRemainingBytes: 20001 }, /stackRemainingBytes is 20000 B against a floor of 20001 B/);
fails(healthy, { minimumFreeHeapBytes: 240000 }, /minimumFreeHeapBytes/);
fails(healthy, { typo: 1 }, /unknown metric typo/);
fails([advertised, sample(5), sample(10, { stackRemaining: undefined }), sample(15)], { stackRemainingBytes: 1 }, /invalid stackRemaining/);
fails([advertised, sample(5, { publishFailures: 1 }), sample(10), sample(15)], null, /publish failures/);
fails([advertised, sample(5, { minimumFreeHeap: 250000 }), sample(10), sample(15)], null, /impossible heap/);
fails(healthy, { stackRemainingBytes: -1 }, /invalid runtime budget/);

// Recovery mode: the peer is away from 100 000 to 120 000 ms on the host clock.
const outage = { startMs: 100_000, endMs: 120_000 };
const at = (receivedAtMs, record) => ({ ...record, receivedAtMs });
const recovered = [
  at(10_000, advertised), at(20_000, sample(5)), at(90_000, sample(10)),
  at(101_000, { event: "sensor-node-session-ended", stage: "serving" }),
  at(110_000, { event: "sensor-node-session-ended", stage: "connect" }),
  at(131_000, advertised),
  at(140_000, sample(15, { sessions: 2, publishFailures: 1 })), at(150_000, sample(20, { sessions: 2, publishFailures: 1 })),
];
const recoveryOptions = { mode: "recovery", outage };
result = evaluateSensorRun(recovered, null, recoveryOptions);
assert.equal(result.passed, true, result.reason);
assert.equal(result.mode, "recovery");
assert.deepEqual(result.metrics.recovery, {
  outageMs: 20_000, sessionEndedAfterMs: 1_000, sessionEndedStages: ["serving", "connect"], readvertisedAfterMs: 11_000, sessions: 2,
});
// The same records are rejected in normal mode: a session ended.
assert.equal(evaluateSensorRun(recovered).passed, false);
assert.throws(() => evaluateSensorRun(recovered, null, { mode: "typo" }), /unknown sensor run mode/);

const recoveryFails = (records, pattern, options = recoveryOptions) => {
  const verdict = evaluateSensorRun(records, null, options);
  assert.equal(verdict.passed, false);
  assert.match(verdict.reason, pattern);
};
const without = predicate => recovered.filter(record => !predicate(record));
recoveryFails(without(record => record.event === "sensor-node-session-ended"), /did not report sensor-node-session-ended/);
recoveryFails(without(record => record.receivedAtMs === 131_000), /did not advertise again/);
recoveryFails(without(record => record.receivedAtMs > 131_000 && record.event === "sensor-node-metrics").concat([at(140_000, sample(15, { sessions: 2 }))]), /at least 2 required/);
recoveryFails([...recovered, at(160_000, { event: "sensor-node-restart" })], /node reported sensor-node-restart/);
recoveryFails([...recovered, at(160_000, { event: "sensor-node-unconfigured" })], /unconfigured/);
recoveryFails([at(50_000, { event: "sensor-node-session-ended", stage: "serving" }), ...recovered], /ended before the outage/);
recoveryFails(recovered.map(record => record.receivedAtMs === 140_000 ? at(140_000, sample(8, { sessions: 2, publishFailures: 1 })) : record), /did not advance/);
recoveryFails(recovered.map(record => record.receivedAtMs === 90_000 ? at(90_000, sample(18)) : record), /did not advance/);
recoveryFails(recovered.map(record => record.receivedAtMs === 150_000 ? at(150_000, sample(20, { sessions: 2, publishFailures: 3 })) : record), /publish failures/);
recoveryFails(recovered.map(record => record.receivedAtMs === 150_000 ? at(150_000, sample(20, { sessions: 2, publishFailures: 1, rejected: 1 })) : record), /rejected/);
recoveryFails(recovered.map(record => record.event === "sensor-node-session-ended" && record.stage === "connect" ? at(110_000, { ...record, stage: "elsewhere" }) : record), /unknown stage/);
recoveryFails(without(record => record.receivedAtMs <= 90_000 && record.event === "sensor-node-metrics"), /no metrics sample precedes/);
recoveryFails(recovered, /outage with a start before its end/, { mode: "recovery" });
recoveryFails(recovered, /outage with a start before its end/, { mode: "recovery", outage: { startMs: 5, endMs: 5 } });
recoveryFails(recovered.map(({ receivedAtMs, ...record }) => record), /host receive time/);
// Budgets hold across the outage: the lowest sample decides.
assert.equal(evaluateSensorRun(recovered, { stackRemainingBytes: 20000 }, recoveryOptions).passed, true);
assert.equal(evaluateSensorRun(recovered.map(record => record.receivedAtMs === 140_000 ? at(140_000, sample(15, { sessions: 2, publishFailures: 1, stackRemaining: 3000 })) : record), { stackRemainingBytes: 5000 }, recoveryOptions).passed, false);

console.log("sensor-node-validator: all cases passed");
