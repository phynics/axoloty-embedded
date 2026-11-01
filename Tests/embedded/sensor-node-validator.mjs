// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

// Judges one `sensor-node` soak from its serial lines. Every field of the result
// comes from what the device reported; a run with too few samples never passes.

/** The fewest metrics lines that count as a soak. */
export const MINIMUM_SAMPLES = 3;

/** The closed set of steps a session-ended record can name. */
export const SESSION_STAGES = ["network", "last-will", "connect", "subscribe", "advertise", "serving"];

/** Reads one serial line as a sensor-node record, or returns `null`. */
export function parseSensorRecord(line) {
  const start = line.indexOf('{"event":"sensor-node-');
  if (start < 0) return null;
  try {
    return JSON.parse(line.slice(start).trim());
  } catch {
    return null;
  }
}

/** The modes a run can be judged in. */
export const SENSOR_MODES = ["normal", "recovery"];

/** The fewest metrics lines that must follow the node's re-advertise in recovery mode. */
export const MINIMUM_RECOVERY_SAMPLES = 2;

/**
 * Evaluates the records of one run against the profile's runtime budgets.
 *
 * In `normal` mode the node must hold one session for the whole soak: a
 * session-ended record fails the run. In `recovery` mode the carrier's peer is
 * stopped for a while and restarted. The node must then report the session
 * ended while the peer was away, advertise again after the peer returned, keep
 * counting readings, and never restart. Records carry `receivedAtMs`, the host
 * clock when the line arrived, so the validator can time the recovery.
 *
 * - Parameter budgets: `budgets.runtime` from the profile, or `null`. A floor
 *   that is declared must hold on every sample, across the outage too.
 * - Parameter options: `mode`, and in recovery mode `outage` with
 *   `startMs` and `endMs` on the same host clock as `receivedAtMs`.
 */
export function evaluateSensorRun(records, budgets = null, options = {}) {
  const mode = options.mode ?? "normal";
  if (!SENSOR_MODES.includes(mode)) throw new Error(`unknown sensor run mode ${JSON.stringify(mode)}`);
  const samples = records.filter(record => record.event === "sensor-node-metrics");
  const failures = [];
  const fields = ["sessions", "readings", "resolves", "rejected", "publishFailures",
    "freeHeap", "minimumFreeHeap", "stackRemaining", "stackSize"];
  const ended = records.filter(record => record.event === "sensor-node-session-ended");
  for (const [index, sample] of samples.entries()) {
    for (const field of fields) {
      if (!Number.isSafeInteger(sample[field]) || sample[field] < 0) {
        failures.push(`sample ${index + 1} has invalid ${field}`);
      }
    }
    if (sample.stackRemaining > sample.stackSize) failures.push(`sample ${index + 1} has impossible stack headroom`);
    if (sample.minimumFreeHeap > sample.freeHeap) failures.push(`sample ${index + 1} has impossible heap minimum`);
    // A publish that fails because the carrier went away counts once and ends
    // that session, so a recovery run allows at most one per ended session.
    if (mode === "normal" ? sample.publishFailures !== 0 : sample.publishFailures > ended.length) {
      failures.push(`sample ${index + 1} has publish failures`);
    }
    if (sample.rejected !== 0) failures.push(`sample ${index + 1} has rejected frames`);
  }
  if (!records.some(record => record.event === "sensor-node-advertised")) failures.push("the node never advertised");
  for (const event of ["sensor-node-restart", "sensor-node-unconfigured"]) {
    if (records.some(record => record.event === event)) failures.push(`the node reported ${event}`);
  }
  // A session that ended names the step it had reached.
  for (const record of ended) {
    if (!SESSION_STAGES.includes(record.stage)) failures.push(`session ended with unknown stage ${JSON.stringify(record.stage)}`);
    else if (mode === "normal") failures.push(`a session ended at stage ${record.stage}`);
  }
  if (samples.length < MINIMUM_SAMPLES) failures.push(`${samples.length} metrics samples, at least ${MINIMUM_SAMPLES} required`);

  const last = samples.at(-1);
  if (last) {
    if (mode === "normal" && last.publishFailures !== 0) failures.push(`${last.publishFailures} publish failures`);
    if (last.rejected !== 0) failures.push(`${last.rejected} rejected frames`);
    if (last.resolves < 1) failures.push("the node answered no Discover");
  }
  for (let index = 1; index < samples.length; index += 1) {
    if (samples[index].readings <= samples[index - 1].readings) failures.push("the reading count did not advance");
  }

  const metrics = samples.length === 0 ? null : {
    samples: samples.length,
    readings: last.readings,
    resolves: last.resolves,
    minimumFreeHeapBytes: Math.min(...samples.map(sample => sample.minimumFreeHeap)),
    stackRemainingBytes: Math.min(...samples.map(sample => sample.stackRemaining)),
    stackSizeBytes: last.stackSize,
  };
  if (mode === "recovery") judgeRecovery(records, samples, ended, options.outage, metrics, failures);
  if (metrics && budgets) {
    for (const [metric, floor] of Object.entries(budgets)) {
      if (metrics[metric] === undefined) failures.push(`runtime budget names unknown metric ${metric}`);
      else if (!Number.isSafeInteger(floor) || floor < 0) failures.push(`invalid runtime budget ${metric}`);
      else if (!Number.isSafeInteger(metrics[metric])) failures.push(`invalid measurement for ${metric}`);
      else if (metrics[metric] < floor) failures.push(`${metric} is ${metrics[metric]} B against a floor of ${floor} B`);
    }
  }
  return {
    mode,
    passed: failures.length === 0,
    reason: failures.join("; ") || null,
    metrics,
    counts: { passed: failures.length === 0 ? samples.length : 0 },
  };
}

/** Judges the outage, the node's report of it, and its return; adds recovery figures to `metrics`. */
function judgeRecovery(records, samples, ended, outage, metrics, failures) {
  const valid = outage && Number.isSafeInteger(outage.startMs) && Number.isSafeInteger(outage.endMs) && outage.startMs < outage.endMs;
  if (!valid) {
    failures.push("recovery mode needs an outage with a start before its end");
    return;
  }
  const at = record => record.receivedAtMs;
  if (!records.every(record => Number.isSafeInteger(at(record)))) {
    failures.push("recovery mode needs a host receive time on every record");
    return;
  }
  const early = ended.filter(record => at(record) < outage.startMs);
  if (early.length > 0) failures.push("a session ended before the outage began");
  const reported = ended.find(record => at(record) >= outage.startMs);
  if (!reported) failures.push("the node did not report sensor-node-session-ended during the outage");
  const advertised = records.find(record => record.event === "sensor-node-advertised" && at(record) >= outage.endMs);
  if (!advertised) failures.push("the node did not advertise again after the outage");
  const before = samples.filter(sample => at(sample) < outage.startMs);
  if (before.length === 0) failures.push("no metrics sample precedes the outage");
  if (advertised) {
    const after = samples.filter(sample => at(sample) > at(advertised));
    if (after.length < MINIMUM_RECOVERY_SAMPLES) {
      failures.push(`${after.length} metrics samples after the re-advertise, at least ${MINIMUM_RECOVERY_SAMPLES} required`);
    } else if (before.length > 0 && after[0].readings <= before.at(-1).readings) {
      failures.push("the reading count did not advance after the outage");
    }
    if (after.length > 0 && !(after.at(-1).sessions >= 1)) failures.push("the session count did not grow");
  }
  if (metrics && reported && advertised) {
    metrics.recovery = {
      outageMs: outage.endMs - outage.startMs,
      sessionEndedAfterMs: at(reported) - outage.startMs,
      sessionEndedStages: ended.filter(record => at(record) >= outage.startMs).map(record => record.stage),
      readvertisedAfterMs: at(advertised) - outage.endMs,
      sessions: samples.at(-1).sessions,
    };
  }
}
