// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

// Prefixes each stdin line with its UTC time of day (HH:MM:SS.mmm) so a device
// run log can be matched against a router log, which is also UTC.

import readline from "node:readline";

const lines = readline.createInterface({ input: process.stdin, crlfDelay: Infinity });
lines.on("line", line => {
  process.stdout.write(`${new Date().toISOString().slice(11, 23)} ${line}\n`);
});
