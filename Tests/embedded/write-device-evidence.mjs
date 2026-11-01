// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

// Build and write one device evidence record from a completed proof. Every
// field is computed from what the run observed; a failed proof refuses.

import fs from "node:fs";
import path from "node:path";
import { writeEvidenceRecord } from "./evidence-record.mjs";

/** Returns the evidence record a passed proof supports; throws otherwise. */
export function deviceEvidenceRecord(proof, device, { profile, check, cases }) {
  if (proof.result !== "passed" || proof.smoke?.validation?.passed !== true) {
    throw new Error("refusing to write device evidence from a failed proof");
  }
  const counts = proof.smoke.validation.counts ?? {};
  const passed = Number.isInteger(counts.passed) ? counts.passed : 0;
  // Declared-unsupported capabilities are neither passes nor failures. Name
  // them, so "N/N passed" never reads as full coverage of the expected set.
  const unsupported = Number.isInteger(counts.unsupported) ? counts.unsupported : 0;
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
    result: `${passed}/${passed} passed` + (unsupported > 0 ? `, ${unsupported} declared unsupported` : ""),
  };
}

/** Writes a record, unless it would replace a passed record, and returns its path. */
export function writeDeviceEvidence(record, outputPath) {
  return writeEvidenceRecord(record, outputPath).path;
}

/**
 * Writes the record for a run whose validation passed, taking the firmware
 * checksum and Core revision from the build provenance the profile build wrote
 * into `evidenceDir`. Throws, writing nothing, when the validation failed.
 */
export function writePassedDeviceEvidence({ evidenceDir, devicePath, validation, profile, check, cases, output }) {
  const provenance = JSON.parse(fs.readFileSync(path.join(evidenceDir, "build-provenance.json"), "utf8"));
  const device = JSON.parse(fs.readFileSync(devicePath, "utf8"));
  const proof = {
    result: "passed",
    smoke: { validation },
    firmwareSha256: provenance.artifact.sha256,
    coreSha: provenance.core.sha,
  };
  writeDeviceEvidence(deviceEvidenceRecord(proof, device, { profile, check, cases }), output);
  console.log(`device evidence written: ${output}`);
  return output;
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
