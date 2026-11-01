// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

// The largest-frame run must fail when the device publishes a sample without the
// `application/cbor` label (#128). Core's binding accepts an unlabeled sample, so
// only the observer can tell.

import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { judgeSampleEncodings, openZenohBus } from "./frame-probe.mjs";

// The judgment.
const good = [{ encoding: "application/cbor" }, { encoding: "application/cbor" }];
assert.deepEqual(judgeSampleEncodings(good), []);
assert.match(judgeSampleEncodings([])[0], /no device sample was observed/);
const bad = judgeSampleEncodings([...good, { encoding: "zenoh/bytes" }, { encoding: "application/json" }]);
assert.equal(bad.length, 1);
assert.match(bad[0], /2 of 4 device samples carry the encoding zenoh\/bytes, application\/json, expected application\/cbor/);
assert.match(judgeSampleEncodings([{}])[0], /1 of 1 device samples carry the encoding none/);

// The helper's line format reaches the judgment: a stand-in helper prints one
// labeled and one unlabeled sample.
const dir = fs.mkdtempSync(path.join(os.tmpdir(), "sample-encoding-"));
const helper = path.join(dir, "helper.sh");
fs.writeFileSync(helper, `#!/bin/sh
echo ready
echo "rx axoloty/1/x/RSV/a/1 application/cbor a1ff"
echo "rx axoloty/1/x/RSV/a/2 zenoh/bytes 00"
echo "rx axoloty/1/x/RSV/a/3 - "
sleep 2
`, { mode: 0o755 });
const seen = [];
const bus = await openZenohBus({
  helper, endpoint: "tcp/127.0.0.1:1", filter: "x/**",
  onMessage: (topic, payload, encoding) => seen.push({ topic, payload: payload.toString("hex"), encoding }),
});
await new Promise(resolve => setTimeout(resolve, 600));
bus.close();
assert.deepEqual(seen.slice(0, 2), [
  { topic: "axoloty/1/x/RSV/a/1", payload: "a1ff", encoding: "application/cbor" },
  { topic: "axoloty/1/x/RSV/a/2", payload: "00", encoding: "zenoh/bytes" },
]);
assert.equal(judgeSampleEncodings(seen).length, 1);
fs.rmSync(dir, { recursive: true, force: true });

console.log("sample-encoding: all checks passed");
