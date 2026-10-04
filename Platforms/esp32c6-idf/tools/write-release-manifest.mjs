// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

// Write the per-profile release manifest from what the build observed.
//
// Every value here is computed from an artifact this build produced or from a
// tracked declaration. Nothing is a literal result. The Core revision and
// dirty state come from the preparation report and build provenance, never
// from the lock directly; the lock is only a cross-check for a release build.
//
// Usage:
//   write-release-manifest.mjs repo-root profile lock VERSION preparation provenance output
//
// Environment:
//   AXOLOTY_PREVIEW_CORE_REVISION  Set by the compatibility-preview path. When
//                                  set, the manifest is labelled preview and
//                                  is never a compatibility claim. The Axoloty
//                                  version and tag stay null: the preparation
//                                  report carries the SHA, not the version, and
//                                  this repository never reads a Core file to
//                                  fill a field the report did not observe.

import crypto from "node:crypto";
import fs from "node:fs";
import path from "node:path";

const [repoRootInput, profilePathInput, lockPathInput, versionPathInput,
  preparationPathInput, provenancePathInput, outputPathInput] = process.argv.slice(2);
if (![repoRootInput, profilePathInput, lockPathInput, versionPathInput,
  preparationPathInput, provenancePathInput, outputPathInput].every(Boolean)) {
  console.error("usage: write-release-manifest.mjs repo-root profile lock VERSION preparation provenance output");
  process.exit(64);
}

const read = file => JSON.parse(fs.readFileSync(file, "utf8"));
const repoRoot = fs.realpathSync(repoRootInput);
const profile = read(profilePathInput);
const lock = read(lockPathInput);
const preparation = read(preparationPathInput);
const provenance = read(provenancePathInput);
const embeddedVersion = fs.readFileSync(versionPathInput, "utf8").trim();

// --- Gates: a release is built from a prepared, clean Core and a passed build.
if (typeof profile.board !== "string" || profile.board.trim() === "") {
  throw new Error("profile does not declare board; the release manifest requires it");
}
if (typeof profile.name !== "string" || profile.name.length === 0) {
  throw new Error("profile does not declare a name");
}
if (preparation.schemaVersion !== 1 || preparation.status !== "prepared") {
  throw new Error("cannot write a release manifest from an unprepared Core report");
}
if (preparation.core?.dirty !== false) {
  throw new Error("cannot write a release manifest from a dirty Core checkout");
}
if (provenance.schemaVersion !== 1 || provenance.status !== "passed") {
  throw new Error("cannot write a release manifest from a failed build");
}
if (provenance.core?.dirty !== false) {
  throw new Error("cannot write a release manifest from a dirty Core build");
}
if (!/^[0-9a-f]{40}$/.test(preparation.core?.sha ?? "")) {
  throw new Error("preparation report Core revision is not a full commit SHA");
}
if (preparation.core.sha !== provenance.core?.sha) {
  throw new Error("preparation report and build provenance disagree on the Core revision");
}
if (!/^[0-9a-f]{40}$/.test(provenance.firmware?.revision ?? "")) {
  throw new Error("firmware revision is not a full commit SHA");
}
if (provenance.firmware?.dirty !== false) {
  throw new Error("cannot write a release manifest from a dirty firmware checkout");
}
if (!/^[0-9a-f]{64}$/.test(provenance.artifact?.sha256 ?? "")) {
  throw new Error("build artifact checksum is not a SHA-256");
}
if (!Number.isInteger(provenance.artifact?.byteCount) || provenance.artifact.byteCount <= 0) {
  throw new Error("build artifact byte count is not a positive integer");
}
if (typeof provenance.artifact?.path !== "string" || provenance.artifact.path.length === 0) {
  throw new Error("build provenance has no artifact path");
}

const previewRevision = process.env.AXOLOTY_PREVIEW_CORE_REVISION ?? "";
const preview = previewRevision.length > 0;
if (preview) {
  if (!/^[0-9a-f]{40}$/.test(previewRevision) || previewRevision !== preparation.core.sha) {
    throw new Error("preview revision does not match the prepared Core revision");
  }
} else if (preparation.core.sha !== lock.core?.revision) {
  // Coordinated local development against an off-lock Core checkout is a
  // supported workflow, and it is not a release. There is no certificate to
  // record, so write nothing rather than mislabel a development build.
  console.error("write-release-manifest: Core is off-lock and no preview was requested; this is a development build, so no release manifest was written");
  process.exit(3);
}

// --- Version identity. The base tracks the lock; the cycle revision lives in VERSION.
const versionMatch = /^(\d+\.\d+\.\d+)-embedded\.([1-9]\d*)$/.exec(embeddedVersion);
if (!versionMatch) {
  throw new Error(`VERSION is not <base>-embedded.<revision>: ${embeddedVersion}`);
}
if (!preview && versionMatch[1] !== lock.core?.version) {
  throw new Error(`VERSION base ${versionMatch[1]} does not match the lock version ${lock.core?.version}`);
}
const axolotyVersion = preview ? null : lock.core.version;

// --- Transport backend identity and version, from a tracked source.
//
// A backend is a property of the transport, not of the SDK. MQTT has no client
// library of its own in this image, so its version is the pinned ESP-IDF
// component that supplies it. Zenoh pins `eclipse-zenoh/zenoh-pico` in its own
// lock. Reading the SDK version as the Zenoh backend version would certify a
// library the image does not use, so each transport declares its source and the
// identity is read from that source, never guessed from the transport name.
const platformDir = path.join(repoRoot, "Platforms", profile.platform);
const dependencyLockPath = path.join(platformDir, "dependencies.lock");
const versionFromLock = (lockText, component) => {
  const lines = lockText.split(/\r?\n/);
  const start = lines.findIndex(line => /^ {2}[^\s].*:\s*$/.test(line) && line.trim() === `${component}:`);
  if (start < 0) return null;
  for (let index = start + 1; index < lines.length; index += 1) {
    const line = lines[index];
    if (/^ {2}[^\s]/.test(line)) break;
    const match = /^ {4}version:\s*'?([^'\s]+)'?\s*$/.exec(line);
    if (match) return match[1];
  }
  return null;
};
// Each entry names the tracked file that pins the backend. `format: component`
// means a JSON component lock whose `component`, `version`, and `revision`
// fields are authoritative; `format: espidf` means the ESP-IDF dependency
// manifest and the named component supplies the version.
const transportBackendSources = {
  "mqtt-espidf": { backend: "esp-idf/mqtt", source: "dependencies.lock", component: "idf", format: "espidf" },
  "zenoh-pico": { source: "dependencies/zenoh-pico.lock.json", format: "component" },
};
const transportBackendSource = transportBackendSources[profile.transport];
if (!transportBackendSource) {
  throw new Error(`transport ${profile.transport} declares no release backend; refusing to guess one`);
}
const transportSourcePath = path.join(platformDir, transportBackendSource.source);
if (!fs.existsSync(transportSourcePath)) {
  throw new Error(`transport backend source ${transportBackendSource.source} is missing for profile ${profile.name}`);
}
let transportBackend;
let transportComponent;
let transportBackendVersion;
let transportBackendRevision;
if (transportBackendSource.format === "component") {
  const backendLock = read(transportSourcePath);
  transportBackend = backendLock.component;
  transportComponent = backendLock.component ?? null;
  transportBackendVersion = backendLock.version;
  transportBackendRevision = backendLock.revision ?? null;
  if (typeof transportBackend !== "string" || transportBackend.length === 0) {
    throw new Error(`${transportBackendSource.source} does not name a component; the transport backend has no identity`);
  }
  if (typeof transportBackendVersion !== "string" || transportBackendVersion.length === 0) {
    throw new Error(`${transportBackendSource.source} does not name a version`);
  }
} else {
  transportBackend = transportBackendSource.backend;
  transportComponent = transportBackendSource.component;
  transportBackendVersion = versionFromLock(fs.readFileSync(transportSourcePath, "utf8"), transportBackendSource.component);
  transportBackendRevision = null;
  if (transportBackendVersion === null) {
    throw new Error(`${transportBackendSource.source} does not pin component ${transportBackendSource.component}`);
  }
}

// --- Configuration fingerprint: the tracked selection and config inputs.
const stableStringify = value => JSON.stringify(value, (key, nested) => {
  if (nested && typeof nested === "object" && !Array.isArray(nested)) {
    return Object.keys(nested).sort().reduce((sorted, name) => {
      sorted[name] = nested[name];
      return sorted;
    }, {});
  }
  return nested;
});
const sha256File = file => fs.existsSync(file)
  ? crypto.createHash("sha256").update(fs.readFileSync(file)).digest("hex")
  : null;
const fingerprint = crypto.createHash("sha256").update(stableStringify({
  application: profile.application,
  board: profile.board ?? null,
  coreRevision: preparation.core.sha,
  dependenciesLockSha256: sha256File(dependencyLockPath),
  partitionTableSha256: sha256File(path.join(platformDir, "partitions.csv")),
  platform: profile.platform,
  profile: profile.name,
  sdkconfigDefaultsSha256: sha256File(path.join(platformDir, "sdkconfig.defaults")),
  transport: profile.transport,
})).digest("hex");

// --- Qualification: a passed device record for this exact artifact and Core.
const evidenceDir = path.join(repoRoot, "docs", "evidence");
const evidence = [];
if (fs.existsSync(evidenceDir)) {
  for (const name of fs.readdirSync(evidenceDir).sort()) {
    if (!name.endsWith(".json")) continue;
    const record = read(path.join(evidenceDir, name));
    if (record.profile !== profile.name) continue;
    const entry = {
      path: `docs/evidence/${name}`,
      check: record.check ?? null,
      tier: record.tier ?? null,
      status: record.status ?? null,
    };
    if (record.status === "passed" || record.status === "failed") {
      entry.coreRevision = record.coreRevision ?? null;
      entry.firmwareSHA256 = record.firmwareSHA256 ?? null;
    } else {
      entry.reason = record.reason ?? null;
    }
    evidence.push(entry);
  }
}
// docs/evidence.md: a build or component record proves the artifact compiles,
// not that the profile works. Only a device record, whose tier defaults to
// "device" when absent, may carry the compatibility claim.
const qualified = evidence.some(entry =>
  (entry.tier === "device" || entry.tier === null) &&
  entry.status === "passed" &&
  entry.coreRevision === preparation.core.sha &&
  entry.firmwareSHA256 === provenance.artifact.sha256);

// --- Resource evidence: only when a size report exists.
const sizeReportPath = path.join(path.dirname(provenance.artifact.path), "size.json");
let resources = null;
if (fs.existsSync(sizeReportPath)) {
  resources = { available: true, report: read(sizeReportPath) };
}

const compatibilityStatus = preview ? "preview" : (qualified ? "qualified" : "unqualified");
const shortSha = preparation.core.sha.slice(0, 12);
const compatibilityDescription = preview
  ? `Preview build of profile ${profile.name} against Axoloty candidate ${shortSha}; this is not a compatibility claim.`
  : qualified
    ? `Profile ${profile.name} is qualified against Axoloty ${axolotyVersion} (${shortSha}) on ${profile.board}.`
    : `Profile ${profile.name} is built against Axoloty ${axolotyVersion} (${shortSha}) but is not qualified; no passed device evidence matches this artifact (${provenance.artifact.sha256.slice(0, 12)}).`;

const manifest = {
  schemaVersion: 1,
  mode: preview ? "preview" : "release",
  profile: profile.name,
  application: profile.application,
  platform: profile.platform,
  board: profile.board ?? null,
  transport: {
    name: profile.transport,
    backend: transportBackend,
    component: transportComponent,
    version: transportBackendVersion,
    revision: transportBackendRevision,
    versionSource: path.relative(repoRoot, transportSourcePath),
  },
  compatibility: {
    scope: "profile",
    status: compatibilityStatus,
    description: compatibilityDescription,
  },
  axoloty: {
    version: axolotyVersion,
    tag: preview ? null : lock.core.tag,
    sha: preparation.core.sha,
    dirty: preparation.core.dirty,
    contractSha256: preparation.contractSHA256 ?? null,
  },
  embedded: {
    version: embeddedVersion,
    sha: provenance.firmware.revision,
    dirty: provenance.firmware.dirty,
  },
  toolchain: {
    swift: provenance.toolchain?.swift ?? null,
    sdk: provenance.toolchain?.espIdf ?? null,
    target: provenance.toolchain?.target ?? null,
  },
  configurationFingerprint: fingerprint,
  image: {
    path: path.basename(provenance.artifact.path),
    sha256: provenance.artifact.sha256,
    byteCount: provenance.artifact.byteCount,
  },
  resources,
  qualification: {
    status: qualified ? "qualified" : "unqualified",
    evidence,
  },
};

const temporary = `${outputPathInput}.tmp-${process.pid}`;
fs.mkdirSync(path.dirname(outputPathInput), { recursive: true });
fs.writeFileSync(temporary, `${JSON.stringify(manifest, null, 2)}\n`, { mode: 0o644 });
fs.renameSync(temporary, outputPathInput);
