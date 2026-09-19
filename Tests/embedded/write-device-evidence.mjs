// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

// Build and write one device evidence record from a completed proof. Every
// field is computed from what the run observed; a failed proof refuses.

import fs from "node:fs";
import path from "node:path";

/** Returns the evidence record a passed proof supports; throws otherwise. */
export function deviceEvidenceRecord(proof, device, { profile, check, cases }) {
  if (proof.result !== "passed" || proof.smoke?.validation?.passed !== true) {
    throw new Error("refusing to write device evidence from a failed proof");
  }
  const counts = proof.smoke.validation.counts ?? {};
  const passed = Number.isInteger(counts.passed) ? counts.passed : 0;
  const unit = device.chipDescription
    ? `${device.chipDescription}${device.mac ? `, MAC ${device.mac}` : ""}`
    : device.device;
  return {
    schemaVersion: 1,
    profile,
    check,
    tier: "device",
    status: "passed",
    recordedAt: new Date().toISOString().slice(0, 10),
    device: unit,
    firmwareSHA256: proof.firmwareSha256,
    coreRevision: proof.coreSha,
    protocol: `${passed} ${cases}`,
    result: `${passed}/${passed} passed`,
  };
}

/** Writes a record atomically and returns its path. */
export function writeDeviceEvidence(record, outputPath) {
  const temporary = `${outputPath}.tmp-${process.pid}`;
  fs.mkdirSync(path.dirname(outputPath), { recursive: true });
  fs.writeFileSync(temporary, `${JSON.stringify(record, null, 2)}\n`, { mode: 0o644 });
  fs.renameSync(temporary, outputPath);
  return outputPath;
}

function runCLI() {
  const proofPath = process.env.PROOF;
  const devicePath = process.env.DEVICE_MANIFEST;
  const outputPath = process.env.EVIDENCE_OUT;
  const profile = process.env.PROFILE_NAME;
  const check = process.env.CHECK_NAME;
  const cases = process.env.CASES || "deterministic cases over serial JSON Lines";
  if (![proofPath, devicePath, outputPath, profile, check].every(Boolean)) {
    console.error("PROOF, DEVICE_MANIFEST, EVIDENCE_OUT, PROFILE_NAME, and CHECK_NAME are required");
    process.exit(64);
  }
  const proof = JSON.parse(fs.readFileSync(proofPath, "utf8"));
  const device = JSON.parse(fs.readFileSync(devicePath, "utf8"));
  const record = deviceEvidenceRecord(proof, device, { profile, check, cases });
  writeDeviceEvidence(record, outputPath);
  console.log(`device evidence written: ${outputPath}`);
}

if (process.argv[1] && path.resolve(process.argv[1]) === import.meta.filename) runCLI();
