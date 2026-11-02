// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

// Capture a production sensor session. The host must subscribe before boot:
// the firmware publishes its Advertise once per session.
//
// SENSOR_MODE=recovery adds an outage during the soak: the runner runs
// SENSOR_OUTAGE_STOP_COMMAND, waits SENSOR_OUTAGE_SECONDS (default 20), then runs
// SENSOR_OUTAGE_START_COMMAND. The commands stop and restart the broker or
// router; the runner holds no knowledge of how. SENSOR_OUTAGE_CYCLES (default 1,
// at most 20) repeats the outage in one boot: after each return the node must
// advertise again and report twice before the next outage starts, with no
// device restart. A second host observer starts as each carrier returns and
// must finish cleanly.
//
// The runner reads build/size.json before flashing and refuses an image built
// with a placeholder or without a real network header. A host that cannot supply them
// exits 69, "capability absent". A passing run writes a device evidence record
// to docs/evidence/<profile>-sensor-node-runtime.json, or
// <profile>-sensor-node-recovery.json in recovery mode, or
// <profile>-sensor-node-recovery-cycles.json when SENSOR_OUTAGE_CYCLES is above 1.
import fs from "node:fs";
import path from "node:path";
import { spawn, spawnSync } from "node:child_process";
import { captureSerial, drainSerial } from "./serial-tools.mjs";
import { flashFirmware, runFirmware } from "./esptool-tools.mjs";
import { bootReasons, createRecordAssembler, evaluateSensorRun, judgeImageReport, judgeRecoveryObservers } from "./sensor-node-validator.mjs";
import { deviceEvidenceRecord, writeDeviceEvidence } from "./write-device-evidence.mjs";

const [device, root, peerPath, esptool, profilePath] = process.argv.slice(2);
if (!device || !root || !peerPath || !esptool || !profilePath) throw new Error("usage: run-sensor-node.mjs DEVICE ROOT PEER ESPTOOL PROFILE");
const repoRoot = path.resolve(import.meta.dirname, "../..");
const profileName = JSON.parse(fs.readFileSync(profilePath, "utf8")).name;
const mode = process.env.SENSOR_MODE ?? "normal";
if (!["normal", "recovery"].includes(mode)) throw new Error("SENSOR_MODE must be normal or recovery");
const outageSeconds = Number(process.env.SENSOR_OUTAGE_SECONDS ?? 20);
if (!Number.isSafeInteger(outageSeconds) || outageSeconds < 5 || outageSeconds > 120) throw new Error("invalid SENSOR_OUTAGE_SECONDS");
const stopCommand = process.env.SENSOR_OUTAGE_STOP_COMMAND;
const startCommand = process.env.SENSOR_OUTAGE_START_COMMAND;
if (mode === "recovery" && (!stopCommand || !startCommand)) {
  console.error("sensor-node: recovery mode needs SENSOR_OUTAGE_STOP_COMMAND and SENSOR_OUTAGE_START_COMMAND");
  process.exit(69);
}
const evidence = path.join(root, "working-evidence");
const ready = path.join(root, "sensor-observer.ready");
fs.mkdirSync(evidence, { recursive: true });
fs.rmSync(ready, { force: true });
const cycles = Number(process.env.SENSOR_OUTAGE_CYCLES ?? 1);
if (!Number.isSafeInteger(cycles) || cycles < 1 || cycles > 20) throw new Error("invalid SENSOR_OUTAGE_CYCLES");
if (mode === "normal" && cycles !== 1) throw new Error("SENSOR_OUTAGE_CYCLES needs SENSOR_MODE=recovery");
const deadlineSeconds = Number(process.env.SENSOR_DEADLINE_SECONDS ?? (mode === "recovery" ? 300 + 100 * (cycles - 1) : 120));
if (!Number.isSafeInteger(deadlineSeconds) || deadlineSeconds < 40 || deadlineSeconds > 1800) throw new Error("invalid SENSOR_DEADLINE_SECONDS");
const records = [];
const assembler = createRecordAssembler();
/** True once outage `index` ended, the node re-advertised and two metrics lines followed. */
function recoveredEnough(index) {
  const outage = outages[index];
  if (!outage || outage.endMs === null) return false;
  const again = records.findIndex(record => record.event === "sensor-node-advertised" && record.receivedAtMs >= outage.endMs);
  return again >= 0 && records.slice(again).filter(record => record.event === "sensor-node-metrics").length >= 2;
}
function runOutageCommand(command) {
  const result = spawnSync("sh", ["-c", command], { stdio: "inherit", timeout: 120_000 });
  if (result.status !== 0) throw new Error(`outage command failed: ${result.status ?? result.signal ?? result.error?.message}`);
}
function spawnPeer(readyFile, extraEnvironment = {}) {
  const child = spawn(peerPath, [], { env: {
    ...process.env, ...extraEnvironment, WIRE_EMBEDDED_HOST_DIRECTION: "sensor-observer", WIRE_READY_FILE: readyFile,
    WIRE_BROKER_HOST: process.env.AXOLOTY_MQTT_HOST,
    WIRE_BROKER_PORT: process.env.AXOLOTY_MQTT_PORT ?? "1883",
    WIRE_ZENOH_ENDPOINT: `tcp/${process.env.AXOLOTY_ZENOH_HOST}:${process.env.AXOLOTY_ZENOH_PORT ?? "7447"}`,
  }, stdio: ["ignore", "pipe", "pipe"] });
  let bytes = 0;
  for (const stream of [child.stdout, child.stderr]) stream.on("data", chunk => {
    bytes += chunk.length;
    if (bytes <= 1024 * 1024) hostOutput.push(chunk.toString());
    else child.kill("SIGTERM");
  });
  const exited = new Promise(resolve => {
    child.once("error", error => resolve({ error: error.message }));
    child.once("exit", (code, signal) => resolve({ code, signal }));
  });
  return { child, exited };
}
async function waitFor(condition, deadlineMs, message) {
  const limit = Date.now() + deadlineMs;
  while (!condition()) {
    if (Date.now() >= limit) throw new Error(message);
    await new Promise(resolve => setTimeout(resolve, 100));
  }
}
const lines = [];
const hostOutput = [];
const controller = new AbortController();
let peer;
const recoveryPeers = [];
const recoveryExits = [];
let hostExit = null;
const outages = [];
let failure = null;
let validation = null;
let boots = [];
try {
  // Refuse a placeholder or unconfigured image before anything reaches the board.
  const imageProblem = judgeImageReport(JSON.parse(fs.readFileSync(path.join(root, "build", "size.json"), "utf8")));
  if (imageProblem) throw new Error(`refusing to flash: ${imageProblem}`);
  flashFirmware(esptool, device, root);
  await drainSerial(device);
  const capture = captureSerial(device, deadlineSeconds, line => {
    lines.push(line);
    const record = assembler.feed(line);
    if (record) records.push({ ...record, receivedAtMs: Date.now() });
    // Normal mode observes the entire bounded window, including after the host
    // exits. Recovery mode ends once the node is back and has reported twice.
    return mode === "recovery" && outages.length === cycles && recoveredEnough(cycles - 1);
  }, controller.signal);
  const first = spawnPeer(ready);
  peer = first.child;
  const exit = first.exited.then(value => { hostExit = value; return value; });
  await waitFor(() => fs.existsSync(ready) || hostExit, 30000, "host readiness deadline exceeded");
  if (hostExit) throw new Error(`host exited before readiness: ${JSON.stringify(hostExit)}`);
  runFirmware(esptool, device);
  let orchestration = Promise.resolve();
  let orchestrationError = null;
  if (mode === "recovery") {
    orchestration = (async () => {
      // The first observer must see the whole exchange before the carrier goes away.
      await waitFor(() => hostExit !== null, 90_000, "the host observer did not finish before the outage");
      if (hostExit.code !== 0) throw new Error(`host=${JSON.stringify(hostExit)} before the outage`);
      await waitFor(() => records.filter(record => record.event === "sensor-node-metrics").length >= 2, 60_000, "no steady state before the outage");
      for (let cycle = 0; cycle < cycles; cycle += 1) {
        const outage = { startMs: Date.now(), endMs: null };
        outages.push(outage);
        runOutageCommand(stopCommand);
        await new Promise(resolve => setTimeout(resolve, outageSeconds * 1000));
        outage.endMs = Date.now();
        runOutageCommand(startCommand);
        // A second observer, started as the carrier returns, must complete a
        // Discover and see readings from the node that came back.
        const lateReady = path.join(root, `sensor-observer-recovery-${cycle + 1}.ready`);
        fs.rmSync(lateReady, { force: true });
        // It may start before or after the node has advertised again, so it waits
        // for a reading instead of that Advertise. The re-advertise itself is judged
        // from the serial log by recoveredEnough and the validator.
        const late = spawnPeer(lateReady, { WIRE_SENSOR_AWAIT_READING: "1" });
        recoveryPeers.push(late.child);
        recoveryExits[cycle] = null;
        late.exited.then(value => { recoveryExits[cycle] = value; });
        await waitFor(() => recoveredEnough(cycle), 150_000, `the node did not recover from outage ${cycle + 1}`);
        await waitFor(() => recoveryExits[cycle] !== null, 90_000, `recovery observer ${cycle + 1} did not finish`);
        fs.rmSync(lateReady, { force: true });
        const observerProblems = judgeRecoveryObservers(recoveryExits.slice(0, cycle + 1));
        if (observerProblems.length > 0) throw new Error(observerProblems.join("; "));
      }
    })().catch(error => { orchestrationError = error; controller.abort(); });
  }
  await capture;
  await orchestration;
  if (orchestrationError) throw orchestrationError;
  if (!hostExit) {
    await Promise.race([exit, new Promise(resolve => setTimeout(resolve, 1000))]);
  }
  validation = evaluateSensorRun(records, JSON.parse(fs.readFileSync(profilePath)).budgets?.runtime ?? null,
    { mode, outages: mode === "recovery" ? outages : undefined });
  boots = bootReasons(lines);
  if (boots.length !== 1) throw new Error(`the device booted ${boots.length} times in one run (${boots.join(", ") || "no banner seen"}), at most one reset is expected`);
  const observerProblems = mode === "recovery"
    ? judgeRecoveryObservers(Array.from({ length: cycles }, (_, index) => recoveryExits[index] ?? null)) : [];
  if (hostExit?.code !== 0 || !validation.passed || observerProblems.length > 0) {
    throw new Error(`host=${JSON.stringify(hostExit)}; ${[validation.reason, ...observerProblems].filter(Boolean).join("; ") || "host did not finish"}`);
  }
} catch (error) {
  failure = error.message;
} finally {
  controller.abort();
  if (peer && hostExit === null) peer.kill("SIGTERM");
  recoveryPeers.forEach((child, index) => { if (recoveryExits[index] === null) child.kill("SIGTERM"); });
  fs.writeFileSync(path.join(evidence, "sensor-serial.log"), `${lines.join("\n")}\n`);
  fs.writeFileSync(path.join(evidence, "sensor-host.log"), hostOutput.join(""));
  fs.writeFileSync(path.join(evidence, "sensor-result.json"), `${JSON.stringify({ passed: failure === null, failure, mode, outages: mode === "recovery" ? outages : undefined, hostExit, hostAfterRecovery: mode === "recovery" ? recoveryExits : undefined, validation }, null, 2)}\n`);
  fs.rmSync(ready, { force: true });
  // A failed run keeps its logs under a name no later run overwrites.
  if (failure) {
    const kept = path.join(evidence, `failed-${new Date().toISOString().replace(/[:.]/g, "-")}`);
    fs.mkdirSync(kept, { recursive: true });
    for (const name of ["sensor-serial.log", "sensor-host.log", "sensor-result.json"]) fs.copyFileSync(path.join(evidence, name), path.join(kept, name));
  }
}
if (failure) { console.error(`sensor-node: ${failure}`); process.exitCode = 1; }
else {
  console.log(`sensor-node: ${mode} run passed`);
  if (validation.metrics.recovery) console.log(`sensor-node: recovery ${JSON.stringify(validation.metrics.recovery)}`);
  console.log(`sensor-node: evidence ${writeEvidence()}`);
}

/** Writes the device evidence record for the run that just passed. */
function writeEvidence() {
  const provenance = JSON.parse(fs.readFileSync(path.join(evidence, "build-provenance.json"), "utf8"));
  const device = JSON.parse(fs.readFileSync(path.join(evidence, "device-manifest.json"), "utf8"));
  const size = JSON.parse(fs.readFileSync(path.join(root, "build", "size.json"), "utf8"));
  const check = mode === "recovery" ? (cycles > 1 ? "sensor-node-recovery-cycles" : "sensor-node-recovery") : "sensor-node-runtime";
  const proof = {
    result: "passed",
    smoke: { validation },
    firmwareSha256: provenance.artifact.sha256,
    coreSha: provenance.core.sha,
  };
  const cases = mode === "recovery"
    ? `metrics samples across ${cycles} carrier outage${cycles === 1 ? "" : "s"} in one boot, with host-observed Advertise, Resolve and readings before the first and after each`
    : "metrics samples over one session, with host-observed Advertise, Resolve and readings";
  const record = deviceEvidenceRecord(proof, device, { profile: profileName, check, cases });
  record.runtimeResourceMetrics = { mode, ...validation.metrics, deviceBoots: boots.length };
  record.configuration = {
    name: size.configuration.name,
    sdkconfigSha256: size.configuration.sdkconfigSha256,
    networkConfigured: size.configuration.networkConfigured,
    networkPlaceholder: size.configuration.networkPlaceholder === true,
  };
  if (record.configuration.networkPlaceholder || !record.configuration.networkConfigured) {
    throw new Error("refusing to write evidence from an image built without a real network header");
  }
  record.firmwareImageBytes = size.image.bytes;
  return writeDeviceEvidence(record, path.join(repoRoot, "docs", "evidence", `${profileName}-${check}.json`));
}
