// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

// The one way a harness writes a tracked evidence record.
//
// A record under docs/evidence/ is the last result that passed. A later run that
// does not pass (the board was missing, the host peer failed, the validation
// failed) says nothing about the image that record names, so it must not replace
// it: a loop that commits after each run would otherwise commit the failure over
// the proof. A non-passing record is withheld into the scratch directory instead,
// where the operator can read it, and the writer says so.
//
// A record replaces anything that is not a passed record: a missing file, a
// failed record, or an unexecuted one.

import fs from "node:fs";
import path from "node:path";

function existingStatus(outputPath) {
  try {
    return JSON.parse(fs.readFileSync(outputPath, "utf8")).status;
  } catch {
    return null;
  }
}

function writeAtomically(record, target) {
  const temporary = `${target}.tmp-${process.pid}`;
  fs.mkdirSync(path.dirname(target), { recursive: true });
  fs.writeFileSync(temporary, `${JSON.stringify(record, null, 2)}\n`, { mode: 0o644 });
  fs.renameSync(temporary, target);
  return target;
}

/**
 * Writes `record` to `outputPath` unless that would replace a passed record with
 * one that is not. Returns `{ written, path }`; `path` is where the record went.
 * A withheld record goes to `withheldDir`, default `$AXOLOTY_SCRATCH/withheld-evidence`.
 */
export function writeEvidenceRecord(record, outputPath, { withheldDir } = {}) {
  if (record.status !== "passed" && existingStatus(outputPath) === "passed") {
    const directory = withheldDir
      ?? path.join(process.env.AXOLOTY_SCRATCH || path.resolve(path.dirname(outputPath), "..", "..", ".axoloty"), "withheld-evidence");
    const withheld = writeAtomically(record, path.join(directory, path.basename(outputPath)));
    console.error(`evidence: ${path.basename(outputPath)} keeps its passed record; this ${record.status} record was withheld to ${withheld}`);
    return { written: false, path: withheld };
  }
  return { written: true, path: writeAtomically(record, outputPath) };
}
