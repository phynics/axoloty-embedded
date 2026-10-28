// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import fs from "node:fs";

const prefix = "AXOLOTY_HEAP_CAL_V1,";
const prefixMarker = "AXOLOTY_HEAP_CAL_V1";
const sdkHeapTraceAll = 0;
const uint32Max = 0xffff_ffff;
const beginStatuses = new Set([0, -2]);
// The runner always passes a valid local output pointer, so INVALID_ARGUMENT
// cannot be returned by its production end call.
const endStatuses = new Set([0, -2, -3]);
const cases = [
  ["zero", "none", 0, 0],
  ["malloc_free", "malloc(size=8);free", 1, 1],
  ["malloc_multiple", "malloc(size=8)x2;free", 2, 2],
  ["heap_caps_internal", "heap_caps_malloc(size=8;caps=INTERNAL+8BIT);heap_caps_free", 1, 1],
  ["calloc", "calloc(nmemb=2;size=4);free", 1, 1],
  ["overflow", "malloc(size=8)x129;free_after_end", 129, 128],
];
const keys = [
  "case", "result", "path", "coverage_complete", "begin", "end", "end_called",
  "alloc", "frees", "overflow", "mode", "mode_ok", "summary", "expected",
  "matched", "records",
];

function parseRecord(line, index, errors) {
  if (!line.startsWith(prefix)) {
    errors.push(`record ${index + 1} has an unknown prefix`);
    return null;
  }
  const fields = Object.create(null);
  for (const field of line.slice(prefix.length).split(",")) {
    const separator = field.indexOf("=");
    if (separator <= 0) {
      errors.push(`record ${index + 1} has a malformed field`);
      continue;
    }
    const key = field.slice(0, separator);
    if (!keys.includes(key)) {
      errors.push(`record ${index + 1} has unknown field ${key}`);
      continue;
    }
    if (Object.hasOwn(fields, key)) {
      errors.push(`record ${index + 1} duplicates field ${key}`);
      continue;
    }
    fields[key] = field.slice(separator + 1);
  }
  for (const key of keys) {
    if (!Object.hasOwn(fields, key)) errors.push(`record ${index + 1} is missing ${key}`);
  }
  return fields;
}

function integer(fields, key, index, errors, { min = 0, max = Number.MAX_SAFE_INTEGER } = {}) {
  const value = fields[key];
  if (typeof value !== "string" || !/^-?(0|[1-9][0-9]*)$/.test(value)) {
    errors.push(`record ${index + 1} has invalid ${key}`);
    return null;
  }
  const parsed = Number(value);
  if (!Number.isSafeInteger(parsed) || parsed < min || parsed > max) {
    errors.push(`record ${index + 1} has out-of-range ${key}`);
    return null;
  }
  return parsed;
}

function validateRecord(fields, index, errors) {
  if (fields === null) return { failed: false };
  const [caseId, path, expected, expectedRecords] = cases[index];
  if (fields.case !== caseId) errors.push(`record ${index + 1} expected case ${caseId}`);
  if (fields.path !== path) errors.push(`record ${index + 1} path does not match ${caseId}`);
  if (fields.result !== "PASS" && fields.result !== "FAIL") errors.push(`record ${index + 1} has invalid result`);

  const values = Object.create(null);
  for (const name of ["coverage_complete", "end_called", "overflow", "mode_ok", "summary"]) {
    values[name] = integer(fields, name, index, errors, { min: 0, max: 1 });
  }
  values.begin = integer(fields, "begin", index, errors, { min: -0x8000_0000, max: 0x7fff_ffff });
  values.end = integer(fields, "end", index, errors, { min: -0x8000_0000, max: 0x7fff_ffff });
  values.alloc = integer(fields, "alloc", index, errors, { min: 0, max: uint32Max });
  values.frees = integer(fields, "frees", index, errors, { min: 0, max: uint32Max });
  for (const name of ["matched", "records"]) {
    values[name] = integer(fields, name, index, errors, { min: 0, max: 128 });
  }
  values.expected = integer(fields, "expected", index, errors, { min: 0, max: 129 });
  const v = values;
  if (v.expected !== expected) errors.push(`${caseId} reports the wrong expected allocation count`);
  if (v.coverage_complete !== 0) errors.push(`${caseId} overstates allocator coverage`);
  v.mode = integer(fields, "mode", index, errors,
    v.summary === 0 ? { min: -1, max: -1 } : { min: 0, max: 1 });
  if (v.summary !== null && v.mode_ok !== null && v.mode !== null &&
      v.mode_ok !== Number(v.summary === 1 && v.mode === sdkHeapTraceAll)) {
    errors.push(`${caseId} mode_ok contradicts summary or raw SDK mode`);
  }
  if (v.begin !== null && !beginStatuses.has(v.begin)) errors.push(`${caseId} reports an unknown production begin status`);
  if (v.end !== null && !endStatuses.has(v.end)) errors.push(`${caseId} reports an unknown production end status`);
  if (v.matched !== null && v.expected !== null &&
      v.matched > Math.min(v.expected, v.summary === 1 ? v.records : 128)) {
    errors.push(`${caseId} matched count exceeds expected allocations or records`);
  }

  const failure = fields.result === "FAIL";
  // End writes the count on success and preserves the sentinel on every
  // failure. A later direct summary failure cannot change that output.
  if (v.end === 0) {
    if (v.alloc === null || v.alloc > 128 || v.alloc < v.matched) {
      errors.push(`${caseId} successful end lacks a capacity-bounded allocation count`);
    }
  } else if (v.alloc !== uint32Max) {
    errors.push(`${caseId} failed end did not preserve the allocation sentinel`);
  }
  if (v.summary === 1 && v.end === 0) {
    if (v.mode !== sdkHeapTraceAll || v.mode_ok !== 1 || v.overflow !== 0 ||
        v.records !== v.alloc) {
      errors.push(`${caseId} successful end contradicts its valid summary mode, overflow, output, or record count`);
    }
  }
  if (v.summary === 1 && v.end === -3 &&
      (v.mode !== sdkHeapTraceAll || v.overflow !== 1 || v.alloc !== uint32Max || v.records !== 128)) {
    errors.push(`${caseId} overflow status contradicts the production helper contract`);
  }
  if (!failure) {
    if (v.begin !== 0 || v.end_called !== 1 || v.summary !== 1 || v.mode !== sdkHeapTraceAll || v.mode_ok !== 1) {
      errors.push(`${caseId} PASS lacks successful begin, end, and ALL summary`);
    }
    if (caseId === "overflow") {
      if (v.end !== -3 || v.alloc !== uint32Max || v.frees !== 0 || v.overflow !== 1 ||
          v.records !== expectedRecords || v.matched !== expectedRecords) {
        errors.push("overflow PASS contradicts the production overflow status, sentinel, or retained records");
      }
    } else if (v.end !== 0 || v.alloc !== expected || v.frees !== expected || v.overflow !== 0 ||
        v.records !== expectedRecords || v.matched !== expected) {
      errors.push(`${caseId} PASS counters or address matches are inconsistent`);
    }
  } else if (v.begin !== 0) {
    if (v.end_called !== 0 || v.end !== -2 || v.alloc !== uint32Max || v.summary !== 0 ||
        v.frees !== 0 || v.overflow !== 0 || v.mode !== -1 || v.mode_ok !== 0 ||
        v.matched !== 0 || v.records !== 0) {
      errors.push(`${caseId} begin failure row is not structurally truthful`);
    }
  } else {
    if (v.end_called !== 1) errors.push(`${caseId} began but did not report calling end`);
    if (v.summary === 0) {
      // matched is from the earlier live inspection. Other summary fields
      // are placeholders, independently of end's status and written count.
      if (v.frees !== 0 || v.overflow !== 0 || v.mode !== -1 || v.mode_ok !== 0 || v.records !== 0) {
        errors.push(`${caseId} unavailable final summary has non-placeholder fields`);
      }
    }
  }
  return { failed: failure };
}

export function validate(text, { expectFailure = false } = {}) {
  const lines = text.split(/\r?\n/);
  if (lines.at(-1) === "") lines.pop();
  const errors = [];
  if (lines.length !== cases.length) errors.push(`expected ${cases.length} records, got ${lines.length}`);
  let failures = 0;
  for (let index = 0; index < Math.min(lines.length, cases.length); index += 1) {
    if (lines[index].length === 0) {
      errors.push(`record ${index + 1} is empty`);
      continue;
    }
    const fields = parseRecord(lines[index], index, errors);
    const record = validateRecord(fields, index, errors);
    if (record.failed) failures += 1;
  }
  if (expectFailure && failures === 0) errors.push("expected at least one reported failed control");
  if (!expectFailure && failures > 0) errors.push("normal calibration input contains a failed control");
  return { valid: errors.length === 0, errors };
}

export function extractCalibrationRows(rawText) {
  const rows = [];
  for (const line of rawText.split(/\r?\n/)) {
    const first = line.indexOf(prefixMarker);
    if (first < 0) continue;
    if (line.indexOf(prefixMarker, first + prefixMarker.length) >= 0) {
      throw new Error("raw capture line contains multiple calibration prefixes");
    }
    rows.push(line.slice(first));
  }
  return rows.length === 0 ? "" : `${rows.join("\n")}\n`;
}

function fixture() {
  const success = cases.map(([id, path, expected, records], index) =>
    `AXOLOTY_HEAP_CAL_V1,case=${id},result=PASS,path=${path},coverage_complete=0,begin=0,end=${index === 5 ? -3 : 0},end_called=1,alloc=${index === 5 ? uint32Max : expected},frees=${index === 0 || index === 5 ? 0 : expected},overflow=${index === 5 ? 1 : 0},mode=0,mode_ok=1,summary=1,expected=${expected},matched=${records},records=${records}`).join("\n");
  const assert = (condition, label) => { if (!condition) throw new Error(`fixture failed: ${label}`); };
  const mutate = (text, index, transform) => text.split("\n").map((line, n) => n === index ? transform(line) : line).join("\n");
  assert(validate(success).valid, "complete ordered normal records pass");
  assert(!validate(success.replace("case=malloc_free", "case=zero")).valid, "duplicate case rejected");
  assert(!validate(success.split("\n").slice(0, -1).join("\n")).valid, "missing record rejected");
  assert(!validate(success.slice(0, success.lastIndexOf("\n"))).valid, "truncated stream rejected");
  assert(!validate(success.replace("\n", "\n\n")).valid, "empty serial row rejected");
  assert(!validate(mutate(success, 1, (s) => s.replace("result=PASS", "result=FAIL,result=PASS"))).valid, "duplicate result rejected");
  assert(!validate(mutate(success, 1, (s) => s.replace("alloc=1", "alloc=0,alloc=1"))).valid, "duplicate alloc rejected");
  assert(!validate(mutate(success, 1, (s) => s.replace("case=malloc_free", "case=zero,case=malloc_free"))).valid, "duplicate case field rejected");
  assert(!validate(mutate(success, 1, (s) => s.replace("mode=0", "mode=-999"))).valid, "invalid raw mode rejected");
  assert(!validate(mutate(success, 1, (s) => s.replace("mode=0", "mode=1"))).valid, "mode contradiction rejected");
  assert(!validate(mutate(success, 1, (s) => s.replace("overflow=0", "overflow=1"))).valid, "ordinary overflow rejected");
  assert(!validate(mutate(success, 1, (s) => s.replace("overflow=0", "overflow=-1"))).valid, "negative overflow rejected");
  assert(!validate(mutate(success, 1, (s) => s.replace("alloc=1", "alloc=4294967296"))).valid, "uint32 overflow rejected");
  assert(!validate(mutate(success, 1, (s) => s.replace("alloc=1", `alloc=${"9".repeat(400)}`))).valid, "unsafe integer rejected");
  assert(!validate(mutate(success, 1, (s) => `${s},typo_field=1`)).valid, "unknown field rejected");
  assert(!validate(mutate(success, 1, (s) => s.replace("frees=1", "frees=-1"))).valid, "negative count rejected");
  assert(!validate(mutate(success, 5, (s) => s.replace("frees=0", "frees=-1"))).valid, "negative overflow free count rejected");
  assert(!validate(mutate(success, 1, (s) => s.replace("mode_ok=1", "mode_ok=2"))).valid, "invalid flag rejected");
  assert(!validate(mutate(success, 5, (s) => s.replace("end=-3", "end=0"))).valid, "overflow/status contradiction rejected");
  assert(!validate(mutate(success, 5, (s) => s.replace("matched=128", "matched=127"))).valid, "overflow retained-record mismatch rejected");
  const failMode = mutate(success, 1, (s) => s.replace("result=PASS", "result=FAIL").replace("mode=0", "mode=1").replace("mode_ok=1", "mode_ok=0").replace("matched=1", "matched=0"));
  assert(!validate(failMode, { expectFailure: true }).valid, "successful end with LEAKS summary rejected in failure mode");
  const failOverflow = mutate(success, 1, (s) => s.replace("result=PASS", "result=FAIL").replace("end=0", "end=0").replace("alloc=1", "alloc=129").replace("overflow=0", "overflow=1").replace("records=1", "records=128").replace("matched=1", "matched=0"));
  assert(!validate(failOverflow, { expectFailure: true }).valid, "successful end with overflow summary rejected in failure mode");
  const failUnknownBegin = mutate(success, 1, (s) => s.replace("result=PASS", "result=FAIL").replace("begin=0", "begin=12345").replace("end=0", "end=-2").replace("end_called=1", "end_called=0").replace("alloc=1", `alloc=${uint32Max}`).replace("summary=1", "summary=0").replace("mode=0", "mode=-1").replace("mode_ok=1", "mode_ok=0").replace("matched=1", "matched=0").replace("records=1", "records=0").replace("frees=1", "frees=0"));
  assert(!validate(failUnknownBegin, { expectFailure: true }).valid, "unknown begin status rejected in failure mode");
  const failUnknownEnd = mutate(success, 1, (s) => s.replace("result=PASS", "result=FAIL").replace("end=0", "end=-42").replace("alloc=1", `alloc=${uint32Max}`).replace("summary=1", "summary=0").replace("mode=0", "mode=-1").replace("mode_ok=1", "mode_ok=0").replace("matched=1", "matched=0").replace("records=1", "records=0").replace("frees=1", "frees=0"));
  assert(!validate(failUnknownEnd, { expectFailure: true }).valid, "unknown end status rejected without summary");
  const failed = mutate(success, 1, (s) => s.replace("result=PASS", "result=FAIL").replace("matched=1", "matched=0"));
  assert(validate(failed, { expectFailure: true }).valid, "structurally truthful failed control accepted");
  assert(!validate(mutate(failed, 1, (s) => s.replace("end_called=1", "end_called=-7")), { expectFailure: true }).valid,
    "malformed failure row rejected");
  const raw = "I (22) boot: ESP-IDF v5.4.0\n" + success.split("\n").map((row) => `I (29) app: ${row}`).join("\n") +
    "\nSMOKE_V2,case=boot,result=PASS\n";
  const extracted = extractCalibrationRows(raw);
  assert(extracted.split("\n").filter(Boolean).length === cases.length, "all calibration rows extracted");
  assert(validate(extracted).valid, "boot and smoke rows are excluded from calibration validation");
  const truncatedPrefix = extractCalibrationRows(`${raw}\nI (30) app: AXOLOTY_HEAP_CAL_V1\n`);
  assert(truncatedPrefix.split("\n").filter(Boolean).length === cases.length + 1 &&
    !validate(truncatedPrefix).valid, "truncated calibration prefix is retained and rejected");
  assert(!validate(extracted.replace("case=malloc_free", "case=malloc_free,result=FAIL" )).valid,
    "malformed calibration-prefix row is retained and rejected");
}

if (process.argv.includes("--self-test")) {
  fixture();
  process.stdout.write("heap-trace-calibration-validator: PASS\n");
} else if (process.argv[2] === "--extract-raw") {
  const input = process.argv[3];
  const output = process.argv[4];
  if (!input || !output) throw new Error("usage: validate-heap-trace-calibration.mjs --extract-raw <raw-capture> <calibration-rows>");
  const inputPath = fs.realpathSync(input);
  if (fs.existsSync(output)) {
    const outputPath = fs.realpathSync(output);
    const inputStat = fs.statSync(inputPath);
    const outputStat = fs.statSync(outputPath);
    if (inputPath === outputPath ||
        (inputStat.dev === outputStat.dev && inputStat.ino === outputStat.ino)) {
      throw new Error("raw capture and extracted calibration output must be different files");
    }
  }
  const extracted = extractCalibrationRows(fs.readFileSync(input, "utf8"));
  fs.writeFileSync(output, extracted);
  process.stdout.write(`heap-trace-calibration-extract: ${extracted.split(/\r?\n/).filter(Boolean).length} rows retained; raw capture unchanged\n`);
} else {
  const expectFailure = process.argv.includes("--expect-failure");
  const input = process.argv.at(-1);
  if (!input || input.startsWith("--")) throw new Error("usage: validate-heap-trace-calibration.mjs [--expect-failure] <records-file>");
  const result = validate(fs.readFileSync(input, "utf8"), { expectFailure });
  if (!result.valid) {
    for (const error of result.errors) process.stderr.write(`heap-trace-calibration-validator: ${error}\n`);
    process.exitCode = 1;
  } else {
    process.stdout.write(`heap-trace-calibration-validator: PASS${expectFailure ? " (observer failure rows structurally valid)" : ""}\n`);
  }
}
