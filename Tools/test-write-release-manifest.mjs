// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

// Run the release-manifest generator against tracked-shape fixtures and assert
// the transport backend identity it records. The regression this guards: the
// Zenoh profile must name `eclipse-zenoh/zenoh-pico` and its pinned version,
// never the ESP-IDF SDK version pinned for the MQTT backend.

import assert from "node:assert/strict";
import { writeEvidenceRecord } from "../Tests/embedded/evidence-record.mjs";
import { execFileSync } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";

const here = path.dirname(fileURLToPath(import.meta.url));
const repo = path.resolve(here, "..");
const GENERATOR = path.join(repo, "Platforms", "esp32c6-idf", "tools", "write-release-manifest.mjs");
const repositoryLock = JSON.parse(fs.readFileSync(path.join(repo, "axoloty-core.lock.json"), "utf8")).core;
// Release certificates require a tagged lock. The fixture names a tag even when
// the repository lock is between releases.
const lock = { ...repositoryLock, tag: repositoryLock.tag || `v${repositoryLock.version}` };
const CORE_SHA = lock.revision;
const VERSION = `${lock.version}-embedded.2`;
const FIRMWARE_SHA = "b".repeat(40);
const IMAGE_SHA = "a".repeat(64);
const ZENOH_REVISION = "96006957fddef401c20c8c2d813c2a630b666974";

const REQUIRED_CHECKS = [
  { check: "smoke", artifact: "release", records: 1, units: 1 },
  { check: "interop", artifact: "variant", records: 2, units: 1 },
  { check: "exchange", artifact: "variant", records: 2, units: 2 },
];

const writeJson = (file, value) => {
  fs.mkdirSync(path.dirname(file), { recursive: true });
  fs.writeFileSync(file, `${JSON.stringify(value, null, 2)}\n`);
};

const generate = (workspace, profilePath, output) => execFileSync(process.execPath, [
  GENERATOR,
  workspace,
  profilePath,
  path.join(workspace, "axoloty-core.lock.json"),
  path.join(workspace, "VERSION"),
  path.join(workspace, "preparation.json"),
  path.join(workspace, "provenance.json"),
  output,
], { stdio: "pipe" });

const workspace = fs.mkdtempSync(path.join(os.tmpdir(), "release-manifest-"));
try {
  const platform = path.join(workspace, "Platforms", "esp32c6-idf");
  fs.writeFileSync(path.join(workspace, "VERSION"), `${VERSION}\n`);
  writeJson(path.join(workspace, "axoloty-core.lock.json"), { schemaVersion: 1, core: lock });
  fs.mkdirSync(path.join(platform, "dependencies"), { recursive: true });
  fs.writeFileSync(path.join(platform, "dependencies.lock"), "  idf:\n    version: 5.4.0\n");
  writeJson(path.join(platform, "dependencies", "zenoh-pico.lock.json"), {
    schemaVersion: 1,
    component: "eclipse-zenoh/zenoh-pico",
    version: "1.10.0",
    revision: ZENOH_REVISION,
  });
  writeJson(path.join(workspace, "preparation.json"), {
    schemaVersion: 1,
    status: "prepared",
    core: { sha: CORE_SHA, dirty: false },
  });
  writeJson(path.join(workspace, "provenance.json"), {
    schemaVersion: 1,
    status: "passed",
    core: { sha: CORE_SHA, dirty: false },
    firmware: { revision: FIRMWARE_SHA, dirty: false },
    artifact: { path: path.join(workspace, "axoloty-swift.bin"), sha256: IMAGE_SHA, byteCount: 752624 },
    toolchain: { swift: "Swift fixture", espIdf: "ESP-IDF fixture", target: "esp32c6" },
  });

  const profiles = {
    "mqtt-espidf": {
      name: "esp32c6-mqtt",
      expected: {
        name: "mqtt-espidf",
        backend: "esp-idf/mqtt",
        component: "idf",
        version: "5.4.0",
        revision: null,
        versionSource: "Platforms/esp32c6-idf/dependencies.lock",
      },
    },
    "zenoh-pico": {
      name: "esp32c6-zenoh",
      expected: {
        name: "zenoh-pico",
        backend: "eclipse-zenoh/zenoh-pico",
        component: "eclipse-zenoh/zenoh-pico",
        version: "1.10.0",
        revision: ZENOH_REVISION,
        versionSource: "Platforms/esp32c6-idf/dependencies/zenoh-pico.lock.json",
      },
    },
  };

  for (const [transport, config] of Object.entries(profiles)) {
    const profilePath = path.join(workspace, "Profiles", config.name, "profile.json");
    writeJson(profilePath, {
      name: config.name,
      application: "device-smoke-agent",
      platform: "esp32c6-idf",
      transport,
      board: "ESP32-C6-DevKitC-1",
      qualification: { requiredChecks: REQUIRED_CHECKS },
    });
    const output = path.join(workspace, "out", `${config.name}.json`);
    generate(workspace, profilePath, output);
    const manifest = JSON.parse(fs.readFileSync(output, "utf8"));
    assert.deepStrictEqual(manifest.transport, config.expected,
      `${config.name} records the wrong transport backend identity`);
  }

  // A transport with no declaration must fail closed rather than fall back to
  // the transport name or the SDK version.
  const unknownProfile = path.join(workspace, "Profiles", "esp32c6-unknown", "profile.json");
  writeJson(unknownProfile, {
    name: "esp32c6-unknown",
    application: "device-smoke-agent",
    platform: "esp32c6-idf",
    transport: "carrier-unknown",
    board: "ESP32-C6-DevKitC-1",
    qualification: { requiredChecks: REQUIRED_CHECKS },
  });
  let failed = false;
  try {
    generate(workspace, unknownProfile, path.join(workspace, "out", "unknown.json"));
  } catch (error) {
    failed = true;
    assert.match(String(error.stderr), /declares no release backend/,
      "the refusal did not name the missing backend declaration");
  }
  assert.ok(failed, "a transport with no backend declaration was accepted");

  // A certificate needs every required check. One passed device record used to
  // qualify the whole profile, so each way of missing a check is proved here.
  const gateProfile = path.join(workspace, "Profiles", "esp32c6-mqtt", "profile.json");
  const evidenceDir = path.join(workspace, "docs", "evidence");
  const passed = (check, suffix, device, firmwareSHA256) => writeJson(
    path.join(evidenceDir, `esp32c6-mqtt-${check}${suffix}.json`),
    { profile: "esp32c6-mqtt", check, tier: "device", status: "passed", device, firmwareSHA256, coreRevision: CORE_SHA });
  const qualification = () => {
    const output = path.join(workspace, "out", "gate.json");
    generate(workspace, gateProfile, output);
    return JSON.parse(fs.readFileSync(output, "utf8")).qualification;
  };
  const expectBlocked = (pattern, message) => {
    const result = qualification();
    assert.equal(result.status, "unqualified", message);
    assert.match(result.outstanding.join("\n"), pattern, message);
  };

  expectBlocked(/smoke has no record/, "no evidence at all qualified the profile");
  passed("smoke", "", "unit-a", IMAGE_SHA);
  expectBlocked(/exchange has no record/, "a passed smoke alone qualified the profile");
  passed("interop", "-a", "unit-a", "1".repeat(64));
  passed("exchange", "-a", "unit-a", "c".repeat(64));
  expectBlocked(/interop has 1 of 2 required records/, "one role satisfied a two-role check");
  passed("interop", "-b", "unit-a", "2".repeat(64));
  expectBlocked(/exchange has 1 of 2 required records/, "one record satisfied a two-record check");
  passed("exchange", "-b", "unit-a", "d".repeat(64));
  expectBlocked(/exchange ran on 1 of 2/, "two records from one board satisfied a two-unit check");
  passed("exchange", "-b", "unit-b", "d".repeat(64));
  assert.equal(qualification().status, "qualified", "a complete evidence set was not qualified");

  // A variant check that passed for image A, then failed for image B, must not
  // qualify: the writer keeps A's passed record and carries B's failure beside it
  // (#117), and the generator reads that failure as a failed record for the check.
  const interopRecord = path.join(evidenceDir, "esp32c6-mqtt-interop-a.json");
  const writeThrough = (status, firmwareSHA256) => {
    const originalError = console.error;
    console.error = () => {};
    try {
      writeEvidenceRecord({ profile: "esp32c6-mqtt", check: "interop", tier: "device", status, device: "unit-a", firmwareSHA256, coreRevision: CORE_SHA, ...(status === "unexecuted" ? { reason: "fixture" } : {}) }, interopRecord, { withheldDir: path.join(workspace, "withheld") });
    } finally { console.error = originalError; }
  };
  writeThrough("failed", "8".repeat(64));
  assert.ok(fs.existsSync(path.join(evidenceDir, "esp32c6-mqtt-interop-a.failed.json")), "the failure was not carried beside the pass");
  assert.equal(JSON.parse(fs.readFileSync(interopRecord, "utf8")).status, "passed", "the writer dropped the earlier pass");
  expectBlocked(/interop has a record that did not pass/, "a variant check that failed on a newer image still qualified on the older pass");
  writeThrough("unexecuted", "8".repeat(64));
  expectBlocked(/interop has a record that did not pass/, "an unexecuted attempt cleared a recorded failure");
  writeThrough("passed", "8".repeat(64));
  assert.equal(qualification().status, "qualified", "a later pass did not clear the failure");

  passed("smoke", "", "unit-a", "e".repeat(64));
  expectBlocked(/smoke has a record that did not pass/, "a release check accepted another image");
  passed("smoke", "", "unit-a", IMAGE_SHA);
  writeJson(path.join(evidenceDir, "esp32c6-mqtt-exchange-b.json"),
    { profile: "esp32c6-mqtt", check: "exchange", tier: "device", status: "failed", device: "unit-b", firmwareSHA256: "d".repeat(64), coreRevision: CORE_SHA });
  expectBlocked(/exchange has a record that did not pass/, "a failed record was ignored");
  writeJson(path.join(evidenceDir, "esp32c6-mqtt-exchange-b.json"),
    { profile: "esp32c6-mqtt", check: "exchange", tier: "device", status: "unexecuted", reason: "fixture" });
  expectBlocked(/exchange has a record that did not pass/, "an unexecuted record was ignored");
  passed("exchange", "-b", "unit-b", "d".repeat(64));
  writeJson(path.join(evidenceDir, "esp32c6-mqtt-exchange-a.json"),
    { profile: "esp32c6-mqtt", check: "exchange", tier: "device", status: "passed", device: "unit-a", firmwareSHA256: "c".repeat(64), coreRevision: "f".repeat(40) });
  expectBlocked(/exchange has a record that did not pass/, "a record from another Core revision was accepted");
  fs.rmSync(evidenceDir, { recursive: true });

  const undeclared = path.join(workspace, "Profiles", "esp32c6-undeclared", "profile.json");
  writeJson(undeclared, {
    name: "esp32c6-undeclared",
    application: "device-smoke-agent",
    platform: "esp32c6-idf",
    transport: "mqtt-espidf",
    board: "ESP32-C6-DevKitC-1",
  });
  assert.throws(() => generate(workspace, undeclared, path.join(workspace, "out", "undeclared.json")),
    /declares no qualification.requiredChecks/, "a profile with no required checks was accepted");

  // A certificate names a tagged Core release. An untagged lock is between
  // releases, so the generator must refuse instead of labelling a commit.
  writeJson(path.join(workspace, "axoloty-core.lock.json"), { schemaVersion: 1, core: { ...lock, tag: null } });
  const untaggedOutput = path.join(workspace, "out", "untagged.json");
  let untaggedStatus = 0;
  try {
    generate(workspace, path.join(workspace, "Profiles", "esp32c6-mqtt", "profile.json"), untaggedOutput);
  } catch (error) {
    untaggedStatus = error.status;
    assert.match(String(error.stderr), /names no Core tag/,
      "the skip did not name the missing Core tag");
  }
  // Status 3 is the wrapper's 'no release manifest' outcome: the build
  // succeeds, and only the certificate is withheld.
  assert.equal(untaggedStatus, 3, "an untagged lock did not take the no-certificate path");
  assert.ok(!fs.existsSync(untaggedOutput), "a release certificate was written against an untagged lock");
} finally {
  fs.rmSync(workspace, { recursive: true, force: true });
}

console.log("release-manifest generator checks passed");
