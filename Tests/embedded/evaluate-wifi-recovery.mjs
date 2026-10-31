// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

// Turns one timestamped host-interop run and its router log into the
// `wifi-recovery` evidence record. The run's own result comes from the
// host-interop record it just wrote; the recovery verdict comes from the
// router log, never from the device.

import fs from "node:fs";
import { analyzeRecovery, parseRouterLog } from "./router-session-analyzer.mjs";

const TIME = /^(\d\d):(\d\d):(\d\d\.\d+) (.*)$/;

function secondsOf(line) {
  const match = TIME.exec(line);
  return match ? Number(match[1]) * 3600 + Number(match[2]) * 60 + Number(match[3]) : null;
}

/** Returns the time of the first run-log line containing `needle`, or null. */
function firstTime(lines, needle) {
  for (const line of lines) {
    if (line.includes(needle)) return secondsOf(line);
  }
  return null;
}

/** Builds the evidence record for one run; `runStatus` is the run's exit status. */
export function wifiRecoveryRecord({ runLog, routerLog, runStatus, hostRecord, recordedAt, coreRevision }) {
  const base = { schemaVersion: 1, profile: "esp32c6-zenoh", check: "wifi-recovery", tier: "device", recordedAt };
  if (runStatus !== 0 || !hostRecord || hostRecord.status !== "passed") {
    return {
      ...base,
      status: "unexecuted",
      ...(coreRevision ? { coreRevision } : {}),
      reason: `the host interoperability run did not pass (exit ${runStatus}), so no recovery could be assessed`,
    };
  }
  const lines = runLog.split("\n");
  const deviceIP = /sta ip: (\d+\.\d+\.\d+\.\d+)/.exec(runLog)?.[1];
  const connected = firstTime(lines, "axoloty:milestone:connected");
  const exchanged = firstTime(lines, "host Deadvertise echo received");
  if (!deviceIP || connected === null || exchanged === null) {
    throw new Error("the run log lacks the device address, the connect milestone, or the host exchange end");
  }
  const analysis = analyzeRecovery(parseRouterLog(routerLog), {
    device: deviceIP,
    windowStart: connected - 5,
    windowEnd: exchanged + 1,
  });
  const common = {
    ...base,
    device: hostRecord.device,
    firmwareSHA256: hostRecord.firmwareSHA256,
    coreRevision: hostRecord.coreRevision,
    protocol: "Wi-Fi drop forced once at boot by the firmware (esp_wifi_disconnect), before application traffic; "
      + "a pinned zenohd 1.10.0 kept its debug log; a Core host peer then completed a CBOR exchange",
    recovery: {
      routerVersion: analysis.routerVersion,
      losses: analysis.losses,
      returnSeconds: analysis.returnSeconds,
      leaseExpiries: analysis.leaseExpiries,
    },
  };
  if (analysis.passed) {
    return {
      ...common,
      status: "passed",
      result: `router saw ${analysis.losses} session loss, the same client returned in ${analysis.returnSeconds.join(", ")} s, `
        + `${analysis.leaseExpiries} lease expiries, host exchange ${hostRecord.result} after recovery`,
    };
  }
  return { ...common, status: "failed", result: analysis.reasons.join("; ") };
}

function runCLI() {
  const [runLogPath, routerLogPath, statusPath, hostRecordPath, outputPath] = process.argv.slice(2);
  const runStatus = Number(fs.readFileSync(statusPath, "utf8").trim());
  const hostRecord = fs.existsSync(hostRecordPath) ? JSON.parse(fs.readFileSync(hostRecordPath, "utf8")) : null;
  const record = wifiRecoveryRecord({
    runLog: fs.readFileSync(runLogPath, "utf8"),
    routerLog: fs.readFileSync(routerLogPath, "utf8"),
    runStatus,
    hostRecord,
    recordedAt: new Date().toISOString().slice(0, 10),
    coreRevision: hostRecord?.coreRevision,
  });
  const temporary = `${outputPath}.tmp-${process.pid}`;
  fs.writeFileSync(temporary, `${JSON.stringify(record, null, 2)}\n`, { mode: 0o644 });
  fs.renameSync(temporary, outputPath);
  console.log(`${record.status}: ${record.result ?? record.reason}`);
  process.exit(record.status === "passed" ? 0 : 1);
}

if (import.meta.url === `file://${process.argv[1]}`) runCLI();
