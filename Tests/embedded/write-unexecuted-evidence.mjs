// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

// Writes one `unexecuted` device evidence record. A run that did not happen
// records that fact; it never claims a result. `docs/evidence.md` allows three
// statuses, and this writer only ever produces the honest one for a run that
// never reached the board.

import fs from "node:fs";
import path from "node:path";
import { writeEvidenceRecord } from "./evidence-record.mjs";

/** Returns the record an unexecuted run supports; throws when a field is absent. */
export function unexecutedEvidenceRecord({ profile, check, coreRevision, reason, recordedAt }) {
  if (typeof profile !== "string" || profile.length === 0) throw new Error("profile is required");
  if (typeof check !== "string" || check.length === 0) throw new Error("check is required");
  if (typeof reason !== "string" || reason.length === 0) throw new Error("reason is required");
  return {
    schemaVersion: 1,
    profile,
    check,
    tier: "device",
    status: "unexecuted",
    recordedAt: recordedAt ?? new Date().toISOString().slice(0, 10),
    ...(typeof coreRevision === "string" && coreRevision.length > 0 ? { coreRevision } : {}),
    reason,
  };
}

/**
 * Writes a record, unless it would replace a passed record (see evidence-record.mjs).
 * Returns the path the record went to.
 */
export function writeUnexecutedEvidence(record, outputPath) {
  return writeEvidenceRecord(record, outputPath).path;
}

function runCLI() {
  const [outputPath] = process.argv.slice(2);
  const profile = process.env.PROFILE_NAME;
  const check = process.env.CHECK_NAME;
  const reason = process.env.REASON;
  const coreRevision = process.env.CORE_REVISION;
  if (!outputPath || !profile || !check || !reason) {
    console.error("usage: write-unexecuted-evidence.mjs <output> (PROFILE_NAME, CHECK_NAME, REASON required)");
    process.exit(64);
  }
  const written = writeUnexecutedEvidence(unexecutedEvidenceRecord({ profile, check, coreRevision, reason }), outputPath);
  if (written === outputPath) console.log(`unexecuted evidence written: ${outputPath}`);
}

if (process.argv[1] && path.resolve(process.argv[1]) === import.meta.filename) runCLI();
