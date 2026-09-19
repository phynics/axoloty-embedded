// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import fs from "node:fs";
import path from "node:path";

const [device, rawPath, outputPath] = process.argv.slice(2);
if (![device, rawPath, outputPath].every(Boolean)) {
  console.error("usage: write-device-manifest.mjs device raw-info output");
  process.exit(64);
}
const raw = fs.readFileSync(rawPath, "utf8");
if (!/ESP32-C6/i.test(raw)) {
  throw new Error("device query did not identify an ESP32-C6");
}
// The port is where the unit was reached, not what it is. A qualification
// names the unit that ran, so the probe's chip description and MAC are read
// out of the raw output and carried in the manifest.
const chipMatch = raw.match(/Chip is ([^\n]+)/);
const macMatch = raw.match(/^MAC:\s*([0-9a-fA-F]{2}(?::[0-9a-fA-F]{2})+)\s*$/m);
if (!macMatch) {
  throw new Error("device query did not report a MAC; the unit cannot be named");
}
const output = {
  schemaVersion: 1,
  device,
  chip: "esp32c6",
  chipDescription: chipMatch ? chipMatch[1].trim() : "ESP32-C6",
  mac: macMatch[1].toLowerCase(),
  queried: true,
  rawInfoPath: rawPath,
};
const temporary = `${outputPath}.tmp-${process.pid}`;
fs.mkdirSync(path.dirname(outputPath), { recursive: true });
fs.writeFileSync(temporary, `${JSON.stringify(output, null, 2)}\n`, { mode: 0o644 });
fs.renameSync(temporary, outputPath);
