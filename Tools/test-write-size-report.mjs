// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

// Exercises the size report writer on section tables in `size -A` shape, taken
// from the 0.10.0-embedded.2 images, without a toolchain or a board.

import assert from "node:assert/strict";
import {
  appPartitionBytes,
  buildConfiguration,
  buildReport,
  computeMetrics,
  parseSizeA,
  verdicts,
} from "../Platforms/esp32c6-idf/tools/write-size-report.mjs";

const ZENOH_SIZE_A = `axoloty-swift.elf  :
section                  size         addr
.rtc_reserved              24   1342193640
.iram0.text             78092   1082130432
.iram0.data                 4   1082208524
.dram0.data             10209   1082208528
.noinit                     3   1082218737
.dram0.bss              69312   1082218752
.flash.text            495056   1107296288
.flash_rodata_dummy    524288   1107296288
.flash.appdesc            256   1107820576
.flash.rodata           86832   1107820832
.flash.rodata_noload     4372   1107907696
.debug_info           2379099            0
Total                  6535379
`;

const PARTITIONS = `# Name, Type, SubType, Offset, Size, Flags
nvs,      data, nvs,     0x9000,  0x6000,
phy_init, data, phy,     0xf000,  0x1000,
factory,  app,  factory, 0x10000, 0x1f0000,
`;

const profile = {
  name: "esp32c6-zenoh",
  application: "device-smoke-agent",
  platform: "esp32c6-idf",
  transport: "zenoh-pico",
  core: { revision: "087bd9bb1bfb563d0347799245ea4dd43e509bc9" },
  budgets: {
    basis: "test fixture",
    build: { imageBytes: 738304, flashTextBytes: 544768, staticRamBytes: 174080, dramBssBytes: 76800 },
  },
};

// A second profile can omit optional end-marker, IRAM data and no-init rows.
const mqttSize = ZENOH_SIZE_A.replace(".iram0.data                 4   1082208524\n", "").replace(".noinit                     3   1082218737\n", "").replace("495056", "500000");
assert.equal(computeMetrics(parseSizeA(mqttSize), 100).flashTextBytes, 500000);

// Section parsing keeps every section line and ignores headers and totals.
const sections = parseSizeA(ZENOH_SIZE_A);
assert.equal(sections.get(".iram0.text"), 78092);
assert.equal(sections.get(".dram0.bss"), 69312);
assert.equal(sections.has("Total"), false);
assert.equal(sections.has("section"), false);

// Metrics: static RAM is instruction RAM plus initialized, zeroed and no-init data.
const metrics = computeMetrics(sections, 670560);
assert.equal(metrics.flashTextBytes, 495056);
assert.equal(metrics.flashRodataBytes, 86832 + 256);
assert.equal(metrics.staticRamBytes, 78092 + 4 + 10209 + 69312 + 3);
assert.equal(metrics.dramBssBytes, 69312 + 3);
assert.equal(metrics.initializedDataBytes, 10209 + 4);

// The padding section is not flash use, and a missing section counts as zero.
assert.equal(computeMetrics(new Map(), 0).staticRamBytes, 0);

assert.equal(appPartitionBytes(PARTITIONS), 0x1f0000);
assert.throws(() => appPartitionBytes("nvs, data, nvs, 0x9000, 0x6000,\n"), /no factory application partition/);

const SDKCONFIG = "CONFIG_IDF_TARGET=\"esp32c6\"\n";
const args = { imageSha256: "a".repeat(64), coreRevision: "b".repeat(40), sdkconfigText: SDKCONFIG, networkState: "unconfigured" };
const policy = { schema: "axoloty.app-static-storage-policy.v1", profile: profile.name, status: "enforced" };
for (const bad of ["not a section table", ZENOH_SIZE_A.replace(/\.dram0.bss[^\n]*\n/, ""), ZENOH_SIZE_A.replace(/Total[^\n]*\n/, ""), ZENOH_SIZE_A.replace("Total ", ".flash.text 1 0\nTotal "), ZENOH_SIZE_A.replace("Total ", ".bad nope 0\nTotal "), ZENOH_SIZE_A.replace("Total ", ".bad 9007199254740992 0\nTotal "), ZENOH_SIZE_A.replace("6535379", "9007199254740992")]) {
  assert.throws(() => parseSizeA(bad));
}
for (const bad of [{ imageByte: 1 }, {}, { imageBytes: true }, { imageBytes: "5" }, { imageBytes: 0 }, null, []]) {
  const invalid = structuredClone(profile); invalid.budgets.build = bad;
  assert.throws(() => buildReport({ ...args, sizeText: ZENOH_SIZE_A, imageBytes: 100, partitionBytes: 200, profile: invalid, policy }));
}
for (const budgets of [{ basis: "test", buid: { imageBytes: 1 } }, { basis: null }, { basis: "" }, { basis: 1 }]) {
  assert.throws(() => buildReport({ ...args, sizeText: ZENOH_SIZE_A, imageBytes: 100, partitionBytes: 200, profile: { ...profile, budgets }, policy }));
}
assert.throws(() => buildReport({ ...args, sizeText: ZENOH_SIZE_A, imageBytes: 100, partitionBytes: 200, profile, policy: { ...policy, status: "not-applicable" } }));
assert.throws(() => buildReport({ ...args, sizeText: ZENOH_SIZE_A, imageBytes: 100, partitionBytes: 200, profile: { ...profile, transport: "mqtt-espidf" }, policy: { ...policy, status: "not-applicable", reason: "configured C-only carrier qualification image" } }));

// Within budget.
let report = buildReport({ ...args, sizeText: ZENOH_SIZE_A, imageBytes: 670560, partitionBytes: 0x1f0000, profile, policy });
assert.equal(report.enforcement.status, "passed");
assert.equal(report.enforcement.results.length, 4);
assert.equal(report.image.partitionHeadroomBytes, 0x1f0000 - 670560);
assert.equal(report.profile, "esp32c6-zenoh");
assert.equal(report.coreRevision, args.coreRevision);

// A measurement names its configuration: the profile's, or the platform default.
assert.equal(report.configuration.name, "default");
assert.match(report.configuration.sdkconfigSha256, /^[0-9a-f]{64}$/);
assert.equal(report.configuration.networkConfigured, false);
assert.equal("networkPlaceholder" in report.configuration, false);
const production = buildConfiguration({ configuration: "production" }, "CONFIG_X=y\n", "configured");
assert.equal(production.name, "production");
assert.notEqual(production.sdkconfigSha256, report.configuration.sdkconfigSha256);
assert.deepEqual(Object.keys(production), ["name", "sdkconfigSha256", "networkConfigured"]);
assert.equal(production.networkConfigured, true);
// A placeholder says so; it is never reported as an operator-configured image.
const placeholder = buildConfiguration({ configuration: "production" }, "CONFIG_X=y\n", "placeholder");
assert.equal(placeholder.networkConfigured, true);
assert.equal(placeholder.networkPlaceholder, true);
for (const bad of ["", undefined, "yes", "Placeholder"]) assert.throws(() => buildConfiguration({}, "x", bad), /network state/);
assert.throws(() => buildConfiguration({}, "", "configured"), /sdkconfig/);
assert.throws(() => buildConfiguration({ configuration: "" }, "x", "configured"), /configuration name/);
report = buildReport({ ...args, networkState: "placeholder", sizeText: ZENOH_SIZE_A, imageBytes: 670560, partitionBytes: 0x1f0000, profile, policy });
assert.equal(report.configuration.networkPlaceholder, true);

// Runtime budgets are floors a device run enforces; the writer validates them and ignores them in the build verdict.
const withRuntime = structuredClone(profile);
withRuntime.budgets.runtime = { minimumFreeHeapBytes: 242000, stackRemainingBytes: 2000 };
report = buildReport({ ...args, sizeText: ZENOH_SIZE_A, imageBytes: 670560, partitionBytes: 0x1f0000, profile: withRuntime, policy });
assert.equal(report.enforcement.results.length, 4);
for (const bad of [{}, { minimumFreeHeapBytes: 0 }, { stackRemaining: 1 }, { stackRemainingBytes: "5" }, null, []]) {
  const invalid = structuredClone(profile); invalid.budgets.runtime = bad;
  assert.throws(() => buildReport({ ...args, sizeText: ZENOH_SIZE_A, imageBytes: 670560, partitionBytes: 0x1f0000, profile: invalid, policy }), /runtime budgets/);
}

// One metric over budget fails the whole report and names the metric.
const tight = structuredClone(profile);
tight.budgets.build.dramBssBytes = 69000;
report = buildReport({ ...args, sizeText: ZENOH_SIZE_A, imageBytes: 670560, partitionBytes: 0x1f0000, profile: tight, policy });
assert.equal(report.enforcement.status, "failed");
assert.deepEqual(report.enforcement.results.filter(result => !result.passed).map(result => result.metric), ["dramBssBytes"]);
assert.ok(report.enforcement.results.find(result => result.metric === "dramBssBytes").headroomBytes < 0);

// Exactly at the budget passes.
const exact = structuredClone(profile);
exact.budgets.build.imageBytes = 670560;
assert.equal(verdicts(metrics, exact.budgets.build).find(result => result.metric === "imageBytes").passed, true);

// A configured qualification variant is reported, not gated.
report = buildReport({ ...args, sizeText: ZENOH_SIZE_A, imageBytes: 952960, partitionBytes: 0x1f0000, profile: tight, policy: { ...policy, status: "not-applicable", reason: "configured C-only carrier qualification image" } });
assert.equal(report.enforcement.status, "not-applicable");
assert.equal(report.budgets, null);
assert.equal(report.metrics.imageBytes, 952960);

// A profile without budgets says so and never claims a pass.
const unbudgeted = structuredClone(profile);
delete unbudgeted.budgets;
report = buildReport({ ...args, sizeText: ZENOH_SIZE_A, imageBytes: 670560, partitionBytes: 0x1f0000, profile: unbudgeted, policy });
assert.equal(report.enforcement.status, "not-configured");

console.log("write-size-report: all cases passed");
