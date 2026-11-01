// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

// Prove on a board that a production sensor node carries the largest frame its
// application declares, and drops what is one byte beyond it without losing the
// frames after.
//
// The runner flashes the image the profile build left in ROOT, waits for the
// node to advertise, then runs the host side (frame-probe.mjs) against the
// broker or router while it captures the serial log:
//
// - a Discover with a payload of exactly maxPayloadSize bytes is answered;
// - a frame on a topic of exactly maxTopicLength bytes reaches the application,
//   which rejects it as a request (the `rejected` counter rises by one);
// - a Discover one byte over the payload bound, and a frame on a topic one byte
//   over the topic bound, are not delivered; the carrier drops them, and the
//   node answers a short Discover afterwards;
// - MQTT counts and logs each drop and keeps its session; Zenoh reports the
//   drop as the carrier's one-shot error, which ends the application's session,
//   and the node advertises again.
//
// The runner reads build/size.json first and refuses a placeholder image.
// A passing run writes docs/evidence/<profile>-sensor-node-largest-frame.json.
import fs from "node:fs";
import path from "node:path";
import { captureSerial, drainSerial } from "./serial-tools.mjs";
import { flashFirmware, runFirmware } from "./esptool-tools.mjs";
import { bootReasons, createRecordAssembler, judgeImageReport } from "./sensor-node-validator.mjs";
import { deviceEvidenceRecord, writeDeviceEvidence } from "./write-device-evidence.mjs";
import { openMqttBus, openZenohBus, runFrameProbe } from "./frame-probe.mjs";

const [device, root, esptool, profilePath] = process.argv.slice(2);
if (!device || !root || !esptool || !profilePath) throw new Error("usage: run-largest-frame.mjs DEVICE ROOT ESPTOOL PROFILE");
const repoRoot = path.resolve(import.meta.dirname, "../..");
const profile = JSON.parse(fs.readFileSync(profilePath, "utf8"));
const wire = profile.transport === "mqtt-espidf" ? "mqtt" : "zenoh";
const application = JSON.parse(fs.readFileSync(path.join(repoRoot, "Applications", profile.application, "app.json"), "utf8"));
const bounds = { topic: application.capacities.maxTopicLength, payload: application.capacities.maxPayloadSize };
const evidence = path.join(root, "working-evidence");
fs.mkdirSync(evidence, { recursive: true });

const lines = [];
const records = [];
const messages = [];
const log = text => console.log(`largest-frame: ${text}`);
const assembler = createRecordAssembler();
const controller = new AbortController();
const startedAt = Date.now();
let probeStartMs = null;
let results = null;
let failure = null;
let boots = [];
let summary = null;

/** Waits for `condition`, polling, or throws. */
async function waitFor(condition, milliseconds, message) {
  const limit = Date.now() + milliseconds;
  while (!condition()) {
    if (Date.now() >= limit) throw new Error(message);
    await new Promise(resolve => setTimeout(resolve, 100));
  }
}
const metricsAfter = ms => records.filter(record => record.event === "sensor-node-metrics" && record.receivedAtMs >= ms);

try {
  const imageProblem = judgeImageReport(JSON.parse(fs.readFileSync(path.join(root, "build", "size.json"), "utf8")));
  if (imageProblem) throw new Error(`refusing to flash: ${imageProblem}`);
  flashFirmware(esptool, device, root);
  await drainSerial(device);
  const capture = captureSerial(device, 600, line => {
    lines.push(line);
    const record = assembler.feed(line);
    if (record) records.push({ ...record, receivedAtMs: Date.now() });
    return false;
  }, controller.signal);
  runFirmware(esptool, device);

  await waitFor(() => records.some(record => record.event === "sensor-node-advertised"), 120_000, "the node did not advertise");
  await waitFor(() => records.filter(record => record.event === "sensor-node-metrics").length >= 2, 60_000, "no steady state before the probe");

  const bus = wire === "mqtt"
    ? await openMqttBus({
      host: process.env.AXOLOTY_MQTT_HOST, port: process.env.AXOLOTY_MQTT_PORT ?? "1883",
      filter: `coaty/3/axoloty-embedded/RSV/#`,
      onMessage: (topic, payload) => messages.push({ topic, payload }),
    })
    : await openZenohBus({
      helper: process.env.FRAME_IO_HELPER, endpoint: `tcp/${process.env.AXOLOTY_ZENOH_HOST}:${process.env.AXOLOTY_ZENOH_PORT ?? "7447"}`,
      filter: `axoloty/1/axoloty-embedded/RSV/**`,
      onMessage: (topic, payload) => messages.push({ topic, payload }),
    });
  const before = records.filter(record => record.event === "sensor-node-metrics").at(-1);
  probeStartMs = Date.now();
  try {
    results = await runFrameProbe({ wire, bounds, bus, messages, log });
  } finally {
    bus.close();
  }
  log(JSON.stringify(results));

  // Let the node report once more after the last frame.
  await waitFor(() => metricsAfter(probeStartMs + 1).length >= 3 || Date.now() - probeStartMs > 120_000, 130_000, "no metrics after the probe");
  await new Promise(resolve => setTimeout(resolve, 12_000));
  controller.abort();
  await capture;

  const after = records.filter(record => record.event === "sensor-node-metrics").at(-1);
  const sinceProbe = records.filter(record => record.receivedAtMs >= probeStartMs);
  const dropLines = lines.filter(line => line.includes("dropped an inbound frame beyond the composed bounds"));
  const endedSinceProbe = sinceProbe.filter(record => record.event === "sensor-node-session-ended");
  const advertisedSinceProbe = sinceProbe.filter(record => record.event === "sensor-node-advertised");
  boots = bootReasons(lines);
  const problems = [];
  const step = name => results.find(result => result.step === name);
  if (!step("maxPayloadDiscover")?.answered) problems.push("a Discover with a payload at the bound was not answered");
  if (step("maxPayloadDiscover")?.payloadBytes !== bounds.payload) problems.push("the largest Discover was not exactly the payload bound");
  if (step("maxTopicFrame")?.topicBytes !== bounds.topic || step("maxTopicFrame")?.payloadBytes !== bounds.payload) {
    problems.push("the largest-topic frame was not exactly the bounds");
  }
  if (after.rejected - before.rejected !== 1) problems.push(`the application rejected ${after.rejected - before.rejected} frames, expected the one at the topic bound`);
  if (step("payloadOneOver")?.answered !== false || step("payloadOneOver")?.responsive !== true) problems.push("a payload one byte over was answered, or the node did not answer afterwards");
  if (step("topicOneOver")?.responsive !== true) problems.push("the node did not answer after a topic one byte over");
  if (wire === "mqtt") {
    if (dropLines.length !== 2) problems.push(`the carrier logged ${dropLines.length} drops, expected 2`);
    if (!dropLines.some(line => line.includes(`payload ${bounds.payload + 1} bytes`))) problems.push("no drop line names the payload one byte over");
    if (!dropLines.some(line => line.includes(`topic ${bounds.topic + 1},`))) problems.push("no drop line names the topic one byte over");
    if (endedSinceProbe.length !== 0) problems.push("the session ended during the probe");
  } else {
    if (endedSinceProbe.length < 2) problems.push(`the session ended ${endedSinceProbe.length} times for 2 dropped frames`);
    if (advertisedSinceProbe.length < endedSinceProbe.length) problems.push("the node did not advertise again after each session end");
  }
  if (boots.length !== 1) problems.push(`the device booted ${boots.length} times in one run`);
  summary = {
    wire, bounds, results, rejectedBefore: before.rejected, rejectedAfter: after.rejected,
    resolvesBefore: before.resolves, resolvesAfter: after.resolves,
    carrierDropLines: wire === "mqtt" ? dropLines.map(line => line.replace(/^.*?(dropped)/, "$1")) : undefined,
    sessionEndsDuringProbe: endedSinceProbe.length, advertisesAfterProbe: advertisedSinceProbe.length,
    deviceBoots: boots.length,
  };
  if (problems.length > 0) throw new Error(problems.join("; "));
} catch (error) {
  failure = error.message;
} finally {
  controller.abort();
  fs.writeFileSync(path.join(evidence, "frame-serial.log"), `${lines.join("\n")}\n`);
  fs.writeFileSync(path.join(evidence, "frame-result.json"), `${JSON.stringify({ passed: failure === null, failure, summary, results, elapsedMs: Date.now() - startedAt }, null, 2)}\n`);
}
if (failure) {
  console.error(`largest-frame: ${failure}`);
  process.exitCode = 1;
} else {
  console.log("largest-frame: run passed");
  console.log(`largest-frame: evidence ${writeEvidence()}`);
}

/** Writes the device evidence record for the run that just passed. */
function writeEvidence() {
  const provenance = JSON.parse(fs.readFileSync(path.join(evidence, "build-provenance.json"), "utf8"));
  const deviceManifest = JSON.parse(fs.readFileSync(path.join(evidence, "device-manifest.json"), "utf8"));
  const size = JSON.parse(fs.readFileSync(path.join(root, "build", "size.json"), "utf8"));
  const proof = {
    result: "passed",
    smoke: { validation: { passed: true, counts: { passed: results.length } } },
    firmwareSha256: provenance.artifact.sha256,
    coreSha: provenance.core.sha,
  };
  const record = deviceEvidenceRecord(proof, deviceManifest, {
    profile: profile.name,
    check: "sensor-node-largest-frame",
    cases: `frame probes over the carrier at the application's declared bounds (topic ${bounds.topic}, payload ${bounds.payload}) and one byte over`,
  });
  record.frameProbe = summary;
  record.firmwareImageBytes = size.image.bytes;
  return writeDeviceEvidence(record, path.join(repoRoot, "docs", "evidence", `${profile.name}-sensor-node-largest-frame.json`));
}
