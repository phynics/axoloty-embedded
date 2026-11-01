// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

// The one way a harness writes a tracked evidence record.
//
// A record under docs/evidence/ is the last result that passed. What a later run
// does to it depends on what the run says:
//
// - passed      replaces any record, and removes the failure beside it: the
//               check ran again and passed.
// - unexecuted  says nothing about any image (the board was missing, the host
//               peer failed to start), so it never replaces a passed or failed
//               record. It is withheld into the scratch directory under a name
//               of its own, so no attempt overwrites another.
// - failed      is a result. It must not erase the proof of an earlier image,
//               and it must not let that proof certify anything either: the
//               failed record is written beside the passed one as
//               `<name>.failed.json`. The release manifest generator reads every
//               record of a check, and a failed record blocks the check until a
//               later run passes (which removes it) or an operator removes it.
//
// A record replaces a missing file, a failed record, or an unexecuted one,
// whatever its status.

import fs from "node:fs";
import path from "node:path";

function statusOf(file) {
  try {
    return JSON.parse(fs.readFileSync(file, "utf8")).status;
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

/** Where the failure of a check is carried beside its passed record. */
export function failureSidecarPath(outputPath) {
  return outputPath.replace(/\.json$/, ".failed.json");
}

/**
 * Writes `record` for `outputPath` by the rules above. Returns `{ written, path }`;
 * `written` is true when `path` is the tracked record or its failure sidecar and
 * false when the record was withheld to `withheldDir` (default
 * `$AXOLOTY_SCRATCH/withheld-evidence`) under a unique name.
 */
export function writeEvidenceRecord(record, outputPath, { withheldDir, now = () => new Date() } = {}) {
  const sidecar = failureSidecarPath(outputPath);
  const existing = statusOf(outputPath);
  if (record.status === "passed") {
    const written = writeAtomically(record, outputPath);
    fs.rmSync(sidecar, { force: true });
    return { written: true, path: written };
  }
  if (record.status === "failed" && existing === "passed") {
    console.error(`evidence: ${path.basename(outputPath)} keeps its passed record; the failed run is recorded as ${path.basename(sidecar)}, which blocks the check until a run passes`);
    return { written: true, path: writeAtomically(record, sidecar) };
  }
  if (record.status === "unexecuted" && (existing === "passed" || existing === "failed" || statusOf(sidecar) !== null)) {
    const directory = withheldDir
      ?? path.join(process.env.AXOLOTY_SCRATCH || path.resolve(path.dirname(outputPath), "..", "..", ".axoloty"), "withheld-evidence");
    const stamp = now().toISOString().replace(/[:.]/g, "-");
    const base = path.basename(outputPath).replace(/\.json$/, `.${stamp}-${process.pid}`);
    // Two attempts in one millisecond of one process still get names of their own.
    let name = `${base}.json`;
    for (let counter = 1; fs.existsSync(path.join(directory, name)); counter += 1) name = `${base}-${counter}.json`;
    const withheld = writeAtomically(record, path.join(directory, name));
    console.error(`evidence: ${path.basename(outputPath)} keeps its earlier result; this unexecuted record was withheld to ${withheld}`);
    return { written: false, path: withheld };
  }
  return { written: true, path: writeAtomically(record, outputPath) };
}
