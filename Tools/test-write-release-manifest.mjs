// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

// Run the release-manifest generator against tracked-shape fixtures and assert
// the transport backend identity it records. The regression this guards: the
// Zenoh profile must name `eclipse-zenoh/zenoh-pico` and its pinned version,
// never the ESP-IDF SDK version pinned for the MQTT backend.

import assert from "node:assert/strict";
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

  // A certificate names a tagged Core release. An untagged lock is between
  // releases, so the generator must refuse instead of labelling a commit.
  writeJson(path.join(workspace, "axoloty-core.lock.json"), { schemaVersion: 1, core: { ...lock, tag: null } });
  let untaggedFailed = false;
  try {
    generate(workspace, path.join(workspace, "Profiles", "esp32c6-mqtt", "profile.json"),
      path.join(workspace, "out", "untagged.json"));
  } catch (error) {
    untaggedFailed = true;
    assert.match(String(error.stderr), /names no Core tag/,
      "the refusal did not name the missing Core tag");
  }
  assert.ok(untaggedFailed, "a release certificate was written against an untagged lock");
} finally {
  fs.rmSync(workspace, { recursive: true, force: true });
}

console.log("release-manifest generator checks passed");
