// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

// The analyzer decides whether the router saw a loss and a recovery. These cases
// use lines in the shape zenohd 1.10.0 logs, taken from real runs, and cover each
// way a recovery claim can be false.

import assert from "node:assert/strict";
import { analyzeRecovery, parseRouterLog } from "./router-session-analyzer.mjs";

const ROUTER = "ea07a93343191cabbc55d9145f7936c9";
const CLIENT = "33075de12cbe78f86b2509e1b7a926d0";
const stamp = (second) => `2026-10-31T10:00:${String(second).padStart(2, "0")}.000000Z`;
const line = (second, thread, module, message) => `${stamp(second)} DEBUG ${thread} ThreadId(04) ${module}: ${message}`;
const accept = (second, port) => line(second, "acc-0", "zenoh_link_tcp::unicast", `Accepted TCP connection on 192.0.2.1:7447: 192.0.2.9:${port}`);
const open = (second, zid = CLIENT) => line(second, "acc-0", "zenoh_transport::unicast::manager", `New transport opened between ${ROUTER} and ${zid} - whatami: client, sn resolution: U32`);
const reset = (second, port) => line(second, " rx-1", "zenoh_transport::unicast::universal::link", `RX task failed: Read error on TCP link 192.0.2.1:7447 => 192.0.2.9:${port}: Connection reset by peer (os error 104) at io/zenoh-links`);
const eof = (second, port) => line(second, " rx-1", "zenoh_transport::unicast::universal::link", `RX task failed: Read error on TCP link 192.0.2.1:7447 => 192.0.2.9:${port}: early eof at io/zenoh-links`);
const expired = (second, port) => line(second, " rx-1", "zenoh_transport::unicast::universal::link", `RX task failed: tcp/192.0.2.1:7447 => tcp/192.0.2.9:${port}:TransportLinkUnicastConfig { direction: Inbound }: expired after 10000 milliseconds at io/zenoh-transport`);
const header = `${stamp(0)}  INFO main ThreadId(01) zenohd: zenohd v1.10.0 built with rustc 1.97.1`;
const base = 10 * 3600;
const options = { device: "192.0.2.9", windowStart: base + 1, windowEnd: base + 40 };
const run = (...lines) => analyzeRecovery(parseRouterLog([header, ...lines].join("\n")), options);

// Loss by reset, the same client returns 4 s later, and the session survives.
const good = run(accept(2, 5001), open(2), reset(5, 5001), accept(9, 5002), open(9), eof(45, 5002));
assert.equal(good.passed, true, good.reasons.join("; "));
assert.equal(good.losses, 1);
assert.deepEqual(good.returnSeconds, [4]);
assert.equal(good.leaseExpiries, 0);
assert.equal(good.routerVersion, "1.10.0");

// A session that never ended is no loss: the run proved nothing about recovery.
assert.match(run(accept(2, 5001), open(2)).reasons.join("\n"), /no loss was observed/);

// A loss with no return.
assert.match(run(accept(2, 5001), open(2), reset(5, 5001)).reasons.join("\n"), /no session with client .* returned/);

// A return from a different client is not a recovery of this one.
assert.match(
  run(accept(2, 5001), open(2), reset(5, 5001), accept(9, 5002), open(9, "f".repeat(32)), eof(45, 5002)).reasons.join("\n"),
  /no session with client/);

// A return later than the bound.
assert.match(
  run(accept(2, 5001), open(2), reset(5, 5001), accept(30, 5002), open(30)).reasons.join("\n"),
  /over the 15 s bound/);

// The recovered session expired by lease: the idle-session fault of #56.
const lease = run(accept(2, 5001), open(2), reset(5, 5001), accept(9, 5002), open(9), expired(19, 5002), accept(26, 5003), open(26));
assert.equal(lease.passed, false);
assert.equal(lease.leaseExpiries, 1);
assert.match(lease.reasons.join("\n"), /expired by lease/);

// Another device's sessions and sessions outside the window are not counted.
const other = analyzeRecovery(parseRouterLog([header, accept(2, 5001), open(2), reset(5, 5001), accept(9, 5002), open(9)].join("\n")),
  { device: "192.0.2.77", windowStart: base + 1, windowEnd: base + 40 });
assert.match(other.reasons.join("\n"), /no session from the device/);

// ANSI colour codes in a log kept from a terminal do not hide events.
const coloured = [header, accept(2, 5001), open(2), reset(5, 5001), accept(9, 5002), open(9)]
  .map(entry => entry.replace(/^(\S+Z)/, "\u001b[2m$1\u001b[0m")).join("\n");
assert.equal(analyzeRecovery(parseRouterLog(coloured), options).passed, true);

console.log("router session analyzer checks passed");
