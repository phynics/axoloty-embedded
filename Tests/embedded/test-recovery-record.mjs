// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

// The recovery records must take its verdict from the router log and must
// never claim a pass when the underlying run did not pass.

import assert from "node:assert/strict";
import { recoveryRecord } from "./evaluate-recovery.mjs";

const ROUTER = "ea07a93343191cabbc55d9145f7936c9";
const CLIENT = "33075de12cbe78f86b2509e1b7a926d0";
const stamp = (second) => `2026-10-31T10:00:${String(second).padStart(2, "0")}.000000Z`;
const line = (second, thread, module, message) => `${stamp(second)} DEBUG ${thread} ThreadId(04) ${module}: ${message}`;
const accept = (second, port) => line(second, "acc-0", "zenoh_link_tcp::unicast", `Accepted TCP connection on 192.0.2.1:7447: 192.0.2.9:${port}`);
const open = (second) => line(second, "acc-0", "zenoh_transport::unicast::manager", `New transport opened between ${ROUTER} and ${CLIENT} - whatami: client`);
const reset = (second, port) => line(second, " rx-1", "zenoh_transport::unicast::universal::link", `RX task failed: Read error on TCP link 192.0.2.1:7447 => 192.0.2.9:${port}: Connection reset by peer (os error 104) at x`);
const expired = (second, port) => line(second, " rx-1", "zenoh_transport::unicast::universal::link", `RX task failed: tcp/192.0.2.1:7447 => tcp/192.0.2.9:${port}:Config {}: expired after 10000 milliseconds at x`);
const header = `${stamp(0)}  INFO main ThreadId(01) zenohd: zenohd v1.10.0 built with rustc 1.97.1`;

const runLog = [
  "10:00:00.500 [B] I (2099) esp_netif_handlers: sta ip: 192.0.2.9, mask: 255.255.255.0",
  "10:00:02.000 [B] axoloty:milestone:connected",
  "10:00:30.000 [host] step: host Deadvertise echo received",
].join("\n");
const hostRecord = {
  status: "passed", device: "ESP32-C6 test unit", firmwareSHA256: "a".repeat(64),
  coreRevision: "b".repeat(40), result: "10/10 passed",
};
const input = (routerLines, overrides = {}) => ({
  scenario: "wifi-recovery", runLog, routerLog: [header, ...routerLines].join("\n"), runStatus: 0, hostRecord,
  recordedAt: "2026-10-31", coreRevision: hostRecord.coreRevision, ...overrides,
});

const passed = recoveryRecord(input([accept(2, 5001), open(2), reset(5, 5001), accept(9, 5002), open(9)]));
assert.equal(passed.status, "passed");
assert.equal(passed.check, "wifi-recovery");
assert.equal(passed.firmwareSHA256, hostRecord.firmwareSHA256);
assert.match(passed.result, /same client returned in 4 s, 0 lease expiries/);

// The recovered session expired by lease: a failed record, not a pass.
const failed = recoveryRecord(input([accept(2, 5001), open(2), reset(5, 5001), accept(9, 5002), open(9), expired(19, 5002)]));
assert.equal(failed.status, "failed");
assert.match(failed.result, /expired by lease/);

// No loss in the log: the run proved nothing, so it must not pass.
assert.equal(recoveryRecord(input([accept(2, 5001), open(2)])).status, "failed");

// A run that did not pass is unexecuted, whatever the router log says.
const unexecuted = recoveryRecord(input([accept(2, 5001), open(2), reset(5, 5001), accept(9, 5002), open(9)], { runStatus: 1 }));
assert.equal(unexecuted.status, "unexecuted");
assert.match(unexecuted.reason, /did not pass \(exit 1\)/);
assert.equal(recoveryRecord(input([], { hostRecord: { ...hostRecord, status: "unexecuted" } })).status, "unexecuted");

// A run log without the milestones cannot be assessed.
assert.throws(() => recoveryRecord(input([], { runLog: "no markers" })), /lacks the device address/);

// router-restart: a second router process starts and the same client opens a session on it.
const restart = (second) => `${stamp(second)}  INFO main ThreadId(01) zenohd: zenohd v1.10.0 built with rustc 1.97.1`;
// The first router process starts well before the device connects, so it is not a restart.
const firstStart = "2026-10-31T09:59:50.000000Z  INFO main ThreadId(01) zenohd: zenohd v1.10.0 built with rustc 1.97.1";
const restartInput = (routerLines, overrides = {}) => ({
  ...input([], { scenario: "router-restart", ...overrides }),
  routerLog: [firstStart, ...routerLines].join("\n"),
  ...overrides,
});
const restarted = recoveryRecord(restartInput([accept(2, 5001), open(2), restart(12), accept(14, 5002), open(14)]));
assert.equal(restarted.status, "passed");
assert.equal(restarted.check, "router-restart");
assert.match(restarted.result, /new process 2 s after it started, 0 lease expiries/);

// No second router process: nothing was restarted.
assert.equal(recoveryRecord(restartInput([accept(2, 5001), open(2)])).status, "failed");

// The router restarted and the client never came back.
assert.match(recoveryRecord(restartInput([accept(2, 5001), open(2), restart(12)])).result, /no session with client/);

// The client came back and then expired by lease.
const expiredAfter = recoveryRecord(restartInput([accept(2, 5001), open(2), restart(12), accept(14, 5002), open(14), expired(25, 5002)]));
assert.equal(expiredAfter.status, "failed");
assert.match(expiredAfter.result, /expired by lease/);

// A restart that happened before the window is not this run's restart.
assert.match(recoveryRecord(restartInput([accept(2, 5001), open(2)])).result, /no router restart in the window/);

assert.throws(() => recoveryRecord(restartInput([], { scenario: "unknown" })), /unknown recovery scenario/);

console.log("recovery record checks passed");
